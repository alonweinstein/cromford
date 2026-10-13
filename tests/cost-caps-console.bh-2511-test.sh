#!/bin/bash
# tests/cost-caps-console.bh-2511-test.sh — the console CAPS section on /costs
# (BH-2566, BH-2511.3).
#
# The screen's behaviour is proved by node --test in
# console-ui/tests/cost-caps.bh-2511.test.js (reached through the console-ui
# job). This file is the part the impact lane and the orphan ratchet can SEE:
# it names the two new sources by path, drives the pure half for real, and
# holds the screen to the rules a reviewer would otherwise check by eye (the
# cost-breaker-console.bh-2331 pattern).
#
#   1. lib/cost-caps.js, DRIVEN: a registry-seed row is CATALOG and an operator
#      row is OVERRIDE, a box-suffixed key is its own display-only row, a
#      non-array read is unreadable, the value grammar accepts and refuses the
#      readers' shapes, a blank reason blocks, and EDIT sends {key,value,reason}
#      with no actor and reports a worker failure as a failure.
#   2. CostCaps.js sorts through the shared SortableTable, confirms through the
#      in-app Modal, and never calls a native dialog.
#   3. the node suite console-ui/tests/cost-caps.bh-2511.test.js, run for real
#      when the console-ui dependencies are installed.
# Run from anywhere: tests/cost-caps-console.bh-2511-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/cost-caps.js"
SCREEN="$DIR/console-ui/src/screens/CostCaps.js"

for f in "$LIB" "$SCREEN"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "cost-caps-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { capRows, validateCapInput, editFormState, makeEditAction } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

const r = capRows([
  { key: 'conf.cost-caps.default', value: '100 5', actor: 'registry-seed' },
  { key: 'conf.cost-caps.budget.acme', value: '120', actor: 'console' },
  { key: 'conf.cost-caps.budget.acme.hub', value: '90', actor: 'console' },
  { key: 'lane.x.y', value: '1', actor: 'console' } ]);
const m = Object.fromEntries(r.rows.map((x) => [x.key, x]));
eq('rows',          r.rows.length, 3);
eq('seed',          [m['conf.cost-caps.default'].catalog, m['conf.cost-caps.default'].override, m['conf.cost-caps.default'].applies], ['100 5', null, '100 5']);
eq('override',      [m['conf.cost-caps.budget.acme'].catalog, m['conf.cost-caps.budget.acme'].override, m['conf.cost-caps.budget.acme'].applies], [null, '120', '120']);
eq('box',           [m['conf.cost-caps.budget.acme.hub'].box, m['conf.cost-caps.budget.acme.hub'].editable], ['hub', false]);
eq('unreadable',    capRows({}).unreadable, true);

for (const [k, v] of [['cost-caps.budget', '100 5'], ['cost-caps.ceiling', '4000'], ['lane-caps.lane', 'off 40000'], ['lane-caps.noise', '0']])
  eq('accept ' + k + ' ' + v, validateCapInput(k, v).ok, true);
for (const [k, v] of [['cost-caps.budget', '0'], ['cost-caps.budget', 'off'], ['cost-caps.budget', '1 2 3'], ['lane-caps.noise', '1.5'], ['lane-caps.lane', '2 0'], ['unknown', '1']])
  eq('refuse ' + k + ' ' + v, validateCapInput(k, v).ok, false);
eq('reason-blank',  editFormState('100', '  ', 'cost-caps.budget').blocked, true);
eq('reason-given',  editFormState('100', 'why', 'cost-caps.budget').blocked, false);

const run = async (put) => {
  const sent = []; const msgs = []; let reloads = 0;
  const act = makeEditAction({
    confirm: async (o) => { o.form.value = '120 5'; o.form.reason = 'demo'; return true; },
    put: async (b) => { sent.push(b); return put(); },
    reload: () => { reloads++; }, onMsg: (x) => msgs.push(x) });
  await act(m['conf.cost-caps.default']);
  return { sent, msgs, reloads };
};
const good = await run(() => ({ ok: true }));
eq('edit-sends',    good.sent, [{ key: 'conf.cost-caps.default', value: '120 5', reason: 'demo' }]);
eq('edit-reports',  [good.msgs[0].text, good.reloads], ['cap conf.cost-caps.default set to 120 5', 1]);
const fail = await run(() => { throw new Error('not implemented'); });
eq('edit-fails',    [fail.msgs[0].ok, fail.msgs[0].text, fail.reloads], [false, 'EDIT failed — not implemented', 0]);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape --------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "CostCaps.js must use the shared SortableTable"
grep -q "from '../ui/Modal.js'" "$SCREEN" && ok || bad "CostCaps.js must confirm EDIT through the in-app useConfirm modal"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ window\.(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the CAPS screen"
else
  ok
fi

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "cost-caps-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/cost-caps.bh-2511.test.js 2>&1); then ok
  else bad "console-ui/tests/cost-caps.bh-2511.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "cost-caps-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
