#!/bin/bash
# tests/controls-screen.bh-2513-test.sh — the console CONTROLS screen
# (/controls/<kind>, BH-2513.4 / BH-2621).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/controls-render.bh-2621.test.js (reached through the
# console-ui job). What this file adds is the part the impact lane and the
# orphan ratchet can SEE: it names the new screen by path, holds it to the
# rules a reviewer would otherwise check by eye, and runs the node suite and
# the console build when the console-ui dependencies are installed.
#
#   1. Controls.js exists, sorts through the shared SortableTable, edits in the
#      shared Modal, never calls a native dialog, and names no kind itself.
#   2. app.js routes /controls/:kind to ControlsScreen; Settings.js links each
#      kind through controlHref.
#   3. the node suite and `npm run build`, run for real when the deps exist.
# Run from anywhere: tests/controls-screen.bh-2513-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SCREEN="$DIR/console-ui/src/screens/Controls.js"
APP="$DIR/console-ui/src/app.js"
SETTINGS="$DIR/console-ui/src/screens/Settings.js"

for f in "$SCREEN" "$APP" "$SETTINGS"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 1: the screen's shape --------------------------------------------------
if [ -f "$SCREEN" ]; then
  CODE=$(grep -vE '^[[:space:]]*//' "$SCREEN")
  grep -q "from '../ui/SortableTable.js'" <<< "$CODE" && ok || bad "Controls.js must use the shared SortableTable"
  grep -q "from '../ui/Modal.js'" <<< "$CODE" && ok || bad "Controls.js must edit in the shared in-app Modal"
  grep -q "CONTROL_KINDS" <<< "$CODE" && ok || bad "Controls.js must read its kinds from CONTROL_KINDS"
  if grep -qE '\b(confirm|alert|prompt)\(' <<< "$CODE"; then bad "a native dialog call in Controls.js"; else ok; fi
  # Generic over CONTROL_KINDS: no kind slug or worker route is spelled here.
  if grep -qE "'(review-gate|rules|retry-policies|contracts)'|/api/(review-gate|rules|retry-policies|contracts)" <<< "$CODE"; then
    bad "Controls.js hardcodes a control kind"
  else ok; fi
fi

# --- 2: the route and the SETTINGS link row ----------------------------------
grep -qF "['/controls/:kind', ControlsScreen]" "$APP" && ok || bad "app.js must route /controls/:kind to ControlsScreen"
SCODE=$(grep -vE '^[[:space:]]*//' "$SETTINGS")
grep -qF "controlHref(" <<< "$SCODE" && ok || bad "Settings.js must link each kind through controlHref"

# --- 3: the node suite and the build, driven ---------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "controls-screen: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
  echo "controls-screen: npm run build SKIPPED — console-ui dependencies are not installed"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/controls-render.bh-2621.test.js 2>&1); then ok
  else bad "console-ui/tests/controls-render.bh-2621.test.js failed:"; printf '%s\n' "$NOUT"
  fi
  # The build writes dist/ inside console-ui; a scratch outDir keeps the tree clean.
  OUTDIR="$T/controls-dist"; mkdir -p "$OUTDIR"
  if BOUT=$(cd "$DIR/console-ui" && npm run build --silent -- --outDir "$OUTDIR" --emptyOutDir 2>&1); then ok
  else bad "console-ui npm run build failed:"; printf '%s\n' "$BOUT"
  fi
  scratch_rm "$OUTDIR"
fi

echo "controls-screen: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
