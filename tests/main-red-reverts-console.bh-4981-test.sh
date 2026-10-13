#!/bin/bash
# tests/main-red-reverts-console.bh-4981-test.sh — the console MAIN-RED REVERTS
# section on /ci (BH-4981).
#
# WHY A SHELL SUITE AS WELL. The section's behaviour is proved by node --test in
# console-ui/tests/main-red-reverts.bh-4981.test.js (reached through the
# console-ui job). What this file adds is the part the impact lane and the
# orphan ratchet can SEE: it names the new source by path and holds the section
# to the rules a reviewer would otherwise check by eye (the
# cost-breaker-console.bh-2331 pattern).
#
#   1. MainRedReverts.js sorts through the shared SortableTable, reads the
#      ledger through api.mainRedAttrib, is mounted on /ci, and never calls a
#      native dialog.
#   2. the node suite console-ui/tests/main-red-reverts.bh-4981.test.js, run for
#      real when the console-ui dependencies are installed.
# Run from anywhere: tests/main-red-reverts-console.bh-4981-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

VIEW="$DIR/console-ui/src/ui/MainRedReverts.js"
SCREEN="$DIR/console-ui/src/screens/CiHealth.js"
API="$DIR/console-ui/src/api.js"

[ -f "$DIR/console-ui/src/ui/MainRedReverts.js" ] && ok || bad "missing console-ui/src/ui/MainRedReverts.js"
for f in "$SCREEN" "$API"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 1: the section's shape -------------------------------------------------
grep -q "from './SortableTable.js'" "$VIEW" && ok || bad "MainRedReverts.js must use the shared SortableTable"
grep -q "kind=main_red_attrib" "$API" && ok || bad "api.js must read the main_red_attrib ledger (api.mainRedAttrib)"
grep -q "api.mainRedAttrib()" "$SCREEN" && ok || bad "CiHealth.js must read api.mainRedAttrib"
grep -q 'title="MAIN-RED REVERTS"' "$SCREEN" && ok || bad "CiHealth.js must mount the MAIN-RED REVERTS section"
CODE=$(grep -hvE '^[[:space:]]*//' "$VIEW")
if [[ "$CODE" =~ (window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the MAIN-RED REVERTS section"
else
  ok
fi

# --- 2: the node suite, driven -----------------------------------------------
# Run here too, so this suite is its door as well as the console-ui CI job's;
# without node or the console deps it says so and skips.
if ! command -v node >/dev/null 2>&1; then
  echo "main-red-reverts-console: node suite SKIPPED — node is not installed on this box"
elif [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "main-red-reverts-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/main-red-reverts.bh-4981.test.js 2>&1); then ok
  else bad "console-ui/tests/main-red-reverts.bh-4981.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "main-red-reverts-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
