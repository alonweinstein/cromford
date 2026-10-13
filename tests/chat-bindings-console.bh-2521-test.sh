#!/bin/bash
# tests/chat-bindings-console.bh-2521-test.sh — the /hub CHAT BINDINGS panel
# (BH-2521, slice BH-2678).
#
# The panel's behaviour is proved by node --test in
# console-ui/tests/chat-bindings.bh-2521.test.js and
# console-ui/tests/chat-bindings-panel.bh-2521.test.js, and the worker's `rows`
# key by worker/jobs/test/routes/telegram-topics.bh-2521.test.js. This file is
# the door the impact lane and the orphan ratchet can see:
#   1. lib/chat-bindings.js, DRIVEN: a positive integer is accepted, "0" and
#      "6.9" are refused, and a payload with no rows array is a broken answer.
#   2. ChatBindings.js never calls a native dialog.
#   3. the three node suites, run for real when their dependencies are installed.
# Run from anywhere: tests/chat-bindings-console.bh-2521-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/chat-bindings.js"
CHAT="$DIR/console-ui/src/screens/hub/ChatBindings.js"

for f in "$LIB" "$CHAT"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 2: no native dialogs ---------------------------------------------------
# useConfirm's own confirm( is the in-app modal; a bare alert(/prompt( or any
# window.confirm/alert/prompt( is a native one.
if grep -nE '(^|[^.a-zA-Z_])(alert|prompt)\(|window\.(confirm|alert|prompt)\(' "$CHAT" "$LIB"; then
  bad "a native dialog in the CHAT BINDINGS panel"
else
  ok
fi

command -v node >/dev/null 2>&1 || { echo "chat-bindings-console: node checks SKIPPED — node is not installed on this box"; echo "chat-bindings-console: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { editBody, bindingsView } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const threw = (f) => { try { f(); return false; } catch { return true; } };
eq('seven',    editBody('project-3', '7'), { project: 'project-3', thread_id: 7 });
eq('zero',     threw(() => editBody('project-3', '0')), true);
eq('fraction', threw(() => editBody('project-3', '6.9')), true);
eq('no-rows',  threw(() => bindingsView({ topics: {} })), true);
eq('empty',    bindingsView({ rows: [] }), { rows: [] });
" 2>&1)
[ -n "$OUT" ] || bad "lib: no output from node"
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 3: the node suites -------------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "chat-bindings-console: console node suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
else
  for s in tests/chat-bindings.bh-2521.test.js tests/chat-bindings-panel.bh-2521.test.js; do
    if NOUT=$(cd "$DIR/console-ui" && node --test "$s" 2>&1); then ok
    else bad "console-ui/$s failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
    fi
  done
fi
if ! "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1; then
  # worker/jobs imports the git-ignored catalog/lanes.json statically, so it is
  # rendered first, as tests/jobs-worker-test.sh does (BH-1247).
  bad "catalog/lanes.json could not be composed from catalog/lanes.d — worker/jobs imports it statically"
elif NOUT=$(cd "$DIR/worker/jobs" && node --test test/routes/telegram-topics.bh-2521.test.js 2>&1); then ok
else bad "worker/jobs/test/routes/telegram-topics.bh-2521.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "chat-bindings-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
