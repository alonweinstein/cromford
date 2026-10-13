#!/bin/bash
# tests/settings-theme-delete.bh-4846-test.sh — custom console themes
# (BH-4846) as the impact lane and the orphan ratchet can SEE them.
#
#   F. the source files this ticket adds or changes, named here by rooted path:
#      the worker's settings routes, the console's theme module and editor.
#   W. the worker node suite: a ui.theme.custom.<slug> PUT takes a ~2.3 KB
#      JSON document (and refuses anything that is not a JSON object), an
#      ordinary key keeps its 256 cap, and DELETE /api/settings/<key> removes
#      only a custom-theme row, audited in config_changes in the same batch.
#   C. the console node suites (validator, resolution, proxy, editor), when the
#      console's dependencies are installed.
# Run from anywhere: tests/settings-theme-delete.bh-4846-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

ROUTES="$DIR/worker/jobs/src/routes/settings.js"
WSUITE="$DIR/worker/jobs/test/settings-theme.bh-4846.test.js"
CUSTOM="$DIR/console-ui/src/theme/custom.js"
EDITOR="$DIR/console-ui/src/screens/ThemeEditor.js"
CSUITES=(
  "$DIR/console-ui/tests/theme-custom.bh-4846.test.js"
  "$DIR/console-ui/tests/theme-proxy.bh-4846.test.js"
  "$DIR/console-ui/tests/appearance-custom.bh-4846.test.js"
)

# --- F: the files ------------------------------------------------------------
for f in "$ROUTES" "$WSUITE" "$CUSTOM" "$EDITOR" "${CSUITES[@]}"; do
  [ -f "$f" ] && ok || bad "F: missing $f"
done

command -v node >/dev/null 2>&1 || { echo "settings-theme-delete: SKIPPED the node suites — node is not installed on this box"; echo "settings-theme-delete: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]; exit; }

# --- W: the worker suite -------------------------------------------------------
# core.js imports the GENERATED, git-ignored catalog/lanes.json statically, so
# it is rendered into the checkout first (the cost-caps-worker.bh-2564 way).
if [ -x "$DIR/bin/lanes-build.sh" ] && [ -d "$DIR/catalog/lanes.d" ]; then
  "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 \
    || { echo "FAIL: settings-theme-delete: catalog/lanes.json could not be composed from catalog/lanes.d — worker/jobs imports it statically"; exit 1; }
fi
if OUT=$(node --test "$WSUITE" 2>&1); then ok
else bad "W: $WSUITE failed"; printf '%s\n' "$OUT" | grep -E '^not ok|^# (pass|fail)|AssertionError|Error' | head -40; fi

# --- C: the console suites -----------------------------------------------------
if [ -d "$DIR/console-ui/node_modules/preact" ]; then
  if OUT=$(cd "$DIR/console-ui" && node --test "${CSUITES[@]}" 2>&1); then ok
  else bad "C: console suites failed"; printf '%s\n' "$OUT" | grep -E '^not ok|^# (pass|fail)|AssertionError|Error' | head -40; fi
else
  echo "settings-theme-delete: SKIPPED the console suites — console-ui/node_modules is not installed"
fi

# --- G: no Google Fonts in a built page (the fonts are self-hosted) -------------
if [ -f "$DIR/console-ui/dist/index.html" ]; then
  if grep -q 'fonts.googleapis\|fonts.gstatic' "$DIR/console-ui/dist/index.html"; then bad "G: dist/index.html links Google Fonts"; else ok; fi
else
  echo "settings-theme-delete: SKIPPED the dist check — console-ui/dist is not built"
fi

echo "settings-theme-delete: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
