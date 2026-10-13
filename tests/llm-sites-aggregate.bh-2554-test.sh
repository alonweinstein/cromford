#!/bin/bash
# tests/llm-sites-aggregate.bh-2554-test.sh — GET /api/metrics/llm-sites filled
# in (BH-2554, BH-2540.1): per-site spend, refusals and knobs.
#
#   1. the new pure lib and the route exist at their rooted paths (the orphan
#      ratchet reads the paths below).
#   2. the node suite worker/jobs/test/llm-sites.bh-2554.test.js, run for real,
#      its true exit code counted.
# Run from anywhere: tests/llm-sites-aggregate.bh-2554-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

for f in \
  "$DIR/worker/jobs/src/lib/llm-sites.js" \
  "$DIR/worker/jobs/src/routes/llm-sites.js" \
  "$DIR/catalog/context-budgets.json"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "llm-sites-aggregate: SKIPPED — node is not installed on this box"; exit 0; }

# core.js imports the GENERATED, git-ignored catalog/lanes.json statically.
if [ -x "$DIR/bin/lanes-build.sh" ] && [ -d "$DIR/catalog/lanes.d" ]; then
  "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 \
    || { echo "FAIL: llm-sites-aggregate: catalog/lanes.json could not be composed from catalog/lanes.d — worker/jobs imports it statically"; exit 1; }
fi
if NOUT=$(cd "$DIR/worker/jobs" && node --test test/llm-sites.bh-2554.test.js 2>&1); then ok
else bad "worker/jobs/test/llm-sites.bh-2554.test.js failed (rc $?):"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "llm-sites-aggregate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
