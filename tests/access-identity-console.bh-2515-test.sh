#!/bin/bash
# tests/access-identity-console.bh-2515-test.sh — BH-2515: console writes name
# the human behind them (the Cloudflare Access email), or 'console' when
# Access is off.
#
#   1. the new sources exist, named here by path so the orphan ratchet and the
#      impact lane can see them.
#   2. bin/poll-commands.sh's pause handlers, EXTRACTED VERBATIM (the
#      poll-commands-pause.bh-1685 pattern): pause_set and pause_board write the
#      command payload's actor onto the pauses row when it fits the worker's
#      actor charset, and 'console' otherwise.
#   3. the node suite console-ui/tests/access-identity.bh-2515.test.js (the
#      Pages functions and the top bar), run for real when the console-ui
#      dependencies are installed.
# Run from anywhere: tests/access-identity-console.bh-2515-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/h/flags"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# --- 1: the sources ----------------------------------------------------------
HELPER="$DIR/console-ui/functions/_lib/access-identity.js"
PILL="$DIR/console-ui/src/lib/identity.js"
NODE_SUITE="$DIR/console-ui/tests/access-identity.bh-2515.test.js"
for f in "$HELPER" "$PILL" "$NODE_SUITE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
# Pages routes any functions/ file that exports onRequest*; the helper must not.
grep -qE 'export (async )?function onRequest|export const onRequest' "$HELPER" \
  && bad "the helper exports onRequest, so Pages would route a URL to it" || ok

# --- 2: the pause handlers, driven -------------------------------------------
{ echo 'case "$TYPE" in'
  awk '/^    # >>> pause handlers/{f=1;next} /^    # <<< pause handlers/{exit} f{print}' "$DIR/bin/poll-commands.sh"
  echo 'esac'
} > "$T/pause.body"
[ "$(wc -l < "$T/pause.body")" -gt 3 ] || { echo "FAIL: could not extract the pause handlers block — markers missing?"; exit 1; }

cat > "$T/stubs.sh" <<'EOF'
set_flag() { case "${2:-}" in on) touch "$HARNESS/flags/$1" ;; off) rm -f "$HARNESS/flags/$1" ;; esac; return 0; }
_jobs_req() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$CALLS"; JOBS_HTTP=200; printf '{}'; return 0; }
EOF
CALLS="$T/calls.log"
run() { # run <type> <payload-json> -> prints the PUT /api/pauses body's actor
  : > "$CALLS"
  HARNESS="$T/h" CALLS="$CALLS" TYPE="$1" PROJECT=project-3 PAYLOAD="$2" ID=42 OK=false RESULT="" \
    bash -c 'set -uo pipefail; . "$0"; . "$1"' "$T/stubs.sh" "$T/pause.body" >/dev/null
  grep '^PUT /api/pauses ' "$CALLS" | head -1 | cut -d' ' -f3- | jq -r '.actor'
}

# P1 / P2: a well-formed actor lands on the row
A=$(run pause_set '{"what":"merges","reason":"x","actor":"operator@example.com"}')
[ "$A" = "operator@example.com" ] && ok || bad "P1 pause_set must record the command's actor (got '$A')"
A=$(run pause_board '{"reason":"x","actor":"operator@example.com"}')
[ "$A" = "operator@example.com" ] && ok || bad "P2 pause_board must record the command's actor (got '$A')"

# P3: anything the worker's actor charset refuses, or that is not a string, is console
for bad_actor in '"x:y"' '["a"]' '""' '"   "' '{"a":1}' '"a b@c.d"' "\"$(printf 'a%.0s' $(seq 1 97))\""; do
  for type in pause_set pause_board; do
    A=$(run "$type" "{\"what\":\"merges\",\"reason\":\"x\",\"actor\":$bad_actor}")
    [ "$A" = "console" ] && ok || bad "P3 $type with actor $bad_actor must record console (got '$A')"
  done
done

# P4: no actor at all is the unchanged contract
for type in pause_set pause_board; do
  A=$(run "$type" '{"what":"merges","reason":"x"}')
  [ "$A" = "console" ] && ok || bad "P4 $type with no actor must record console (got '$A')"
done

# --- 3: the node suite, driven -----------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "access-identity-console: node suite SKIPPED — node is not installed on this box"
elif [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "access-identity-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/access-identity.bh-2515.test.js 2>&1); then ok
  else bad "console-ui/tests/access-identity.bh-2515.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "access-identity-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
