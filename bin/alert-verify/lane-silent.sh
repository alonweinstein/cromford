#!/bin/bash
# bin/alert-verify/lane-silent.sh — the verify script of the `lane-silent` row of
# alert_family_scripts (BH-2577). Protocol: the header of
# bin/triage-family-scripts.sh; shared reads: bin/lib/alert-verify.sh.
#
# bin/jobs-watchdog.sh's `[jobs-watchdog] LANE SILENT: <project>@<box> ` page. ONE
# worker read (jobs-client.sh lanes). Stale is the worker's own definition
# (2x the lane's cadence, bin/lib/jobs/lanes.sh): live clears it, stale or
# pending still reproduces, and no row, retired, unexpected or a failed read
# is doubt.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
LIB="$HARNESS/bin/lib"
[ -r "$LIB/alert-verify.sh" ] || LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
. "$LIB/alert-verify.sh" || exit 75
M=$(av_field line | av_one '\[jobs-watchdog\] LANE SILENT: [A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+ ') || exit 75
PB=${M#*LANE SILENT: }; PB=${PB% }
P=${PB%@*}; B=${PB#*@}
ROWS=$(JOBS_ALERT=0 "$AV_HARNESS/bin/jobs-client.sh" lanes 2>/dev/null) || exit 75
ROW=$(printf '%s\n' "$ROWS" | awk -F'\t' -v p="$P" -v b="$B" '$1 == p && $2 == b')
[ -n "$ROW" ] && [ "$(printf '%s\n' "$ROW" | wc -l)" -eq 1 ] || exit 75
IFS=$'\t' read -r _ _ ST _ TICK _ <<<"$ROW"
case "$ST" in
  live) echo "lane-silent: $P@$B is live (last tick ${TICK}s ago)" ;;
  stale|pending) exit 1 ;;
  *) exit 75 ;;
esac
