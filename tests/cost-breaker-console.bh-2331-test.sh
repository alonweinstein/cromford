#!/bin/bash
# tests/cost-breaker-console.bh-2331-test.sh — the console COST BREAKER
# section on /costs (BH-2331).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/cost-breaker.bh-2331.test.js (reached through the console-ui
# job). What this file adds is the part the impact lane and the orphan ratchet
# can SEE: it names the two new sources by path, drives the pure half for real,
# and holds the screen to the rules a reviewer would otherwise check by eye
# (the account-usage-console.bh-1916 pattern).
#
#   1. lib/cost-breaker.js, DRIVEN: only cb_halt's two suffixes on an active
#      paused-<project> row count as a trip, an unreadable settings read is
#      UNKNOWN (never ON), a non-numeric settings value falls back to the
#      default, CAP HIT follows refused > 0, a blank reason blocks RESET, and
#      the RESET action sends nothing without a reason and reports nothing
#      without a numeric count.
#   2. CostBreaker.js sorts through the shared SortableTable, links every
#      project cell, is mounted on /costs, and never calls a native dialog.
#   3. the node suite console-ui/tests/cost-breaker.bh-2331.test.js, run for
#      real when the console-ui dependencies are installed.
# Run from anywhere: tests/cost-breaker-console.bh-2331-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/cost-breaker.js"
SCREEN="$DIR/console-ui/src/screens/CostBreaker.js"
COSTS="$DIR/console-ui/src/screens/Costs.js"

for f in "$LIB" "$SCREEN" "$COSTS"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "cost-breaker-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { isAutohaltReason, autohaltTrips, autohaltState, callGuardRows,
         resetFormState, makeResetAction, AUTOHALT_KEY, GUARD_LIMIT }
  from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

eq('key',            AUTOHALT_KEY, 'lane.pipeline-health.cost_autohalt');
eq('reason-cost',    isAutohaltReason('spend 42 over cap (cost autohalt)'), true);
eq('reason-zero',    isAutohaltReason('no merges in 6h (zero-merge breaker) '), true);
eq('reason-other',   isAutohaltReason('paused by operator for a demo'), false);
eq('reason-null',    isAutohaltReason(null), false);

const t = autohaltTrips({ flags: [
  { name: 'paused-alpha', active: 1, reason: 'x (cost autohalt)', updated_at: 't1', actor: 'pipeline-health' },
  { name: 'paused-beta',  active: '1', reason: 'y (zero-merge breaker)' },
  { name: 'paused-gamma', active: 0, reason: 'z (cost autohalt)' },
  { name: 'paused-delta', active: 1, reason: 'a human pause' },
  { name: 'paused-all',   active: 1, reason: 'q (cost autohalt)' },
  { name: 'paused-box-3', active: 1, reason: 'q (cost autohalt)' },
  { name: 'paused-lane-x', active: 1, reason: 'q (cost autohalt)' } ] });
eq('trips-projects', t.trips.map((r) => r.project), ['alpha', 'beta']);
eq('trips-readable', t.unreadable, false);
eq('trips-since',    [t.trips[0].since, t.trips[1].since], ['t1', null]);
eq('trips-unread',   autohaltTrips({}).unreadable, true);

eq('state-unread',   autohaltState(null).on, null);
eq('state-default',  autohaltState({ settings: [] }), { on: true, source: 'default', raw: null });
eq('state-off',      autohaltState({ settings: [{ key: 'LANE.PIPELINE-HEALTH.COST_AUTOHALT', value: '0' }] }).on, false);
eq('state-on',       autohaltState({ settings: [{ key: AUTOHALT_KEY, value: ' 1 ' }] }), { on: true, source: 'settings', raw: '1' });
const junk = autohaltState({ settings: [{ key: AUTOHALT_KEY, value: 'off' }] });
eq('state-junk',     [junk.on, junk.source, typeof junk.note], [true, 'default', 'string']);

const g = callGuardRows({ rows: [
  { project: 'p', stage: 'plan', fp: 'f1', paid: '2', refused: '3', last_at: 't' },
  { project: 'q', stage: 'exec', fp: 'f2', paid: 1, refused: 0 },
  { project: 'r', stage: 'exec', fp: 'f3', paid: null, refused: '' } ] });
eq('guard-cap',      g.rows.map((r) => r.capHit), [true, false, false]);
eq('guard-nums',     [g.rows[0].paid, g.rows[0].refused, g.rows[2].paid, g.rows[2].refused], [2, 3, null, null]);
eq('guard-key',      g.rows[0].key, 'p|plan|f1');
eq('guard-capped',   g.capped, false);
eq('guard-full',     callGuardRows({ rows: Array.from({ length: GUARD_LIMIT }, (_, i) => ({ project: 'p', stage: 's', fp: String(i) })) }).capped, true);
eq('guard-unread',   callGuardRows({}).unreadable, true);

eq('form-blank',     resetFormState('   ').blocked, true);
eq('form-reason',    resetFormState('stuck key').blocked, false);

// The RESET action: confirm writes the reason through the form object it is handed.
const row = { key: 'p|plan|f1', project: 'p', stage: 'plan', fp: 'f1' };
const run = async (reason, answer) => {
  const sent = []; const msgs = []; let reloads = 0;
  const act = makeResetAction({
    confirm: async (o) => { o.form.reason = reason; return true; },
    reset: async (b) => { sent.push(b); return answer; },
    reload: () => { reloads++; }, onMsg: (m) => msgs.push(m)
  });
  await act(row);
  return { sent, msgs, reloads };
};
const blank = await run('  ', { reset: 1 });
eq('reset-blank-sends-nothing', [blank.sent.length, blank.msgs[0].ok], [0, false]);
const good = await run(' guard stuck ', { reset: 2 });
eq('reset-sends',    good.sent, [{ project: 'p', stage: 'plan', fp: 'f1', reason: 'guard stuck' }]);
eq('reset-reports',  [good.msgs[0].ok, good.reloads], [true, 1]);
const nocount = await run('why', { ok: true });
eq('reset-no-count', [nocount.msgs[0].ok, nocount.reloads], [false, 0]);
const cancelled = makeResetAction({ confirm: async () => false, reset: async () => { throw new Error('sent'); },
  reload: () => {}, onMsg: () => { throw new Error('msg'); } });
await cancelled(row);
eq('reset-cancel',   true, true);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape --------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "CostBreaker.js must use the shared SortableTable"
grep -q '<\${Link} to=\${`/p/' "$SCREEN" && ok || bad "CostBreaker.js must link every project cell to /p/<project> (no dead rows)"
grep -q "useConfirm" "$SCREEN" && ok || bad "CostBreaker.js must confirm RESET through the in-app useConfirm modal"
grep -q "CostBreakerSection" "$COSTS" && ok || bad "Costs.js must mount the COST BREAKER section"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ window\.(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the COST BREAKER screen"
else
  ok
fi

# --- 3: the node suite, driven -----------------------------------------------
# console-ui/tests/cost-breaker.bh-2331.test.js drives the proxy, the api
# helpers and a server-side render. Run here too, so this suite is its door as
# well as the console-ui CI job's; without the console deps it says so and skips.
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "cost-breaker-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/cost-breaker.bh-2331.test.js 2>&1); then ok
  else bad "console-ui/tests/cost-breaker.bh-2331.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "cost-breaker-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
