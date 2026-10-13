#!/bin/bash
# tests/agent-call-codex-ladder.bh-1853-test.sh — a codex-primary stage whose
# OpenRouter fallback the exhausted-only gate refused gets a claude rung in its
# place (BH-1853, #1850 follow-up 3c).
#
# OPENROUTER_FALLBACK=exhausted-only (default) refuses OpenRouter as a fallback
# while a Claude OAuth account can serve. For a claude-primary stage that is
# right: claude already ran. For a codex-primary stage whose configured
# fallback is openrouter it left the ladder with nothing after grok: the stage
# failed without a single claude attempt. The ladder is now
#   primary -> grok tier-2 -> claude (all accounts) -> OpenRouter only if claude is out.
# Driven through bin/agent-call.sh with fake CLIs (the
# agent-call-openrouter-gate-test.sh shape). The fake codex FAILS as the
# primary codex provider and succeeds as the openrouter/fireworks provider; the
# fake claude succeeds unless CLAUDE_MODE says otherwise.
#   X1  RUNNER_EVAL_FALLBACK=openrouter: claude runs once, openrouter never,
#       rc 0, one failovers line naming the substitution
#   X2  no configured fallback: claude runs once, openrouter never
#   X3  OPENROUTER_FALLBACK=always: openrouter runs, claude never (as before)
#   X4  AGENT_CALL_RUNNERS=codex,openrouter: claude is not allowed, never runs
#   X5  no OPENROUTER_API_KEY: the gate removed nothing, claude never runs
#   X6  claude primary failing for a real reason: no second claude call
#   X7  every claude account cooling (ACCOUNT_ROUTING=1): claude is out, so
#       openrouter runs and claude never does
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
case "${CLAUDE_MODE:-ok}" in
  real) printf '{"result":"could not do it","usage":{"input_tokens":5,"output_tokens":1}}\n'; exit 1 ;;
esac
printf '{"result":"claude answered","usage":{"input_tokens":5,"output_tokens":1},"total_cost_usd":0.01}\n'
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
if [ "$provider" = codex ]; then
  echo "I could not complete this task: the tests in the repository do not build and I stopped."
  exit 1
fi
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

RC=0
run_call() { # run_call <keep-quota:0|1> <env...>
  local keep="$1"; shift
  : > "$T/order"; : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"
  [ "$keep" = 1 ] || rm -rf "$T/state/quota"
  ( export ORDER_SINK="$T/order" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           ACCOUNTS_DIR="$T/env/accounts.d" LADDER_BACKOFF_SECS=0 LADDER_TIER2_GROK=1 \
           RUNNER_EVAL=codex CODEX_API_KEY=x CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    env -u ACCOUNT_ROUTING -u RUNNER_EVAL_FALLBACK -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY \
      -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u OPENROUTER_FALLBACK -u AGENT_CALL_RUNNERS \
      "$@" bash "$DIR/bin/agent-call.sh" eval testproj claude-opus-5 600 "$T/out.txt" "hello" \
      >/dev/null 2>&1 ); RC=$?
}
ran() { grep -c "^$1\$" "$T/order" 2>/dev/null || true; }
order() { tr '\n' ',' < "$T/order"; }
subs() { grep -c 'claude in place of openrouter' "$T/logs/failovers.log" 2>/dev/null || true; }

# X1 — configured openrouter fallback, gated away: claude takes the rung
run_call 0 env OPENROUTER_API_KEY=x RUNNER_EVAL_FALLBACK=openrouter
[ "$(ran codex)" -ge 1 ] && ok || bad "X1: fixture: the codex primary never ran ($(order))"
[ "$(ran claude)" = 1 ] && ok || bad "X1: expected one claude call in OpenRouter's place, got $(ran claude) ($(order))"
[ "$(ran openrouter)" = 0 ] && ok || bad "X1: OpenRouter was bought while claude could serve ($(order))"
[ "$RC" = 0 ] && ok || bad "X1: the stage should end rc 0 on the claude rung, got rc $RC"
[ "$(subs)" = 1 ] && ok || bad "X1: expected one failovers line naming the substitution, got $(subs): $(cat "$T/logs/failovers.log")"

# X2 — no configured fallback (tier-3 path)
run_call 0 env OPENROUTER_API_KEY=x
[ "$(ran claude)" = 1 ] && ok || bad "X2: expected one claude call, got $(ran claude) ($(order))"
[ "$(ran openrouter)" = 0 ] && ok || bad "X2: OpenRouter was bought while claude could serve ($(order))"
[ "$RC" = 0 ] && ok || bad "X2: the stage should end rc 0, got rc $RC"

# X3 — always: the behaviour before the gate, no substitution
run_call 0 env OPENROUTER_API_KEY=x RUNNER_EVAL_FALLBACK=openrouter OPENROUTER_FALLBACK=always
[ "$(ran openrouter)" -ge 1 ] && ok || bad "X3: OPENROUTER_FALLBACK=always did not reach OpenRouter ($(order))"
[ "$(ran claude)" = 0 ] && ok || bad "X3: claude ran although OpenRouter was allowed ($(order))"
[ "$(subs)" = 0 ] && ok || bad "X3: a substitution line was written under always"

# X4 — claude not in AGENT_CALL_RUNNERS
run_call 0 env OPENROUTER_API_KEY=x RUNNER_EVAL_FALLBACK=openrouter AGENT_CALL_RUNNERS=codex,openrouter
[ "$(ran claude)" = 0 ] && ok || bad "X4: claude ran although the caller does not accept it ($(order))"
[ "$(subs)" = 0 ] && ok || bad "X4: a substitution line was written for a runner the caller refuses"

# X5 — no OpenRouter key: the gate took nothing away
run_call 0 env RUNNER_EVAL_FALLBACK=openrouter
[ "$(ran claude)" = 0 ] && ok || bad "X5: claude ran with no OpenRouter key to replace ($(order))"
[ "$(subs)" = 0 ] && ok || bad "X5: a substitution line was written with no OpenRouter key"

# X6 — claude primary, real failure: no second claude call
run_call 0 env RUNNER_EVAL=claude CLAUDE_MODE=real OPENROUTER_API_KEY=x RUNNER_EVAL_FALLBACK=openrouter
[ "$(ran claude)" = 1 ] && ok || bad "X6: a claude primary got a second claude call, got $(ran claude) ($(order))"
[ "$(subs)" = 0 ] && ok || bad "X6: a substitution line was written for a claude primary"

# X7 — every claude account cooling: claude is out, OpenRouter is the rung
two_accounts; rm -rf "$T/state/quota"; cool_all
run_call 1 env OPENROUTER_API_KEY=x RUNNER_EVAL_FALLBACK=openrouter ACCOUNT_ROUTING=1
[ "$(ran openrouter)" -ge 1 ] && ok || bad "X7: every claude account is cooling and OpenRouter was refused ($(order))"
[ "$(ran claude)" = 0 ] && ok || bad "X7: a cooling claude account was called ($(order))"
[ "$(subs)" = 0 ] && ok || bad "X7: a substitution line was written while claude is out"
rm -f "$T/env/accounts.d"/*.env

echo "agent-call-codex-ladder.bh-1853: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
