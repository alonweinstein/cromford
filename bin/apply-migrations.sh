#!/bin/bash
# Self-serve migration driver (wave 2, 2026-07-27). Runs on each worker box for
# its own project: asks the app's internal migration endpoint what's pending in
# the DEPLOYED bundle and triggers application. The box holds NO db credential —
# the app applies its own merged+deployed SQL server-side (spec:
# docs/MIGRATION_ENDPOINT_SPEC.html). Requires MIGRATION_TOKEN in the project
# env; silently no-ops until it's provisioned (the endpoint fail-closes anyway).
# usage: apply-migrations.sh <project>                  (cron */15)
#        apply-migrations.sh <project> --files <f...>   (these files, now)
#
# THE TWO MODES, AND WHY THE SECOND ONE IS LOUD (BH-375, the hotfix lane). The
# cron mode is a background tick on eleven boxes, most with no endpoint at all, so
# every unhappy answer is a quiet `exit 0`. That silence is right for a tick and
# wrong for a caller that named two files and has to decide whether a hotfix went
# live, so `--files` reports: one JSON line per requested basename in the order
# given, each keeping its own status word, and rc 0 only when every one came back
# `applied` or `already-applied`. The POST is the SAME code in both modes
# (apply_one), so the cron path's refused-memory, log line and beat cannot drift.
set -uo pipefail
PROJECT="${1:?usage: apply-migrations.sh <project> [--files <file...>]}"; shift
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
LOG="$HARNESS/logs/migrations.log"
ALERTS="$HARNESS/logs/ALERTS.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

MODE=cron; REQ=()
if [ "${1:-}" = "--files" ]; then
  shift; MODE=files; REQ=("$@")
  [ "${#REQ[@]}" -gt 0 ] || { echo "usage: apply-migrations.sh <project> --files <file...>" >&2; exit 2; }
fi

# A tick that cannot do anything says nothing (six crontab lines on endpoint-less
# boxes depend on that); a --files caller always gets an answer. The one loud
# exception is generic_base below: an in-app board with no app base.
NO_ENDPOINT() { [ "$MODE" = files ] || exit 0; echo '{"status":"no-endpoint"}'; exit 5; }

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-apply-migrations
# (or its project row) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off apply-migrations <project>.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
[ "${MODE:-cron}" = cron ] && command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit apply-migrations "$PROJECT"
[ "${MODE:-cron}" = cron ] && command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    apply-migrations "$PROJECT"

set -a
[ -f "$HENV/global.env" ] && . "$HENV/global.env"
[ -f "$HENV/$PROJECT.env" ] && . "$HENV/$PROJECT.env"
set +a
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
[ "${MODE:-cron}" = cron ] && command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    apply-migrations "$PROJECT"

# generic_base — every project the four arms below do not name (BH-1956). A
# project whose fleet.conf row has a real board prefix is an in-app board, so it
# has an app, so its env file names the app's base in exactly one
# *_APP_BASE= / *_API_BASE= line (bin/lib/internal-token.sh). A "-" prefix, a
# project fleet.conf does not know, or an unreadable registry stays the quiet
# NO_ENDPOINT it always was. An in-app board with no base, or with two, used to
# be that same silent exit 0: a migration lane that never ran and never said so.
# Now the cron tick says so, once a day per project; --files keeps its
# no-endpoint answer. Two candidates are never guessed between.
generic_base() {
  local PFX V WHY STAMPF
  PFX=$("$(dirname "${BASH_SOURCE[0]}")/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null) || NO_ENDPOINT
  { [ -n "$PFX" ] && [ "$PFX" != "-" ]; } || NO_ENDPOINT
  # shellcheck source=bin/lib/internal-token.sh
  . "${HARNESS}/bin/lib/internal-token.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/internal-token.sh" 2>/dev/null \
    || WHY="bin/lib/internal-token.sh is missing"
  BASE=""
  [ -r "$HENV/$PROJECT.env" ] || WHY="${WHY:-the file is missing or unreadable}"
  if [ -z "${WHY:-}" ]; then
    V=$(app_base_var "$HENV/$PROJECT.env"); case $? in
      0) BASE="${!V:-}"; [ -n "$BASE" ] || WHY="$V is empty" ;;
      1) WHY="no *_APP_BASE/*_API_BASE line" ;;
      *) WHY="ambiguous: 2+ *_APP_BASE/*_API_BASE lines: $(env_vars_matching "$APP_BASE_RE" "$HENV/$PROJECT.env" | paste -sd, -)" ;;
    esac
  fi
  [ -n "$BASE" ] && return 0
  [ "$MODE" = files ] && NO_ENDPOINT
  STAMPF="$HARNESS/state/apply-migrations-nobase-$PROJECT.stamp"
  [ -n "$(find "$STAMPF" -mmin -1440 2>/dev/null)" ] && exit 0
  mkdir -p "$HARNESS/state" "$HARNESS/logs" 2>/dev/null
  # Written BEFORE the stamp: a failed append leaves no stamp, so the next tick retries.
  echo "$(STAMP) [$PROJECT] apply-migrations: in-app board (fleet.conf prefix $PFX) but no usable app base in env/$PROJECT.env ($WHY) — migration lane inert; leave exactly one *_APP_BASE= (or *_API_BASE=) line naming the app's URL" >> "$ALERTS" \
    && touch "$STAMPF" 2>/dev/null
  exit 0
}

case "$PROJECT" in
  project-1)   BASE="${PROJECT_1_API_BASE:-}" ;;
  project-2) BASE="${PROJECT_2_APP_BASE:-}" ;;
  project-3)       BASE="${PROJECT_3_APP_BASE:-}" ;;
  project-4)       BASE="${PROJECT_4_API_BASE:-}" ;;
  *) generic_base ;;
esac
TOKEN="${MIGRATION_TOKEN:-}"
[ -n "$BASE" ] && [ -n "$TOKEN" ] || NO_ENDPOINT   # not provisioned yet

exec 8>"$HARNESS/locks/apply-migrations-$PROJECT.lock"
# Dedupe, never a queue: the */15 tick and a hotfix stage can both want this
# project. Whoever is second says so and leaves.
flock -n 8 || { [ "$MODE" = files ] && exit 75; exit 0; }
# >>> BH-1062 wake backstop
# ONLY the cron tick may skip. A --files caller is the hotfix lane (BH-375) and
# always gets its answer, so the guard is on MODE, not on the lib. Window 3600 =
# the deploy class cuts this */15 tick to an hourly backstop; every unclear
# answer (no lib, no flag, no stamp, kill switch) still means RUN.
# shellcheck source=bin/lib/wake-lanes.sh
[ -r "$HARNESS/bin/lib/wake-lanes.sh" ] && . "$HARNESS/bin/lib/wake-lanes.sh"
[ "$MODE" = cron ] && command -v wake_backstop_skip >/dev/null 2>&1 && wake_backstop_skip apply-migrations "$PROJECT" 3600 && exit 0
# <<< BH-1062 wake backstop

API() { curl -sf -m 60 -H "Authorization: Bearer $TOKEN" -H "User-Agent: curl/8" "$@"; }

# Terminal-refusal memory: a classifier verdict is deterministic per checksum, so
# re-POSTing an unchanged refused file every 15 min can never succeed — it only
# re-fires the NEEDS-HUMAN alert (the 2026-08-06 pb67 storm). Remember refusals
# per (file, checksum); skip quietly until the file changes or a human clears
# state/migrations-refused-$PROJECT.txt (e.g. after a hand-apply + mark-external).
REFUSED_STATE="$HARNESS/state/migrations-refused-$PROJECT.txt"
mkdir -p "$HARNESS/state" "$HARNESS/logs" 2>/dev/null; touch "$REFUSED_STATE"

# apply_one <file> <checksum> — the POST and everything that hangs off it.
# Leaves its answer in AO_STATUS / AO_OK / AO_RES; never exits, never decides.
AO_STATUS=""; AO_OK=false; AO_RES="{}"
apply_one() {
  local F="$1" SUM="$2" RES ST OK FLAGGED RLSFIX
  AO_STATUS=""; AO_OK=false; AO_RES="{}"
  if grep -qF "$F $SUM" "$REFUSED_STATE"; then
    echo "$(STAMP) [$PROJECT] apply $F: skipped (previously refused, unchanged — awaiting human)" >> "$LOG"
    AO_STATUS="refused"; AO_OK=false; AO_RES='{"note":"previously refused, unchanged"}'
    return 0
  fi
  RES=$(API -X POST -H 'Content-Type: application/json' -d "$(jq -nc --arg f "$F" '{filename:$f, actor:"watcher"}')" \
        "$BASE/api/internal/migrations/apply") || {
          echo "$(STAMP) [$PROJECT] apply $F: request failed" >> "$LOG"
          AO_STATUS="request failed"; AO_OK=false; AO_RES='{}'; return 0; }
  ST=$(jq -r '.status // "unknown"' <<<"$RES")
  OK=$(jq -r '.ok // false' <<<"$RES")
  FLAGGED=$(jq -r '(.flagged // []) | length' <<<"$RES")
  RLSFIX=$(jq -r '(.rlsWarnings // []) | length' <<<"$RES")
  echo "$(STAMP) [$PROJECT] apply $F: status=$ST ok=$OK flagged=$FLAGGED rlsAuto=$RLSFIX" >> "$LOG"
  case "$ST" in
    applied|already-applied)
      "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "migapply:$PROJECT:$F" \
        --arg l "migration $F applied via self-serve endpoint (flagged=$FLAGGED rlsAuto=$RLSFIX)" \
        '{kind:"migration_applied",project:$p,akey:$akey,line:$l}')" ;;
    in-progress) ;;  # another caller owns it; next tick reconciles
    refused)
      # Terminal for this checksum: alert ONCE, then stay quiet until the file changes.
      echo "$F $SUM" >> "$REFUSED_STATE"
      echo "$(STAMP) [$PROJECT] MIGRATION NEEDS HUMAN (once per version): $F status=refused $(jq -c '.reason // .perStatement[-1] // empty' <<<"$RES" | head -c 300)" >> "$ALERTS" ;;
    *)  # failed / checksum-mismatch → transient-or-human; keep the guard pinging
      echo "$(STAMP) [$PROJECT] MIGRATION NEEDS HUMAN: $F status=$ST $(jq -c '.reason // .perStatement[-1] // empty' <<<"$RES" | head -c 300)" >> "$ALERTS" ;;
  esac
  AO_STATUS="$ST"; AO_OK="$OK"
  jq -e . >/dev/null 2>&1 <<<"$RES" && AO_RES="$RES" || AO_RES='{}'
  return 0
}

# One GET /status. A tick that cannot read it waits for the next tick; a --files
# caller is told per file that we could not even ask. The JSON check is part of
# "could not read it": a 200 carrying a maintenance page or a WAF interstitial
# passes curl -sf, then every jq lookup below comes back empty, which reads as
# "none of your files are pending" and would be recorded as deferred-to-deploy
# with exit 0. An answer we cannot parse is a failed request, not an empty one.
if ! STATUS=$(API "$BASE/api/internal/migrations/status") || ! jq -e . >/dev/null 2>&1 <<<"$STATUS"; then
  [ "$MODE" = files ] || exit 0
  for RAW in "${REQ[@]}"; do
    jq -nc --arg f "$(basename "$RAW")" '{filename:$f,status:"request failed",ok:false}'
  done
  exit 1
fi

if [ "$MODE" = cron ]; then
  PENDING=$(jq -r '.pending[]? | "\(.filename) \(.checksum // "-")"' <<<"$STATUS" 2>/dev/null) || exit 0
  [ -n "$PENDING" ] || exit 0
  while IFS=' ' read -r F SUM; do
    [ -n "$F" ] || continue
    apply_one "$F" "$SUM"
  done <<<"$PENDING"
  exit 0
fi

# --files: in the order given, one JSON line each, and an honest exit code.
RC=0
for RAW in "${REQ[@]}"; do
  F=$(basename "$RAW")
  SUM=$(jq -r --arg f "$F" 'first(.pending[]? | select(.filename==$f) | (.checksum // "-")) // empty' <<<"$STATUS" 2>/dev/null)
  if [ -n "$SUM" ]; then
    apply_one "$F" "$SUM"
    # --argjson refuses anything that is not JSON; an app answering ok:"yes"
    # must not take the whole result line down with it.
    case "$AO_OK" in true|false) ;; *) AO_OK=false ;; esac
    jq -nc --arg f "$F" --arg s "$AO_STATUS" --argjson ok "$AO_OK" --argjson r "$AO_RES" \
      '{filename:$f,status:$s,ok:$ok,response:$r}'
    # The WORD decides, never .ok — the endpoint has answered ok:true beside a
    # refused status, and a hotfix caller must read that as "we did not do it".
    case "$AO_STATUS" in applied|already-applied) ;; *) RC=1 ;; esac
  elif jq -e --arg f "$F" '[.applied[]? | select(.filename==$f)] | length > 0' <<<"$STATUS" >/dev/null 2>&1; then
    jq -nc --arg f "$F" '{filename:$f,status:"already-applied"}'
  else
    # Not in the deployed bundle yet (the spec's rule: a file is pending only
    # once the merge that carries it is live) or simply not a file this app has.
    jq -nc --arg f "$F" '{filename:$f,status:"not-pending"}'
    RC=1
  fi
done
exit "$RC"
