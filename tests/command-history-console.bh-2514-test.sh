#!/bin/bash
# tests/command-history-console.bh-2514-test.sh — the console COMMAND HISTORY
# screen at /history/commands (BH-2514).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/command-history.bh-2514.test.js (reached through the
# console-ui job). This file names the two new sources by path for the orphan
# ratchet, drives the pure half for real, and holds the screen to the rules a
# reviewer would otherwise check by eye (the cost-breaker-console.bh-2331
# pattern).
#
#   1. lib/commands.js, DRIVEN: merge_pr links its PR, pause_set its board, an
#      unknown type links nothing, and a row with no actor stays null.
#   2. CommandHistory.js sorts through the shared SortableTable, is routed at
#      /history/commands, and never calls a native dialog.
#   3. the node suite console-ui/tests/command-history.bh-2514.test.js, run for
#      real when the console-ui dependencies are installed.
# Run from anywhere: tests/command-history-console.bh-2514-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/commands.js"
SCREEN="$DIR/console-ui/src/screens/CommandHistory.js"
APP="$DIR/console-ui/src/app.js"

MISSING=0
for f in "$LIB" "$SCREEN"; do
  if [ -f "$f" ]; then ok; else bad "missing $f"; MISSING=1; fi
done
if [ "$MISSING" -eq 1 ]; then
  echo "command-history-console: $PASS passed, $FAIL failed"
  exit 1
fi

command -v node >/dev/null 2>&1 || { echo "command-history-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { commandRows, commandTarget } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const t = (raw) => commandTarget(commandRows([raw]).rows[0]);
eq('merge_pr',  t({ id: 1, type: 'merge_pr', project: 'project-3',
  payload: '{\"pr_url\":\"https://github.com/example-org/project-3/pull/412\"}' })?.to, '/pr/project-3/412');
eq('pause_set', t({ id: 2, type: 'pause_set', project: 'project-3', payload: '{\"actor\":\"operator@example.com\"}' })?.to, '/p/project-3');
eq('unknown',   t({ id: 3, type: 'foo', project: 'project-3', payload: '{}' }), null);
eq('actor',     commandRows([{ id: 2, type: 'pause_set', payload: '{\"actor\":\"operator@example.com\"}' }]).rows[0].actor, 'operator@example.com');
eq('no-actor',  commandRows([{ id: 4, type: 'pause_set', payload: '{}' }]).rows[0].actor, null);
eq('malformed', commandRows({ rows: [] }).malformed, true);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape --------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "CommandHistory.js must use the shared SortableTable"
grep -q "'/history/commands', CommandHistoryScreen" "$APP" && ok || bad "app.js must route /history/commands to CommandHistoryScreen"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (^|[^A-Za-z_.])(window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the COMMAND HISTORY screen"
else
  ok
fi

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "command-history-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/command-history.bh-2514.test.js 2>&1); then ok
  else bad "console-ui/tests/command-history.bh-2514.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "command-history-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
