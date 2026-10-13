#!/bin/bash
# tests/registry-seed-console.bh-2521-test.sh — the SEED REGISTRY panel on
# /hub (BH-2521, slice BH-2677).
#
# The panel is proved by node --test in console-ui/tests/registry-seed.bh-2521.test.js
# (the lib) and console-ui/tests/seed-registry-panel.bh-2521.test.js (the view and
# the mounted panel). This file is what the impact lane and the orphan ratchet
# can see (the restore-lab-console.bh-1946 pattern):
#   1. both new sources exist, named here by rooted path.
#   2. neither file calls a native dialog; in SeedRegistry.js the useConfirm
#      function is named `ask`, so any bare confirm( there is a failure too.
#   3. neither file imports worker code: the panel talks HTTP through api.js.
#   4. lib/registry-seed.js, DRIVEN: a plan with no plan_fp is an error, a 200
#      apply with no id is a failure, a stale started run is "outcome unknown",
#      a blank reason sends no apply (BH-2995).
#   5. When console-ui's node deps are installed, the node suites run too,
#      including console-ui/tests/hub-reason-panels.bh-2995.test.js.
# Run from anywhere: tests/registry-seed-console.bh-2521-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/registry-seed.js"
PANEL="$DIR/console-ui/src/screens/hub/SeedRegistry.js"

for f in "$LIB" "$PANEL"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 2: no native dialogs ---------------------------------------------------
# The lib's requestApply takes the dialog as a `confirm` parameter (the
# restore-lab shape), so the bare-confirm check is the panel's alone.
CODE=$(grep -hvE '^[[:space:]]*//' "$PANEL" 2>/dev/null)
LIBCODE=$(grep -hvE '^[[:space:]]*//' "$LIB" 2>/dev/null)
[ -n "$CODE" ] && [ -n "$LIBCODE" ] && ok || bad "no code read from the panel and lib"
if [[ "$CODE" =~ (^|[^A-Za-z0-9_])(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog (or a bare confirm call) in SeedRegistry.js"
else
  ok
fi
if [[ "$LIBCODE" =~ (window|globalThis)\.(confirm|alert|prompt)[[:space:]]*\( ]] \
  || [[ "$LIBCODE" =~ (^|[^A-Za-z0-9_.])(alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in lib/registry-seed.js"
else
  ok
fi
grep -q "useConfirm } from '../../ui/Modal.js'" "$PANEL" && grep -q 'useConfirm()' "$PANEL" && ok \
  || bad "SeedRegistry.js must confirm through the in-app modal (useConfirm)"

# --- 3: no worker import ----------------------------------------------------
if grep -nE "^[[:space:]]*import[^;]*['\"][^'\"]*worker/" "$PANEL" "$LIB"; then
  bad "the SEED REGISTRY panel imports worker code"
else
  ok
fi

command -v node >/dev/null 2>&1 || { echo "registry-seed-console: node checks SKIPPED — node is not installed on this box"; echo "registry-seed-console: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

# --- 4: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { planView, applyOutcome, runsView, submitApply } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const throws = (f) => { try { f(); return false; } catch { return true; } };
const FP = 'c'.repeat(64);

eq('no-fp-throws',      throws(() => planView({ insert: [], update: [], prune: [] })), true);
eq('upper-fp-throws',   throws(() => planView({ insert: [], update: [], prune: [], plan_fp: 'C'.repeat(64) })), true);
eq('pending',           planView({ insert: ['a'], update: [], prune: ['b'], plan_fp: FP }).pending, 2);
eq('no-id-bad',         applyOutcome({ result: { changed: 3 } }).tone, 'bad');
eq('id-ok',             applyOutcome({ result: { id: 4, changed: 2, pruned: 0 } }), { tone: 'ok', text: 'Applied #4: 2 changed, 0 pruned.' });
const now = Date.parse('2026-09-26T12:00:00Z');
eq('stale-unknown',     runsView({ runs: [{ status: 'started', started_at: '2026-09-26T11:49:00Z' }] }, now).rows[0].display, 'outcome unknown');
eq('fresh-in-progress', runsView({ runs: [{ status: 'started', started_at: '2026-09-26T11:58:00Z' }] }, now).rows[0].display, 'in progress');
let sent = 0;
const apiObj = { seedApply: async () => { sent++; return { id: 1, changed: 0, pruned: 0 }; } };
const plan = planView({ insert: ['a'], update: [], prune: [], plan_fp: FP });
eq('cancel-sends-none', [await submitApply(apiObj, plan, false, 'why'), sent], [null, 0]);
eq('blank-reason-none', [await submitApply(apiObj, plan, true, '  '), sent], [null, 0]);
eq('true-sends-one',    [(await submitApply(apiObj, plan, true, 'why')).tone, sent], ['ok', 1]);
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

# --- 5: the node suites, when deps are installed ----------------------------
if [ -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  LOG=$(mktemp)
  if (cd "$DIR/console-ui" && node --test tests/registry-seed.bh-2521.test.js tests/seed-registry-panel.bh-2521.test.js tests/hub-reason-panels.bh-2995.test.js >"$LOG" 2>&1); then
    ok
  else
    cat "$LOG"; bad "the seed-registry node suites failed"
  fi
  rm -f "$LOG"
else
  echo "registry-seed-console: node suites SKIPPED — console-ui/node_modules is not installed"
fi

echo "registry-seed-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
