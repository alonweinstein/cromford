#!/bin/bash
# tests/pipeline-health-stuck-queue-test.sh — check 1 of bin/pipeline-health.sh
# ("queued Nm with no spawn") pages for a real queue file only, never for a
# `*.failed.json` PARK beside it (2026-09-28).
#
# bin/fly-pool.sh parks a build it gave up on as <KEY>.failed.json in the same
# state/build-queue/<project>/ directory. Nothing will ever spawn it — that is
# what a park means — and the ticket is often closed by then. The `*.json` glob
# matched it too, so a closed ticket paged "queued with no spawn" every 2h,
# forever. bin/fly-dispatch.sh and bin/fleet-status-push.sh already skip parks.
#
# The block is extracted VERBATIM from bin/pipeline-health.sh between its own
# markers and executed with alert() stubbed, so what is asserted is the alert
# the real code raises, not the source text.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

PH="$DIR/bin/pipeline-health.sh"
A=$(grep -c '^# >>> stuck queue' "$PH")
B=$(grep -c '^# <<< stuck queue' "$PH")
[ "$A" = 1 ] && [ "$B" = 1 ] \
  && ok || bad "bin/pipeline-health.sh must carry exactly one '# >>> stuck queue' … '# <<< stuck queue' block (open=$A close=$B)"
awk '/^# >>> stuck queue/{f=1;next} /^# <<< stuck queue/{exit} f' "$PH" > "$T/block.sh"
grep -q 'stuckqueue:' "$T/block.sh" && ok || bad "the extracted block is not the stuck-queue check"

H="$T/h"
Q="$H/state/build-queue/proj"
mkdir -p "$Q"
NOW=1789000000
OLD=$(( NOW - 3 * 3600 ))
aged() { : > "$1"; touch -d "@$OLD" "$1"; }
aged "$Q/PR-10.json"           # a real queued build nobody picked up: pages
aged "$Q/PR-11.failed.json"    # a park: nothing will ever spawn it
aged "$Q/PR-12.failed.json"
: > "$Q/PR-13.json"            # fresh: under 45m, no page

drive() {
  : > "$T/alerts.txt"
  ( alert() { printf '%s\t%s\n' "$2" "$3" >> "$T/alerts.txt"; }
    PROJECTS=proj
    # shellcheck disable=SC1090
    . "$T/block.sh" )
}
drive

grep -q '^stuckqueue:proj:PR-10.json	proj PR-10 queued 180m with no spawn' "$T/alerts.txt" \
  && ok || bad "a real queue file aged 3h must still page: $(cat "$T/alerts.txt")"
grep -q 'failed' "$T/alerts.txt" \
  && bad "a *.failed.json park must never page 'queued with no spawn': $(grep failed "$T/alerts.txt")" || ok
grep -q 'PR-13' "$T/alerts.txt" && bad "a fresh queue file must not page" || ok
[ "$(wc -l < "$T/alerts.txt")" = 1 ] && ok || bad "exactly one alert expected, got: $(cat "$T/alerts.txt")"

echo "pipeline-health-stuck-queue: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
