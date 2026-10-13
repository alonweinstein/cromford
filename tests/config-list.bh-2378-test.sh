#!/bin/bash
# tests/config-list.bh-2378-test.sh — the /config list screen (BH-2378,
# BH-2330.3): SETTINGS, FLAGS and RECENT CHANGES, the audited EDIT and TURN
# ON/OFF modals, and the coord proxy forwarding the EDIT's reason.
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by three node suites in
# console-ui/tests (config.bh-2378, config-render.bh-2378, config-proxy.bh-2378).
# This file names the touched sources by path so the impact lane and the orphan
# ratchet can see them, drives the pure half for real, and runs the node suites.
#
#   1. lib/config.js, DRIVEN: settingRows hides lane/lib rows unless asked and
#      never makes them editable here, a non-array is a failed read (null), the
#      validators refuse blank / multi-line / over-long input, and the PUT body
#      carries the reason and no note.
#   2. Config.js calls no native dialog.
#   3. the three node suites, run for real when console-ui dependencies exist.
# Run from anywhere: tests/config-list.bh-2378-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/config.js"
SCREEN="$DIR/console-ui/src/screens/Config.js"
PROXY="$DIR/console-ui/functions/api/coord/[[path]].js"

for f in "$LIB" "$SCREEN" "$PROXY"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "config-list: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { settingRows, validateValue, validateReason, settingPutBody, RECENT_CHANGES_LIMIT } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const S = [{ key: 'merge-conductor.mode' }, { key: 'lane.merge-conductor.mode' }, { key: 'lib.call-guard.x' }, { key: 'gh.quota.reserve' }];
const keys = (rows) => rows.map((r) => r.key + ':' + r.editableHere + (r.href ? ':' + r.href : ''));

eq('default-hides-lane', keys(settingRows(S, '', false)), ['gh.quota.reserve:true', 'merge-conductor.mode:true']);
eq('showlane-never-editable', keys(settingRows(S, '', true)), ['gh.quota.reserve:true', 'lane.merge-conductor.mode:false:/settings/merge-conductor', 'lib.call-guard.x:false:/settings', 'merge-conductor.mode:true']);
eq('filter-case', keys(settingRows(S, 'QUOTA', false)), ['gh.quota.reserve:true']);
eq('non-array-null', settingRows({ error: 'x' }, '', false), null);
eq('limit', RECENT_CHANGES_LIMIT, 50);
for (const [n, v] of [['empty', ''], ['blank', '   '], ['newline', 'a\nb'], ['long', 'x'.repeat(257)]]) eq('value-' + n, validateValue(v).ok, false);
eq('value-trim', validateValue(' 700 '), { ok: true, value: '700' });
for (const [n, v] of [['empty', ''], ['blank', '  '], ['long', 'x'.repeat(513)]]) eq('reason-' + n, validateReason(v).ok, false);
eq('put-body', settingPutBody('k', 'v', 'r'), { key: 'k', value: 'v', reason: 'r', actor: 'console' });
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: no native dialogs ------------------------------------------------------
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (window\.)?(^|[^a-zA-Z_.])(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the /config list screen"
else
  ok
fi
grep -q "path: 'settings', body: \['key', 'value', 'note', 'reason'\]" "$PROXY" && ok || bad "the coord proxy's PUT settings row must forward reason"

# --- 3: the node suites, driven ----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "config-list: console suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
else
  for t in config.bh-2378 config-render.bh-2378 config-proxy.bh-2378; do
    if NOUT=$(cd "$DIR/console-ui" && node --test "tests/$t.test.js" 2>&1); then ok
    else bad "console-ui/tests/$t.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
    fi
  done
fi

echo "config-list: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
