#!/bin/bash
# tests/legibility-helpers.bh-3567-test.sh — the shared legibility primitives
# of #3558 (BH-3567, child 1): plain labels, dated stamps, the $ basis, and the
# raw-name header field.
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by node --test in
# console-ui/tests/legibility-helpers.bh-3567.test.js (reached through the
# console-ui job). This file names the new sources by path so the impact lane
# and the orphan ratchet can see them, drives the pure half with node, and runs
# the node suite when the console-ui dependencies are installed.
# Run from anywhere: tests/legibility-helpers.bh-3567-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LABELS="$DIR/console-ui/src/lib/labels.js"
FORMAT="$DIR/console-ui/src/lib/format.js"
USDCELL="$DIR/console-ui/src/ui/UsdCell.js"
HELPER="$DIR/console-ui/tests/legibility.bh-3558.js"
NODE_SUITE="$DIR/console-ui/tests/legibility-helpers.bh-3567.test.js"

for f in "$LABELS" "$FORMAT" "$USDCELL" "$HELPER" "$NODE_SUITE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "legibility-helpers: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the pure helpers, driven ---------------------------------------------
OUT=$(node --input-type=module -e "
import { plainLabel, tierLabel } from '$LABELS';
import { whenLabel, countOrNull, usdBasis } from '$FORMAT';
const NOW = Date.UTC(2026, 8, 29, 14, 5);
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('plain',     plainLabel('MAX_CONCURRENT'), 'max concurrent');
eq('plain-rc',  plainLabel('RC'), 'exit code');
eq('tier-1',    tierLabel(1), 'auto-merge');
eq('tier-str',  tierLabel('2'), 'reviewed merge');
eq('tier-null', tierLabel(null), 'no tier');
eq('when-3h',   whenLabel(new Date(NOW - 3 * 3600e3).toISOString(), NOW), '3h ago');
eq('when-date', whenLabel(new Date(NOW - 4 * 86400e3).toISOString(), NOW), 'Sep 25 14:05Z');
eq('when-null', whenLabel(null, NOW), 'never');
eq('count',     [countOrNull(null), countOrNull(0), countOrNull(null, { uncapped: true })], ['no data', '0', 'no cap']);
eq('usd',       usdBasis(1.234, 'api'), { text: '\$1.23', basis: 'api', label: 'API-eq' });
eq('usd-null',  usdBasis(null).text, 'no data');
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "helpers: ${line#no }" ;;
    *) [ -n "$line" ] && bad "helpers: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "legibility-helpers: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/legibility-helpers.bh-3567.test.js 2>&1); then ok
  else bad "console-ui/tests/legibility-helpers.bh-3567.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "legibility-helpers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
