#!/bin/bash
# tests/error-report-console.bh-5619-test.sh — the console's screen error
# boundary and its Sentry reporter (BH-5619).
#
# The behaviour is proved by node --test in
# console-ui/tests/error-report.bh-5619.test.js. This file names the two new
# sources by path for the impact lane and the orphan ratchet, holds them to
# the rules a reviewer would otherwise check by eye, and runs the node suite
# when the console-ui dependencies are installed.
#
#   1. both sources exist; App wraps the routed screen in ErrorBoundary and
#      main.js calls initSentry(import.meta.env) once.
#   2. no replay, no PII, no setUser, no @sentry/react, no native dialog.
#   3. the node suite, driven.
# Run from anywhere: tests/error-report-console.bh-5619-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/error-report.js"
BOUNDARY="$DIR/console-ui/src/ui/ErrorBoundary.js"
APP="$DIR/console-ui/src/app.js"
MAIN="$DIR/console-ui/src/main.js"
PKG="$DIR/console-ui/package.json"

for f in "$LIB" "$BOUNDARY" "$APP" "$MAIN" "$PKG"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 1: wiring ---------------------------------------------------------------
grep -q '<\${ErrorBoundary} key=\${path}>\${screen}<//>' "$APP" && ok || bad "app.js must wrap the routed screen in ErrorBoundary keyed by path"
[ "$(grep -c 'initSentry(import.meta.env)' "$MAIN")" = 1 ] && ok || bad "main.js must call initSentry(import.meta.env) exactly once"
grep -q 'componentDidCatch' "$BOUNDARY" && ok || bad "ErrorBoundary.js must catch with componentDidCatch"

# --- 2: policy ---------------------------------------------------------------
CODE=$(grep -hvE '^[[:space:]]*//' "$LIB" "$BOUNDARY")
grep -q 'sendDefaultPii: false' "$LIB" && ok || bad "error-report.js must set sendDefaultPii: false"
if grep -qiE 'replay|setUser' <<< "$CODE"; then bad "no replay and no setUser in the reporter"; else ok; fi
if grep -q '@sentry/react' "$PKG"; then bad "console-ui must not depend on @sentry/react"; else ok; fi
if [[ "$CODE" =~ (window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then bad "a native dialog in the boundary"; else ok; fi

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/@sentry/browser" ]; then
  echo "error-report-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
elif ! command -v node >/dev/null 2>&1; then
  echo "error-report-console: node suite SKIPPED — node is not installed on this box"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/error-report.bh-5619.test.js 2>&1); then ok
  else bad "console-ui/tests/error-report.bh-5619.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "error-report-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
