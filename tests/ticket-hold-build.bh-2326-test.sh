#!/bin/bash
# tests/ticket-hold-build.bh-2326-test.sh — the HOLD / UNHOLD control on the
# Build screen (BH-2326.3, #3149).
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by node --test in
# console-ui/tests/ticket-hold-build.bh-2326.test.js (reached through the
# console-ui job). What this file adds is the part the impact lane and the
# orphan ratchet can SEE (the ticket-hold-console.bh-2326 pattern):
#
#   1. ui/TicketHold.js exists, calls no native dialog and keeps its 36px
#      touch targets.
#   2. screens/Build.js mounts the HELD tag and the control.
#   3. the node suite, run for real when the console-ui dependencies are
#      installed.
# Run from anywhere: tests/ticket-hold-build.bh-2326-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

CTL="$DIR/console-ui/src/ui/TicketHold.js"
BUILD="$DIR/console-ui/src/screens/Build.js"

# --- 1: the control ------------------------------------------------------------
if [ -f "$CTL" ]; then
  ok
  CODE=$(grep -vE '^[[:space:]]*//' "$CTL")
  if grep -nE 'window\.confirm|alert\(|prompt\(' <<< "$CODE" >/dev/null; then
    bad "TicketHold.js calls a native dialog"
  else
    ok
  fi
  grep -q 'min-height:36px' <<< "$CODE" && ok || bad "TicketHold.js: no min-height:36px on its buttons"
else
  bad "missing $CTL"
fi

# --- 2: the Build screen mounts -------------------------------------------------
if [ -f "$BUILD" ]; then
  for mount in '<${TicketHoldControl}' '<${HeldTag}' 'useTicketHold(project, ticket)'; do
    grep -qF "$mount" "$BUILD" && ok || bad "Build.js does not carry $mount"
  done
else
  bad "missing $BUILD"
fi

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact" ]; then
  echo "ticket-hold-build: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
elif ! command -v node >/dev/null 2>&1; then
  echo "ticket-hold-build: node suite SKIPPED — node is not installed on this box"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/ticket-hold-build.bh-2326.test.js 2>&1); then ok
  else bad "console-ui/tests/ticket-hold-build.bh-2326.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "ticket-hold-build: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
