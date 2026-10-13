#!/bin/bash
# tests/build-queue-panel-console.bh-2510-test.sh — the BUILD QUEUE table on
# /p/<project> and its audited RELEASE / DROP route (BH-3151, BH-2510.1).
#
# The behaviour is proved by two node suites, both run here:
#   worker/jobs/test/queue-actions.bh-2510.test.js   the route through worker.fetch
#   console-ui/tests/build-queue-panel.bh-2510.test.js  the lib and the mounted screen
# What this file adds is what the impact lane and the orphan ratchet can SEE
# (the cost-breaker-console.bh-2331 pattern):
#   1. every new or filled source, named by rooted path.
#   2. the pure lib, DRIVEN: which action a row offers and the body it sends.
#   3. BuildQueuePanel.js sorts through the shared SortableTable, confirms
#      through useConfirm, and never calls a native dialog.
#   4. both node suites: the worker one whenever node is present (after
#      rendering catalog/lanes.json), the console one when the console-ui
#      dependencies are installed.
# Run from anywhere: tests/build-queue-panel-console.bh-2510-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/build-queue-panel.js"
SCREEN="$DIR/console-ui/src/screens/BuildQueuePanel.js"
ROUTE="$DIR/worker/jobs/src/routes/queue-actions.js"

for f in "$LIB" "$SCREEN" "$ROUTE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 3: the screen's shape ----------------------------------------------------
grep -q "import { SortableTable } from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "BuildQueuePanel.js must use the shared SortableTable"
grep -q "import { useConfirm } from '../ui/Modal.js'" "$SCREEN" && ok || bad "BuildQueuePanel.js must confirm through useConfirm"
if grep -nE '(^|[^A-Za-z_.])(confirm|alert|prompt)\(' "$SCREEN"; then bad "BuildQueuePanel.js calls a native dialog"; else ok; fi

command -v node >/dev/null 2>&1 || { echo "build-queue-panel-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 2: the lib, driven -------------------------------------------------------
OUT=$(node --input-type=module -e "
import { allowedActions, actionBody, BUILD_STATUSES } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('statuses', BUILD_STATUSES, ['ready', 'queued', 'claimed']);
eq('claimed', allowedActions({ status: 'claimed' }), ['release']);
eq('queued',  allowedActions({ status: 'queued' }), ['drop']);
eq('ready',   allowedActions({ status: 'ready' }), ['drop']);
eq('done',    allowedActions({ status: 'done' }), []);
eq('failed',  allowedActions({ status: 'failed' }), []);
eq('body',    actionBody('p', { ticket_key: 'BH-1', actor: 'x' }, 'drop', ' why '), { project: 'p', key: 'BH-1', action: 'drop', reason: 'why' });
console.log('end');
" 2>&1)
ENDED=0
while IFS= read -r line; do
  case "$line" in
    end) ENDED=1 ;;
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"
[ "$ENDED" -eq 1 ] || bad "lib: the node script did not run to the end"

# --- 4: the node suites -------------------------------------------------------
if ! "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1; then
  # worker/jobs imports the git-ignored catalog/lanes.json statically, so it is
  # rendered first, as tests/jobs-worker-test.sh does (BH-1247).
  bad "catalog/lanes.json could not be composed from catalog/lanes.d"
elif WOUT=$(cd "$DIR/worker/jobs" && node --test test/queue-actions.bh-2510.test.js 2>&1); then ok
else bad "worker/jobs/test/queue-actions.bh-2510.test.js failed:"; printf '%s\n' "$WOUT" | grep -E '^not ok|Error' | head -20
fi
if [ -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  if COUT=$(cd "$DIR/console-ui" && node --test tests/build-queue-panel.bh-2510.test.js 2>&1); then ok
  else bad "console-ui/tests/build-queue-panel.bh-2510.test.js failed:"; printf '%s\n' "$COUT" | grep -E '^not ok|Error' | head -20
  fi
else
  echo "build-queue-panel-console: console node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
fi

echo "build-queue-panel-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
