#!/bin/bash
# tests/agent-call-exhausted-lane-test.sh — what bin/agent-call.sh says, and
# refuses to buy, when the runner lane is out (2026-09-23 pool loop).
#
# Every pool plan that night ended on the same two facts: the leased Claude
# account had "hit your weekly limit", and the OpenRouter floor under it
# answered 403 "Key limit exceeded". The stage verdict could not say which
# runner ran out or when it came back, the 403 was classified as AUTH, the floor
# stayed "ready" and was bought again on every stage, its refusals wrote cost
# rows with a blank cost_usd (or none at all for the models before the last),
# and the one line the ladder logged for it said only "failed rc=1".
#
# DRIVEN, NOT GREPPED: agent-call.sh runs for real against a temp HARNESS with
# fake CLIs (the ladder-recovery-test.sh shape), and the verdict line, the
# failovers log and cost.csv are read back off disk.
#   1  a Claude weekly limit: the verdict carries exhausted=claude and the
#      reset the CLI printed, as resets_at=<epoch> (prose and pipe forms)
#   2  OpenRouter's 403 "Key limit exceeded" is account-exhausted(credits), not
#      auth; the verdict names exhausted=openrouter and NOT claude
#   3  one cost row per OpenRouter model tried, each a priced $0 with
#      refused:key_limit, and the vendor's text on the failovers line
#   4  runner_ready openrouter is false while the hub canary records the lane
#      DOWN, and while the key's own headroom is below the floor; true again
#      when the key has headroom
#
# The file anchors wall-clock time in $NOW; every fixture timestamp is derived
# from that one value so the suite does not flake on calendar drift.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" testproj
mkdir -p "$T/bin" "$T/bin/lib" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env/accounts.d"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
NOW=$(date -u +%s)
ORKEY="sk-or-v1-FIXTURE-not-a-real-key"

cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) printf -- '  --resume <sessionId>\n'; exit 0 ;; esac
echo "claude" >> "$ORDER_SINK"
case "${CLAUDE_MODE:-quota}" in
  quota) echo "${CLAUDE_QUOTA_TEXT:-You have hit your weekly limit}" >&2; exit 1 ;;
  real)  printf '{"result":"could not do it","usage":{"input_tokens":5,"output_tokens":1}}\n'; exit 1 ;;
esac
EOF
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
echo "grok" >> "$ORDER_SINK"; echo "grok is not configured" >&2; exit 1
EOF
# codex drives the OpenRouter lane: it refuses the way OpenRouter does for a key
# past its limit, and names the model it was asked for.
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
provider=codex; model=""; prev=""
for arg in "$@"; do
  case "$arg" in *model_provider*openrouter*) provider=openrouter ;; *model_provider*fireworks*) provider=fireworks ;; esac
  [ "$prev" = "-m" ] && model="$arg"; prev="$arg"
done
echo "$provider $model" >> "$ORDER_SINK"
echo 'ERROR: unexpected status 403 Forbidden: {"error":{"message":"Key limit exceeded (total limit). Manage it using https://openrouter.ai/settings/keys","code":403}}' >&2
exit 1
EOF
# The key-headroom probe: answers whatever $CURL_BODY holds and records the call.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$CURL_SINK"; printf '%s' "${CURL_BODY:-}"
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
# A refused call has no session and no usage: codex-usage finds nothing.
printf '#!/bin/bash\nexit 0\n' > "$T/bin/codex-usage.sh"
cp "$DIR/bin/account-pick.sh" "$T/bin/account-pick.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh

reset() { : > "$T/order"; : > "$T/curl-calls"; : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"
          rm -f "$T/logs/cost.csv" "$T/out.txt.class"; rm -rf "$T/state/quota"; }
run_call() {
  reset
  ( export ORDER_SINK="$T/order" CURL_SINK="$T/curl-calls" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           ACCOUNTS_DIR="$T/env/accounts.d" LADDER_BACKOFF_SECS=0 LADDER_TIER2_GROK=1 \
           RUNNER_EVAL=claude CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           OPENROUTER_FALLBACK=always
    # `always`: this suite pins what the OpenRouter lane DOES once it is reached;
    # WHEN it may be reached is tests/agent-call-openrouter-gate-test.sh.
    env -u ACCOUNT_ROUTING -u RUNNER_EVAL_FALLBACK -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY \
      -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u CODEX_API_KEY \
      "$@" bash "$DIR/bin/agent-call.sh" eval testproj claude-opus-5 600 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
}
verdict() { cat "$T/out.txt.class" 2>/dev/null; }
ran() { grep -c "^$1" "$T/order" 2>/dev/null || true; }

# ── 1. a Claude weekly limit names the runner and the reset ────────────────
EXP=$(TZ=UTC date -d "3am" +%s); [ "$EXP" -le "$NOW" ] && EXP=$((EXP + 86400))
run_call env CLAUDE_MODE=quota "CLAUDE_QUOTA_TEXT=You've hit your weekly limit · resets 3am (UTC)"
case "$(verdict)" in RUNNER_EXHAUSTED*) ok ;; *) bad "1: the verdict is not RUNNER_EXHAUSTED: $(verdict)" ;; esac
grep -q ' exhausted=claude\b' "$T/out.txt.class" 2>/dev/null && ok || bad "1: the verdict does not say claude ran out: $(verdict)"
grep -q " resets_at=$EXP\b" "$T/out.txt.class" 2>/dev/null && ok || bad "1: the verdict does not carry the CLI's reset ($EXP): $(verdict)"
RESET=$((NOW + 2*86400))
run_call env CLAUDE_MODE=quota "CLAUDE_QUOTA_TEXT=Claude AI usage limit reached|$RESET"
grep -q " resets_at=$RESET\b" "$T/out.txt.class" 2>/dev/null && ok || bad "1: the pipe-form reset was not carried: $(verdict)"
run_call env CLAUDE_MODE=quota "CLAUDE_QUOTA_TEXT=You have hit your weekly limit"
grep -q 'resets_at=' "$T/out.txt.class" 2>/dev/null && bad "1: a limit with no reset text invented one: $(verdict)" || ok

# ── 2 + 3. OpenRouter's key limit: credits, named, priced $0, explained ────
run_call env CLAUDE_MODE=real OPENROUTER_API_KEY="$ORKEY" CODEX_API_KEY=x \
  'CURL_BODY={"data":{"label":"fixture","limit":null,"limit_remaining":null}}'
[ "$(ran openrouter)" = 2 ] && ok || bad "2: expected both OpenRouter models tried, got $(ran openrouter) ($(tr '\n' ',' < "$T/order"))"
grep -q 'class=account-exhausted(credits)' "$T/out.txt.class" 2>/dev/null \
  && ok || bad "2: a 403 Key limit exceeded must classify as account-exhausted(credits): $(verdict)"
grep -q ' exhausted=openrouter\b' "$T/out.txt.class" 2>/dev/null && ok || bad "2: the verdict does not name openrouter: $(verdict)"
grep -q 'exhausted=[a-z,]*claude' "$T/out.txt.class" 2>/dev/null && bad "2: claude was named exhausted after a REAL failure: $(verdict)" || ok
# `note` is column 24; BH-2303 appended lane_id after it, so $NF is no longer the
# note. TEST-CHANGE: this read $NF.
ORROWS=$(awk -F, '$5 == "openrouter" { print $13 "|" $24 }' "$T/logs/cost.csv" 2>/dev/null)
[ "$(printf '%s\n' "$ORROWS" | grep -c .)" = 2 ] && ok \
  || bad "3: expected one cost row per OpenRouter model (2), got: $(printf '%s' "$ORROWS" | tr '\n' ';')"
[ "$(printf '%s\n' "$ORROWS" | grep -c '^0|.*refused:key_limit')" = 2 ] && ok \
  || bad "3: every refused row must be cost_usd 0 with refused:key_limit, got: $(printf '%s' "$ORROWS" | tr '\n' ';')"
grep -q 'openrouter: .* failed rc=1 — .*Key limit exceeded' "$T/logs/failovers.log" \
  && ok || bad "3: the failovers line does not carry the vendor's text: $(grep 'openrouter:' "$T/logs/failovers.log" | head -1)"

# ── 4. a lane known dead is not ready ──────────────────────────────────────
mkdir -p "$T/state/lane-down"
printf 'box=hub\nlane=openrouter\n' > "$T/state/lane-down/hub-openrouter"
run_call env CLAUDE_MODE=real OPENROUTER_API_KEY="$ORKEY" CODEX_API_KEY=x \
  'CURL_BODY={"data":{"limit_remaining":null}}'
[ "$(ran openrouter)" = 0 ] && ok || bad "4: the canary says hub-openrouter is DOWN and the lane was still bought"
rm -f "$T/state/lane-down/hub-openrouter"

rm -rf "$T/state/openrouter-headroom"
run_call env CLAUDE_MODE=real OPENROUTER_API_KEY="$ORKEY" CODEX_API_KEY=x \
  'CURL_BODY={"data":{"limit":50,"limit_remaining":0.02}}'
[ "$(ran openrouter)" = 0 ] && ok || bad "4: a key with \$0.02 of headroom was still bought"
grep -q 'openrouter.ai/api/v1/key' "$T/curl-calls" && ok || bad "4: the key's headroom was never asked"
grep -q "$ORKEY" "$T/curl-calls" && bad "4: the key travelled in curl's argv" || ok
ls "$T/state/openrouter-headroom/"* >/dev/null 2>&1 && ok || bad "4: the headroom reading was not cached"
# Cached: a second call inside the TTL does not ask again.
run_call env CLAUDE_MODE=real OPENROUTER_API_KEY="$ORKEY" CODEX_API_KEY=x \
  'CURL_BODY={"data":{"limit":50,"limit_remaining":40}}'
[ -s "$T/curl-calls" ] && bad "4: a cached reading inside the TTL asked the vendor again" || ok
[ "$(ran openrouter)" = 0 ] && ok || bad "4: the cached low-headroom reading was not honoured"
rm -rf "$T/state/openrouter-headroom"
run_call env CLAUDE_MODE=real OPENROUTER_API_KEY="$ORKEY" CODEX_API_KEY=x \
  'CURL_BODY={"data":{"limit":50,"limit_remaining":40}}'
[ "$(ran openrouter)" -ge 1 ] && ok || bad "4: a key with headroom was not bought"

echo "agent-call-exhausted-lane: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
