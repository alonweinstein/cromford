#!/bin/bash
# tests/standby-verify-console.bh-2519-test.sh — standby VERIFY from Mission
# Control (BH-2519 / BH-2642): the pure lib, the three StandbyVerify.js
# components and the coord proxy's POST hub/standby/verify row.
#
# The components are proved by node --test in
# console-ui/tests/standby-verify.bh-2519.test.js and the proxy row by
# console-ui/tests/standby-verify-proxy.bh-2519.test.js. This file names the new
# sources by path for the impact lane and the orphan ratchet, drives the lib
# for real, and holds the screen to the no-native-dialog rule.
#
#   S0. both sources exist.
#   S1. lib/standby-verify.js, DRIVEN: the body is exactly {box, confirm:true};
#       deduped reads "already queued", a 409 unknown_standby and an answer with
#       no id are failures; the newest run per box wins; anything but a literal
#       true from the dialog sends nothing.
#   S2. StandbyVerify.js confirms through useConfirm and calls no native dialog.
#   S3. When console-ui's node deps are installed, the two node suites run too.
# Run from anywhere: tests/standby-verify-console.bh-2519-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/standby-verify.js"
SCREEN="$DIR/console-ui/src/screens/hub/StandbyVerify.js"

# --- S0 -----------------------------------------------------------------------
for f in "$LIB" "$SCREEN"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "standby-verify-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- S1: the lib, driven -------------------------------------------------------
OUT=$(node --input-type=module -e "
import { verifyBody, verifyOutcome, submitVerify, historyView, lastVerifyByBox, confirmOpts, STANDBY_VERIFY_LIMIT }
  from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const throws = (f) => { try { f(); return false; } catch { return true; } };

eq('limit',              STANDBY_VERIFY_LIMIT, 20);
eq('body',               verifyBody('sb-1'), { box: 'sb-1', confirm: true });
eq('blank-box-throws',   throws(() => verifyBody('  ')), true);
eq('deduped-queued',     verifyOutcome('sb-1', { result: { deduped: true, id: 3 } }), { tone: 'warn', text: 'A verify for sb-1 is already queued (#3).' });
const e409 = Object.assign(new Error('unknown_standby'), { status: 409, body: { error: 'unknown_standby' } });
eq('409-unknown-bad',    verifyOutcome('sb-1', { error: e409 }), { tone: 'bad', text: 'Verify failed: sb-1 is not a known standby.' });
eq('id-ok',              verifyOutcome('sb-1', { result: { id: 4 } }), { tone: 'ok', text: 'Queued verify #4 for sb-1.' });
eq('no-id-bad',          verifyOutcome('sb-1', { result: { ok: true } }).tone, 'bad');
eq('no-runs-throws',     throws(() => historyView({ error: 'not_implemented' })), true);
eq('truncated-strict',   historyView({ runs: [], truncated: 'true' }).truncated, false);
const runs = [
  { id: 1, box: 'a', requested_at: '2026-09-26T09:00:00Z' },
  { id: 3, box: 'b', requested_at: '2026-09-26T08:00:00Z' },
  { id: 2, box: 'a', requested_at: '2026-09-26T10:00:00Z' },
];
const last = lastVerifyByBox(runs);
eq('newest-per-box',     [last.a.id, last.b.id], [2, 3]);
eq('confirm-title',      confirmOpts('sb-1', 'hub-a').title, 'VERIFY STANDBY');

let sent = 0;
const apiObj = { standbyVerify: async () => { sent++; return { id: 1 }; } };
eq('cancel-sends-none',  [await submitVerify(async () => false, apiObj, 'sb-1'), sent], [null, 0]);
eq('string-true-none',   [await submitVerify(async () => 'true', apiObj, 'sb-1'), sent], [null, 0]);
eq('one-sends-none',     [await submitVerify(async () => 1, apiObj, 'sb-1'), sent], [null, 0]);
eq('true-sends-one',     [(await submitVerify(async () => true, apiObj, 'sb-1')).tone, sent], ['ok', 1]);
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

# --- S2: the screen's shape ----------------------------------------------------
grep -q "useConfirm } from '../../ui/Modal.js'" "$SCREEN" && grep -q 'useConfirm()' "$SCREEN" && ok \
  || bad "StandbyVerify.js must confirm through the in-app modal (useConfirm)"
grep -q "from '../../ui/SortableTable.js'" "$SCREEN" && grep -q '<\${SortableTable}' "$SCREEN" && ok \
  || bad "StandbyVerify.js must render the shared SortableTable"
if grep -nE '\b(confirm|alert|prompt)\(' "$SCREEN" "$LIB"; then
  bad "a native dialog call (or a bare confirm( ) in the standby verify screen or lib"
else
  ok
fi

# --- S3: the node suites, when deps are installed ------------------------------
if [ -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  LOG=$(mktemp)
  if (cd "$DIR/console-ui" && node --test tests/standby-verify.bh-2519.test.js tests/standby-verify-proxy.bh-2519.test.js >"$LOG" 2>&1); then
    ok
  else
    cat "$LOG"; bad "the standby verify node suites failed"
  fi
  rm -f "$LOG"
else
  echo "standby-verify-console: node suites SKIPPED — console-ui/node_modules is not installed"
fi

echo "standby-verify-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
