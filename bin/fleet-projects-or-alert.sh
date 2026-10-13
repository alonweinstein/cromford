#!/bin/bash
# fleet-projects-or-alert.sh <lane> [--with-board] — the fleet's project list,
# or one loud ALERTS line and rc=1. Never an empty list with rc=0.
#
# WHY THIS EXISTS. `for P in $(fleet-conf.sh --projects); do …` is correct on
# every day the registry is readable, and on the day it is not it iterates zero
# times, finishes, and reports success. That is the same failure the whole
# fleet.conf wave is about — a lane doing nothing, indistinguishable from a lane
# with nothing to do — only now it hits EVERY project at once instead of the
# five that were missing from a hardcoded list. bin/quiesce-for-resize.sh could
# print SAFE_TO_RESIZE having paused no watcher at all.
#
# So every lane that sweeps the fleet reads its list through here:
#   PROJECTS=$("$H/bin/fleet-projects-or-alert.sh" my-lane) || exit 1
#
# One ALERTS line per lane per day (flags/alerted-noregistry-<lane>-<date>),
# because these lanes run on crons as tight as a minute and an alert repeated
# every minute is an alert nobody reads.
set -uo pipefail
LANE="${1:?lane name}"
MODE="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
HR="${HARNESS:-$(cd "$HERE/.." && pwd)}"
SUB=--projects
[ "$MODE" = "--with-board" ] && SUB=--projects-with-board
LIST=$("$HERE/fleet-conf.sh" "$SUB" 2>/dev/null || true)
if [ -n "$LIST" ]; then printf '%s\n' "$LIST"; exit 0; fi
FLAG="$HR/flags/alerted-noregistry-$LANE-$(date -u +%Y%m%d)"
if [ ! -f "$FLAG" ]; then
  mkdir -p "$HR/flags" "$HR/logs" 2>/dev/null
  touch "$FLAG" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$LANE] fleet.conf gave an EMPTY project list — this lane sweeps every project, so it would have swept NOTHING and exited clean. Refusing to run. Check fleet.conf is readable at \$FLEET_CONF, /root/harness/fleet.conf, or next to bin/." >> "$HR/logs/ALERTS.log"
fi
exit 1
