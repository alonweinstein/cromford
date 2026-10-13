#!/bin/bash
# tests/agent-call-openrouter-gate-test.sh — OpenRouter is not a fallback while
# a Claude OAuth account can still serve the call (the operator, 2026-09-24: "No need to
# use OpenRouter if the Claude OAuth is working").
#
# On 09-21..23 OpenRouter cost ~$1.1K/day as an ordinary fallback — the tier-3
# survival block and the configured RUNNER_<STAGE>_FALLBACK=openrouter arm —
# while healthy Claude accounts sat idle. OPENROUTER_FALLBACK (default
# exhausted-only) gates both arms. Pinned, driven through bin/agent-call.sh with
# fake CLIs (the ladder-recovery-test.sh shape):
#   G1  claude healthy, failing for a NON-account reason, openrouter configured
#       as the stage's fallback: no OpenRouter call, one SKIPPED line
#   G2  the same through the tier-3 survival block (no configured fallback)
#   G3  every claude account cooling (ACCOUNT_ROUTING=1): OpenRouter is allowed
#   G4  the only claude account exhausted, no routing: OpenRouter is allowed
#   G5  OPENROUTER_FALLBACK=off: never, even with claude exhausted
#   G6  OPENROUTER_FALLBACK=always: the behaviour before the gate
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" testproj
mkdir -p "$T/bin" "$T/bin/lib" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env/accounts.d"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) printf -- '  --resume <sessionId>\n'; exit 0 ;; esac
echo "claude" >> "$ORDER_SINK"
case "${CLAUDE_MODE:-real}" in
  quota) echo "You have hit your weekly limit" >&2; exit 1 ;;
  real)  printf '{"result":"could not do it","usage":{"input_tokens":5,"output_tokens":1}}\n'; exit 1 ;;
esac
EOF
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
echo "grok" >> "$ORDER_SINK"; echo "grok is not configured" >&2; exit 1
EOF
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
provider=codex
for arg in "$@"; do case "$arg" in *model_provider*openrouter*) provider=openrouter ;; *model_provider*fireworks*) provider=fireworks ;; esac; done
echo "$provider" >> "$ORDER_SINK"
echo "$provider answered"; exit 0
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
printf '#!/bin/bash\necho "1 2 3 4"\n' > "$T/bin/codex-usage.sh"
cp "$DIR/bin/account-pick.sh" "$T/bin/account-pick.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh

mkdir -p "$T/.claude-a" "$T/.claude-b"
two_accounts() {
  printf 'ACCOUNT_NAME=a\nACCOUNT_VENDOR=claude\nACCOUNT_PRIORITY=20\nCLAUDE_CONFIG_DIR=%s/.claude-a\n' "$T" > "$T/env/accounts.d/a.env"
  printf 'ACCOUNT_NAME=b\nACCOUNT_VENDOR=claude\nACCOUNT_PRIORITY=10\nCLAUDE_CONFIG_DIR=%s/.claude-b\n' "$T" > "$T/env/accounts.d/b.env"
  chmod 600 "$T/env/accounts.d"/*.env
}
cool_all() {
  mkdir -p "$T/state/quota/cooldown/claude"
  date -u +%s > "$T/state/quota/cooldown/claude/a"; date -u +%s > "$T/state/quota/cooldown/claude/b"
}

run_call() { # run_call <keep-quota:0|1> <env...>
  local keep="$1"; shift
  : > "$T/order"; : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"
  [ "$keep" = 1 ] || rm -rf "$T/state/quota"
  ( export ORDER_SINK="$T/order" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           ACCOUNTS_DIR="$T/env/accounts.d" LADDER_BACKOFF_SECS=0 LADDER_TIER2_GROK=1 \
           RUNNER_EVAL=claude CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    env -u ACCOUNT_ROUTING -u RUNNER_EVAL_FALLBACK -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY \
      -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u CODEX_API_KEY -u OPENROUTER_FALLBACK \
      "$@" bash "$DIR/bin/agent-call.sh" eval testproj claude-opus-5 600 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
}
ran() { grep -c "^$1\$" "$T/order" 2>/dev/null || true; }
skips() { grep -c 'openrouter SKIPPED as a fallback' "$T/logs/failovers.log" 2>/dev/null || true; }

# G1 — configured fallback arm
run_call 0 env CLAUDE_MODE=real OPENROUTER_API_KEY=x RUNNER_EVAL_FALLBACK=openrouter
[ "$(ran openrouter)" = 0 ] && ok || bad "G1: claude is healthy and OpenRouter was bought as the configured fallback ($(tr '\n' ',' < "$T/order"))"
[ "$(skips)" = 1 ] && ok || bad "G1: expected one SKIPPED line, got $(skips)"
grep -q 'SKIPPED as a fallback: a Claude OAuth account can still serve' "$T/logs/failovers.log" \
  && ok || bad "G1: the SKIPPED line does not say why: $(grep SKIPPED "$T/logs/failovers.log")"

# G2 — tier-3 survival block
run_call 0 env CLAUDE_MODE=real OPENROUTER_API_KEY=x
[ "$(ran openrouter)" = 0 ] && ok || bad "G2: claude is healthy and the tier-3 block bought OpenRouter ($(tr '\n' ',' < "$T/order"))"
[ "$(skips)" = 1 ] && ok || bad "G2: expected one SKIPPED line, got $(skips)"

# G3 — every claude account cooling
two_accounts; rm -rf "$T/state/quota"; cool_all
run_call 1 env CLAUDE_MODE=real OPENROUTER_API_KEY=x ACCOUNT_ROUTING=1
[ "$(ran openrouter)" -ge 1 ] && ok || bad "G3: every claude account is cooling and OpenRouter was still refused ($(tr '\n' ',' < "$T/order"))"
[ "$(ran claude)" = 0 ] && ok || bad "G3: a cooling claude account was called anyway"
rm -f "$T/env/accounts.d"/*.env

# G4 — the only account exhausted, no routing
run_call 0 env CLAUDE_MODE=quota OPENROUTER_API_KEY=x
[ "$(ran openrouter)" -ge 1 ] && ok || bad "G4: claude's only account is exhausted and OpenRouter was refused ($(tr '\n' ',' < "$T/order"))"

# G5 — off
run_call 0 env CLAUDE_MODE=quota OPENROUTER_API_KEY=x OPENROUTER_FALLBACK=off RUNNER_EVAL_FALLBACK=openrouter
[ "$(ran openrouter)" = 0 ] && ok || bad "G5: OPENROUTER_FALLBACK=off still bought OpenRouter"
[ "$(skips)" = 1 ] && ok || bad "G5: expected one SKIPPED line, got $(skips)"
grep -q '^RUNNER_EXHAUSTED ' "$T/out.txt.class" 2>/dev/null && ok || bad "G5: the stage did not end RUNNER_EXHAUSTED: $(cat "$T/out.txt.class" 2>/dev/null)"

# G6 — always
run_call 0 env CLAUDE_MODE=real OPENROUTER_API_KEY=x OPENROUTER_FALLBACK=always
[ "$(ran openrouter)" -ge 1 ] && ok || bad "G6: OPENROUTER_FALLBACK=always did not reach OpenRouter"
[ "$(skips)" = 0 ] && ok || bad "G6: always wrote a SKIPPED line"

echo "agent-call-openrouter-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
