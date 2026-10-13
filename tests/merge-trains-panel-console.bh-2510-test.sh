#!/bin/bash
# tests/merge-trains-panel-console.bh-2510-test.sh — the read-only MERGE TRAINS
# table in the QUEUES section of /p/<project> (BH-3153, BH-2510.3).
#
#   1. both sources exist, named by rooted path so the orphan ratchet sees them.
#   2. the panel renders through SortableTable, and neither file writes or
#      opens a native dialog (supplementary: the node suite asserts every
#      request the mounted panel sends is a GET).
#   3. the node suites, run for real when the console-ui deps are installed:
#      the panel's own and the QUEUES contract's (which mounts ProjectScreen).
# Run from anywhere: tests/merge-trains-panel-console.bh-2510-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/merge-trains-panel.js"
PANEL="$DIR/console-ui/src/screens/MergeTrainsPanel.js"

for f in "$LIB" "$PANEL"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 2: shape of the sources --------------------------------------------------
if [ -f "$PANEL" ]; then
  grep -q "import { SortableTable } from '../ui/SortableTable.js'" "$PANEL" && ok || bad "the panel must import SortableTable"
  grep -q '<${SortableTable}' "$PANEL" && ok || bad "the panel must render SortableTable"
  grep -q 'api.mergeTrains(' "$PANEL" && ok || bad "the panel must read api.mergeTrains"
fi
for f in "$LIB" "$PANEL"; do
  [ -f "$f" ] || continue
  for pat in 'post(' 'queueAction' "method: 'POST'" 'method: "POST"' 'confirm(' 'alert(' 'prompt('; do
    if grep -qF "$pat" "$f"; then bad "$(basename "$f") must not contain $pat"; else ok; fi
  done
done

# --- 3: the node suites, when deps are installed -----------------------------
if [ -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/merge-trains-panel.bh-2510.test.js tests/queue-panel.bh-2510.test.js 2>&1); then ok
  else bad "the merge-trains node suites failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
else
  echo "merge-trains-panel-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
fi

echo "merge-trains-panel-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
