#!/bin/bash
# tests/box-commands-console.bh-2518-test.sh — the console box-op buttons and
# BOX COMMANDS history on /machines (BH-2518.4, BH-2662).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/box-commands.bh-2518.test.js (reached through the console-ui
# job). This file names the two sources by path so the impact lane and the
# orphan ratchet can see them, drives the pure half for real, and holds the
# screen to the rules a reviewer would otherwise check by eye:
#
#   1. lib/box-commands.js, DRIVEN: a blank reason and a Fly type without its
#      app are refused (never defaulted), and the valid Fly body is exact.
#   2. Machines.js sends through requestBoxCommand (confirm first), polls the
#      history on the screen's 30 s cadence, and never calls a native dialog.
#   3. the node suite, run for real when the console-ui dependencies are installed.
# Run from anywhere: tests/box-commands-console.bh-2518-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/box-commands.js"
SCREEN="$DIR/console-ui/src/screens/Machines.js"

for f in "$LIB" "$SCREEN"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "box-commands-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { boxCommandFor } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('blank-reason', boxCommandFor('backup_now', { box: 'hub-1', reason: '  ' }), { error: 'reason required' });
eq('fly-no-app',   boxCommandFor('fly_machine_stop', { project: 'p', machineId: 'm1', reason: 'x' }), { error: 'app required' });
eq('fly-body',     boxCommandFor('fly_machine_destroy', { project: 'p', app: 'p-pool', machineId: 'abc12345', reason: ' stray ' }),
  { box: 'hub', type: 'fly_machine_destroy', target: 'abc12345', project: 'p', app: 'p-pool', reason: 'stray', confirm: true });
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape --------------------------------------------------
grep -q "requestBoxCommand(" "$SCREEN" && ok || bad "Machines.js must send box ops through requestBoxCommand (confirm first)"
grep -q "useConfirm" "$SCREEN" && ok || bad "Machines.js must confirm box ops through the in-app useConfirm modal"
grep -q "intervalMs: 30000" <(grep -E "api\.boxCommands\(" "$SCREEN") && ok || bad "the BOX COMMANDS useApi must poll on the screen's 30 s interval"
# useConfirm's own confirm({...}) is the in-app modal; window.* and a bare
# alert(/prompt( are the native dialogs this bans.
if grep -qE 'window\.(confirm|alert|prompt)|(^|[^.A-Za-z_])(alert|prompt)[[:space:]]*\(' <(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB"); then
  bad "a native dialog in the Machines screen"
else
  ok
fi

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "box-commands-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/box-commands.bh-2518.test.js 2>&1); then ok
  else bad "console-ui/tests/box-commands.bh-2518.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "box-commands-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
