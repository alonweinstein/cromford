#!/bin/bash
# tests/fleet-flag-columns.bh-5643-test.sh — the Fleet PROJECTS table's
# PAUSED, WIP and ROUTE columns (BH-5643, BH-5635.4).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/flagrows.bh-5643.test.js and flags-proxy.bh-5643.test.js
# (reached through the console-ui job). This file names the new source by path
# so the impact lane and the orphan ratchet can see it, drives the pure shaper
# for real, and runs both node suites when the console deps are installed (the
# cost-breaker-console.bh-2331 pattern).
#
#   1. lib/flagrows.js, DRIVEN: an unreadable flags read is null ("—"), never
#      false ("off"); a paused-<p> row matches its project exactly; a wip
#      value that is not a whole number is null; the WIP input refuses 0.
#   2. Fleet.js imports the shaper and never calls a native dialog.
#   3. the two node suites, run for real when console-ui/node_modules exists.
# Run from anywhere: tests/fleet-flag-columns.bh-5643-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/flagrows.js"
SCREEN="$DIR/console-ui/src/screens/Fleet.js"

for f in "$LIB" "$SCREEN"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "fleet-flag-columns: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { shapeProjectFlags, wipInputError, cellText } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('unreadable',  shapeProjectFlags(null, null, ['a']).a, { paused: null, wip: null, route: null });
eq('unread-text', cellText('paused', shapeProjectFlags({}, null, ['a']).a.paused), '—');
eq('exact-name',  shapeProjectFlags({ flags: [{ name: 'paused-ab', active: 1 }] }, null, ['a']).a.paused, false);
eq('paused-on',   shapeProjectFlags({ flags: [{ name: 'paused-a', active: 1 }] }, null, ['a']).a.paused, true);
eq('wip-5',       shapeProjectFlags({ flags: [{ name: 'wip-limit-a', active: 1, value: '5' }] }, null, ['a']).a.wip, 5);
eq('wip-bad',     shapeProjectFlags({ flags: [{ name: 'wip-limit-a', active: 1, value: 'x' }] }, null, ['a']).a.wip, null);
eq('route',       shapeProjectFlags(null, { routing: [{ project: 'a', builder: 'pool', pool_app: 'bh-pool', halted: 1 }] }, ['a']).a.route, 'pool · bh-pool · HALTED');
eq('wip-input-0', typeof wipInputError('0'), 'string');
eq('wip-input-5', wipInputError('5'), null);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape --------------------------------------------------
grep -q "from '../lib/flagrows.js'" "$SCREEN" && ok || bad "Fleet.js must shape the flag cells through lib/flagrows.js"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ window\.(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the Fleet screen"
else
  ok
fi

# --- 3: the node suites, driven ---------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "fleet-flag-columns: node suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/flagrows.bh-5643.test.js tests/flags-proxy.bh-5643.test.js 2>&1); then ok
  else bad "console-ui/tests/flagrows.bh-5643.test.js or flags-proxy.bh-5643.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "fleet-flag-columns: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
