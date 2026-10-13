#!/bin/bash
# bin/runner-routes-seed.sh — BH-1766 (BH-1749.4): write THIS box's live
# RUNNER_<STAGE> / RUNNER_<STAGE>_FALLBACK values as hub stage.<stage> ladders
# in model_routes. One-shot, operator-run, on the hub. No cron line.
#
# usage: runner-routes-seed.sh [--apply]
#   (no flag)  print the ladder each stage would get, and whether it differs
#   --apply    PUT every ladder that differs via /api/model-routes, with this
#              box's name as the actor (it lands in updated_by)
#
# WHY A SCRIPT AND NOT A SEED. worker/jobs/schema.sql seeds every stage.* role
# at today's template default (claude, fallback codex). A box's own values —
# the hub's RUNNER_TRIAGE=grok — are a decision somebody made on that box, so
# they reach the table as an audited write naming the box, never blind in SQL.
#
# WHERE THE VALUES COME FROM. The process env first, else the RUNNER_* line of
# $(harness_env_dir)/global.env, read with sed and NEVER sourced: that file
# holds secrets. Quotes and spaces are stripped and the value lowercased. A
# stage with neither value is left alone. A fallback with no primary means the
# primary is claude (agent-call's default runner). No fallback, or a fallback
# equal to the primary, is a one-rung ladder: that is what the box runs.
#
# THE MODEL ON EACH RUNG is never invented here. A claude rung takes the first
# claude model on the stage's current hub ladder, else rung 0 of claude.ladder.
# Any other runner takes rung 0 of <runner>.default. No answer = the stage is
# refused (rc 1), never a guess.
#
# ORDER: validate every value, then read every ladder, then write. One invalid
# runner or one unresolvable model anywhere and nothing is written.
#
# EXIT: 0 every stage unchanged / would write / written / no box value;
#       1 a runner or model refused, or a PUT answered non-200 (409 = somebody
#         edited the ladder between our read and our write; rerun);
#       2 a worker read failed (never reported as "unchanged").
# Tests only: HARNESS, HARNESS_ENV_DIR, JOBS_URL.
set -uo pipefail
H="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"

APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  "") ;;
  *) echo "usage: runner-routes-seed.sh [--apply]" >&2; exit 2 ;;
esac

# shellcheck source=bin/lib/env-path.sh
. "$HERE/lib/env-path.sh" || { echo "runner-routes-seed: cannot load $HERE/lib/env-path.sh" >&2; exit 2; }
# shellcheck source=/dev/null
. "$HERE/jobs-client.sh" >/dev/null 2>&1 || { echo "runner-routes-seed: cannot load $HERE/jobs-client.sh" >&2; exit 2; }
# shellcheck source=bin/lib/model-route.sh
. "$HERE/lib/model-route.sh" || { echo "runner-routes-seed: cannot load $HERE/lib/model-route.sh" >&2; exit 2; }
command -v _jobs_req >/dev/null 2>&1 || { echo "runner-routes-seed: jobs client did not load" >&2; exit 2; }

# The six stages env-templates/lanes/030-llm-runners.env.example carries a
# RUNNER_*_FALLBACK for, and the six stage.* roles schema.sql seeds.
STAGES="triage plan preplan execute review fix"
VALID=" claude codex openrouter grok fireworks "
ENVF="$(harness_env_dir "$H")/global.env"

# box_value <VAR>: the env value, else global.env's, normalised; empty = unset.
box_value() {
  local var="$1" v=""
  if [ -n "${!var+x}" ]; then v="${!var}"
  elif [ -r "$ENVF" ]; then v=$(sed -n "s/^$var=//p" "$ENVF" | tail -1)
    # A trailing "  # note" is a comment, as it is when the file is sourced
    # (the hub's RUNNER_*_FALLBACK lines carry one), never part of the value.
    v=$(printf '%s' "$v" | sed -E 's/[[:space:]]+#.*$//')
  fi
  printf '%s' "$v" | tr -d "\"' \t\r" | tr '[:upper:]' '[:lower:]'
}

# ── 1. values, and every refusal before any network call ─────────────────────
REFUSED=0
declare -A PRI FB
for s in $STAGES; do
  S=$(printf '%s' "$s" | tr '[:lower:]' '[:upper:]')
  p=$(box_value "RUNNER_$S"); f=$(box_value "RUNNER_${S}_FALLBACK")
  for pair in "RUNNER_$S=$p" "RUNNER_${S}_FALLBACK=$f"; do
    v="${pair#*=}"
    [ -z "$v" ] || case "$VALID" in *" $v "*) ;; *)
      echo "refused: $pair is not one of claude|codex|openrouter|grok|fireworks" >&2; REFUSED=1 ;;
    esac
  done
  [ -n "$p$f" ] || continue
  PRI[$s]="${p:-claude}"
  [ "$f" = "${PRI[$s]}" ] && f=""
  FB[$s]="$f"
done
[ "$REFUSED" = 0 ] || exit 1

# ── 2. read: current ladders, and a model for every rung ──────────────────────
# _jobs_req writes to a file, not through $(...), so JOBS_HTTP / JOBS_BODY
# survive for the failure message.
TMPF=$(mktemp "${TMPDIR:-/tmp}/runner-routes-seed.XXXXXX") || { echo "runner-routes-seed: mktemp failed" >&2; exit 2; }
trap 'rm -f "$TMPF"' EXIT
get_route() { # get_route <role> -> body on stdout; rc 2 on any failure
  local out rc
  JOBS_ALERT=0 _jobs_req GET "/api/model-routes/$1" > "$TMPF"; rc=$?
  out=$(cat "$TMPF")
  if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | jq -e '(.ladder | type) == "array"' >/dev/null 2>&1; then
    echo "worker read failed for $1: http=${JOBS_HTTP:-none} ${JOBS_BODY:0:200}" >&2
    return 2
  fi
  printf '%s' "$out"
}

model_for() { # model_for <runner> <current-ladder-json>
  local runner="$1" cur="$2" m="" body src=""
  if [ "$runner" = claude ]; then
    m=$(printf '%s' "$cur" | jq -r '[.ladder[] | select(.runner == "claude")][0].model // empty')
    if [ -z "$m" ]; then
      body=$(get_route claude.ladder) || return 2
      m=$(printf '%s' "$body" | jq -r '.ladder[0].model // empty'); src=claude.ladder
    fi
  else
    body=$(get_route "$runner.default") || return 2
    m=$(printf '%s' "$body" | jq -r '.ladder[0].model // empty'); src="$runner.default"
  fi
  [ -n "$m" ] || { echo "refused: no model for runner $runner ($src has no rung 0); PUT one first" >&2; return 1; }
  printf '%s' "$m"
}

declare -A CUR WANT LINE
READFAIL=0
for s in $STAGES; do
  role=$(stage_route_role "$s")
  if [ -z "${PRI[$s]+x}" ]; then echo "$role: no box value, seed row stands"; continue; fi
  CUR[$s]=$(get_route "$role") || { READFAIL=1; continue; }
  m0=$(model_for "${PRI[$s]}" "${CUR[$s]}"); rc=$?
  [ "$rc" = 2 ] && { READFAIL=1; continue; }
  [ "$rc" = 0 ] || { REFUSED=1; continue; }
  WANT[$s]=$(jq -cn --arg r "${PRI[$s]}" --arg m "$m0" '[{model:$m, runner:$r}]')
  LINE[$s]="${PRI[$s]}($m0)"
  if [ -n "${FB[$s]}" ]; then
    m1=$(model_for "${FB[$s]}" "${CUR[$s]}"); rc=$?
    [ "$rc" = 2 ] && { READFAIL=1; continue; }
    [ "$rc" = 0 ] || { REFUSED=1; continue; }
    WANT[$s]=$(printf '%s' "${WANT[$s]}" | jq -c --arg r "${FB[$s]}" --arg m "$m1" '. + [{model:$m, runner:$r}]')
    LINE[$s]="${LINE[$s]} -> ${FB[$s]}($m1)"
  fi
done
[ "$READFAIL" = 0 ] || exit 2
[ "$REFUSED" = 0 ] || exit 1

# ── 3. compare, and (with --apply) write ──────────────────────────────────────
RC=0
for s in $STAGES; do
  [ -n "${WANT[$s]+x}" ] || continue
  role=$(stage_route_role "$s")
  have=$(printf '%s' "${CUR[$s]}" | jq -c '[.ladder[] | {model, runner}]')
  if [ "$have" = "${WANT[$s]}" ]; then echo "$role: ${LINE[$s]}  unchanged"; continue; fi
  if [ "$APPLY" = 0 ]; then echo "$role: ${LINE[$s]}  would write"; continue; fi
  ver=$(printf '%s' "${CUR[$s]}" | jq -r '.scope_version // 0')
  body=$(jq -cn --arg role "$role" --argjson ladder "${WANT[$s]}" --argjson v "$ver" \
    --arg actor "$JOBS_BOX" --arg reason "runner-routes-seed: live RUNNER_* on $JOBS_BOX" \
    '{role:$role, project:null, ladder:$ladder, expected_version:$v, actor:$actor, reason:$reason}')
  if JOBS_ALERT=0 _jobs_req PUT /api/model-routes "$body" >/dev/null && [ "$JOBS_HTTP" = 200 ]; then
    echo "$role: ${LINE[$s]}  written"
  else
    echo "$role: ${LINE[$s]}  NOT written: http=${JOBS_HTTP:-none} ${JOBS_BODY:0:300}" >&2
    RC=1
  fi
done
exit "$RC"
