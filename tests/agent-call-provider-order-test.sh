#!/bin/bash
# Drives agent-call.sh against fake providers to pin the provider ladder:
# configured Claude attempts -> Grok tier-2 -> OpenRouter -> Fireworks.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1510.1: agent-call reads its ladders from model_routes; this worker-less box carries the resolver's cache of #1507's table.
# TEST-CHANGE (BH-1510.1): the argv model below was claude-fable-5, which no route
# names; the in-lane fable->opus rung is claude.ladder's now, starting at
# claude-fable-5-1, and a model the table does not know gets no guessed rung.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
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
case "${GROK_RESULT:-success}" in
  fail) echo "grok unavailable" >&2; exit 1 ;;
  kill) exit 137 ;;
esac
echo "grok answered"
EOF
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
provider=codex
web_search_disabled=0
for arg in "$@"; do
  case "$arg" in
    *model_provider*openrouter*) provider=openrouter ;;
    *model_provider*fireworks*) provider=fireworks ;;
    *web_search*disabled*) web_search_disabled=1 ;;
  esac
done
echo "$provider" >> "$ORDER_SINK"
[ "$provider" != fireworks ] || [ "$web_search_disabled" = 1 ] || {
  echo "Fireworks rejected mixed client/server tools" >&2
  exit 1
}
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

# AGENT_CALL_LEDGER=0 (BH-1037): every call below — here and in
# run_claude_only — ships the SAME prompt on the same stage and project, which
# is exactly the key the prompt ledger replays on. This suite's subject is the
# ladder's ORDER, so a second call that answers from the cache erases the thing
# it exists to pin. The opt-out is the spec change BH-1037 forces on it, not a
# weakened assertion.
run_call() { # run_call <grok-result: success|fail|kill>
  : > "$T/order"
  : > "$T/logs/ALERTS.log"
  : > "$T/logs/failovers.log"
  ( export ORDER_SINK="$T/order" GROK_RESULT="$1" PATH="$T/fakebin:$PATH" \
           HARNESS="$T" HOME="$T" OPENROUTER_API_KEY=test FIREWORKS_API_KEY=test \
           LADDER_BACKOFF_SECS=0 LADDER_TIER2_GROK=1 AGENT_CALL_LEDGER=0 \
           RUNNER_REVIEW=claude RUNNER_REVIEW_FALLBACK=openrouter \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    # Every case shares one HARNESS, and the `fail` case's instant grok rc 1
    # would arm the BH-3224 fast-fail cooldown for the `kill` case after it.
    # This suite pins the ladder's order, not the cooldown
    # (tests/runner-fastfail.bh-3224-test.sh does), so it runs with it off.
    export RUNNER_FASTFAIL_COOLDOWN_S=0
    bash "$DIR/bin/agent-call.sh" review testproj claude-fable-5-1 60 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}

# Claude exhausts its Fable -> Opus retry, then Grok answers. No paid survival
# provider is touched and the routine failover does not claim the stage stuck.
RC=$(run_call success)
[ "$RC" -eq 0 ] && ok || bad "Grok answered but the stage exited $RC"
[ "$(paste -sd, "$T/order")" = "claude,claude,grok" ] \
  && ok || bad "expected Claude -> Grok, got $(paste -sd, "$T/order")"
grep -qE 'openrouter|fireworks' "$T/order" \
  && bad "a provider after Grok was called even though Grok succeeded" || ok
grep -q 'STUCK' "$T/logs/ALERTS.log" \
  && bad "a successful Grok tier-2 failover emitted a false STUCK alert" || ok

# If Grok itself fails, OpenRouter is next. Fireworks must remain untouched
# because OpenRouter succeeded.
RC=$(run_call fail)
[ "$RC" -eq 0 ] && ok || bad "OpenRouter answered after Grok failed but the stage exited $RC"
[ "$(paste -sd, "$T/order")" = "claude,claude,grok,openrouter" ] \
  && ok || bad "expected Claude -> Grok -> OpenRouter, got $(paste -sd, "$T/order")"
grep -q '^fireworks$' "$T/order" \
  && bad "Fireworks ran before or alongside a successful OpenRouter attempt" || ok

# The Fireworks provider rejects Codex's client-executed tools when Codex also
# sends its default cached web-search tool. Pin the provider-specific override
# so a future Codex default change cannot silently take this survival lane down.
grep -A35 '^    fireworks)' "$DIR/bin/agent-call.sh" | grep -q 'web_search="disabled"' \
  && ok || bad "the Fireworks attempt did not disable Codex web search"
# The canary (bin/lane-probe.sh) runs no vendor CLI of its own since BH-2560:
# it probes through agent-call.sh, so its Fireworks call IS the arm pinned above.
# A raw `codex exec` back in lane-probe would bypass that pin.
if grep -qE '(^|[;&|( ])codex +exec' "$DIR/bin/lane-probe.sh"; then
  bad "the Fireworks canary runs codex exec directly, outside agent-call's web_search pin"
elif grep -qE '"\$AC" canary ' "$DIR/bin/lane-probe.sh"; then ok
else bad "the Fireworks canary does not go through agent-call.sh"; fi

# A killed Grok attempt is not a provider failure. It must stop the ladder,
# just as a killed primary does, and the alert must name the runner that was
# actually killed rather than blaming Claude.
RC=$(run_call kill)
[ "$RC" -ne 0 ] && ok || bad "a killed Grok attempt reported success"
[ "$(paste -sd, "$T/order")" = "claude,claude,grok" ] \
  && ok || bad "a killed Grok attempt reached a lower provider: $(paste -sd, "$T/order")"
grep -qi 'KILLED: grok was killed' "$T/logs/ALERTS.log" \
  && ok || bad "the kill alert did not name Grok: $(tail -1 "$T/logs/ALERTS.log")"

# ---------------------------------------------------------------------------
# A REVIEW-SIZED PROMPT MUST REACH THE SURVIVAL LANES AT ALL (2026-09-16,
# project-5 #1621). The codex-backed lanes passed the whole prompt as ONE argv
# element, and Linux caps a single argv element at MAX_ARG_STRLEN (32 pages =
# 131072 bytes). The merge conductor's head-bound re-review assembles ~136KB, so
# the entire recorded output of the read it bought for #1621 was 84 bytes:
#   /root/harness/bin/agent-call.sh: line 872: /usr/bin/timeout: Argument list too long
# — which the conductor read as "the reviewer had no verdict", parked the PR,
# and closed it to rebuild. This is DRIVEN rather than grepped precisely because
# the fake `timeout` below execs its arguments for real: on the old code the
# execve fails here exactly as it failed in production.
: > "$T/order"
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
prompt=""
for arg in "$@"; do
  case "$arg" in
    -) prompt=$(cat) ;;
    -c|-m|exec|--*) : ;;
    *) [ "${#arg}" -gt "${#prompt}" ] && prompt="$arg" ;;
  esac
done
printf '%s' "${#prompt}" > "$PROMPT_BYTES_SINK"
echo "openrouter answered"
EOF
chmod +x "$T/fakebin/codex"
# @file, the way bin/lib/merge-conductor-lib.sh and bin/review-prs.sh call it —
# a prompt this size cannot be an argv element of agent-call.sh EITHER, which is
# the same lesson one layer up (project-4 #1181/#1168).
yes x | head -200000 | tr -d '\n' > "$T/big.prompt"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" OPENROUTER_API_KEY=test          PROMPT_BYTES_SINK="$T/pbytes" RUNNER_REVIEW=openrouter          CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
  bash "$DIR/bin/agent-call.sh" review testproj claude-fable-5-1 60 "$T/big.txt" "@$T/big.prompt" ) >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok || bad "a 200KB prompt must still run on the openrouter lane (exit $RC) — this is the #1621 E2BIG"
[ "$(cat "$T/pbytes" 2>/dev/null || echo 0)" -ge 200000 ]   && ok || bad "the whole prompt must reach codex (got $(cat "$T/pbytes" 2>/dev/null) bytes) — over the argv ceiling it goes on stdin via '-'"
grep -qi "Argument list too long" "$T/big.txt" "$T/big.txt.err" 2>/dev/null   && bad "the lane still E2BIGs on a review-sized prompt" || ok
# And UNDER the ceiling nothing changed: argv, exactly as it has always been.
( export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" OPENROUTER_API_KEY=test          PROMPT_BYTES_SINK="$T/pbytes2" RUNNER_REVIEW=openrouter          CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
  bash "$DIR/bin/agent-call.sh" review testproj claude-fable-5-1 60 "$T/small.txt" "a short prompt" ) >/dev/null 2>&1
[ "$(cat "$T/pbytes2" 2>/dev/null || echo 0)" -ge 14 ]   && ok || bad "a short prompt must still reach the lane (got $(cat "$T/pbytes2" 2>/dev/null))"
# The judge-provenance markers: BOTH of them, from the lane that actually served
# (2026-09-16). The .model write used to live in the claude branch alone, so a
# fallback attempt inherited the claude attempt's model — project-5 #1624's grok
# review carried `claude-opus-5`.
[ "$(cat "$T/small.txt.runner" 2>/dev/null)" = openrouter ]   && ok || bad "the runner marker must name the lane that served (got $(cat "$T/small.txt.runner" 2>/dev/null))"
grep -q '^anthropic/claude-' "$T/small.txt.model" 2>/dev/null   && ok || bad "the model marker must name the anthropic/ slug this lane served with (got $(cat "$T/small.txt.model" 2>/dev/null))"
# ...which is what makes the pair read as a Claude read downstream.
( . "$DIR/bin/lib/review-provenance.sh"; rp_out_is_claude "$T/small.txt" ) && ok \
  || bad "runner=openrouter + an anthropic/ slug must read as a Claude review (bin/lib/review-provenance.sh)"

# ---------------------------------------------------------------------------
# AGENT_CALL_RUNNERS: THE CALLER NAMES THE LANES IT WILL ACCEPT (BH-1019).
# The ladder is right for a build stage — something must answer. It is wrong for
# a caller whose own gate then REFUSES what a lower rung produced: the merge
# conductor's head-bound re-review asks for a Claude read of a head and
# bin/lib/review-provenance.sh throws a grok/kimi verdict away on arrival, so
# cromford#818 bought five fallback reviews of one pull request and binned
# every one. With the intent passed, a claude outage descends nowhere and an
# absent claude is refused before a single token is bought.
# ---------------------------------------------------------------------------
# The E2BIG case above replaced the codex stub with one that records prompt
# BYTES and not the lane it served. Put the lane-recording stub back, or "no
# fallback ran" would be proved by a stub that never records anything.
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
chmod +x "$T/fakebin/codex"
run_claude_only() { # run_claude_only <PATH to run under>
  : > "$T/order"; : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"
  # The sidecars from the previous attempt go first, exactly as
  # bin/lib/merge-conductor-lib.sh clears them before every re-review: a marker
  # left by an earlier run would otherwise be read as this run's provenance.
  rm -f "$T/co.txt" "$T/co.txt.runner" "$T/co.txt.model"
  ( export ORDER_SINK="$T/order" GROK_RESULT=success PATH="$1" \
           HARNESS="$T" HOME="$T" OPENROUTER_API_KEY=test FIREWORKS_API_KEY=test \
           LADDER_BACKOFF_SECS=0 LADDER_TIER2_GROK=1 AGENT_CALL_RUNNERS=claude \
           AGENT_CALL_LEDGER=0 \
           RUNNER_REVIEW=claude RUNNER_REVIEW_FALLBACK=openrouter \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    bash "$DIR/bin/agent-call.sh" review testproj claude-fable-5-1 60 "$T/co.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}
# 1. Claude is installed and failing. Its own recovery runs; NOTHING below it does.
RC=$(run_claude_only "$T/fakebin:$PATH")
[ "$RC" -ne 0 ] && ok || bad "a claude-only call whose lane failed must fail (exit $RC)"
[ "$(paste -sd, "$T/order")" = "claude,claude" ] && ok \
  || bad "a claude-only call must reach no other vendor, got $(paste -sd, "$T/order")"
grep -qE 'grok|openrouter|fireworks' "$T/order" \
  && bad "AGENT_CALL_RUNNERS=claude still bought a fallback lane: $(paste -sd, "$T/order")" || ok

# 2. Claude is not available at all. A PATH mirror of everything EXCEPT the
#    claude binary, so the absence is a fact of the run rather than a mock of
#    runner_ready: rc 2, the refusal marker, and an empty order sink.
mkdir -p "$T/noclaude"
IFS=: read -r -a PDIRS <<<"$T/fakebin:$PATH"
for D in "${PDIRS[@]}"; do
  [ -d "$D" ] || continue
  for F in "$D"/*; do
    B=${F##*/}
    [ "$B" = claude ] && continue
    [ -e "$T/noclaude/$B" ] || ln -s "$F" "$T/noclaude/$B" 2>/dev/null
  done
done
[ -z "$(PATH="$T/noclaude" command -v claude 2>/dev/null)" ] && ok \
  || bad "the noclaude PATH still resolves a claude binary — this case would prove nothing"
RC=$(run_claude_only "$T/noclaude")
[ "$RC" -eq 2 ] && ok || bad "claude-only with no claude lane must refuse with rc 2 (got $RC)"
[ ! -s "$T/order" ] && ok || bad "a refused claude-only call must invoke NO runner: $(paste -sd, "$T/order")"
grep -q '^AGENT_CALL_REFUSED runners-restricted' "$T/co.txt" && ok \
  || bad "the refusal must name itself in the out file, which is what the caller's lane-failure check reads (got $(head -1 "$T/co.txt"))"
[ -f "$T/co.txt.runner" ] && bad "a call that ran no lane must write no runner marker" || ok
# ...and the refusal is the caller's, not a new default: unset, the ladder is
# exactly what the four cases above pinned.
( . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  grep -q 'AGENT_CALL_RUNNERS=' <<<"$(declare -f mc_rereview)" ) && ok \
  || bad "the merge conductor's head-bound re-review must be the caller that asks for the claude-only lane"

echo "agent-call-provider-order-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
