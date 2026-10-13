#!/bin/bash
# tests/mill-form-console.bh-4845-test.sh — the Mill Floor form in Mission
# Control's Mill themes (BH-4845, wave 3 of BH-4840).
#
# The behaviour is proved by node --test in
# console-ui/tests/theme-shape.bh-4845.test.js and, in a real browser, by
# console-ui/tests/drive/density-drive.mjs --theme mill|phosphor. This file is
# the part the impact lane and the orphan ratchet can SEE: it names the new
# files by path, checks the vendored fonts, drives the boot script for both
# themes, and runs the node suite when the console-ui dependencies are installed.
#
#   1. the three vendored faces are woff2s, and OFL.txt travels with them.
#   2. theme/boot.js, DRIVEN: empty storage paints Mill's shape (Archivo,
#      999px pills); ui.theme=phosphor paints Phosphor's (JetBrains, 2px).
#   3. the node suites, run for real when node_modules is present.
# Run from anywhere: tests/mill-form-console.bh-4845-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

ARCHIVO="$DIR/console-ui/public/fonts/archivo-latin-wdth.woff2"
GEIST="$DIR/console-ui/public/fonts/geist-latin.woff2"
GEIST_MONO="$DIR/console-ui/public/fonts/geist-mono-latin.woff2"
OFL="$DIR/console-ui/public/fonts/OFL.txt"
SUITE="$DIR/console-ui/tests/theme-shape.bh-4845.test.js"
BOOT="$DIR/console-ui/src/theme/boot.js"
THEMES="$DIR/console-ui/src/theme/themes.js"

for f in "$ARCHIVO" "$GEIST" "$GEIST_MONO" "$OFL" "$SUITE" "$BOOT" "$THEMES"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 1: the fonts and their licence -------------------------------------------
for f in "$ARCHIVO" "$GEIST" "$GEIST_MONO"; do
  [ "$(head -c4 "$f" 2>/dev/null)" = "wOF2" ] && ok || bad "$f is not a woff2"
done
for name in "Archivo" "Geist" "Geist Mono" "SIL OPEN FONT LICENSE Version 1.1"; do
  grep -qF "$name" "$OFL" && ok || bad "OFL.txt does not name $name"
done

command -v node >/dev/null 2>&1 || { echo "mill-form-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 2: the boot script paints each theme's shape -----------------------------
OUT=$(node --input-type=module -e "
import vm from 'node:vm';
import { bootScript } from '$BOOT';
import { BUILTIN_THEMES } from '$THEMES';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const boot = (store) => {
  const set = {};
  const document = { documentElement: { style: { setProperty: (k, v) => { set[k] = v; } }, setAttribute() {} }, querySelector: () => null };
  vm.runInContext(bootScript(), vm.createContext({ document, window: { localStorage: { getItem: (k) => store[k] ?? null } } }));
  return set;
};
const m = boot({});
eq('mill-display', m['--font-display'], BUILTIN_THEMES.mill.shape['--font-display']);
eq('mill-archivo', /^'Archivo'/.test(m['--font-display']), true);
eq('mill-pill', m['--radius-pill'], '999px');
eq('mill-case', m['--label-case'], 'uppercase');
const p = boot({ 'ui.theme': 'phosphor' });
eq('phosphor-display', /^'JetBrains Mono'/.test(p['--font-display']), true);
eq('phosphor-pill', p['--radius-pill'], '2px');
eq('phosphor-case', p['--label-case'], 'none');
eq('phosphor-live', p['--live'], '#2E5A3A');
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    *) bad "boot: $line" ;;
  esac
done <<< "$OUT"

# --- 3: the node suites -------------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact" ] || [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "mill-form-console: node suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
else
  for t in tests/theme-shape.bh-4845.test.js tests/theme-boot.bh-4844.test.js tests/theme-contrast.bh-4844.test.js; do
    if NOUT=$(cd "$DIR/console-ui" && node --test "$t" 2>&1); then ok
    else bad "node suite $t"; echo "$NOUT" | grep -E '^not ok|# (pass|fail)' | head -20; fi
  done
fi

echo "mill-form-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
