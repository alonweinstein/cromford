#!/bin/bash
# tests/token-health-panel.bh-2647-test.sh — the /settings ACCOUNT & TOKEN
# HEALTH panel (BH-2516.3, slice BH-2647).
#
# The panel's behaviour is proved by node --test in
# console-ui/tests/token-health.bh-2647.test.js. This file is the door the
# impact lane and the orphan ratchet can see:
#   1. Settings.js imports and mounts TokenHealthSection.
#   2. TokenHealth.js is read-only: no native dialog, no useConfirm, no form.
#   3. lib/token-health.js, DRIVEN: red is the worker's `expiring`, never a
#      clock rule; a fail count of 0 stays 0 and an absent one is unknown.
#   4. the node suites, run for real when their dependencies are installed.
# Run from anywhere: tests/token-health-panel.bh-2647-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/token-health.js"
PANEL="$DIR/console-ui/src/screens/TokenHealth.js"
SETTINGS="$DIR/console-ui/src/screens/Settings.js"

for f in "$LIB" "$PANEL" "$SETTINGS"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 1: the mount -------------------------------------------------------------
grep -q "import { TokenHealthSection } from './TokenHealth.js'" "$SETTINGS" && ok || bad "Settings.js does not import TokenHealthSection"
grep -q '<${TokenHealthSection}/>' "$SETTINGS" && ok || bad "Settings.js does not mount TokenHealthSection"
grep -q 'intervalMs: 60000' "$PANEL" && ok || bad "TokenHealth.js does not refresh every 60 s"

# --- 2: read-only ---------------------------------------------------------------
if grep -nE 'useConfirm|(^|[^a-zA-Z_])(confirm|alert|prompt)\(|<form|<input' "$PANEL" "$LIB"; then
  bad "a write control or native dialog in the TOKEN HEALTH panel"
else
  ok
fi

command -v node >/dev/null 2>&1 || { echo "token-health-panel: node checks SKIPPED — node is not installed on this box"; echo "token-health-panel: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

# --- 3: the lib, driven -----------------------------------------------------------
OUT=$(node --input-type=module -e "
import { healthRows, warnNote } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const rows = healthRows({ accounts: [
  { kind: 'oauth', subject: 'a', expires_in_s: 7200, expiring: true, fail_count: 0 },
  { kind: 'gh_app', subject: 'b', expires_in_s: 7200, expiring: false },
  { kind: 'oauth', subject: 'c', expires_in_s: 172800, expiring: true, reported: false },
] });
eq('red',      rows.map((r) => r.red), [true, false, true]);
eq('kind',     rows.map((r) => r.kindLabel), ['OAuth', 'GH App', 'OAuth']);
eq('fails',    rows.map((r) => r.failCount), [0, null, null]);
eq('expires',  rows[0].expiresText, 'in 2h 0m');
eq('noreport', rows.map((r) => r.noReport), [false, false, true]);
eq('junk',     healthRows({ accounts: 'x' }), []);
eq('warn',     warnNote({ warn_h: 24, warn_h_source: 'default' }), 'Red = under 24 h to expiry (default)');
" 2>&1)
[ -n "$OUT" ] || bad "lib: no output from node"
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 4: the node suites -------------------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "token-health-panel: console node suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
else
  for s in tests/token-health.bh-2647.test.js tests/project-accounts.bh-1657.test.js; do
    if NOUT=$(cd "$DIR/console-ui" && node --test "$s" 2>&1); then ok
    else bad "console-ui/$s failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
    fi
  done
fi

echo "token-health-panel: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
