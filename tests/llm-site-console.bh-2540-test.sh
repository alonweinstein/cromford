#!/bin/bash
# tests/llm-site-console.bh-2540-test.sh — the console LLM SITE drill screen at
# /llm-sites/:site (BH-2557, slice 4 of BH-2540).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/llm-site.bh-2540.test.js (reached through the console-ui
# job). This file names the screen by path for the orphan ratchet and holds it
# to the rules a reviewer would otherwise check by eye (the
# command-history-console.bh-2514 pattern).
#
#   1. LlmSite.js sorts through the shared SortableTable, is routed at
#      /llm-sites/:site, and never calls a native dialog.
#   2. the node suite console-ui/tests/llm-site.bh-2540.test.js, run for real
#      when the console-ui dependencies are installed.
# Run from anywhere: tests/llm-site-console.bh-2540-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SCREEN="$DIR/console-ui/src/screens/LlmSite.js"
APP="$DIR/console-ui/src/app.js"

if [ -f "$SCREEN" ]; then ok; else
  bad "missing $SCREEN"
  echo "llm-site-console: $PASS passed, $FAIL failed"
  exit 1
fi

# --- 1: the screen's shape --------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "LlmSite.js must use the shared SortableTable"
grep -q "'/llm-sites/:site', LlmSiteScreen" "$APP" && ok || bad "app.js must route /llm-sites/:site to LlmSiteScreen"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN")
if [[ "$CODE" =~ (^|[^A-Za-z_.])(window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the LLM SITE screen"
else
  ok
fi

# --- 2: the node suite, driven -----------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "llm-site-console: node suite SKIPPED — node is not installed on this box"
elif [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "llm-site-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/llm-site.bh-2540.test.js 2>&1); then ok
  else bad "console-ui/tests/llm-site.bh-2540.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "llm-site-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
