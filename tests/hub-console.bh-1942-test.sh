#!/bin/bash
# tests/hub-console.bh-1942-test.sh — the console HUB screen (BH-1942 contract,
# BH-1945 / BH-1909.3 screen).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/hub.bh-1942.test.js and the two BH-1945 suites
# (hub.bh-1909.test.js, hub-render.bh-1909.test.js), reached through the
# console-ui job. What this file adds is the part the impact lane and the
# orphan ratchet can SEE: it names the screen and its lib by path, runs those
# node suites when the console's dependencies are installed, and holds the
# screen to the console's no-native-dialog rule (the models-console.bh-1510-3
# pattern).
#
#   1. The three node suites, DRIVEN: the four api URLs, /hub in the real
#      ROUTES and NAV, the empty RestoreLabPanel, and (BH-1945) the lease,
#      role, backups table, 501-as-load-error and the typed-confirm promote.
#   2. Hub.js and lib/hub.js exist, HubScreen is exported, and neither calls
#      a native dialog: promote goes through the in-app Modal, never confirm().
# Run from anywhere: tests/hub-console.bh-1942-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SCREEN="$DIR/console-ui/src/screens/Hub.js"
PANEL="$DIR/console-ui/src/screens/hub/RestoreLab.js"
LIB="$DIR/console-ui/src/lib/hub.js"
SUITES="tests/hub.bh-1942.test.js tests/hub.bh-1909.test.js tests/hub-render.bh-1909.test.js"

for f in "$SCREEN" "$PANEL" "$LIB"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
for s in $SUITES; do
  f="$DIR/console-ui/$s"
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 2: the screen and its lib ------------------------------------------------
# The absent case first (D3): a Hub.js that lost its component would pass every
# "does not contain" check below.
grep -q 'export function HubScreen' "$SCREEN" && ok || bad "Hub.js no longer exports HubScreen"
grep -q 'export function promoteFormState' "$LIB" && ok || bad "lib/hub.js no longer exports promoteFormState"
for f in "$SCREEN" "$LIB"; do
  code=$(grep -v '^\s*//' "$f")
  grep -qE '\b(confirm|alert|prompt)\(' <<<"$code" && bad "$(basename "$f") calls a native dialog" || ok
done

# --- 1: the node suites, driven ------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "hub-console: node suite SKIPPED — node is not installed on this box"
elif [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "hub-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  # shellcheck disable=SC2086 # SUITES is a word list on purpose
  if OUT=$(cd "$DIR/console-ui" && node --test $SUITES 2>&1); then ok
  else bad "console-ui hub suites failed:"; printf '%s\n' "$OUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "hub-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
