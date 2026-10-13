#!/bin/bash
# tests/line-shell-console.bh-4990-test.sh — "The Line" shell and the Jobs
# screen in Mission Control (BH-4990, wave 1 of BH-4947).
#
# The behaviour is proved by node --test in console-ui/tests/*.bh-4990.test.js.
# This file is the part the impact lane and the orphan ratchet can SEE: it
# names the new files by path, drives the boot script with a stored
# `mill-light` (it must paint Paper: Paper replaced Mill Light), and runs the
# node suites when the console-ui dependencies are installed.
#
#   1. the new sources and suites exist, and so does the design reference:
#      console-ui/design-ref/mission-control-line.html (verbatim, with a
#      [data-theme="paper"] block) and a README.md naming its blob sha.
#   2. theme/boot.js, DRIVEN: ui.theme=mill-light paints data-theme=paper and
#      Paper's surface; ui.theme.fleet=MILL-LIGHT does too; empty storage is Mill.
#   3. the node suites, run for real when node_modules is present.
# Run from anywhere: tests/line-shell-console.bh-4990-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LINE_LIB="$DIR/console-ui/src/lib/line.js"
LINE_UI="$DIR/console-ui/src/ui/line.js"
TOPBAR="$DIR/console-ui/src/ui/TopBar.js"
TICKET="$DIR/console-ui/src/screens/Ticket.js"
JOBS="$DIR/console-ui/src/screens/Jobs.js"
BOOT="$DIR/console-ui/src/theme/boot.js"
THEMES="$DIR/console-ui/src/theme/themes.js"
SUITES="tests/station-track.bh-4990.test.js tests/jobs-render.bh-4990.test.js tests/theme-paper.bh-4990.test.js tests/line-shell.bh-4990.test.js"

for f in "$LINE_LIB" "$LINE_UI" "$TOPBAR" "$TICKET" "$JOBS" "$BOOT" "$THEMES"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
for t in $SUITES; do
  [ -f "$DIR/console-ui/$t" ] && ok || bad "missing console-ui/$t"
done

REF="$DIR/console-ui/design-ref/mission-control-line.html"
REF_README="$DIR/console-ui/design-ref/README.md"
if [ -f "$REF" ]; then
  ok
  grep -q 'data-theme="paper"' "$REF" && ok || bad "design-ref copy has no [data-theme=\"paper\"] block"
  SHA=$(git hash-object "$REF" 2>/dev/null)
  [ -f "$REF_README" ] && [ -n "$SHA" ] && grep -q "$SHA" "$REF_README" && ok \
    || bad "design-ref/README.md missing or does not name the copy's blob sha ${SHA:-?}"
else
  bad "missing $REF (verbatim copy of example-org/cromford-web docs/design/mission-control-line.html)"
fi

command -v node >/dev/null 2>&1 || { echo "line-shell-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 2: a stored mill-light paints Paper before first paint --------------------
OUT=$(node --input-type=module -e "
import vm from 'node:vm';
import { bootScript } from '$BOOT';
import { BUILTIN_THEMES } from '$THEMES';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const boot = (store) => {
  const set = {}; const attrs = {};
  const document = { documentElement: { style: { setProperty: (k, v) => { set[k] = v; } }, setAttribute: (k, v) => { attrs[k] = v; } }, querySelector: () => null };
  vm.runInContext(bootScript(), vm.createContext({ document, window: { localStorage: { getItem: (k) => store[k] ?? null } } }));
  return { set, attrs };
};
const v = boot({ 'ui.theme': 'mill-light' });
eq('viewer-mill-light-is-paper', v.attrs['data-theme'], 'paper');
eq('viewer-paper-surface', v.set['--surface-0'], BUILTIN_THEMES.paper.tokens['--surface-0']);
eq('fleet-mill-light-is-paper', boot({ 'ui.theme.fleet': 'MILL-LIGHT' }).attrs['data-theme'], 'paper');
eq('empty-is-mill', boot({}).attrs['data-theme'], 'mill');
eq('no-mill-light-builtin', BUILTIN_THEMES['mill-light'], undefined);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    *) bad "boot: $line" ;;
  esac
done <<< "$OUT"

# --- 3: the node suites -------------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact" ] || [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "line-shell-console: node suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
else
  for t in $SUITES; do
    if NOUT=$(cd "$DIR/console-ui" && node --test "$t" 2>&1); then ok
    else bad "node suite $t"; echo "$NOUT" | grep -E '^not ok|# (pass|fail)' | head -20; fi
  done
fi

echo "line-shell-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
