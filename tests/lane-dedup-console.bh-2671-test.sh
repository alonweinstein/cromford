#!/bin/bash
# tests/lane-dedup-console.bh-2671-test.sh — the console CALLS PER DISTINCT
# INPUT · BY LANE section on /costs (BH-2671, BH-2537.4).
#
# The screen's behaviour is proved by node --test in
# console-ui/tests/lane-dedup.bh-2671.test.js. This file names the new source
# by path for the impact lane and the orphan ratchet, holds the screen to the
# rules a reviewer would otherwise check by eye, and runs the node suite when
# the console-ui dependencies are installed (the account-usage-console.bh-1916
# pattern).
#
#   1. LaneDedup.js exists, sorts through the shared SortableTable (no raw
#      <table>), polls every 60s, uses no cards and no native dialog.
#   2. Costs.js imports it and mounts it on the line directly above the
#      ACCOUNT USAGE section (below it would break account-usage.bh-167's pin
#      that ACCOUNT USAGE sits directly above ANCHORED).
#   3. the node suite, run for real when console-ui/node_modules exists.
# Run from anywhere: tests/lane-dedup-console.bh-2671-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SCREEN="$DIR/console-ui/src/screens/LaneDedup.js"
COSTS="$DIR/console-ui/src/screens/Costs.js"

for f in "$SCREEN" "$COSTS"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 1: the screen's shape --------------------------------------------------
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" 2>/dev/null)
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "LaneDedup.js must use the shared SortableTable"
if grep -q '<table' <<< "$CODE"; then bad "LaneDedup.js renders a raw <table>"; else ok; fi
grep -q 'intervalMs: 60000' <<< "$CODE" && ok || bad "LaneDedup.js must poll every 60s"
if grep -qE 'class="[^"]*card' <<< "$CODE"; then bad "LaneDedup.js uses a card"; else ok; fi
if grep -qE '(^|[^A-Za-z_.])(window\.)?(confirm|alert|prompt)[[:space:]]*\(' <<< "$CODE"; then
  bad "a native dialog in the lane-dedup screen"
else
  ok
fi

# --- 2: mounted on /costs, directly above ACCOUNT USAGE ------------------------------
grep -qF "import { LaneDedupSection } from './LaneDedup.js';" "$COSTS" && ok || bad "Costs.js must import LaneDedupSection"
AU=$(grep -nF '<${AccountUsageSection}/>' "$COSTS" | head -1 | cut -d: -f1)
LD=$(grep -nF '<${LaneDedupSection}/>' "$COSTS" | head -1 | cut -d: -f1)
if [ -n "$AU" ] && [ -n "$LD" ] && [ "$LD" -eq $((AU - 1)) ]; then ok
else bad "Costs.js must render LaneDedupSection on the line directly above AccountUsageSection (au=${AU:-absent} ld=${LD:-absent})"
fi

# --- 3: the node suite, driven -----------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "lane-dedup-console: node suite SKIPPED — node is not installed on this box"
elif [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "lane-dedup-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/lane-dedup.bh-2671.test.js 2>&1); then ok
  else bad "console-ui/tests/lane-dedup.bh-2671.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "lane-dedup-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
