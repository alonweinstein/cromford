#!/bin/bash
# tests/agent-call-budget-stop-cost.bh-4609-test.sh — BH-4609: the BUDGET STOP
# line in bin/agent-call.sh carries the stopped attempt's cost.
#
# The line runs at top level after the ladder, where run_attempt's `local USD`
# is out of scope, so it printed `cost $?` on every stop (Archie's I2 on
# 2026-10-05 said `cost $?` for a call the envelope priced). It now reads the
# envelope's total_cost_usd, then the last attempt's spend, then `?`.
#
#   B1  a budget envelope with total_cost_usd 0.4321: rc != 0, exactly one
#       BUDGET STOP line, `cost $0.4321`
#   B2  the same with no total_cost_usd: still one line, an honest `cost $?`
#   B3  the ladder does not engage on a budget stop (no grok / OpenRouter /
#       Fireworks marker)
#
# HOW: the real bin/agent-call.sh against a scratch $HARNESS, a fake `claude`,
# `timeout`, `grok`, `curl` on PATH, the way tests/context-kill.bh-653-test.sh
# drives it.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/agent-call-budget-stop-cost.bh-4609-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/bin" "$T/fakebin" "$T/.claude/projects/-work"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

# The fake claude answers with whatever $T/envelope holds and exits 1, the way
# the CLI ends a --max-budget-usd stop.
cat > "$T/fakebin/claude" <<'SH'
#!/bin/bash
cat "$T_DIR/envelope"
exit 1
SH
cat > "$T/fakebin/grok" <<'SH'
#!/bin/bash
touch "$T_DIR/grok-was-called"; echo "GROK ANSWER"
SH
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
case "$*" in *openrouter*) touch "$T_DIR/openrouter-was-called" ;; *fireworks*) touch "$T_DIR/fireworks-was-called" ;; esac
exit 7
SH
cat > "$T/fakebin/timeout" <<'SH'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
SH
chmod +x "$T/fakebin/claude" "$T/fakebin/grok" "$T/fakebin/curl" "$T/fakebin/timeout"
mkdir -p "$T/.grok/bin"; cp "$T/fakebin/grok" "$T/.grok/bin/grok"
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"; chmod +x "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"

run_call() { # run_call <outfile> ; echoes the rc
  local out="$1"
  rm -f "$out" "$out".* "$T/grok-was-called" "$T/openrouter-was-called" "$T/fireworks-was-called"
  : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" T_DIR="$T" LADDER_TIER2_GROK=1 \
           XAI_API_KEY=x OPENROUTER_API_KEY=x FIREWORKS_API_KEY=x
    unset AGENT_CALL_TICKET AGENT_CALL_FP COST_KEY HARNESS_TICKET
    bash "$DIR/bin/agent-call.sh" eval testproj claude-fable-5-1 60 "$out" "hello" >/dev/null 2>&1 )
  echo $?
}

# ── B1: the envelope's cost reaches the line ────────────────────────────────
printf '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":0.4321,"session_id":"s-1","usage":{"input_tokens":10,"output_tokens":2}}\n' > "$T/envelope"
RC=$(run_call "$T/out.b1")
[ "$RC" != 0 ] && ok || bad "B1 a budget stop returned rc 0"
N=$(grep -c 'BUDGET STOP' "$T/logs/ALERTS.log")
[ "$N" = 1 ] && ok || bad "B1 want exactly one BUDGET STOP line, got $N: $(cat "$T/logs/ALERTS.log")"
L=$(grep 'BUDGET STOP' "$T/logs/ALERTS.log")
grep -q 'cost \$0\.4321' <<<"$L" && ok || bad "B1 the line does not carry cost \$0.4321: $L"
grep -qF 'cost $?' <<<"$L" && bad "B1 the line still says cost \$?: $L" || ok
# B3 on the B1 run: no rung below engaged.
for m in grok openrouter fireworks; do
  [ -f "$T/$m-was-called" ] && bad "B3 $m engaged on a budget stop" || ok
done
grep -q 'failing over' "$T/logs/failovers.log" && bad "B3 the ladder failed over: $(cat "$T/logs/failovers.log")" || ok

# ── B2: no cost in the envelope is an honest `?` ────────────────────────────
printf '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"session_id":"s-2"}\n' > "$T/envelope"
RC=$(run_call "$T/out.b2")
[ "$RC" != 0 ] && ok || bad "B2 a budget stop returned rc 0"
N=$(grep -c 'BUDGET STOP' "$T/logs/ALERTS.log")
[ "$N" = 1 ] && ok || bad "B2 want exactly one BUDGET STOP line, got $N: $(cat "$T/logs/ALERTS.log")"
L=$(grep 'BUDGET STOP' "$T/logs/ALERTS.log")
grep -qF 'cost $?)' <<<"$L" && ok || bad "B2 want cost \$? with no envelope cost: $L"
for m in grok openrouter fireworks; do
  [ -f "$T/$m-was-called" ] && bad "B3 $m engaged on a budget stop (B2)" || ok
done

echo "agent-call-budget-stop-cost: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
