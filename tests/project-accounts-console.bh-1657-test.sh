#!/bin/bash
# tests/project-accounts-console.bh-1657-test.sh — the console PROJECT
# ACCOUNTS table on /settings (BH-1657).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/project-accounts.bh-1657.test.js (reached through the
# console-ui job). What this file adds is the part the impact lane and the
# orphan ratchet can SEE: it names the two new sources by path, drives the pure
# half for real, and holds the screen to the rules a reviewer would otherwise
# check by eye (the models-console.bh-1510-3 pattern).
#
#   1. lib/project-accounts.js, DRIVEN: the label rule refuses a token and never
#      echoes it, `shared` unpins, rows are the union of fleet and pins, and the
#      write path confirms before it writes the exact settings row.
#   2. ProjectAccounts.js sorts through the shared SortableTable, links every
#      project cell, and never calls a native dialog; the confirm is the in-app
#      modal (the setter is built in Settings.js from useConfirm).
# Run from anywhere: tests/project-accounts-console.bh-1657-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/project-accounts.js"
SCREEN="$DIR/console-ui/src/screens/ProjectAccounts.js"
SETTINGS="$DIR/console-ui/src/screens/Settings.js"

for f in "$LIB" "$SCREEN" "$SETTINGS"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "project-accounts-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { checkAccountLabel, accountRows, makeAccountSetter, SHARED }
  from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

eq('label-ok',        checkAccountLabel(' acct-a ').value, 'acct-a');
eq('shared-ok',       checkAccountLabel(SHARED), { ok: true, value: 'shared' });
eq('empty-refused',   checkAccountLabel('').ok, false);
const tok = checkAccountLabel('sk-ant-FAKE0000');
eq('token-refused',   tok.ok, false);
eq('token-not-echoed', tok.message.includes('FAKE0000'), false);
eq('dotdot-refused',  checkAccountLabel('a..b').ok, false);

const rows = accountRows({ settings: [
  { key: 'account.p-b', value: 'acct-b', actor: 'console', updated_at: 'T' },
  { key: 'account.p-gone', value: 'shared' },
  { key: 'lane.x.y', value: '1' } ] }, ['p-a', 'p-b']);
eq('rows-union-sorted', rows.map((r) => r.project), ['p-a', 'p-b', 'p-gone']);
eq('rows-labels',       rows.map((r) => r.label), [null, 'acct-b', null]);
eq('rows-href',         rows[0].href, '/settings?project=p-a');

const asked = [], writes = [];
const setter = makeAccountSetter({
  confirm: async (o) => { asked.push(o); return true; },
  writeSetting: async (b) => { writes.push(b); }, refresh: () => {}, onNote: () => {} });
const w = await setter.set(rows[0], 'acct-a');
eq('set-written',    w.status, 'written');
eq('set-confirmed',  asked.length, 1);
eq('set-body',       writes[0], { key: 'account.p-a', value: 'acct-a', actor: 'console' });
const bad1 = await setter.set(rows[0], 'sk-ant-FAKE0000');
eq('token-never-asks-or-writes', [bad1.status, asked.length, writes.length], ['invalid', 1, 1]);
const no = makeAccountSetter({ confirm: async () => false, writeSetting: async (b) => { writes.push(b); } });
eq('cancel-writes-nothing', [(await no.set(rows[1], SHARED)).status, writes.length], ['cancelled', 1]);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape --------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "ProjectAccounts.js must use the shared SortableTable"
grep -q '<\${Link} to=\${r.href}' "$SCREEN" && ok || bad "ProjectAccounts.js must link every project cell (no dead rows)"
grep -q "from '../ui/Modal.js'" "$SETTINGS" && grep -q 'makeAccountSetter' "$SETTINGS" && ok \
  || bad "Settings.js must build the account setter on the in-app modal (useConfirm)"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ window\.(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the PROJECT ACCOUNTS screen"
else
  ok
fi

echo "project-accounts-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
