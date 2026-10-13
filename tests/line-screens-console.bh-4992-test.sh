#!/bin/bash
# tests/line-screens-console.bh-4992-test.sh — Now, Fleet and Kanban on the
# line in Mission Control (BH-4992, wave 3 of BH-4947).
#
# The behaviour is proved by node --test in console-ui/tests/*-line.bh-4992.test.js.
# This file is the part the impact lane and the orphan ratchet can SEE: it
# names the new sources by path, drives the pure headlines with plain node
# (no dependencies needed), and runs the node suites when the console-ui
# dependencies are installed.
#
#   1. the new sources and suites exist.
#   2. console-ui/src/lib/line-screens.js, DRIVEN: each headline derives from
#      the counts only; an unread count says so, never 0; Kanban columns map to
#      stations and failed is off the line.
#   3. the node suites (now-line, fleet-line, kanban-line), run for real when
#      node_modules is present; they cover console-ui/src/ui/LineBoard.js.
# Run from anywhere: tests/line-screens-console.bh-4992-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SCREENS_LIB="$DIR/console-ui/src/lib/line-screens.js"
LINE_BOARD="$DIR/console-ui/src/ui/LineBoard.js"
SUITES="tests/now-line.bh-4992.test.js tests/fleet-line.bh-4992.test.js tests/kanban-line.bh-4992.test.js"

for f in "$SCREENS_LIB" "$LINE_BOARD" "$DIR/console-ui/src/screens/Now.js" "$DIR/console-ui/src/screens/Fleet.js" "$DIR/console-ui/src/screens/Kanban.js"; do
  [ -s "$f" ] && ok || bad "missing $f"
done
for t in $SUITES; do [ -s "$DIR/console-ui/$t" ] && ok || bad "missing console-ui/$t"; done

command -v node >/dev/null 2>&1 || { echo "line-screens-console: SKIPPED — node is not installed on this box"; exit 0; }

OUT=$(node --input-type=module -e "
import { nowHeadline, fleetHeadline, kanbanHeadline, KANBAN_STATION, cardStation } from '$SCREENS_LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('N1 now, from counts', nowHeadline({ inFlight: 3, needs: 2, boards: 4, ticks: 5, failing: 0 }).line1, '3 tickets on the line.');
eq('N2 now, unread', nowHeadline({ inFlight: null }).line1, 'Reading the line.');
eq('F1 fleet, in words', fleetHeadline({ boxes: { a: '1m ago', b: '45m ago' } }).line2, 'None overdue. 1 silent.');
eq('F2 fleet, unread', fleetHeadline({ boxes: null }).line1, 'Reading the fleet.');
eq('K1 kanban, from counts', kanbanHeadline({ building: 1, review: 2, merge_queue: 0, merged_deployed: 3, dead_failed: 0, queued: 4 }).lede, '4 queued to build.');
eq('K2 failed is off the line', KANBAN_STATION.dead_failed, null);
eq('K3 a card at review sits at station 4', cardStation({ stage: 'reviewing' }, 'building'), 3);
" 2>&1)
while IFS= read -r l; do
  case "$l" in "ok "*) ok ;; "no "*) bad "${l#no }" ;; *) [ -n "$l" ] && bad "node: $l" ;; esac
done <<<"$OUT"

if [ ! -d "$DIR/console-ui/node_modules/preact" ] || [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "line-screens-console: node suites SKIPPED — console-ui/node_modules is not installed (CI's console-ui job runs them)"
else
  for t in $SUITES; do
    if NOUT=$(cd "$DIR/console-ui" && node --test "$t" 2>&1); then ok
    else bad "node --test $t failed: $(grep -E '^(not ok|✖)' <<<"$NOUT" | head -5)"; fi
  done
fi

echo "line-screens-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
