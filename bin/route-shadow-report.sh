#!/bin/bash
# bin/route-shadow-report.sh [--window <hours>] [--no-send] [--print]
#
# P4, THE NIGHTLY SHADOW-ROUTING REPORT. Every build since P4 records what the
# plan-driven route rules WOULD have picked beside what it actually ran on
# (route_shadow rows, bin/lib/route-rules.sh). This lane reads the last window
# of those rows from the harness-jobs worker and says, in a few lines, what a
# live router would have done: how many builds would have left the live
# execute model, to which role, per project and per rule. It is the evidence
# the "turn it on?" decision is made from (docs/ROUTE-RULES.md). Read-only: it
# changes no rule, no route and no build.
#
# OUTPUT
#   state/route-shadow/latest.txt   the message, verbatim
#   state/route-shadow/<date>.json  the same numbers as JSON, with the window
#   one fleet-topic beat carrying the text — the {kind:fleet_alert,
#   project:fleet, triaged:true} pass-through bin/dora-digest.sh uses for a
#   daily digest. --no-send writes the files and posts nothing, and so does a
#   window with zero builds.
#
# AN UNREADABLE WORKER IS "n/a", NEVER "0 builds": a quiet day and a report
# that could not read its source must not look alike. Nothing is posted then.
# Every path exits 0: a report that can fail a cron tick is a report people
# turn off.
#
# Knobs (catalog/lanes.d/route-shadow-report.json; settings rows via lane_env_apply):
#   ROUTE_SHADOW_REPORT_WINDOW_H   the trailing window in hours (default 24)
#   ROUTE_SHADOW_REPORT_SEND       1 = post the beat (default); 0 = files only
set -uo pipefail
H="${HARNESS:-/root/harness}"

# >>> lane gate — one off-switch and one source of numbers for this lane.
# lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-route-shadow-report
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN. Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off route-shadow-report.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit route-shadow-report
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    route-shadow-report
# <<< lane gate

WINDOW="" SEND="" PRINT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --window) WINDOW="${2:-}"; shift 2 ;;
    --no-send) SEND=0; shift ;;
    --print) PRINT=1; shift ;;
    *) echo "usage: route-shadow-report.sh [--window <hours>] [--no-send] [--print]" >&2; exit 2 ;;
  esac
done
WINDOW="${WINDOW:-${ROUTE_SHADOW_REPORT_WINDOW_H:-24}}"
case "$WINDOW" in ''|*[!0-9]*|0) WINDOW=24 ;; esac
SEND="${SEND:-${ROUTE_SHADOW_REPORT_SEND:-1}}"

OUT_DIR="$H/state/route-shadow"
mkdir -p "$OUT_DIR" "$H/logs" 2>/dev/null
NOW=$(date -u +%s)
SINCE_S=$((NOW - WINDOW * 3600))
SINCE=$(date -u -d "@$SINCE_S" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$SINCE_S" +%Y-%m-%dT%H:%M:%SZ)
DATE_TAG=$(date -u +%Y-%m-%d)

# shellcheck disable=SC1091
. "$H/bin/jobs-client.sh" >/dev/null 2>&1 || true
RESP=""
if command -v route_shadow_list >/dev/null 2>&1; then
  RESP=$(JOBS_ALERT=0 route_shadow_list "$SINCE" "" 2000 2>/dev/null) || RESP=""
fi

# `[ -n ]` first: jq 1.6 exits 0 on `jq -e` over empty input, which would read
# an empty 200 as a valid answer with no rows (review of #2288, I3).
if ! { [ -n "$RESP" ] && printf '%s' "$RESP" | jq -e '(.rows | type) == "array"' >/dev/null 2>&1; }; then
  TEXT="Route shadow (P4, log only) — last ${WINDOW}h
builds: n/a (GET /api/route-shadow was unreadable — worker down or HARNESS_SECRET missing on $(hostname 2>/dev/null))"
  printf '%s\n' "$TEXT" > "$OUT_DIR/latest.txt"
  [ "$PRINT" = 1 ] && printf '%s\n' "$TEXT"
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [route-shadow-report] window=${WINDOW}h rows=n/a beat=not-sent" >> "$H/logs/route-shadow-report.log"
  exit 0
fi

SUMMARY=$(printf '%s' "$RESP" | jq -c --arg since "$SINCE" --arg w "$WINDOW" '
  .rows as $r
  | ($r | length) as $n
  | def pct($a; $b): if $b == 0 then 0 else (($a * 100 / $b) | round) end;
  {window_h: ($w | tonumber), since: $since, builds: $n, truncated: (.truncated // false),
   moved: ([$r[] | select((.would_execute_role // "build.execute") != "build.execute")] | length),
   differs: ([$r[] | select(.differs == 1)] | length),
   bumped: ([$r[] | select((.bumped // "") != "")] | length),
   by_role: ([$r[] | select((.would_execute_role // "build.execute") != "build.execute") | .would_execute_role]
             | group_by(.) | map({role: .[0], n: length})),
   by_project: ($r | group_by(.project) | map({project: .[0].project, n: length,
               moved: ([.[] | select((.would_execute_role // "build.execute") != "build.execute")] | length)})),
   by_rule: ($r | group_by(.rule // "") | map({rule: (.[0].rule // ""), n: length}) | sort_by(-.n, .rule))}
  | .moved_pct = pct(.moved; .builds)
  | .by_role |= map(.pct = pct(.n; $n))
  | .by_project |= map(.pct = pct(.moved; .n))')

TEXT=$(printf '%s' "$SUMMARY" | jq -r '
  "Route shadow (P4, log only) — last \(.window_h)h",
  "builds: \(.builds)\(if .truncated then " (truncated at 2000 rows)" else "" end)",
  "would move off the live execute model: \(.moved) (\(.moved_pct)%)",
  (.by_role[] | "  \(.role): \(.n) (\(.pct)%)"),
  "would run a different model than it ran: \(.differs)",
  "escalated by a bump rule: \(.bumped)",
  "by project (builds, would move):",
  (.by_project[] | "  \(.project | . + (" " * ([18 - length, 1] | max))) \(.n)  \(.moved) (\(.pct)%)"),
  "by rule:",
  (.by_rule[] | "  \((if .rule == "" then "(no rule)" else .rule end) | . + (" " * ([18 - length, 1] | max))) \(.n)")')

printf '%s\n' "$TEXT" > "$OUT_DIR/latest.txt"
printf '%s\n' "$SUMMARY" > "$OUT_DIR/$DATE_TAG.json"
[ "$PRINT" = 1 ] && printf '%s\n' "$TEXT"

# A day with no builds writes its files and posts nothing: "0 builds" every
# quiet night is noise in the fleet topic (review of #2288).
SENT=not-sent
if [ "$SEND" = 1 ] && [ "$(jq -r .builds <<<"$SUMMARY")" != 0 ] && [ -x "$H/bin/beat.sh" ]; then
  "$H/bin/beat.sh" "$(jq -nc --arg akey "route-shadow-report:$DATE_TAG" --arg l "$TEXT" \
    '{kind:"fleet_alert",project:"fleet",triaged:true,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  SENT=sent
fi
echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [route-shadow-report] window=${WINDOW}h builds=$(jq -r .builds <<<"$SUMMARY") moved=$(jq -r .moved <<<"$SUMMARY") beat=$SENT" >> "$H/logs/route-shadow-report.log"
exit 0
