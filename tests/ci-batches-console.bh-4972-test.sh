#!/bin/bash
# tests/ci-batches-console.bh-4972-test.sh — the MERGE-QUEUE BATCHES section
# on /ci (BH-4972, slice 4 of BH-4964).
#
# The section's behaviour is proved by node --test in
# console-ui/tests/ci-batches.bh-4972.test.js. This file is the part the impact
# lane and the orphan ratchet can SEE (the ci-health-console.bh-2634 pattern):
# it names the new lib and the screen by path, drives the pure half with node,
# and holds the section to the rules a reviewer would otherwise check by eye.
#
#   1. lib/ci-batches.js, DRIVEN: the before/after median (odd, even, empty
#      side, null billed excluded, window edges, null cutover), the cutover is
#      the earliest batch-selected row, runUrl refuses an unreadable repo or id,
#      batchRows keeps a missing count null and refuses a non-array payload.
#   2. CiHealth.js mounts the section through the shared SortableTable, and
#      neither file calls a native dialog.
#   3. the node suite, run for real when the console-ui dependencies are installed.
# Run from anywhere: tests/ci-batches-console.bh-4972-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/ci-batches.js"
SCREEN="$DIR/console-ui/src/screens/CiHealth.js"

for f in "$LIB" "$SCREEN"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "ci-batches-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { medianBatchMinutes, cutoverIso, runUrl, batchRows } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const C = '2026-09-20T12:00:00Z';
const at = (d) => new Date(Date.parse(C) + d * 86400000).toISOString();
const r = (d, billedMin, mode = 'full-legacy') => ({ when: at(d), billedMin, mode });

const rows = [r(-1, 5), r(-2, 9), r(-3, 7), r(-4, null), r(0, 2, 'batch-selected'), r(1, 4, 'full'), r(2, 6, 'batch-selected'), r(3, 10, 'batch-selected')];
eq('median-odd-even', medianBatchMinutes(rows, C), { before: 7, after: 5, nBefore: 3, nAfter: 4 });
eq('median-empty-side', medianBatchMinutes([r(0, 2)], C), { before: null, after: 2, nBefore: 0, nAfter: 1 });
eq('median-edges', medianBatchMinutes([r(-7, 3), r(7, 99), r(0, 11)], C), { before: 3, after: 11, nBefore: 1, nAfter: 1 });
eq('median-no-cutover', medianBatchMinutes(rows, null), { before: null, after: null, nBefore: 0, nAfter: 0 });

eq('cutover-earliest-batch-selected', cutoverIso([r(5, 1, 'batch-selected'), r(-9, 1, 'full'), r(-10, 1, 'full-legacy'), r(0, 1, 'batch-selected')]), at(0));
eq('cutover-none', cutoverIso([r(0, 1, 'full')]), null);

eq('runurl-ok', runUrl('example-org/cromford', 42), 'https://github.com/example-org/cromford/actions/runs/42');
eq('runurl-refuses', ['', '../x', 'a/b/c'].map((x) => runUrl(x, 42)).concat([runUrl('a/b', 0), runUrl('a/b', '12')]), [null, null, null, null, null]);

const b = batchRows({ rows: [{ run_id: 7, repo: 'a/b', escalation: '-', total: 340 }], truncated: true });
eq('rows-null-not-zero', [b.rows[0].selected, b.rows[0].billedMin, b.rows[0].escalation, b.rows[0].total, b.truncated], [null, null, null, 340, true]);
eq('rows-bad-payload', [batchRows({ error: 'x' }), batchRows({ rows: 'x' }), batchRows(null)], [null, null, null]);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"
DRIVEN=$(grep -c '^ok ' <<< "$OUT")
[ "$DRIVEN" -eq 10 ] && ok || bad "lib: expected 10 driven checks, got $DRIVEN"

# --- 2: the screen's shape --------------------------------------------------
grep -q '<${CiBatchesView}' "$SCREEN" && ok || bad "CiHealthScreen must render CiBatchesView"
grep -q "from '../lib/ci-batches.js'" "$SCREEN" && ok || bad "CiHealth.js must shape the rows through lib/ci-batches.js"
grep -q 'SortableTable} wide columns=${batchColumns}' "$SCREEN" && ok || bad "the batches table must be the shared SortableTable, wide"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (^|[^A-Za-z_.])(window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the CI batches section"
else
  ok
fi

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "ci-batches-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/ci-batches.bh-4972.test.js 2>&1); then ok
  else bad "console-ui/tests/ci-batches.bh-4972.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "ci-batches-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
