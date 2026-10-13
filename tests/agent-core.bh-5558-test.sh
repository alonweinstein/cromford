#!/bin/bash
# tests/agent-core.bh-5558-test.sh — BH-5558 (wave 1 of #5556): the agent-core package.
# Thin wrapper over agent-core/test/*.test.js, which import the REAL agent-core/src/index.js
# and parse the REAL prompts/archie-soul.d/*.md. It fails when node reports 0 passing
# tests or any skipped one: a suite that skipped gates nothing.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/agent-core.bh-5558-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v node >/dev/null 2>&1 || { echo "agent-core.bh-5558-test: SKIPPED — node is not installed on this box"; exit 0; }

# The sources this suite exercises, named by path so bin/test-impact.sh maps a
# change to any of them onto this suite.
for SRC in "$DIR/agent-core/package.json" "$DIR/agent-core/src/index.js" \
           "$DIR/agent-core/src/soul.js" "$DIR/agent-core/src/autonomy.js" \
           "$DIR/agent-core/src/fingerprint.js" "$DIR/agent-core/src/sha256.js" \
           "$DIR/agent-core/src/learning.js" "$DIR/agent-core/src/validate.js" \
           "$DIR/agent-core/schema/charter.schema.json" "$DIR/agent-core/schema/soul.schema.json" \
           "$DIR/agent-core/schema/finding.schema.json" "$DIR/agent-core/schema/suppression.schema.json" \
           "$DIR/agent-core/schema/decision.schema.json" "$DIR/agent-core/schema/outcome.schema.json" \
           "$DIR/agent-core/test/soul.test.js" "$DIR/agent-core/test/autonomy.test.js" \
           "$DIR/agent-core/test/fingerprint.test.js" "$DIR/agent-core/test/learning.test.js" \
           "$DIR/agent-core/test/schema.test.js" \
           "$DIR/prompts/archie-soul.d/10-authority.md"; do
  [ -r "$SRC" ] || { echo "FAIL: agent-core.bh-5558-test: missing $SRC"; exit 1; }
done

LOG="$T/node.log"
cd "$DIR/agent-core" || exit 1
node --test --test-reporter=spec test/*.test.js >"$LOG" 2>&1
RC=$?
PASSED=$(sed -n 's/^[^ ]* pass \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
SKIPPED=$(sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
if [ "$RC" -ne 0 ]; then cat "$LOG"; echo "FAIL: agent-core.bh-5558-test: node --test rc=$RC"; exit 1; fi
if [ -z "$PASSED" ] || [ -z "$SKIPPED" ]; then cat "$LOG"; echo "FAIL: agent-core.bh-5558-test: no test summary — node's reporter changed shape"; exit 1; fi
[ "$PASSED" -gt 0 ] || { cat "$LOG"; echo "FAIL: agent-core.bh-5558-test: 0 tests passed — the suite did not run"; exit 1; }
[ "$SKIPPED" = 0 ] || { cat "$LOG"; echo "FAIL: agent-core.bh-5558-test: $SKIPPED test(s) SKIPPED"; exit 1; }
echo "agent-core.bh-5558-test: $PASSED passed, 0 skipped"
