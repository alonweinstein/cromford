#!/bin/bash
# tests/restore-lab-console.bh-1946-test.sh — the RESTORE LAB panel on /hub
# (BH-1946 / BH-1909.4).
#
# WHY A SHELL SUITE AS WELL. The panel is proved by node --test in
# console-ui/tests/restore-lab-panel.bh-1909.test.js and the proxy row by
# console-ui/tests/restore-lab-proxy.bh-1946.test.js. What this file adds is
# the part the impact lane and the orphan ratchet can SEE: it names the new lib
# by path, drives it for real, and holds the panel to the rules a reviewer
# would otherwise check by eye (the project-accounts-console.bh-1657 pattern).
#
#   1. lib/restore-lab.js, DRIVEN: a payload with no runs array is an error,
#      never an empty history; the request body is exactly
#      {box, snapshot:'latest', confirm:true}; deduped and a 409 already_open
#      read as "already queued", an answer with no id is a failure; anything
#      but an explicit true from the dialog sends nothing.
#   2. RestoreLab.js sorts through the shared SortableTable, confirms through
#      the in-app useConfirm modal, and never calls a native dialog.
#   3. When console-ui's node deps are installed, the two node suites run too.
# Run from anywhere: tests/restore-lab-console.bh-1946-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/restore-lab.js"
PANEL="$DIR/console-ui/src/screens/hub/RestoreLab.js"

for f in "$LIB" "$PANEL"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "restore-lab-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { historyView, panelState, requestBody, requestOutcome, submitRestore, RESTORE_LAB_LIMIT }
  from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const throws = (f) => { try { f(); return false; } catch { return true; } };

eq('501-body-throws',    throws(() => historyView({ error: 'not_implemented' })), true);
eq('null-throws',        throws(() => historyView(null)), true);
eq('state-error',        panelState({ view: null, error: new Error('x') }), 'error');
eq('state-loading',      panelState({ view: null, error: null }), 'loading');
eq('state-empty',        panelState({ view: historyView({ runs: [] }), error: null }), 'empty');
eq('state-rows',         panelState({ view: historyView({ runs: [{ id: 1 }] }), error: null }), 'rows');
eq('truncated-strict',   historyView({ runs: [], truncated: 'true' }).truncated, false);
eq('limit',              RESTORE_LAB_LIMIT, 20);
eq('body',               requestBody('hub-1'), { box: 'hub-1', snapshot: 'latest', confirm: true });
eq('blank-box-throws',   throws(() => requestBody('  ')), true);
eq('deduped-queued',     requestOutcome('hub-1', { result: { deduped: true, id: 3 } }).tone, 'warn');
const e409 = Object.assign(new Error('already_open'), { status: 409, body: { error: 'already_open', id: 9 } });
eq('409-queued',         requestOutcome('hub-1', { error: e409 }).text, 'A restore for hub-1 is already queued (#9).');
eq('id-ok',              requestOutcome('hub-1', { result: { id: 4 } }), { tone: 'ok', text: 'Queued restore #4 for hub-1.' });
eq('no-id-bad',          requestOutcome('hub-1', { result: { ok: true } }).tone, 'bad');

let sent = 0;
const apiObj = { restoreLab: async () => { sent++; return { id: 1 }; } };
eq('cancel-sends-none',  [await submitRestore(apiObj, 'hub-1', false), sent], [null, 0]);
eq('undef-sends-none',   [await submitRestore(apiObj, 'hub-1', undefined), sent], [null, 0]);
eq('true-sends-one',     [(await submitRestore(apiObj, 'hub-1', true)).tone, sent], ['ok', 1]);
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

# --- 2: the panel's shape ---------------------------------------------------
grep -q "from '../../ui/SortableTable.js'" "$PANEL" && grep -q '<\${SortableTable}' "$PANEL" && ok \
  || bad "RestoreLab.js must render the shared SortableTable"
grep -q "useConfirm } from '../../ui/Modal.js'" "$PANEL" && grep -q 'useConfirm()' "$PANEL" && ok \
  || bad "RestoreLab.js must confirm through the in-app modal (useConfirm)"
CODE=$(grep -hvE '^[[:space:]]*//' "$PANEL" "$LIB")
[ -n "$CODE" ] && ok || bad "no code read from the panel and lib"
# `confirm(` alone is the useConfirm function; the natives are window./globalThis.
# confirm, and alert/prompt under any spelling.
if [[ "$CODE" =~ (window|globalThis)\.(confirm|alert|prompt)[[:space:]]*\( ]] \
  || [[ "$CODE" =~ (^|[^A-Za-z0-9_.])(alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the RESTORE LAB panel"
else
  ok
fi

# --- 3: the node suites, when deps are installed ----------------------------
if [ -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  LOG=$(mktemp)
  if (cd "$DIR/console-ui" && node --test tests/restore-lab-panel.bh-1909.test.js tests/restore-lab-proxy.bh-1946.test.js >"$LOG" 2>&1); then
    ok
  else
    cat "$LOG"; bad "the restore-lab node suites failed"
  fi
  rm -f "$LOG"
else
  echo "restore-lab-console: node suites SKIPPED — console-ui/node_modules is not installed"
fi

echo "restore-lab-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
