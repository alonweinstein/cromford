#!/bin/bash
# tests/models-console.bh-1510-3-test.sh — the console MODELS screen (BH-1510.3).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/models*.test.js (reached through the console-ui job). What
# this file adds is the part the impact lane and the literal ratchet can SEE:
# it names the two new sources by path, drives the pure half for real, and
# holds the screen to the rules a reviewer would otherwise check by eye.
#
#   1. lib/models.js, DRIVEN: attribution grades, the hub-only lane on a
#      project tab, the ledger-shaped `since`, the validation that runs before
#      any modal, and the write path's exact body.
#   2. neither file carries a model id (the catalog's own vocabulary, the same
#      one tests/model-literal-lint.sh uses) — every model on the screen comes
#      from model_prices or model_routes.
#   3. Models.js confirms through the shared in-app modal, sorts through the
#      shared SortableTable, and never calls a native dialog.
# Run from anywhere: tests/models-console.bh-1510-3-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/models.js"
SCREEN="$DIR/console-ui/src/screens/Models.js"
PRICES="$DIR/catalog/model-prices.json"

for f in "$LIB" "$SCREEN" "$PRICES"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "models-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { attributionFor, spendPlan, spendSince, validateLadder, makeModelActions, modelRows }
  from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

eq('exact',   attributionFor('build.qa').kind, 'exact');
eq('shared',  attributionFor('build.review').kind, 'shared');
eq('partial', attributionFor('greenfield').kind, 'partial');
eq('none',    attributionFor('auth.fallback').kind, 'none');
eq('unknown-role-is-none', attributionFor('some.future.role').kind, 'none');

const plan = spendPlan(['alert.triage', 'build.qa'], 'project-4');
eq('hub-lane-na-on-project', plan.byRole['alert.triage'].kind, 'none');
eq('project-scoped-read', plan.queries.map((q) => q.params), [{ stage: 'qa', project: 'project-4' }]);

// A fixed epoch, so this asserts a shape and an offset, never today's date.
eq('since-shape', spendSince(1790000000000), '2026-09-14T14:13:20Z');

const priced = new Set(['m-a', 'm-b']);
eq('refuse-unpriced', validateLadder([{ model: 'm-x', runner: 'claude' }], priced, ['claude']).ok, false);
eq('refuse-runner',   validateLadder([{ model: 'm-a', runner: 'nope' }], priced, ['claude']).ok, false);
eq('refuse-empty',    validateLadder([], priced, ['claude']).ok, false);

// No attribution is a dash (null), never a confident zero.
const rows = modelRows({ routes: { roles: [{ role: 'auth.fallback', source: 'hub', ladder: [{ position: 0, model: 'm-a', runner: 'claude' }] }] },
  prices: { per_token: { 'm-a': { prompt: 0.000001, completion: 0.000002 } } }, spend: {}, plan: spendPlan(['auth.fallback'], null), project: null });
eq('no-attribution-null', [rows[0].usd_7d, rows[0].calls_7d, rows[0].price_in], [null, null, 1]);

const writes = [], asked = [];
const actions = makeModelActions({
  confirm: async (o) => { asked.push(o); return true; },
  writeLadder: async (b) => { writes.push(b); }, resetLadder: async () => {}, refresh: () => {}, onNote: () => {}
});
const r = await actions.saveLadder({ role: 'build.qa', project: null, before: [{ position: 0, model: 'm-a', runner: 'claude' }],
  draft: [{ model: 'm-b', runner: 'claude' }], priced, runners: ['claude'], reason: 'why' });
eq('save-written', r.status, 'written');
eq('save-confirmed-first', asked.length, 1);
eq('save-body', writes[0], { role: 'build.qa', project: null, ladder: [{ model: 'm-b', runner: 'claude' }], actor: 'console', reason: 'why' });
const bad1 = await actions.saveLadder({ role: 'build.qa', project: null, before: [], draft: [{ model: 'm-x', runner: 'claude' }], priced, runners: ['claude'] });
eq('invalid-never-asks', [bad1.status, asked.length], ['invalid', 1]);
const rs = await actions.resetOverride({ role: 'build.qa', project: null, current: [], hub: [] });
eq('reset-refuses-hub', rs.status, 'invalid');
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: no model id in either file -----------------------------------------
IDS=$(node -e "
const p = require('$PRICES');
console.log(Object.keys(p.per_token || {}).join('\n'));
" 2>/dev/null)
[ -n "$IDS" ] && ok || bad "could not read the model vocabulary from $PRICES"
HITS=0
while IFS= read -r id; do
  [ -z "$id" ] && continue
  for f in "$LIB" "$SCREEN"; do
    if grep -qF -- "'$id'" "$f" || grep -qF -- "\"$id\"" "$f" || grep -qF -- "\`$id\`" "$f"; then
      bad "model-id literal $id in ${f#"$DIR"/}"; HITS=$((HITS+1))
    fi
  done
done <<< "$IDS"
[ "$HITS" -eq 0 ] && ok

# --- 3: the screen's shape --------------------------------------------------
grep -q "from '../ui/Modal.js'" "$SCREEN" && ok || bad "Models.js must confirm through ui/Modal.js (useConfirm)"
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "Models.js must use the shared SortableTable"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ window\.(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the MODELS screen"
else
  ok
fi
grep -q "api.putModelRoute" "$SCREEN" && ok || bad "Models.js writes through api.putModelRoute (the audited PUT)"
grep -q "api.resetModelRoute" "$SCREEN" && ok || bad "Models.js resets through api.resetModelRoute (the audited reset)"

echo "models-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
