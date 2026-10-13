#!/bin/bash
# bin/utilization-quiet.sh — BH-4012 (BH-3988.4): the daily went-quiet alert.
# Hub only, at 07:20Z (cron/lanes/725-utilization-quiet.cron). For every
# fleet.conf project it asks whether the project has had free build slots and
# no ready work for the whole window, after shipping the week before, and says
# so once.
#
# One run, under `flock -n locks/utilization-quiet.lock` (dedupe, never a wait):
#   1. the project list from bin/fleet-projects-or-alert.sh; an unreadable
#      fleet.conf is that helper's ALERTS line and rc 1.
#   2. per project:
#      rows    utilization_rows <p> <now - UTIL_QUIET_WINDOW_H> (the history
#              form of GET /api/utilization). rc 2 (no rows) is 0 rows; rc 1,
#              or a `truncated:true` answer, is unmeasured.
#      merges  GET /api/metrics/dora?project=<p> twice, days=<window days +
#              UTIL_QUIET_PRIOR_DAYS> minus days=<window days>. A read that
#              fails or has no `.projects` array is unmeasured; a project
#              absent from an answered `.projects` merged 0.
#      verdict util_quiet (bin/lib/utilization-quiet.sh).
#   3. quiet       bin/lane-alert.sh --id util-went-quiet-<p> --severity warn.
#                  An open id is counted, not re-sent, so a project that stays
#                  quiet is told once (the cron is daily on top of that).
#      not-quiet   --resolve --id util-went-quiet-<p> (silent unless open).
#      unmeasured  a log line, and the project joins ONE util-quiet-unmeasured
#                  warn. It NEVER resolves util-went-quiet-<p>: not knowing is
#                  not the same as having ready work again.
#      A run where every project was measured resolves util-quiet-unmeasured.
# Never calls gh and never calls a model; the alert text is fixed.
#
# Summary line (logs/utilization-quiet.log): <ts> disabled | <ts> busy |
#   <ts> projects=N quiet=N not_quiet=N unmeasured=N
#
# Knobs (settings rows through lane_env_apply; the literals are the documented
# fallbacks, and a value that is not an integer falls back with a log line):
#   UTIL_QUIET_WINDOW_H (72), UTIL_QUIET_PRIOR_DAYS (7), UTIL_QUIET_MIN_ROWS
#   (60, fewer hourly rows than this is unmeasured), UTIL_QUIET_ENABLED (1,
#   0 = disabled).
# Test seam, honoured only under HARNESS_TEST_SANDBOX=1: UTIL_NOW (epoch
# seconds, all digits) replaces the clock.
#
# OFF: flags/lane-off-utilization-quiet (bin/harness-ctl.sh off
# utilization-quiet, read by lane_gate_or_exit) or UTIL_QUIET_ENABLED=0.
# Registry: catalog/lanes.d/utilization-quiet.json.
# Doc: docs/notes/2026-10-03-BH-3988-went-quiet-alert.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/utilization-quiet.sh" 2>/dev/null || true
}

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit utilization-quiet
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply utilization-quiet
command -v util_quiet >/dev/null 2>&1 || util_quiet() { printf 'unmeasured\tpredicate lib did not load\n'; }

mkdir -p "$H/logs" 2>/dev/null
LOG="$H/logs/utilization-quiet.log"
summary() { printf '%s%s\n' "$(date -u +%FT%TZ)" "${1:+ $1}" >> "$LOG"; }

[ "${UTIL_QUIET_ENABLED:-1}" = 0 ] && { summary disabled; exit 0; }
mkdir -p "$H/locks" 2>/dev/null
exec 9>"$H/locks/utilization-quiet.lock"
flock -n 9 || { summary busy; exit 0; }

NOW=$(date -u +%s)
[ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ "${UTIL_NOW:-}" =~ ^[0-9]+$ ]] && NOW=$UTIL_NOW
# knob <ENV> <fallback> — the knob's value when it is a non-negative integer,
# else the fallback plus a log line.
knob() {
  local v="${!1:-}"
  [ -z "$v" ] && { echo "$2"; return; }
  [[ "$v" =~ ^[0-9]+$ ]] && { echo "$v"; return; }
  summary "$1=$v is not an integer, using $2"
  echo "$2"
}
WINDOW_H=$(knob UTIL_QUIET_WINDOW_H 72)
PRIOR_DAYS=$(knob UTIL_QUIET_PRIOR_DAYS 7)
MIN_ROWS=$(knob UTIL_QUIET_MIN_ROWS 60)
# DORA takes whole days: the window rounded up.
WD=$(( (WINDOW_H + 23) / 24 ))
SINCE=$(date -u -d "@$(( NOW - WINDOW_H * 3600 ))" +%FT%TZ)

PROJECTS=$("$H/bin/fleet-projects-or-alert.sh" utilization-quiet) || exit 1

# merged <project> <days> — that project's DORA merge count over <days>, or
# nothing (rc 1) when the read failed or the answer has no .projects array.
merged() {
  local p out
  p=$(jq -rn --arg v "$1" '$v|@uri') || return 1
  out=$(_jobs_req GET "/api/metrics/dora?project=$p&days=$2" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -er --arg p "$1" '
    if (.projects | type) != "array" then empty
    else ([.projects[] | select(.project == $p)][0]) as $e
      | if $e == null then 0
        elif ($e.merged | type) == "number" then $e.merged
        else empty end
    end' 2>/dev/null
}

# board <project> — where the project's ready work would show up. Never a
# made-up URL (D26): `not configured` when fleet.conf cannot say.
board() {
  local prefix url repo
  prefix=$("$H/bin/fleet-conf.sh" "$1" board_prefix 2>/dev/null)
  if [ -n "$prefix" ] && [ "$prefix" != "-" ]; then
    url=$("$H/bin/fleet-conf.sh" "$1" prod 2>/dev/null)
    [ -n "$url" ] && [ "$url" != "-" ] && { echo "$url"; return; }
  else
    repo=$("$H/bin/fleet-conf.sh" "$1" repo 2>/dev/null)
    [ -n "$repo" ] && [ "$repo" != "-" ] \
      && { echo "https://github.com/$repo/issues?q=is%3Aopen+label%3Aai-build"; return; }
  fi
  echo "not configured"
}

n=0 quiet=0 notquiet=0 unmeasured=0 UNMEASURED=""
for p in $PROJECTS; do
  n=$((n+1))
  res="" why="" rows=""
  out=$(utilization_rows "$p" "$SINCE" 2>/dev/null); rc=$?
  case "$rc" in
    0) if [ "$(printf '%s' "$out" | jq -r '.truncated' 2>/dev/null)" = true ]; then
         res=unmeasured why="rows truncated"
       else
         # An old worker ignores the params and answers every project's newest
         # row: only this project's rows count.
         rows=$(printf '%s' "$out" | jq -c --arg p "$p" '[.rows[] | select(.project == $p)]' 2>/dev/null)
       fi ;;
    2) rows='[]' ;;
    *) res=unmeasured why="utilization read failed" ;;
  esac
  if [ -z "$res" ]; then
    merges=x
    if long=$(merged "$p" "$(( WD + PRIOR_DAYS ))") && short=$(merged "$p" "$WD") \
      && [[ "$long" =~ ^[0-9]+$ ]] && [[ "$short" =~ ^[0-9]+$ ]]; then
      # Negative when a merge left the short window between the two reads:
      # util_quiet answers unmeasured for it, never quiet.
      merges=$(( long - short ))
    fi
    IFS=$'\t' read -r res why <<< "$(util_quiet "$rows" "$merges" "$MIN_ROWS")"
  fi
  case "$res" in
    quiet)
      quiet=$((quiet+1))
      last=$(printf '%s' "$rows" | jq -r '[.[] | select((.payload.tickets.ready | type) == "number" and .payload.tickets.ready > 0) | .hour] | last // "not in window"' 2>/dev/null)
      "$H/bin/lane-alert.sh" --id "util-went-quiet-$p" --severity warn utilization-quiet \
        "$p has had free slots and no ready work for ${WINDOW_H}h (last ready: ${last:-not in window}), after $merges merges the week before. Board: $(board "$p")" ;;
    not-quiet)
      notquiet=$((notquiet+1))
      "$H/bin/lane-alert.sh" --resolve --id "util-went-quiet-$p" utilization-quiet \
        "$p has ready work or recent activity again ($why)." ;;
    *)
      unmeasured=$((unmeasured+1))
      summary "unmeasured project=$p why=${why:-no answer}"
      UNMEASURED="${UNMEASURED:+$UNMEASURED, }$p (${why:-no answer})" ;;
  esac
done

if [ -n "$UNMEASURED" ]; then
  "$H/bin/lane-alert.sh" --id util-quiet-unmeasured --severity warn utilization-quiet \
    "Went-quiet check could not measure: $UNMEASURED. An outage here hides the went-quiet signal."
else
  "$H/bin/lane-alert.sh" --resolve --id util-quiet-unmeasured utilization-quiet \
    "Went-quiet check measured every project again."
fi

summary "projects=$n quiet=$quiet not_quiet=$notquiet unmeasured=$unmeasured"
exit 0
