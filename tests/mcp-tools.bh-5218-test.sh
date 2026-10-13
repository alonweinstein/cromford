#!/bin/bash
# tests/mcp-tools.bh-5218-test.sh — BH-5224 (child 2 of #5218): the MCP read and action tools.
# Thin wrapper over mcp/test/read-action-tools.test.mjs, which spawns the REAL
# `node mcp/server.mjs` against the stub console, lists the 16 tools and calls
# each one, checking the route, method and body the console receives. It fails
# when node reports 0 passing tests or any skipped one.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mcp-tools.bh-5218-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v node >/dev/null 2>&1 || { echo "mcp-tools.bh-5218-test: SKIPPED — node is not installed on this box"; exit 0; }

# The sources this suite exercises, named by path so bin/test-impact.sh maps a
# change to any of them onto this suite.
for SRC in "$DIR/mcp/tools/read.mjs" "$DIR/mcp/tools/actions.mjs" \
           "$DIR/mcp/tools/lib/schema.mjs" \
           "$DIR/mcp/test/read-action-tools.test.mjs" \
           "$DIR/docs/MCP.md"; do
  [ -r "$SRC" ] || { echo "FAIL: mcp-tools.bh-5218-test: missing $SRC"; exit 1; }
done

LOG="$T/node.log"
cd "$DIR" || exit 1
# Run the file directly, not under --test: --test reports the file itself as a
# passing test, so an emptied file would read "1 passed".
node --test-reporter=spec mcp/test/read-action-tools.test.mjs >"$LOG" 2>&1
RC=$?
PASSED=$(sed -n 's/^[^ ]* pass \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
SKIPPED=$(sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
if [ "$RC" -ne 0 ]; then cat "$LOG"; echo "FAIL: mcp-tools.bh-5218-test: node rc=$RC"; exit 1; fi
if [ -z "$PASSED" ] || [ -z "$SKIPPED" ]; then cat "$LOG"; echo "FAIL: mcp-tools.bh-5218-test: no test summary — the file ran no tests, or node's reporter changed shape"; exit 1; fi
[ "$PASSED" -gt 0 ] || { cat "$LOG"; echo "FAIL: mcp-tools.bh-5218-test: 0 tests passed — the suite did not run"; exit 1; }
[ "$SKIPPED" = 0 ] || { cat "$LOG"; echo "FAIL: mcp-tools.bh-5218-test: $SKIPPED test(s) SKIPPED"; exit 1; }
echo "mcp-tools.bh-5218-test: $PASSED passed, 0 skipped"
