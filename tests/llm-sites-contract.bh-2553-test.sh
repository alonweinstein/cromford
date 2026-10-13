#!/bin/bash
# tests/llm-sites-contract.bh-2553-test.sh — the BH-2540 LLM sites contract
# slice (BH-2553): the catalog lib, the two stub worker routes and the two stub
# console screens.
#
#   1. every new source exists at its rooted path (the orphan ratchet reads
#      the paths below).
#   2. the node suite worker/jobs/test/llm-sites-catalog.bh-2553.test.js, run
#      for real, its true exit code counted.
# Run from anywhere: tests/llm-sites-contract.bh-2553-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

for f in \
  "$DIR/console-ui/src/screens/LlmSites.js" \
  "$DIR/console-ui/src/screens/LlmSite.js" \
  "$DIR/worker/jobs/src/lib/llm-sites-catalog.js" \
  "$DIR/worker/jobs/src/routes/llm-sites.js" \
  "$DIR/worker/jobs/src/routes/llm-site-rows.js"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "llm-sites-contract: SKIPPED — node is not installed on this box"; exit 0; }

# worker/jobs has no npm dependencies; core.js imports the GENERATED,
# git-ignored catalog/lanes.json statically, so it is rendered first (see
# controls-contract.bh-2513-test.sh).
if [ -x "$DIR/bin/lanes-build.sh" ] && [ -d "$DIR/catalog/lanes.d" ]; then
  "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 \
    || { echo "FAIL: llm-sites-contract: catalog/lanes.json could not be composed from catalog/lanes.d — worker/jobs imports it statically"; exit 1; }
fi
if NOUT=$(cd "$DIR/worker/jobs" && node --test test/llm-sites-catalog.bh-2553.test.js 2>&1); then ok
else bad "worker/jobs/test/llm-sites-catalog.bh-2553.test.js failed (rc $?):"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "llm-sites-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
