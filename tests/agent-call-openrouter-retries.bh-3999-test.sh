#!/bin/bash
# tests/agent-call-openrouter-retries.bh-3999-test.sh — the OpenRouter rung runs
# codex with its own stream/request retries OFF (BH-3999, split child of
# BH-3983).
#
# codex's `Reconnecting... n/5` loop re-sends requests OpenRouter bills, and only
# the last one lands in codex's session ledger, so only that one gets a cost row
# (four 2026-09-16 plan-run.txt.err files on the hub show the loop). With
# retries at 0 a dropped stream fails the rung, the ladder decides what to do
# next, and every try is its own row. Driven through bin/agent-call.sh:
#   R1  one openrouter call: codex's argv carries both retries=0 overrides
#   R2  first model fails, floor answers: two rows with their own tokens, and
#       both codex invocations carried both overrides
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" testproj
mkdir -p "$T/bin" "$T/bin/lib" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/fakebin/codex" <<EOF
#!/bin/bash
m=""; prev=""
for a in "\$@"; do [ "\$prev" = -m ] && m="\$a"; prev="\$a"; done
{ printf '%s ' "\$@" | tr '\n' ' '; echo; } >> "$T/argv.log"  # one line per invocation
echo "session id: 00000000-0000-0000-0000-00000000000c" >&2
[ -n "\${CODEX_FAIL_MODEL:-}" ] && [ "\$m" = "\$CODEX_FAIL_MODEL" ] && { echo "upstream error" >&2; exit 1; }
echo "openrouter answered"; exit 0
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho "1200 300 0 0"\n' > "$T/bin/codex-usage.sh"
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
cat > "$T/prices.json" <<'EOF'
{"per_token": {
  "anthropic/claude-opus-5": {"prompt": 0.000005, "completion": 0.000025,
                              "cache_read": 5e-7, "cache_write": 0.00000625},
  "deepseek/deepseek-v4-flash": {"prompt": 1e-7, "completion": 4e-7,
                                 "cache_read": 1e-8, "cache_write": null}
}}
EOF

run_call() {
  rm -f "$T/argv.log" "$T/logs/cost.csv"
  ( exec env -u ACCOUNT_ROUTING -u RUNNER_EVAL_FALLBACK -u FIREWORKS_API_KEY -u XAI_API_KEY \
      -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u CODEX_API_KEY -u OPENAI_API_KEY \
      -u CODEX_FAIL_MODEL \
      PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" LADDER_BACKOFF_SECS=0 \
      MODEL_PRICES="$T/prices.json" CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
      RUNNER_EVAL=openrouter AGENT_CALL_RUNNERS=openrouter OPENROUTER_API_KEY=sk-or-test \
      OPENROUTER_FALLBACK=always "$@" \
      bash "$DIR/bin/agent-call.sh" eval testproj claude-opus-5 600 "$T/out.txt" hello >/dev/null 2>&1 )
}
nrows() { if [ -s "$T/logs/cost.csv" ]; then tail -n +2 "$T/logs/cost.csv" | grep -c . ; else echo 0; fi; }
c() {
  awk -F, -v r="$1" -v name="$2" 'NR==1{for(i=1;i<=NF;i++) if($i==name) k=i; next}
    NR==r+1{print $k}' "$T/logs/cost.csv" 2>/dev/null
}
both_flags() { # both_flags <argv line>
  case "$1" in *"model_providers.openrouter.stream_max_retries=0"*) ;; *) return 1 ;; esac
  case "$1" in *"model_providers.openrouter.request_max_retries=0"*) ;; *) return 1 ;; esac
}

# R1 — one normal call
run_call; rc=$?
[ "$rc" = 0 ] && ok || bad "R1: agent-call exit $rc"
[ "$(grep -c . "$T/argv.log" 2>/dev/null)" = 1 ] && ok || bad "R1: codex ran $(grep -c . "$T/argv.log" 2>/dev/null) times, want 1"
both_flags "$(sed -n 1p "$T/argv.log" 2>/dev/null)" && ok \
  || bad "R1: codex argv lacks a retries=0 override: $(sed -n 1p "$T/argv.log" 2>/dev/null)"

# R2 — first model fails, floor answers: every try has its own row
run_call CODEX_FAIL_MODEL=anthropic/claude-opus-5; rc=$?
[ "$rc" = 0 ] && ok || bad "R2: agent-call exit $rc"
[ "$(nrows)" = 2 ] && ok || bad "R2: $(nrows) cost rows, want 2"
[ "$(c 1 rc)" = 1 ] && [ "$(c 1 input_toks)" = 1200 ] && [ "$(c 1 output_toks)" = 300 ] && ok \
  || bad "R2: row 1 rc '$(c 1 rc)' in '$(c 1 input_toks)' out '$(c 1 output_toks)', want 1/1200/300"
[ "$(c 2 rc)" = 0 ] && [ "$(c 2 input_toks)" = 1200 ] && [ "$(c 2 output_toks)" = 300 ] && ok \
  || bad "R2: row 2 rc '$(c 2 rc)' in '$(c 2 input_toks)' out '$(c 2 output_toks)', want 0/1200/300"
[ "$(grep -c . "$T/argv.log" 2>/dev/null)" = 2 ] && ok || bad "R2: codex ran $(grep -c . "$T/argv.log" 2>/dev/null) times, want 2"
n=0; while IFS= read -r line; do both_flags "$line" && n=$((n+1)); done < "$T/argv.log"
[ "$n" = 2 ] && ok || bad "R2: $n of the codex invocations carried both retries=0 overrides, want 2"

echo "agent-call-openrouter-retries: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
