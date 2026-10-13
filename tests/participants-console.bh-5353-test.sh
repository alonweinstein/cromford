#!/bin/bash
# tests/participants-console.bh-5353-test.sh — the Mission Control participants
# screen, its worker detail route and its coord proxy rows (BH-5353, BH-5348.4).
#
# The behaviour is proved by three node suites, all run here:
#   worker/jobs/test/participants-detail.bh-5353.test.js   the routes through worker.fetch
#   console-ui/tests/participants.bh-5353.test.js           the mounted screens
#   console-ui/tests/participants-proxy.bh-5353.test.js     the proxy's decision rows
# What this file adds is what the impact lane and the orphan ratchet can SEE
# (the build-queue-panel-console.bh-2510 pattern):
#   1. every new or changed source, named by rooted path.
#   2. Participants.js sorts through the shared SortableTable, confirms through
#      useConfirm, and never calls a native dialog.
#   3. the worker route never reads the Fly pool's `machines` table.
#   4. the node suites: the worker one whenever node is present (after
#      rendering catalog/lanes.json), the console ones when the console-ui
#      dependencies are installed.
# Run from anywhere: tests/participants-console.bh-5353-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SCREEN="$DIR/console-ui/src/screens/Participants.js"
ROUTE="$DIR/worker/jobs/src/routes/participants.js"
PROXY="$DIR/console-ui/functions/api/coord/[[path]].js"

for f in "$SCREEN" "$ROUTE" "$PROXY"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 2: the screen's shape ----------------------------------------------------
grep -q "import { SortableTable } from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "Participants.js must use the shared SortableTable"
grep -q "import { useConfirm } from '../ui/Modal.js'" "$SCREEN" && ok || bad "Participants.js must confirm through useConfirm"
if grep -nE '(^|[^A-Za-z_.])(confirm|alert|prompt)\(' "$SCREEN"; then bad "Participants.js calls a native dialog"; else ok; fi

# --- 3: participant_machines, never the pool's machines table -----------------
if grep -nE '(FROM|JOIN|UPDATE|INTO)[[:space:]]+machines\b' "$ROUTE"; then bad "participants.js touches the pool machines table"; else ok; fi
grep -q 'leadToken: true' "$PROXY" && ok || bad "the coord proxy has no participant decision rows"

command -v node >/dev/null 2>&1 || { echo "participants-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 4: the node suites -------------------------------------------------------
if ! "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1; then
  # worker/jobs imports the git-ignored catalog/lanes.json statically, so it is
  # rendered first, as tests/jobs-worker-test.sh does (BH-1247).
  bad "catalog/lanes.json could not be composed from catalog/lanes.d"
elif WOUT=$(cd "$DIR/worker/jobs" && node --test test/participants-detail.bh-5353.test.js 2>&1); then ok
else bad "worker/jobs/test/participants-detail.bh-5353.test.js failed:"; printf '%s\n' "$WOUT" | grep -E '^not ok|Error' | head -20
fi
if [ -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  for t in tests/participants.bh-5353.test.js tests/participants-proxy.bh-5353.test.js; do
    if COUT=$(cd "$DIR/console-ui" && node --test "$t" 2>&1); then ok
    else bad "console-ui/$t failed:"; printf '%s\n' "$COUT" | grep -E '^not ok|Error' | head -20
    fi
  done
else
  echo "participants-console: console node suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
fi

echo "participants-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
