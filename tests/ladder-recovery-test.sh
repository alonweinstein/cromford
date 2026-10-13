#!/bin/bash
# tests/ladder-recovery-test.sh — RECOVERY BEFORE FALLBACK (2026-09-16).
#
# WHY. the operator: "if it's stuck for very little it falls back; we need recovery
# procedures. Falling all the way to Fireworks is bad but ok as the LAST
# resort." The ladder used to read one thing off a failed attempt — the exit
# code — and answer every failure the same way: change vendor. A 30-second 503,
# an account that ran out of weekly quota, an expired login and an agent that
# genuinely could not do the job all bought the next rung down.
#
# So this suite pins the CLASS -> RECOVERY contract:
#   transient         -> retry the SAME runner+account, LADDER_SAME_RETRIES times
#   timeout           -> same, resuming the session id when the CLI takes --resume
#   account-exhausted -> cool the account down, rotate to the next one of the
#   auth                 SAME vendor, until the vendor has none left
#   real-failure      -> no same-vendor retry; descend a rung
# and that the rungs below the OpenRouter anthropic/ slug are never silent.
#
# DRIVEN, NOT GREPPED: bin/agent-call.sh is executed for real against a temp
# HARNESS with fake CLIs, and what actually ran is read back off disk.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1510.1: agent-call reads its ladders from model_routes; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" testproj
mkdir -p "$T/bin" "$T/bin/lib" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env/accounts.d"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------- fakes -----------------------------------------------------------
# The fake claude records every invocation WITH ITS ARGV (that is how --resume
# is observed) and fails in whichever way the case under test needs. --help is
# answered without counting: the CLI capability probe must not look like an
# attempt.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in
  *" --help "*) printf -- '  --resume <sessionId>\n  --session-id <uuid>\n'; exit 0 ;;
esac
printf 'claude cfg=%s args=%s\n' "${CLAUDE_CONFIG_DIR:-default}" "$*" >> "$ORDER_SINK"
N=$(grep -c '^claude ' "$ORDER_SINK")
if [ "$N" -gt "${CLAUDE_FAIL_TIMES:-99}" ]; then
  printf '{"result":"ok","usage":{"input_tokens":5,"output_tokens":1},"total_cost_usd":0.01}\n'
  exit 0
fi
case "${CLAUDE_MODE:-transient}" in
  transient) echo "API Error: 503 Service Unavailable" >&2; exit 1 ;;
  timeout)   exit 124 ;;
  auth)      echo "API Error: 401 Unauthorized" >&2; exit 1 ;;
  quota)     echo "${CLAUDE_QUOTA_TEXT:-Claude AI: you have hit your weekly limit}" >&2; exit 1 ;;
  real)      printf '{"result":"I read the ticket and could not do it","usage":{"input_tokens":5,"output_tokens":1}}\n'; exit 1 ;;
esac
EOF
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
echo "grok cfg=- args=-" >> "$ORDER_SINK"
[ "${GROK_RESULT:-fail}" = ok ] && { echo "grok answered"; exit 0; }
echo "grok is not configured" >&2; exit 1
EOF
# codex is the binary behind the configured fallback AND both survival lanes.
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
provider=codex; model=""
for arg in "$@"; do
  case "$arg" in
    *model_provider*openrouter*) provider=openrouter ;;
    *model_provider*fireworks*)  provider=fireworks ;;
  esac
done
prev=""
for arg in "$@"; do [ "$prev" = "-m" ] && model="$arg"; prev="$arg"; done
echo "$provider cfg=- args=-m $model" >> "$ORDER_SINK"
[ "${CODEX_RESULT:-fail}" = ok ] && { echo "$provider answered"; exit 0; }
echo "$provider: upstream refused" >&2; exit 1
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

# ---------- fixtures --------------------------------------------------------
mkdir -p "$T/.claude-a" "$T/.claude-b"
two_accounts() {
  rm -f "$T/env/accounts.d"/*.env
  cat > "$T/env/accounts.d/b.env" <<EOF
ACCOUNT_NAME=b
ACCOUNT_VENDOR=claude
ACCOUNT_PRIORITY=10
CLAUDE_CONFIG_DIR=$T/.claude-b
EOF
  cat > "$T/env/accounts.d/a.env" <<EOF
ACCOUNT_NAME=a
ACCOUNT_VENDOR=claude
ACCOUNT_PRIORITY=20
CLAUDE_CONFIG_DIR=$T/.claude-a
EOF
  chmod 600 "$T/env/accounts.d"/*.env
}
reset() { : > "$T/order"; : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"; rm -rf "$T/state/quota"; rm -f "$T/state/model-cooldown-"*; }

# run_call <model> <extra-env...> — drives bin/agent-call.sh for real.
run_call() {
  local model="$1"; shift
  reset
  ( export ORDER_SINK="$T/order" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           ACCOUNTS_DIR="$T/env/accounts.d" LADDER_BACKOFF_SECS=0 LADDER_TIER2_GROK=1 \
           RUNNER_EVAL=claude CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    env -u ACCOUNT_ROUTING -u RUNNER_EVAL_FALLBACK -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY \
      -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY \
      "$@" bash "$DIR/bin/agent-call.sh" eval testproj "$model" 600 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}
lanes() { cut -d' ' -f1 "$T/order" | paste -sd,; }
count() { grep -c "^$1 " "$T/order" 2>/dev/null || echo 0; }

# =============================================================================
# 1. TRANSIENT -> SAME RUNNER, SAME ACCOUNT, BEFORE ANY VENDOR CHANGE
# =============================================================================
RC=$(run_call claude-opus-5 env CLAUDE_MODE=transient GROK_RESULT=ok)
[ "$(count claude)" = 3 ] \
  && ok || bad "1: expected 1 attempt + 2 same-runner retries, got $(count claude) ($(lanes))"
[ "$(lanes)" = "claude,claude,claude,grok" ] \
  && ok || bad "1: the ladder descended before recovery was spent: $(lanes)"
grep -q 'class=transient(vendor)' "$T/logs/failovers.log" \
  && ok || bad "1: the failure class is not on the failovers.log line: $(tail -1 "$T/logs/failovers.log")"
grep -q 'retry 1/2 on the SAME runner+account' "$T/logs/failovers.log" \
  && ok || bad "1: the same-runner retry was not logged"
grep -q '2 same-runner retries spent — descending a rung' "$T/logs/failovers.log" \
  && ok || bad "1: the descent did not say the retries were spent"

# A transient blip that clears costs nothing below it: no vendor is touched.
RC=$(run_call claude-opus-5 env CLAUDE_MODE=transient CLAUDE_FAIL_TIMES=1 GROK_RESULT=ok)
[ "$RC" = 0 ] && ok || bad "1: the recovered stage still exited $RC"
[ "$(lanes)" = "claude,claude" ] \
  && ok || bad "1: a blip that cleared on retry still changed vendor: $(lanes)"

# LADDER_SAME_RETRIES=0 is the old behaviour, exactly.
RC=$(run_call claude-opus-5 env CLAUDE_MODE=transient GROK_RESULT=ok LADDER_SAME_RETRIES=0)
[ "$(lanes)" = "claude,grok" ] \
  && ok || bad "1: LADDER_SAME_RETRIES=0 did not restore the straight descent: $(lanes)"

# The backoff is real seconds, not a comment.
S=$(date +%s)
RC=$(run_call claude-opus-5 env CLAUDE_MODE=transient CLAUDE_FAIL_TIMES=1 GROK_RESULT=ok \
     LADDER_BACKOFF_SECS=1)
[ $(( $(date +%s) - S )) -ge 1 ] \
  && ok || bad "1: LADDER_BACKOFF_SECS did not delay the retry"

# =============================================================================
# 2. A TIMEOUT IS "STUCK", NOT A DEAD VENDOR
# =============================================================================
# One same-runner retry that RESUMES the session the timeout interrupted, and no
# model escalation: buying the same stuck run again at the opus rate answers
# nothing.
RC=$(run_call claude-fable-5-1 env CLAUDE_MODE=timeout CLAUDE_FAIL_TIMES=1 GROK_RESULT=ok)
[ "$RC" = 0 ] && ok || bad "2: the resumed retry did not recover the stage (rc=$RC)"
[ "$(count claude)" = 2 ] \
  && ok || bad "2: expected exactly 2 claude calls (one retry, no opus escalation), got $(count claude) ($(lanes))"
grep -q '^grok ' "$T/order" \
  && bad "2: the FIRST timeout descended to another vendor" || ok
grep -q 'class=transient(timeout)' "$T/logs/failovers.log" \
  && ok || bad "2: a timeout was not classified transient: $(tail -2 "$T/logs/failovers.log")"
grep -q 'not escalating models on a timeout' "$T/logs/failovers.log" \
  && ok || bad "2: the fable->opus escalation still ran on a timeout"
SID=$(sed -n '1s/.*--session-id \([0-9a-f-]*\).*/\1/p' "$T/order")
[ -n "$SID" ] && ok || bad "2: the first attempt minted no session id, so there is nothing to resume"
sed -n '2p' "$T/order" | grep -q -- "--resume $SID" \
  && ok || bad "2: the retry did not resume the timed-out session: $(sed -n '2p' "$T/order")"
grep -q -- '--session-id' <<<"$(sed -n '2p' "$T/order")" \
  && bad "2: the retry passed --session-id AND --resume (mutually exclusive)" || ok

# A CLI without --resume still retries — it just starts fresh.
cp "$T/fakebin/claude" "$T/claude-with-resume"
sed -i 's/  --resume <sessionId>\\n//' "$T/fakebin/claude"
RC=$(run_call claude-fable-5-1 env CLAUDE_MODE=timeout CLAUDE_FAIL_TIMES=1 GROK_RESULT=ok)
[ "$(count claude)" = 2 ] \
  && ok || bad "2: a CLI without --resume lost the retry entirely ($(lanes))"
grep -q -- '--resume' "$T/order" \
  && bad "2: --resume was passed to a CLI that does not advertise it" || ok
cp "$T/claude-with-resume" "$T/fakebin/claude"

# =============================================================================
# 3. EXHAUSTED / DE-AUTHED ACCOUNT -> ROTATE, DON'T DESCEND
# =============================================================================
two_accounts
# DEFAULT_CRED makes the box's own credentials detectable, i.e. the implicit
# `default` account account-pick.sh ranks last. It is the rotation's final stop.
DEFAULT_CRED="sk-ant-oat01-FIXTURE-do-not-ship"
# The wordings the pre-2026-09-16 regex missed are the ones the CLI actually
# prints: "session limit" and "weekly limit".
for TEXT in "Claude AI: you have hit your weekly limit" \
            "Approaching session limit reached for this account" \
            "Claude AI: out of usage credits"; do
  RC=$(run_call claude-opus-5 env ACCOUNT_ROUTING=1 CLAUDE_MODE=quota CLAUDE_QUOTA_TEXT="$TEXT" \
       CLAUDE_FAIL_TIMES=2 GROK_RESULT=ok CLAUDE_CODE_OAUTH_TOKEN="$DEFAULT_CRED")
  [ "$RC" = 0 ] && ok || bad "3: rotation did not recover the stage for '$TEXT' (rc=$RC)"
  [ "$(count claude)" = 3 ] \
    && ok || bad "3: expected b -> a -> default for '$TEXT', got $(count claude) attempts"
  [ "$(cut -d' ' -f2 "$T/order" | paste -sd,)" = "cfg=$T/.claude-b,cfg=$T/.claude-a,cfg=default" ] \
    && ok || bad "3: wrong rotation order for '$TEXT': $(cut -d' ' -f2 "$T/order" | paste -sd,)"
  [ -f "$T/state/quota/cooldown/claude/b" ] && [ -f "$T/state/quota/cooldown/claude/a" ] \
    && ok || bad "3: an exhausted account was not marked for the picker to skip ('$TEXT')"
  grep -q '^grok ' "$T/order" \
    && bad "3: the vendor ladder engaged while a Claude account still had headroom ('$TEXT')" || ok
  grep -q 'class=account-exhausted(quota)' "$T/logs/failovers.log" \
    && ok || bad "3: '$TEXT' was not classified account-exhausted"
done

# 401 is the same shape of answer: this account cannot serve, the next one can.
RC=$(run_call claude-opus-5 env ACCOUNT_ROUTING=1 CLAUDE_MODE=auth CLAUDE_FAIL_TIMES=1 GROK_RESULT=ok \
     CLAUDE_CODE_OAUTH_TOKEN="$DEFAULT_CRED")
[ "$RC" = 0 ] && ok || bad "3: an auth failure did not rotate to the next account (rc=$RC)"
grep -q 'class=auth(credential)' "$T/logs/failovers.log" \
  && ok || bad "3: a 401 was not classified auth: $(tail -2 "$T/logs/failovers.log")"
[ -f "$T/state/quota/cooldown/claude/b" ] \
  && ok || bad "3: the de-authed account was not marked for the picker to skip"
[ "$(count claude)" = 2 ] \
  && ok || bad "3: expected one rotation on a 401, got $(count claude) attempts"

# Every account exhausted -> the vendor really is out, and only then do we descend.
RC=$(run_call claude-opus-5 env ACCOUNT_ROUTING=1 CLAUDE_MODE=quota GROK_RESULT=ok \
     CLAUDE_CODE_OAUTH_TOKEN="$DEFAULT_CRED")
[ "$(lanes)" = "claude,claude,claude,grok" ] \
  && ok || bad "3: the ladder did not descend once every account was exhausted: $(lanes)"

# =============================================================================
# 4. A REAL FAILURE IS NOT RETRIED ANYWHERE
# =============================================================================
# The vendor answered and the answer failed. Retrying the same account buys the
# same answer; rotating accounts buys it on someone else's quota.
RC=$(run_call claude-opus-5 env ACCOUNT_ROUTING=1 CLAUDE_MODE=real GROK_RESULT=ok)
[ "$(count claude)" = 1 ] \
  && ok || bad "4: a genuine agent failure was retried $(count claude)x on claude"
[ "$(lanes)" = "claude,grok" ] \
  && ok || bad "4: expected one claude attempt then the next rung, got $(lanes)"
[ ! -e "$T/state/quota/cooldown/claude/b" ] \
  && [ "$(find "$T/state/quota/cooldown" -type f 2>/dev/null | grep -c '')" = 0 ] \
  && ok || bad "4: a genuine agent failure cooled a healthy account down"
grep -q 'class=real-failure(agent)' "$T/logs/failovers.log" \
  && ok || bad "4: a genuine agent failure was not classified real-failure"

# =============================================================================
# 5. THE DESCENT ORDER, AND THE GROK KNOB
# =============================================================================
rm -f "$T/env/accounts.d"/*.env
RC=$(run_call claude-opus-5 env CLAUDE_MODE=real GROK_RESULT=fail CODEX_RESULT=ok \
     RUNNER_EVAL_FALLBACK=codex CODEX_API_KEY=x)
[ "$(lanes)" = "claude,grok,codex" ] \
  && ok || bad "5: expected claude -> grok -> configured fallback, got $(lanes)"
RC=$(run_call claude-opus-5 env CLAUDE_MODE=real CODEX_RESULT=ok LADDER_TIER2_GROK=0 \
     RUNNER_EVAL_FALLBACK=codex CODEX_API_KEY=x)
[ "$(lanes)" = "claude,codex" ] \
  && ok || bad "5: LADDER_TIER2_GROK=0 did not remove the Grok rung: $(lanes)"

# =============================================================================
# 6. NOTHING BELOW THE OPENROUTER anthropic/ SLUG HAPPENS SILENTLY
# =============================================================================
# Fireworks and deepseek stay allowed — they are the one rung that survives
# Anthropic itself being the outage — but each of them says so.
# OPENROUTER_FALLBACK=always (2026-09-24): claude fails here for a non-account
# reason, and the default exhausted-only gate would skip OpenRouter by design
# (tests/agent-call-openrouter-gate-test.sh). This case pins what the rungs BELOW
# it say once they are reached.
RC=$(run_call claude-opus-5 env CLAUDE_MODE=real GROK_RESULT=fail CODEX_RESULT=fail \
     OPENROUTER_API_KEY=x FIREWORKS_API_KEY=x CODEX_API_KEY=x OPENROUTER_FALLBACK=always)
[ "$RC" != 0 ] && ok || bad "6: every lane failed but the stage reported success"
grep -q 'openrouter cfg=- args=-m anthropic/' "$T/order" \
  && ok || bad "6: the OpenRouter rung did not run the stage model: $(lanes)"
[ "$(grep -c 'LAST RESORT' "$T/logs/ALERTS.log")" = 3 ] \
  && ok || bad "6: expected one LAST RESORT line per rung below OpenRouter-anthropic, got $(grep -c 'LAST RESORT' "$T/logs/ALERTS.log")"
grep -q 'LAST RESORT: eval testproj fell to openrouter/deepseek/deepseek-v4-flash after real-failure' "$T/logs/ALERTS.log" \
  && ok || bad "6: the deepseek floor did not name the rung and the classes: $(grep 'LAST RESORT' "$T/logs/ALERTS.log" | head -1)"
grep -q 'LAST RESORT: eval testproj fell to fireworks after ' "$T/logs/ALERTS.log" \
  && ok || bad "6: the Fireworks descent wrote no lane alert"
grep -q 'LAST RESORT: eval testproj fell to fireworks/deepseek-v4-flash-0731 after ' "$T/logs/ALERTS.log" \
  && ok || bad "6: the Fireworks deepseek floor wrote no lane alert"
grep -q 'fireworks cfg=' "$T/order" \
  && ok || bad "6: Fireworks was never reached, so it cannot be the last resort: $(lanes)"

echo "ladder-recovery-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
