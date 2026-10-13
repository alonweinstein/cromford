#!/bin/bash
# tests/theme-tokens-console.bh-4843-test.sh — Mission Control's token layer
# (BH-4843, wave 1 of BH-4840).
#
# The behaviour is proved by node --test in console-ui/tests/theme-tokens.bh-4843.test.js
# and console-ui/tests/theme-world.bh-4843.test.js. This file is the part the
# impact lane and the orphan ratchet can SEE: it names the new sources by path,
# drives the pure half for real, and runs both node suites when the console-ui
# dependencies are installed (the cost-breaker-console.bh-2331 pattern).
#
#   1. theme/tokens.js, DRIVEN: readToken falls back with no DOM, parseColor
#      reads #rgb/#rrggbb/rgb() and refuses junk, every legacy alias points at
#      a semantic token, and the theme event is 'mc:themechange'.
#   2. theme/phosphor.js: every fallback key is a token styles.css declares.
#   3. no 0xRRGGBB colour left in console-ui/src outside src/theme/.
#   4. the two node suites, run for real when node_modules is present.
# Run from anywhere: tests/theme-tokens-console.bh-4843-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

TOKENS="$DIR/console-ui/src/theme/tokens.js"
PHOSPHOR="$DIR/console-ui/src/theme/phosphor.js"
CSS="$DIR/console-ui/src/styles.css"
HEADLESS="$DIR/console-ui/tests/helpers/three-headless.bh-4843.js"

for f in "$TOKENS" "$PHOSPHOR" "$CSS" "$HEADLESS"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "theme-tokens-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1 + 2: the pure half, driven ---------------------------------------------
OUT=$(node --input-type=module -e "
import fs from 'node:fs';
import { readToken, parseColor, LEGACY_ALIASES, SEMANTIC_TOKENS, THEME_CHANGE_EVENT } from '$TOKENS';
import { PHOSPHOR_FALLBACK } from '$PHOSPHOR';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('readToken-no-dom', readToken('--ok', '#4AF37A'), '#4AF37A');
eq('parse-6',  parseColor('#4AF37A'), [74, 243, 122]);
eq('parse-3',  parseColor('#fff'), [255, 255, 255]);
eq('parse-rgb', parseColor('rgb(1, 2, 3)'), [1, 2, 3]);
eq('parse-junk', parseColor('junk'), null);
eq('event', THEME_CHANGE_EVENT, 'mc:themechange');
eq('aliases-semantic', Object.values(LEGACY_ALIASES).every((s) => SEMANTIC_TOKENS.includes(s)), true);
const css = fs.readFileSync('$CSS', 'utf8');
const root = css.match(/:root\s*\{([\s\S]*?)\n\}/)[1];
for (const k of Object.keys(PHOSPHOR_FALLBACK)) eq('declared ' + k, new RegExp('\\\\n\\\\s*' + k + '\\\\s*:').test(root), true);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    *) bad "tokens: $line" ;;
  esac
done <<< "$OUT"

# --- 3: no 0xRRGGBB colour outside src/theme/ ---------------------------------
HITS=$(grep -rnE '0x[0-9a-fA-F]{6}\b' "$DIR/console-ui/src" --include='*.js' | grep -v "/console-ui/src/theme/" || true)
[ -z "$HITS" ] && ok || bad "0x colour literal outside src/theme/: $HITS"

# --- 4: the node suites -------------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/three" ] || [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "theme-tokens-console: node suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
else
  for t in tests/theme-tokens.bh-4843.test.js tests/theme-world.bh-4843.test.js; do
    if NOUT=$(cd "$DIR/console-ui" && node --test "$t" 2>&1); then ok
    else bad "node suite $t"; echo "$NOUT" | grep -E '^not ok|# (pass|fail)' | head -20; fi
  done
fi

echo "theme-tokens-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
