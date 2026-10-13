#!/bin/bash
# tests/kill-not-failover-test.sh — an externally KILLED run must not be routed
# to another vendor (2026-08-27).
#
# WHY. rc=137 is SIGKILL — the OS, an operator, or a parent turn ending. The
# vendor never answered, so there is nothing to route around, and the ladder's
# reflex ("primary failed -> try OpenRouter with the same stage model") re-buys
# the entire context at full API price with a cold cache. That is exactly the
# line item that put $239 of anthropic/claude-opus-5 through OpenRouter in one
# day. Budget stops were made terminal for the same reason; kills are the other
# half of that lesson.
#
# Driven, not grepped: agent-call.sh is run for real against a temp HARNESS with
# fake CLIs, and which binaries actually ran is read back off disk.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/bin" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Fake claude: counts its calls, then dies the way the incident died — no
# output at all, exit 137, immediately (well inside the timeout window).
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
echo x >> "$T_SENTINEL_DIR/claude-calls"
[ -f "$T_SENTINEL_DIR/claude-fails-soft" ] && { echo "API Error: 500 upstream"; exit 1; }
exit 137
EOF
# codex is the binary behind BOTH the codex fallback and the openrouter/
# fireworks survival lanes. If any of them engage on a kill, it leaves a file.
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
echo x >> "$T_SENTINEL_DIR/codex-calls"
echo "fallback answered"
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
# timeout shim (also keeps this runnable on a dev box without GNU coreutils):
# strip the kill-after flag and the duration, keep the child's exit code.
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/"* "$T/bin/beat.sh"

run_call() {
  rm -f "$T/claude-calls" "$T/codex-calls" "$T/logs/ALERTS.log" "$T/logs/kills.log" "$T/logs/failovers.log"
  # LADDER_BACKOFF_SECS=0: the recovery ladder's transient retry sleeps for real
  # (60s doubling on the fleet), and a suite that waits it out tests patience.
  ( export T_SENTINEL_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           LADDER_BACKOFF_SECS=0 \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           RUNNER_EVAL_FALLBACK=codex CODEX_API_KEY=x OPENROUTER_API_KEY=x FIREWORKS_API_KEY=x \
           OPENROUTER_FALLBACK=always
    # `always` (2026-09-24): case 2's answer comes from the OpenRouter survival
    # rung while claude is healthy, which the default exhausted-only gate now
    # refuses by design (tests/agent-call-openrouter-gate-test.sh). What this
    # suite pins is that a KILL never descends and a real error still does.
    bash "$DIR/bin/agent-call.sh" eval testproj claude-fable-5 600 "$T/out.txt" "hello" >/dev/null 2>&1 )
  echo $?
}
calls() { [ -f "$T/$1-calls" ] && wc -l < "$T/$1-calls" | tr -d ' ' || echo 0; }

# --- 1. killed (rc=137, fast, silent) -> same lane once, then STOP -----------
rm -f "$T/claude-fails-soft"
RC=$(run_call)
[ "$RC" -ne 0 ] && ok || bad "a killed stage exited 0"
[ "$(calls codex)" = 0 ] \
  && ok || bad "a KILLED run engaged another vendor $(calls codex)x — this is the money leak the guard exists to stop"
[ "$(calls claude)" = 2 ] \
  && ok || bad "expected exactly one same-lane retry on a kill, got $(calls claude) claude calls"
grep -q "KILLED" "$T/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "no KILLED line in ALERTS: $(tail -1 "$T/logs/ALERTS.log" 2>/dev/null)"
grep -qiE "re-login|AUTH DOWN|setup-token" "$T/logs/ALERTS.log" 2>/dev/null \
  && bad "the kill alert blames auth — that is the false-diagnosis this guard removes" || ok
grep -q "rc=137 killed after" "$T/logs/kills.log" 2>/dev/null \
  && ok || bad "no forensics row in kills.log (mem/load at kill time is how we find the killer)"

# --- 2. a REAL vendor failure still fails over (the guard is not a mute) -----
touch "$T/claude-fails-soft"
RC=$(run_call)
[ "$(calls codex)" -ge 1 ] \
  && ok || bad "a genuine vendor error (rc=1 with an API message) no longer reaches the fallback runner"
[ "$RC" -eq 0 ] && ok || bad "the fallback answered but the stage still exited $RC"

echo "kill-not-failover: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
