#!/bin/bash
# bin/alert-verify/hb-db-silent.sh — the verify script of the `hb-db-silent` row of
# alert_family_scripts (BH-2577). Protocol: the header of
# bin/triage-family-scripts.sh; shared reads: bin/lib/alert-verify.sh.
#
# bin/heartbeat-reaper.sh's DB page, `<lane> on <box> is silent|overdue: its last
# beat was <N>m ago`. ONE worker read (jobs-client.sh lane-procs). The state is
# the worker's own: fresh or ended clears it, silent or overdue still
# reproduces, and no row, "none", or a failed read is doubt.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
LIB="$HARNESS/bin/lib"
[ -r "$LIB/alert-verify.sh" ] || LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
. "$LIB/alert-verify.sh" || exit 75
M=$(av_field line | av_one '[A-Za-z0-9_.-]+ on [A-Za-z0-9_.-]+ is (silent|overdue): its last beat was [0-9]+m ago') || exit 75
read -r LANE _ BOX _ <<<"$M"
ROWS=$(JOBS_ALERT=0 "$AV_HARNESS/bin/jobs-client.sh" lane-procs 2>/dev/null) || exit 75
ROW=$(printf '%s\n' "$ROWS" | awk -F'\t' -v l="$LANE" -v b="$BOX" '$1 == l && $2 == b')
[ -n "$ROW" ] && [ "$(printf '%s\n' "$ROW" | wc -l)" -eq 1 ] || exit 75
IFS=$'\t' read -r _ _ PST AGE _ <<<"$ROW"
case "$PST" in
  fresh|ended) echo "hb-db-silent: $LANE on $BOX is $PST (last beat ${AGE}s ago)" ;;
  silent|overdue) exit 1 ;;
  *) exit 75 ;;
esac
