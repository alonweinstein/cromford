#!/bin/bash
# tests/flags-console.bh-4153-test.sh — the console /flags screen (BH-4153).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/flags-screen.bh-4153.test.js (reached through the console-ui
# job). What this file adds is the part the impact lane and the orphan ratchet
# can SEE: it names the two new sources by path, drives the pure half for real,
# and holds the screen to the rules a reviewer would otherwise check by eye
# (the cost-breaker-console.bh-2331 pattern).
#
#   1. lib/flags.js, DRIVEN: a cleared row is hidden unless SHOW CLEARED, the
#      filter matches name/scope/reason, an unreadable body is null (never an
#      empty list), PROJECT is named only for a fleet project, the name and
#      scope checks use the worker alphabet, and the SET body and CLEAR query
#      carry exactly the fields the coord proxy forwards.
#   2. Flags.js sorts through the shared SortableTable, writes through the
#      in-app Modal, is routed at /flags, and never calls a native dialog.
#   3. the node suite console-ui/tests/flags-screen.bh-4153.test.js, run for
#      real when the console-ui dependencies are installed.
# Run from anywhere: tests/flags-console.bh-4153-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/flags.js"
SCREEN="$DIR/console-ui/src/screens/Flags.js"
APP="$DIR/console-ui/src/app.js"
PROXY="$DIR/console-ui/functions/api/coord/[[path]].js"

for f in "$LIB" "$SCREEN" "$APP" "$PROXY"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "flags-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { flagRowsAll, flagProject, setBody, clearQuery, validateFlagName, validateScope,
         setFormState, clearFormState } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

const rows = { flags: [
  { scope: 'fleet', name: 'paused-project-3', reason: 'deploy', cleared_at: null },
  { scope: 'boxa', name: 'lanedown-boxa-codex-20261003', reason: 'canary', cleared_at: null },
  { scope: 'fleet', name: 'alerts-db', reason: 'quiet', cleared_at: '2026-10-02T00:00:00Z' } ], truncated: true };
eq('rows-default',   flagRowsAll(rows, {}).rows.map((r) => r.name), ['paused-project-3', 'lanedown-boxa-codex-20261003']);
eq('rows-hidden',    flagRowsAll(rows, {}).hidden, 1);
eq('rows-cleared',   flagRowsAll(rows, { showCleared: true }).rows.length, 3);
eq('rows-state',     flagRowsAll(rows, { showCleared: true }).rows.map((r) => r.on), [true, true, false]);
eq('rows-scope',     flagRowsAll(rows, { filter: 'BOXA' }).rows.map((r) => r.name), ['lanedown-boxa-codex-20261003']);
eq('rows-reason',    flagRowsAll(rows, { filter: 'deploy' }).rows.map((r) => r.name), ['paused-project-3']);
eq('rows-truncated', flagRowsAll(rows, {}).truncated, true);
eq('rows-unread',    [flagRowsAll(null, {}), flagRowsAll({}, {}), flagRowsAll({ flags: 'x' }, {})], [null, null, null]);

const P = ['project-3'];
eq('project-paused', flagProject('paused-project-3', P), 'project-3');
eq('project-am',     flagProject('automerge-disabled-project-3', P), 'project-3');
eq('project-ghost',  flagProject('paused-ghost', P), null);
eq('project-all',    flagProject('paused-all', P), null);
eq('project-bare',   flagProject('automerge-disabled', P), null);
eq('project-lane',   flagProject('lanedown-project-3', P), null);

eq('name-ok',        validateFlagName('paused-project-3').ok, true);
eq('name-space',     validateFlagName('paused project-3').ok, false);
eq('name-blank',     validateFlagName('  ').ok, false);
eq('name-long',      validateFlagName('a'.repeat(129)).ok, false);
eq('scope-blank',    validateScope(''), { ok: true, value: 'fleet' });
eq('scope-box',      validateScope('boxa').value, 'boxa');
eq('scope-bad',      validateScope('a b').ok, false);

eq('set-body',       setBody({ name: 'paused-p', scope: '', value: '', reason: ' r ' }),
                     { name: 'paused-p', scope: 'fleet', value: null, active: 1, reason: 'r' });
eq('clear-query',    clearQuery({ name: 'paused-p', scope: 'fleet', reason: 'done' }), 'name=paused-p&scope=fleet&reason=done');
eq('set-blocked',    setFormState({ name: 'paused-p', scope: 'fleet', reason: ' ' }).blocked, true);
eq('set-open',       setFormState({ name: 'paused-p', scope: 'fleet', reason: 'r' }).blocked, false);
eq('clear-blocked',  clearFormState({ reason: '' }).blocked, true);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape --------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "Flags.js must use the shared SortableTable"
grep -q "from '../ui/Modal.js'" "$SCREEN" && ok || bad "Flags.js must write through the in-app Modal"
grep -q "\['/flags', FlagsScreen\]" "$APP" && ok || bad "app.js must route /flags to FlagsScreen"
grep -q "p === '/flags'" "$APP" && ok || bad "the SETTINGS nav tab must match /flags"
grep -q "method: 'DELETE', path: 'flags', body: null, query: \['name', 'scope', 'reason'\]" "$PROXY" \
  && ok || bad "the coord proxy must admit DELETE flags with name/scope/reason"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ window\.(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the /flags screen"
else
  ok
fi

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "flags-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/flags-screen.bh-4153.test.js 2>&1); then ok
  else bad "console-ui/tests/flags-screen.bh-4153.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "flags-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
