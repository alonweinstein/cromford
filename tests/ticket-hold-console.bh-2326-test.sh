#!/bin/bash
# tests/ticket-hold-console.bh-2326-test.sh — the ticket-hold CONTRACT in the
# console (BH-2326.0): the pure lib, the HELD tag, api.ticketHold and the two
# command types in the /history/commands BOARD target set.
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by node --test in
# console-ui/tests/ticket-hold-lib.bh-2326.test.js (reached through the
# console-ui job). What this file adds is the part the impact lane and the
# orphan ratchet can SEE (the cost-breaker-console.bh-2331 pattern):
#
#   1. lib/ticket-hold.js, DRIVEN: the holdTarget accept/refuse table, the
#      holdCommand bodies with the reason trimmed then capped, and holdFromLedger
#      keeping held, clear/absent and unknown/garbage/failure three answers.
#   2. neither new file calls a native dialog, and commands.js carries both
#      command types inside its BOARD set.
#   3. the node suite, run for real when the console-ui dependencies are
#      installed.
# Run from anywhere: tests/ticket-hold-console.bh-2326-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/ticket-hold.js"
TAG="$DIR/console-ui/src/ui/HeldTag.js"
COMMANDS="$DIR/console-ui/src/lib/commands.js"

for f in "$LIB" "$TAG" "$COMMANDS"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "ticket-hold-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { HOLD_LEDGER_KIND, HOLD_REASON_MAX, holdKey, holdTarget, holdCommand, holdFromLedger }
  from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

eq('kind',           HOLD_LEDGER_KIND, 'ticket_hold');
eq('max',            HOLD_REASON_MAX, 500);
eq('key',            holdKey('cromford', 2326), 'cromford#2326');
eq('target-ok',      holdTarget('cromford', 'BH-2326'), { project: 'cromford', ticket: 'BH-2326', issue: 2326 });
for (const k of ['BH-2326a', '2326', 'BH-0', 'BH-01', '../2326']) eq('target-refuse ' + k, holdTarget('cromford', k), null);
eq('target-no-project', holdTarget('', 'BH-2326'), null);
eq('target-undef-project', holdTarget(undefined, 'BH-2326'), null);

const t = holdTarget('cromford', 'BH-2326');
eq('cmd-hold',       holdCommand('hold', t, ' why '), { type: 'hold_ticket', project: 'cromford', ticket: 'BH-2326', reason: 'why' });
eq('cmd-unhold',     holdCommand('unhold', t, 'ok').type, 'unhold_ticket');
eq('cmd-cap',        holdCommand('hold', t, ' ' + 'a'.repeat(600)).reason.length, 500);
eq('cmd-blank',      holdCommand('hold', t, '  ').reason, '');
eq('cmd-no-target',  holdCommand('hold', null, 'x'), null);

eq('ledger-held',    holdFromLedger({ kind: 'ticket_hold', status: 'held', detail: 'hold by operator at 2026-09-28T10:00:00Z: a | b' }),
                     { held: true, by: 'operator', at: '2026-09-28T10:00:00Z', why: 'a | b' });
eq('ledger-body',    holdFromLedger({ ledger: { kind: 'ticket_hold', status: 'clear' } }), { held: false });
eq('ledger-clear',   holdFromLedger({ status: 'clear' }), { held: false });
eq('ledger-absent',  holdFromLedger(null), { held: false });
eq('ledger-unknown', holdFromLedger({ status: 'unknown' }), { unknown: true });
eq('ledger-garbage', holdFromLedger('x'), { unknown: true });
eq('ledger-bogus',   holdFromLedger({ status: 'bogus' }), { unknown: true });
eq('ledger-failure', holdFromLedger(new Error('http_500')), { unknown: true });
eq('ledger-kind',    holdFromLedger({ kind: 'merge', status: 'held' }), { unknown: true });
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: no native dialogs; both types in BOARD -------------------------------
CODE=$(grep -hvE '^[[:space:]]*//' "$LIB" "$TAG")
if [[ "$CODE" =~ (^|[^A-Za-z0-9_.])(window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the ticket-hold lib or HeldTag"
else
  ok
fi
# The BOARD literal runs from 'const BOARD = new Set([' to the first '])'.
BOARD_LIT=$(sed -n '/^const BOARD = new Set(\[/,/\]);/p' "$COMMANDS")
[ -n "$BOARD_LIT" ] && ok || bad "commands.js: no BOARD Set literal found"
for type in hold_ticket unhold_ticket; do
  grep -q "'$type'" <<< "$BOARD_LIT" && ok || bad "commands.js: '$type' is not in the BOARD set"
done

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "ticket-hold-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/ticket-hold-lib.bh-2326.test.js 2>&1); then ok
  else bad "console-ui/tests/ticket-hold-lib.bh-2326.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "ticket-hold-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
