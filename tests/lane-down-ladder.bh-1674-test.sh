#!/bin/bash
# tests/lane-down-ladder.bh-1674-test.sh — BH-1690 (BH-1674.4): a lane-down mark
# is a report for humans, never a skip in the provider ladder. The canary marks
# hub-grok down through bin/lib/lane-down.sh; bin/agent-call.sh must still try
# grok on the very next call, and the one after, so a lane that came back is
# found by real traffic and not left dark until the next 6h canary pass.
#   A1  baseline, no marks: claude's Fable->Opus retry, then grok answers.
#   A2  ld_mark plants all three artifacts: today's flags/lanedown-hub-grok-*,
#       the hub-grok line in state/claude-auth-down.txt, and the
#       state/lane-down/hub-grok record (box=hub, lane=grok).
#   A3  call 1 with the marks set: rc 0, order claude,claude,grok, no paid
#       survival provider.
#   A4  call 2, nothing cleared but the order sink: the same, and the marks are
#       still there, so the second call really ran with them present.
# Drives the real bin/agent-call.sh with the fake providers of
# tests/agent-call-provider-order-test.sh. Run from anywhere with
# HARNESS_TEST_SANDBOX=1 (exit 0 = pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
. "$DIR/bin/lib/lane-down.sh" || exit 1
mrs_fixture "$T" testproj
mkdir -p "$T/bin" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
echo "usage limit" >&2
exit 1
EOF
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
echo grok >> "$ORDER_SINK"
echo "grok answered"
EOF
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
provider=codex
for arg in "$@"; do
  case "$arg" in
    *model_provider*openrouter*) provider=openrouter ;;
    *model_provider*fireworks*) provider=fireworks ;;
  esac
done
echo "$provider" >> "$ORDER_SINK"
echo "$provider answered"
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
cat > "$T/bin/billing-mode.sh" <<'EOF'
#!/bin/bash
echo subscription
EOF
cat > "$T/bin/beat.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$T/bin/sync-agent-rules.sh" <<'EOF'
#!/bin/bash
echo "test rules"
EOF
chmod +x "$T/fakebin/"* "$T/bin/"*

# AGENT_CALL_LEDGER=0 (BH-1037): both marked calls ship the same prompt, so
# without it the second one replays from the prompt ledger and "each call is a
# fresh attempt" would be proved by a cache hit.
run_call() {
  : > "$T/order"
  ( export ORDER_SINK="$T/order" PATH="$T/fakebin:$PATH" \
           HARNESS="$T" HOME="$T" OPENROUTER_API_KEY=test FIREWORKS_API_KEY=test \
           LADDER_BACKOFF_SECS=0 LADDER_TIER2_GROK=1 AGENT_CALL_LEDGER=0 \
           RUNNER_REVIEW=claude RUNNER_REVIEW_FALLBACK=openrouter \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    bash "$DIR/bin/agent-call.sh" review testproj claude-fable-5-1 60 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}

check_call() { # check_call <label>
  local rc=$1 label=$2 order
  order=$(paste -sd, "$T/order")
  [ "$rc" -eq 0 ] && ok || bad "$label: grok answered but the stage exited $rc"
  [ "$order" = "claude,claude,grok" ] \
    && ok || bad "$label: expected claude,claude,grok, got $order"
  grep -qE '^(openrouter|fireworks)$' "$T/order" \
    && bad "$label: a paid survival provider ran: $order" || ok
}

# ---- A1: baseline, nothing marked ---------------------------------------------
[ ! -e "$T/state/lane-down/hub-grok" ] && ok || bad "A1 fixture: a record exists before ld_mark"
check_call "$(run_call)" "A1 baseline"

# ---- A2: plant all three artifacts through the contract lib ------------------
NOW=$(date -u +%s)
TODAY=$(date -u -d "@$NOW" +%Y%m%d)
ld_mark "$T" hub-grok "" "grok: probe failed" "$NOW" \
  || { echo "FAIL: fixture: ld_mark hub-grok returned $?"; exit 1; }
REC=$(ld_record_path "$T" hub-grok)
marks_present() { # marks_present <label>
  [ -f "$T/flags/lanedown-hub-grok-$TODAY" ] && ok || bad "$1 fixture: flags/lanedown-hub-grok-$TODAY missing"
  grep -qxF hub-grok "$T/state/claude-auth-down.txt" 2>/dev/null \
    && ok || bad "$1 fixture: no hub-grok line in state/claude-auth-down.txt"
  [ "$(ld_get "$REC" lane)" = grok ] && ok || bad "$1 fixture: record lane=$(ld_get "$REC" lane)"
  [ "$(ld_get "$REC" box)" = hub ] && ok || bad "$1 fixture: record box=$(ld_get "$REC" box)"
}
marks_present A2

# ---- A3/A4: two calls in a row, marks left in place ---------------------------
check_call "$(run_call)" "A3 call 1 with lane-down marks"
check_call "$(run_call)" "A4 call 2 with lane-down marks"
marks_present A4

echo "lane-down-ladder: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
