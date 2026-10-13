#!/bin/bash
# tests/config-console.bh-2375-test.sh — the /config route stubs and the
# config_changes read behind them (BH-2375, BH-2330.0).
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by two node suites:
# console-ui/tests/config.bh-2375.test.js (the screens, mounted through the
# real ROUTES table) and worker/jobs/test/config-changes.bh-2375.test.js (the
# reader and GET /api/config-changes through the real worker.fetch). This file
# names the new sources by path so the impact lane and the orphan ratchet can
# see them, drives the pure half for real, and runs both node suites.
#
#   1. lib/config.js, DRIVEN: configHref encodes each segment once, and
#      changesStatus says loading, a failed read, an empty log and a count in
#      four different lines, with a malformed body read as a failure.
#   2. Config.js and ConfigDetail.js are routed in app.js and call no native
#      dialog.
#   3. the two node suites, run for real (the console one only when the
#      console-ui dependencies are installed).
# Run from anywhere: tests/config-console.bh-2375-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/config.js"
SCREEN="$DIR/console-ui/src/screens/Config.js"
DETAIL="$DIR/console-ui/src/screens/ConfigDetail.js"
APP="$DIR/console-ui/src/app.js"
ROUTE="$DIR/worker/jobs/src/routes/config-changes.js"

for f in "$LIB" "$SCREEN" "$DETAIL" "$APP" "$ROUTE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "config-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { configHref, changesStatus, CONFIG_CHANGES_LIMIT } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

eq('href-plain',   configHref('setting', 'a.b'), '/config/setting/a.b');
eq('href-encoded', configHref('flag', 'a/b c'), '/config/flag/a%2Fb%20c');
eq('limit',        CONFIG_CHANGES_LIMIT, 100);
eq('loading',      changesStatus({ loading: true, error: null, data: null }), 'Loading the change log…');
eq('error',        changesStatus({ loading: false, error: new Error('boom'), data: null }), 'Could not load the change log: boom');
eq('malformed',    changesStatus({ loading: false, error: null, data: { error: 'x' } }), 'Could not load the change log: unexpected response');
eq('empty',        changesStatus({ loading: false, error: null, data: { changes: [], truncated: false } }), 'No changes recorded yet.');
eq('one',          changesStatus({ loading: false, error: null, data: { changes: [{}], truncated: false } }), '1 recent change');
eq('truncated',    changesStatus({ loading: false, error: null, data: { changes: [{}, {}], truncated: true } }), '2 recent changes (more not shown)');
eq('truthy-only',  changesStatus({ loading: false, error: null, data: { changes: [{}, {}], truncated: 'yes' } }), '2 recent changes');
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: routed, no native dialogs -------------------------------------------
grep -q "\['/config', ConfigScreen\]" "$APP" && ok || bad "app.js must route /config to ConfigScreen"
grep -q "\['/config/:kind/:name', ConfigDetailScreen\]" "$APP" && ok || bad "app.js must route /config/:kind/:name to ConfigDetailScreen"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$DETAIL" "$LIB")
if [[ "$CODE" =~ (window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the /config screens"
else
  ok
fi

# --- 3: the node suites, driven ----------------------------------------------
if [ ! -f "$DIR/catalog/lanes.json" ]; then
  echo "config-console: worker suite SKIPPED — catalog/lanes.json is not rendered (bin/lanes-build.sh --write)"
elif WOUT=$(cd "$DIR/worker/jobs" && node --test test/config-changes.bh-2375.test.js 2>&1); then ok
else bad "worker/jobs/test/config-changes.bh-2375.test.js failed:"; printf '%s\n' "$WOUT" | grep -E '^not ok|Error' | head -20
fi
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "config-console: console suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
elif NOUT=$(cd "$DIR/console-ui" && node --test tests/config.bh-2375.test.js 2>&1); then ok
else bad "console-ui/tests/config.bh-2375.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "config-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
