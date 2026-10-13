#!/bin/bash
# tests/factory-stop-console.bh-3687-test.sh — the console half of the
# factory-stop switch (BH-3712, slice 5 of BH-3687).
#
# The behaviour is proved by node --test in
# console-ui/tests/factory-stop.bh-3687.test.js. This file names the new
# sources by path (the orphan ratchet and the impact lane read shell suites
# only), drives the pure lib for real, checks the banner is mounted once on the
# Fleet screen above the PAUSE FLEET row, and runs the node suite when the
# console-ui dependencies are installed.
#   1. lib/factory-stop.js, DRIVEN: an unreadable row is unknown (never on), a
#      blank reason builds no body.
#   2. screens/Fleet.js imports FactoryStopBanner and renders it exactly once,
#      before the PAUSE FLEET button.
#   3. the node suite, run for real when console-ui/node_modules exists.
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/factory-stop.js"
BANNER="$DIR/console-ui/src/ui/FactoryStopBanner.js"
FLEET="$DIR/console-ui/src/screens/Fleet.js"
for f in "$LIB" "$BANNER" "$FLEET"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 2: mounted once on Fleet, above PAUSE FLEET ---------------------------
IMP=$(grep -c "^import { FactoryStopBanner } from '../ui/FactoryStopBanner.js';$" "$FLEET")
[ "$IMP" = 1 ] && ok || bad "Fleet.js imports FactoryStopBanner $IMP times"
REN=$(grep -c '<\${FactoryStopBanner} confirm=\${confirm} />' "$FLEET")
[ "$REN" = 1 ] && ok || bad "Fleet.js renders FactoryStopBanner $REN times"
BL=$(grep -n '<\${FactoryStopBanner}' "$FLEET" | head -1 | cut -d: -f1)
PL=$(grep -n "'PAUSE FLEET…'" "$FLEET" | head -1 | cut -d: -f1)
if [ -n "$BL" ] && [ -n "$PL" ] && [ "$BL" -lt "$PL" ]; then ok; else bad "the banner (line ${BL:-none}) is not above PAUSE FLEET (line ${PL:-none})"; fi

command -v node >/dev/null 2>&1 || { echo "factory-stop-console: $PASS passed, $FAIL failed (node not installed: lib and node suite SKIPPED)"; [ "$FAIL" -eq 0 ]; exit; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { shapeFactoryStop, factoryStopBody } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('on',        shapeFactoryStop({ setting: { value: '1' } }, 0).state, 'on');
eq('none-off',  shapeFactoryStop({ setting: null }, 0).state, 'off');
eq('yes-unk',   shapeFactoryStop({ setting: { value: 'yes' } }, 0).state, 'unknown');
eq('empty-unk', shapeFactoryStop({}, 0).state, 'unknown');
eq('body',      factoryStopBody('on', 'r'), { key: 'switch.factory-stop', value: '1', reason: 'r', note: 'r' });
eq('blank',     factoryStopBody('off', '  '), { error: 'reason required' });
" 2>&1)
while IFS= read -r l; do
  case "$l" in ok\ *) ok ;; *) bad "lib: $l" ;; esac
done <<<"$OUT"
[ "$(grep -c '^ok ' <<<"$OUT")" = 6 ] && ok || bad "lib: expected 6 checks, got: $OUT"

# --- 3: the node suite ------------------------------------------------------
if [ -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  if (cd "$DIR/console-ui" && node --test tests/factory-stop.bh-3687.test.js >"$T/node.out" 2>&1); then ok
  else bad "node suite console-ui/tests/factory-stop.bh-3687.test.js failed:"; cat "$T/node.out"; fi
else
  echo "factory-stop-console: node suite SKIPPED (console-ui/node_modules not installed; CI's console-ui job runs it)"
fi

echo "factory-stop-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
