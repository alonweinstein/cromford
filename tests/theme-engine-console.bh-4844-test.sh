#!/bin/bash
# tests/theme-engine-console.bh-4844-test.sh — Mission Control's theme engine
# and the APPEARANCE screen (BH-4844, wave 2 of BH-4840).
#
# The behaviour is proved by node --test in console-ui/tests/theme-resolve.bh-4844.test.js,
# theme-contrast.bh-4844.test.js, theme-boot.bh-4844.test.js and
# appearance-render.bh-4844.test.js. This file is the part the impact lane and
# the orphan ratchet can SEE: it names the new sources by path, drives the pure
# half for real, and runs the four node suites when the console-ui
# dependencies are installed (the cost-breaker-console.bh-2331 pattern).
#
#   1. theme/resolve.js + themes.js, DRIVEN: viewer, then fleet, then Mill;
#      junk falls through; a malformed settings answer names no fleet default.
#   2. theme/boot.js, DRIVEN: the generated script, run in a vm with empty
#      storage, paints Mill; the plugin puts it before the first <link>.
#   3. the four node suites, run for real when node_modules is present.
# Run from anywhere: tests/theme-engine-console.bh-4844-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

THEMES="$DIR/console-ui/src/theme/themes.js"
RESOLVE="$DIR/console-ui/src/theme/resolve.js"
APPLY="$DIR/console-ui/src/theme/apply.js"
BOOT="$DIR/console-ui/src/theme/boot.js"
SCREEN="$DIR/console-ui/src/screens/Appearance.js"
INDEX="$DIR/console-ui/index.html"

for f in "$THEMES" "$RESOLVE" "$APPLY" "$BOOT" "$SCREEN" "$INDEX"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "theme-engine-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1 + 2: the pure half, driven ---------------------------------------------
OUT=$(node --input-type=module -e "
import fs from 'node:fs';
import vm from 'node:vm';
import { resolveTheme, fleetFromSettingResponse } from '$RESOLVE';
import { BUILTIN_THEMES, DEFAULT_THEME_ID } from '$THEMES';
import { bootScript, injectBootScript } from '$BOOT';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('default', DEFAULT_THEME_ID, 'mill');
eq('viewer-wins', resolveTheme({ viewer: 'phosphor', fleet: 'mill-light' }).id, 'phosphor');
eq('fleet-next', resolveTheme({ viewer: 'neon', fleet: 'mill-light' }), { id: 'paper', source: 'fleet' });
eq('mill-last', resolveTheme({ viewer: null, fleet: null }), { id: 'mill', source: 'default' });
eq('no-row', fleetFromSettingResponse({ setting: null }), null);
eq('bad-row', fleetFromSettingResponse({ setting: { value: 7 } }), null);
eq('row', fleetFromSettingResponse({ setting: { value: ' Phosphor ' } }), 'phosphor');
const set = {}; const attrs = {};
const document = { documentElement: { style: { setProperty: (k, v) => { set[k] = v; } }, setAttribute: (k, v) => { attrs[k] = v; } }, querySelector: () => null };
vm.runInContext(bootScript(), vm.createContext({ document, window: { localStorage: { getItem: () => null } } }));
eq('boot-mill', attrs['data-theme'], 'mill');
eq('boot-tokens', set['--surface-0'], BUILTIN_THEMES.mill.tokens['--surface-0']);
const out = injectBootScript(fs.readFileSync('$INDEX', 'utf8'));
eq('boot-before-link', out.indexOf('<script>') > 0 && out.indexOf('<script>') < out.indexOf('<link'), true);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    *) bad "theme: $line" ;;
  esac
done <<< "$OUT"

# --- the two production call sites: the app syncs the fleet default after its
# first render, and the build injects the boot script. Static, because neither
# main.js nor vite.config.js can be imported in node without a page.
MAIN="$DIR/console-ui/src/main.js"
VCONF="$DIR/console-ui/vite.config.js"
grep -qE '^syncFleetDefault\(api\)' "$MAIN" && ok || bad "console-ui/src/main.js no longer calls syncFleetDefault(api)"
grep -qE 'plugins: \[themeBootPlugin\(\)\]' "$VCONF" && ok || bad "console-ui/vite.config.js no longer wires themeBootPlugin()"

# --- 3: the node suites -------------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact" ] || [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "theme-engine-console: node suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
else
  for t in tests/theme-resolve.bh-4844.test.js tests/theme-contrast.bh-4844.test.js \
           tests/theme-boot.bh-4844.test.js tests/appearance-render.bh-4844.test.js; do
    if NOUT=$(cd "$DIR/console-ui" && node --test "$t" 2>&1); then ok
    else bad "node suite $t"; echo "$NOUT" | grep -E '^not ok|# (pass|fail)' | head -20; fi
  done
fi

echo "theme-engine-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
