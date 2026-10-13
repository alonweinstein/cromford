#!/bin/bash
# tests/job-actions-console.bh-2323-test.sh — RETRY / REQUEUE on the Mission
# Control Job and Build screens (BH-2323).
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by node --test in
# console-ui/tests/job-actions.bh-2323.test.js and
# console-ui/tests/job-actions-proxy.bh-2323.test.js (reached through the
# console-ui job). What this file adds is the part the impact lane and the
# orphan ratchet can SEE: it names the two new sources by path, drives the pure
# half for real, and holds the screen to the rules a reviewer would otherwise
# check by eye (the account-usage-console.bh-1916 pattern).
#
#   1. lib/job-actions.js, DRIVEN: which rows get which buttons, the body sends
#      no actor and no max_attempts, a quiet row's confirm says the job may
#      still be alive, and the outcome line reads the worker's decision.
#   2. JobActions.js asks through the in-app useConfirm, is mounted on the Job
#      and Build screens, and never calls a native dialog.
#   3. both node suites, run for real when the console-ui dependencies are
#      installed.
# Run from anywhere: tests/job-actions-console.bh-2323-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/job-actions.js"
UI="$DIR/console-ui/src/ui/JobActions.js"
JOB="$DIR/console-ui/src/screens/Job.js"
BUILD="$DIR/console-ui/src/screens/Build.js"

for f in "$LIB" "$UI" "$JOB" "$BUILD"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "job-actions-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { availableActions, requestBody, confirmOpts, actionOutcome, runJobAction }
  from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const row = (o) => ({ id: 'J1', status: 'running', heartbeating: true, beat_age_s: 30, activity_age_s: 30, ...o });
const STALLED = row({ beat_age_s: 1200, activity_age_s: 1200 });
const QUIET = row({ heartbeating: false, beat_age_s: null, activity_age_s: 1200 });

// TEST-CHANGE (BH-2406): ABANDON joins these lists; tests/job-abandon.bh-2406-test.sh pins it.
eq('stalled-actions',  availableActions(STALLED), ['retry', 'requeue', 'abandon']);
eq('quiet-actions',    availableActions(QUIET), ['retry', 'requeue', 'abandon']);
eq('orphaned-actions', availableActions(row({ status: 'orphaned', activity_age_s: 1200 })), ['requeue', 'abandon']);
eq('running-none',     availableActions(row({})), []);
eq('done-none',        availableActions(row({ status: 'done' })), []);
eq('null-none',        availableActions(null), []);
eq('body-keys',        Object.keys(requestBody('requeue')), ['detail']);
eq('quiet-warns',      /may still be alive/.test(confirmOpts('retry', QUIET).body), true);
eq('stalled-no-warn',  /may still be alive/.test(confirmOpts('retry', STALLED).body), false);
eq('copy-names-job',   confirmOpts('requeue', STALLED).body.includes('J1'), true);
eq('outcome-queued',   actionOutcome('retry', { result: { decision: 'queued_for_retry', reason: 'r' } }).tone, 'ok');
eq('outcome-held',     actionOutcome('requeue', { result: { decision: 'held', reason: 'sibling live' } }).text,
  'REQUEUE: Held, not requeued: sibling live');
eq('outcome-nodec',    actionOutcome('retry', { result: {} }).tone, 'bad');

let sent = 0, reloads = 0;
const apiObj = { retryJob: async () => { sent++; return { decision: 'parked' }; }, requeueJob: async () => { sent++; return {}; } };
eq('cancel-sends-none', await runJobAction({ apiObj, job: STALLED, action: 'retry', confirm: async () => false, reload: () => reloads++ }), null);
eq('cancel-count',      [sent, reloads], [0, 0]);
const out = await runJobAction({ apiObj, job: STALLED, action: 'retry', confirm: async () => true, reload: () => reloads++ });
eq('confirm-sends-one', [sent, reloads, out.tone], [1, 1, 'warn']);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape --------------------------------------------------
grep -q "useConfirm" "$UI" && ok || bad "JobActions.js must ask through the in-app useConfirm modal"
grep -q "JobActions" "$JOB" && ok || bad "Job.js must mount JobActions"
grep -q "JobActions" "$BUILD" && ok || bad "Build.js must mount JobActions"
CODE=$(grep -hvE '^[[:space:]]*//' "$UI" "$LIB")
if [[ "$CODE" =~ (window\.|globalThis\.|[^.a-zA-Z_])(confirm|alert|prompt)[[:space:]]*\([[:space:]]*[\'\"\`] ]]; then
  bad "a native dialog in the job actions"
else
  ok
fi

# --- 3: the node suites, driven ----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "job-actions-console: node suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/job-actions.bh-2323.test.js tests/job-actions-proxy.bh-2323.test.js 2>&1); then ok
  else bad "console-ui job-actions node suites failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "job-actions-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
