#!/bin/bash
# tests/merge-queue-contract.bh-3155-test.sh — BH-3155 (BH-2325.0 contract): the
# merge-queue / held-page console client calls and the two action-cell stubs.
#
#   1. the sources exist, named here by path so the orphan ratchet and the
#      impact lane can see them.
#   2. the node suite console-ui/tests/merge-queue-contract.bh-3155.test.js
#      (URL, method and body of the four calls; both stubs render null), run
#      for real when node and the console-ui dependencies are installed.
# Run from anywhere: tests/merge-queue-contract.bh-3155-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# --- 1: the sources ----------------------------------------------------------
STUBS="$DIR/console-ui/src/screens/merge-queue-actions.js"
API="$DIR/console-ui/src/api.js"
NODE_SUITE="$DIR/console-ui/tests/merge-queue-contract.bh-3155.test.js"
for f in "$STUBS" "$API" "$NODE_SUITE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 2: the node suite, driven -----------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "merge-queue-contract: node suite SKIPPED — node is not installed on this box"
elif [ ! -d "$DIR/console-ui/node_modules/preact" ]; then
  echo "merge-queue-contract: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/merge-queue-contract.bh-3155.test.js 2>&1); then ok
  else bad "console-ui/tests/merge-queue-contract.bh-3155.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "merge-queue-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
