#!/bin/bash
# tests/merge-queue-console.bh-3158-test.sh — the console /merge-queue screen
# (BH-3158, BH-2325.3).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/merge-queue.bh-3158.test.js (reached through the console-ui
# job). This file names the two new sources by path so the impact lane and the
# orphan ratchet can see them, drives the pure half for real, and holds the
# screen to the rules a reviewer would otherwise check by eye:
#
#   1. lib/merge-queue.js, DRIVEN: a failed status read is failed, never an
#      empty list; a status read of 500 rows is capped and 499 is not; the
#      rows-only setting is unread on a failed read, on only for 1|on|true|yes.
#   2. MergeQueue.js sorts through the shared SortableTable in wide tables,
#      never calls a native dialog, is routed at /merge-queue in app.js, and
#      the Kanban header links to it.
#   3. the node suite, run for real when the console-ui dependencies are installed.
# Run from anywhere: tests/merge-queue-console.bh-3158-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/merge-queue.js"
SCREEN="$DIR/console-ui/src/screens/MergeQueue.js"
APP="$DIR/console-ui/src/app.js"
KANBAN="$DIR/console-ui/src/screens/Kanban.js"

for f in "$LIB" "$SCREEN" "$APP" "$KANBAN"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "merge-queue-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { MQ_READ_LIMIT, MQ_STATUSES, mqRows, rowsOnlyState } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const res = (rows) => ({ data: { merge_queue: rows }, error: null });
const fail = { data: null, error: new Error('down') };
const n = (k) => Array.from({ length: k }, (_, i) => ({ project: 'p', pr: i + 1, status: 'queued' }));

eq('limit',          MQ_READ_LIMIT, 500);
eq('statuses',       MQ_STATUSES, ['queued', 'blocked', 'dropped']);
const r = mqRows(res(n(2)), fail, res([]));
eq('failed',         r.failed, ['blocked']);
eq('rows',           r.rows.length, 2);
eq('no-array',       mqRows({ data: {}, error: null }, res([]), res([])).failed, ['queued']);
eq('capped-500',     mqRows(res(n(500)), res([]), res([])).capped, ['queued']);
eq('capped-499',     mqRows(res(n(499)), res([]), res([])).capped, []);
eq('setting-unread', rowsOnlyState(fail), 'unread');
eq('setting-none',   rowsOnlyState({ data: { setting: null, source: 'none' }, error: null }), 'off');
eq('setting-on',     rowsOnlyState({ data: { setting: { value: ' Yes ' } }, error: null }), 'on');
eq('setting-zero',   rowsOnlyState({ data: { setting: { value: '0' } }, error: null }), 'off');
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape --------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "MergeQueue.js must use the shared SortableTable"
# BH-5022 added RISK TIERS as the fourth table; every one of them stays wide.
[ "$(grep -c '<\${SortableTable} wide' "$SCREEN")" -eq 4 ] && [ "$(grep -c '<\${SortableTable}' "$SCREEN")" -eq 4 ] && ok || bad "MergeQueue.js must render its four tables wide (they scroll inside their own container at 375px)"
grep -q "\['/merge-queue', MergeQueueScreen\]" "$APP" && ok || bad "app.js must route /merge-queue to MergeQueueScreen"
grep -q 'to="/merge-queue"' "$KANBAN" && ok || bad "Kanban.js must link its header to /merge-queue"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (^|[^A-Za-z_.])(window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the merge-queue screen"
else
  ok
fi

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "merge-queue-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/merge-queue.bh-3158.test.js 2>&1); then ok
  else bad "console-ui/tests/merge-queue.bh-3158.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "merge-queue-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
