#!/bin/bash
# tests/config-detail-console.bh-2379-test.sh — /config/:kind/:name, one
# config row's current value and its config_changes history (BH-2379,
# BH-2330.4).
#
# The behaviour is proved by console-ui/tests/config-detail-render.bh-2330.test.js
# (the view in every load state, and the screen mounted through the real
# ROUTES table). This file names the new sources by path so the impact lane
# and the orphan ratchet can see them, drives the pure half for real, and runs
# the node suite.
#
#   1. lib/config-detail.js, DRIVEN: the kind mirror, historyRows, sideText
#      and currentFor, with a malformed body read as a failure and a missing
#      flag in a full list not read as gone.
#   2. ConfigDetail.js and lib/config-detail.js call no native dialog.
#   3. the node suite, run for real when the console-ui dependencies are
#      installed.
# Run from anywhere: tests/config-detail-console.bh-2379-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/config-detail.js"
DETAIL="$DIR/console-ui/src/screens/ConfigDetail.js"
KINDS="$DIR/worker/jobs/src/lib/config-changes.js"

for f in "$LIB" "$DETAIL" "$KINDS"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "config-detail-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { CONFIG_KIND_VALUES, isKnownKind, historyRows, sideText, currentFor, DETAIL_LIMIT } from '$LIB';
import { CONFIG_KINDS } from '$KINDS';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

eq('kinds-parity',   [...CONFIG_KIND_VALUES], Object.values(CONFIG_KINDS));
eq('known',          isKnownKind('cost_cap'), true);
eq('unknown',        isKnownKind('bogus'), false);
eq('limit',          DETAIL_LIMIT, 500);
eq('rows',           historyRows({ changes: [1], truncated: true }), { rows: [1], truncated: true });
eq('rows-truthy',    historyRows({ changes: [], truncated: 'yes' }), { rows: [], truncated: false });
eq('rows-malformed', historyRows({ error: 'x' }), { malformed: true });
eq('created',        sideText(null, 'before'), '(created)');
eq('deleted',        sideText('null', 'after'), '(deleted)');
eq('one-field',      sideText('{\"value\":\"900\"}', 'after'), '900');
eq('many-fields',    sideText('{\"a\":1,\"b\":null}', 'after'), 'a: 1 · b: —');
eq('unparseable',    sideText('oops', 'after'), 'oops');
eq('setting-row',    currentFor('setting', 'k', { setting: { value: '8', actor: 'l', note: 'n', updated_at: 't' } }), { row: { value: '8', actor: 'l', at: 't', note: 'n' } });
eq('setting-none',   currentFor('setting', 'k', { setting: null }), { missing: true });
eq('setting-bad',    currentFor('setting', 'k', { error: 'x' }), { malformed: true });
eq('flag-row',       currentFor('flag', 'x', { flags: [{ name: 'x', active: 0, reason: 'r' }] }).row.value, 'inactive');
eq('flag-missing',   currentFor('flag', 'x', { flags: [] }), { missing: true, capped: false });
eq('flag-capped',    currentFor('flag', 'x', { flags: Array(500).fill({ name: 'y' }) }), { missing: true, capped: true });
eq('other-kind',     currentFor('cost_cap', 'x', {}), { none: true });
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: no native dialogs ---------------------------------------------------
CODE=$(grep -hvE '^[[:space:]]*//' "$DETAIL" "$LIB")
if [[ "$CODE" =~ (window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the /config detail page"
else
  ok
fi

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "config-detail-console: console suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
elif NOUT=$(cd "$DIR/console-ui" && node --test tests/config-detail-render.bh-2330.test.js 2>&1); then ok
else bad "console-ui/tests/config-detail-render.bh-2330.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "config-detail-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
