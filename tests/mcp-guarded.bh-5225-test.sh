#!/bin/bash
# tests/mcp-guarded.bh-5225-test.sh — BH-5225 (child 3 of #5218): the MCP guarded tools and generic defaults.
# Thin wrapper over mcp/test/generic-defaults.test.mjs, which spawns the REAL
# `node mcp/server.mjs` with only a console URL against the stub console, and
# checks merge_pr and set_automerge refuse (confirm_required,
# repo_not_allowlisted) and send nothing unless confirmed AND allowlisted. Two
# mutation cases prove each guard is load-bearing. It fails when node reports
# 0 passing tests or any skipped one.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mcp-guarded.bh-5225-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v node >/dev/null 2>&1 || { echo "mcp-guarded.bh-5225-test: SKIPPED — node is not installed on this box"; exit 0; }

# The sources this suite exercises, named by path so bin/test-impact.sh maps a
# change to any of them onto this suite.
for SRC in "$DIR/mcp/tools/guarded.mjs" "$DIR/mcp/test/generic-defaults.test.mjs" \
           "$DIR/mcp/server.mjs" "$DIR/mcp/test/lib/stub-console.mjs"; do
  [ -r "$SRC" ] || { echo "FAIL: mcp-guarded.bh-5225-test: missing $SRC"; exit 1; }
done

LOG="$T/node.log"
cd "$DIR" || exit 1
# Run the file directly, not under --test: --test reports the file itself as a
# passing test, so an emptied file would read "1 passed".
node --test-reporter=spec mcp/test/generic-defaults.test.mjs >"$LOG" 2>&1
RC=$?
PASSED=$(sed -n 's/^[^ ]* pass \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
SKIPPED=$(sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
if [ "$RC" -ne 0 ]; then cat "$LOG"; echo "FAIL: mcp-guarded.bh-5225-test: node rc=$RC"; exit 1; fi
if [ -z "$PASSED" ] || [ -z "$SKIPPED" ]; then cat "$LOG"; echo "FAIL: mcp-guarded.bh-5225-test: no test summary — the file ran no tests, or node's reporter changed shape"; exit 1; fi
[ "$PASSED" -gt 0 ] || { cat "$LOG"; echo "FAIL: mcp-guarded.bh-5225-test: 0 tests passed — the suite did not run"; exit 1; }
[ "$SKIPPED" = 0 ] || { cat "$LOG"; echo "FAIL: mcp-guarded.bh-5225-test: $SKIPPED test(s) SKIPPED"; exit 1; }
echo "mcp-guarded.bh-5225-test: $PASSED passed, 0 skipped"
