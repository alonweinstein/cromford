#!/bin/bash
# tests/protected-paths-console.bh-4147-test.sh — the PROTECTED PATHS panel on
# /settings and the coord proxy row behind its PUT (BH-4147, BH-4140.2).
#
# The behaviour is proved by console-ui/tests/protected-paths.bh-4140.test.js
# (the proxy row through onRequest, the api client, the view and the mounted
# panel). What this file adds is what the impact lane and the orphan ratchet can
# SEE (the build-queue-panel-console.bh-2510 pattern):
#   1. the new source, named by rooted path.
#   2. ProtectedPaths.js sorts through the shared SortableTable, confirms
#      through useConfirm, and never calls a native dialog.
#   3. the node suite, when the console-ui dependencies are installed.
# Run from anywhere: tests/protected-paths-console.bh-4147-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

UI="$DIR/console-ui/src/ui/ProtectedPaths.js"
SCREEN="$DIR/console-ui/src/screens/Settings.js"
PROXY="$DIR/console-ui/functions/api/coord/[[path]].js"

for f in "$UI" "$SCREEN" "$PROXY"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

grep -q "import { SortableTable } from './SortableTable.js'" "$UI" && ok || bad "ProtectedPaths.js must use the shared SortableTable"
grep -q "import { useConfirm } from './Modal.js'" "$UI" && ok || bad "ProtectedPaths.js must confirm through useConfirm"
# `await confirm(` is useConfirm's promise, injected as a parameter; anything
# else named confirm/alert/prompt, or reached through window/globalThis, is native.
if grep -nE '(^|[^A-Za-z_.])(confirm|alert|prompt)\(|(window|globalThis)\.(confirm|alert|prompt)' "$UI" | grep -v 'await confirm('; then
  bad "ProtectedPaths.js calls a native dialog"; else ok; fi
grep -q "import { ProtectedPathsPanel } from '../ui/ProtectedPaths.js'" "$SCREEN" && ok || bad "Settings.js must mount ProtectedPathsPanel"
grep -q "path: 'lead-protected-paths'" "$PROXY" && ok || bad "the coord proxy has no lead-protected-paths write row"

command -v node >/dev/null 2>&1 || { echo "protected-paths-console: SKIPPED — node is not installed on this box"; exit 0; }
if [ -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  if COUT=$(cd "$DIR/console-ui" && node --test tests/protected-paths.bh-4140.test.js 2>&1); then ok
  else bad "console-ui/tests/protected-paths.bh-4140.test.js failed:"; printf '%s\n' "$COUT" | grep -E '^not ok|Error' | head -20
  fi
else
  echo "protected-paths-console: console node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
fi

echo "protected-paths-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
