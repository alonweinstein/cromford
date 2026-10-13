#!/bin/bash
# tests/cost-cap-history-console.bh-2511-test.sh — the CAP HISTORY section on
# the Costs page (BH-2511.4 / BH-2567).
#
# The section's behaviour is proved by node --test in
# console-ui/tests/cost-cap-history.bh-2511.test.js (reached through the
# console-ui job). This file names both sources by path for the orphan ratchet,
# drives the pure half (lib/cost-cap-changes.js, no preact) for real, and holds the section to the rules a reviewer
# would otherwise check by eye (the cost-breaker-console.bh-2331 pattern).
#
#   1. changeRows, DRIVEN: a loaded body, a malformed one, a truncated one.
#   2. CostCapHistory.js sorts through the shared SortableTable, polls through
#      lib/poll.js, does not import the CAPS section, names no model and never
#      calls a native dialog.
#   3. the node suite, run for real when the console-ui dependencies are installed.
# Run from anywhere: tests/cost-cap-history-console.bh-2511-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/cost-cap-changes.js"
SCREEN="$DIR/console-ui/src/screens/CostCapHistory.js"

MISSING=0
for f in "$LIB" "$SCREEN"; do
  if [ -f "$f" ]; then ok; else bad "missing $f"; MISSING=1; fi
done
if [ "$MISSING" -eq 1 ]; then
  echo "cost-cap-history-console: $PASS passed, $FAIL failed"
  exit 1
fi

command -v node >/dev/null 2>&1 || { echo "cost-cap-history-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: changeRows, driven ---------------------------------------------------
OUT=$(node --input-type=module -e "
import { changeRows } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const row = { id: 1, key: 'conf.cost-caps.default', before_value: null, after_value: '80', actor: 'a', reason: null, at: '2026-09-01T00:00:00Z' };
eq('loaded',     changeRows({ changes: [row], truncated: false }), { rows: [row], truncated: false, malformed: false });
eq('malformed',  changeRows({}).malformed, true);
eq('not-object', changeRows(null).malformed, true);
eq('truncated',  changeRows({ changes: [], truncated: true }).truncated, true);
eq('truthy-str', changeRows({ changes: [], truncated: 'true' }).truncated, false);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "changeRows: ${line#no }" ;;
    *) [ -n "$line" ] && bad "changeRows: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the section's shape ---------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "CostCapHistory.js must use the shared SortableTable"
grep -q "from '../lib/poll.js'" "$SCREEN" && ok || bad "CostCapHistory.js must poll through lib/poll.js"
grep -q "from '../lib/cost-cap-changes.js'" "$SCREEN" && ok || bad "CostCapHistory.js must read the body through lib/cost-cap-changes.js"
grep -q "from './CostCaps.js'" "$SCREEN" && bad "CostCapHistory.js must not import the CAPS section" || ok
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (^|[^A-Za-z_.])(window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the CAP HISTORY section"
else
  ok
fi
if [[ "$CODE" == *claude-* ]]; then bad "a model id in CostCapHistory.js"; else ok; fi

# --- 3: the node suite, driven -------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "cost-cap-history-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/cost-cap-history.bh-2511.test.js 2>&1); then ok
  else bad "console-ui/tests/cost-cap-history.bh-2511.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "cost-cap-history-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
