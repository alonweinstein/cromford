#!/bin/bash
# tests/agent-call-model-mismatch.bh-1765-test.sh — the model/runner mismatch
# check in bin/agent-call.sh (BH-1765, part of #1749), driven for real.
#
# THE BUG. A caller asks for a claude-family model, but RUNNER_<STAGE>=grok
# sends the call to grok, and grok runs its own route model. Nothing said so.
# Now agent-call compares the family of the argv model with the primary runner,
# right after runner selection, and writes an ALERTS line (once per day per
# stage/project/runner/model) plus a failovers.log line: per refused call, or
# once per day per stage/runner/model under warn (BH-1837). With
# AGENT_CALL_MODEL_MISMATCH=refuse the call stops there, rc 74, before any rung.
#
# Every assertion is on an artifact: the rc, $OUT, logs/ALERTS.log,
# logs/failovers.log and the sink the stub CLIs write their own name into.
#   M1  refuse: rc 74, grok never runs, $OUT marker, one ALERTS line for 2 calls
#   M2  warn (mode unset): rc 0, grok runs, one ALERTS and one failovers line for 2 calls
#   M3  claude model on claude: no mismatch
#   M4  grok model on grok: no mismatch
#   M5  unknown-family model on grok: no mismatch
#   M6  grok as a FALLBACK after a failed claude primary: no mismatch
#   M7  the named block exists and holds the exit 74
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/bin" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$SINK"
[ -f "$SINK.claude-fails" ] && { echo "API Error: 500 upstream" >&2; exit 1; }
printf '{"result":"claude answered","usage":{"input_tokens":5,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"session_id":"s1","total_cost_usd":0.01}\n'
EOF
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
echo grok >> "$SINK"
echo "grok answered"
EOF
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
echo codex >> "$SINK"
echo "codex answered"
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
chmod +x "$T/fakebin/"* "$T/bin/"*

CLAUDE_M=claude-fable-5-1
GROK_M=grok-test-9

reset() { rm -f "$T/sink" "$T/sink.claude-fails" "$T/out.txt" "$T/out.txt.err" "$T"/flags/*; : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"; }
# call <model> [VAR=value...] — one real agent-call, triage/testproj; echoes rc.
call() {
  local m="$1"; shift
  ( unset RUNNER_TRIAGE RUNNER_TRIAGE_FALLBACK AGENT_CALL_MODEL_MISMATCH HARNESS_SECRET JOBS_URL AGENT_CALL_RUNNERS
    export SINK="$T/sink" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           LADDER_BACKOFF_SECS=0 AGENT_CALL_LEDGER=0 GROK_MODEL="$GROK_M" CODEX_MODEL=codex-test-1 \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    for kv in "$@"; do export "${kv?}"; done
    bash "$DIR/bin/agent-call.sh" triage testproj "$m" 60 "$T/out.txt" "hello" >/dev/null 2>&1 )
  echo $?
}
mm_alerts()    { grep -c 'MODEL/RUNNER MISMATCH' "$T/logs/ALERTS.log" 2>/dev/null; }
mm_failovers() { grep -c 'MODEL/RUNNER MISMATCH' "$T/logs/failovers.log" 2>/dev/null; }
ran() { grep -qx "$1" "$T/sink" 2>/dev/null; }

# ---- M1: refuse
reset
rc1=$(call "$CLAUDE_M" RUNNER_TRIAGE=grok AGENT_CALL_MODEL_MISMATCH=refuse)
rc2=$(call "$CLAUDE_M" RUNNER_TRIAGE=grok AGENT_CALL_MODEL_MISMATCH=refuse)
[ "$rc1" = 74 ] && [ "$rc2" = 74 ] && ok || bad "M1 refuse rc=$rc1,$rc2, want 74,74"
ran grok && bad "M1 grok ran under refuse" || ok
ran claude && bad "M1 claude ran under refuse" || ok
head -n1 "$T/out.txt" 2>/dev/null | grep -q '^AGENT_CALL_REFUSED model-runner-mismatch' && ok \
  || bad "M1 \$OUT does not start with the refusal marker: $(head -c 200 "$T/out.txt" 2>/dev/null)"
[ "$(mm_alerts)" = 1 ] && ok || bad "M1 want 1 MISMATCH line in ALERTS after 2 calls, got $(mm_alerts)"
grep 'MODEL/RUNNER MISMATCH' "$T/logs/ALERTS.log" | grep -q "triage/testproj asked for $CLAUDE_M but RUNNER_TRIAGE=grok would run $GROK_M" && ok \
  || bad "M1 ALERTS line does not name stage/project/model/runner/rung model: $(cat "$T/logs/ALERTS.log")"
[ "$(mm_failovers)" -ge 2 ] && ok || bad "M1 want a failovers MISMATCH line per call, got $(mm_failovers)"

# ---- M2: warn is the default (mode unset)
reset
rc1=$(call "$CLAUDE_M" RUNNER_TRIAGE=grok)
rc2=$(call "$CLAUDE_M" RUNNER_TRIAGE=grok)
[ "$rc1" = 0 ] && [ "$rc2" = 0 ] && ok || bad "M2 warn rc=$rc1,$rc2, want 0,0"
ran grok && ok || bad "M2 grok did not run under warn"
[ "$(mm_alerts)" = 1 ] && ok || bad "M2 want 1 MISMATCH line in ALERTS after 2 calls, got $(mm_alerts)"
# BH-1837 changed this from "a line per call": warn dedupes per (stage, runner, model) per day.
[ "$(mm_failovers)" = 1 ] && ok || bad "M2 want 1 failovers MISMATCH line for 2 same-day warn calls, got $(mm_failovers)"
# an unrecognised mode is warn, never refuse
reset
rc1=$(call "$CLAUDE_M" RUNNER_TRIAGE=grok AGENT_CALL_MODEL_MISMATCH=bogus)
[ "$rc1" = 0 ] && ran grok && ok || bad "M2 unknown mode 'bogus' did not behave as warn (rc=$rc1)"

# ---- M3: claude model on claude
reset
rc1=$(call "$CLAUDE_M")
[ "$rc1" = 0 ] && ran claude && ok || bad "M3 claude-on-claude rc=$rc1 or claude did not run"
[ "$(mm_alerts)" = 0 ] && [ "$(mm_failovers)" = 0 ] && ok || bad "M3 claude-on-claude raised a mismatch"

# ---- M4: grok model on grok
reset
rc1=$(call "$GROK_M" RUNNER_TRIAGE=grok AGENT_CALL_MODEL_MISMATCH=refuse)
[ "$rc1" = 0 ] && ran grok && ok || bad "M4 grok-on-grok rc=$rc1 or grok did not run"
[ "$(mm_alerts)" = 0 ] && [ "$(mm_failovers)" = 0 ] && ok || bad "M4 grok-on-grok raised a mismatch"

# ---- M5: an unknown-family model on grok
reset
rc1=$(call kimi-k3 RUNNER_TRIAGE=grok AGENT_CALL_MODEL_MISMATCH=refuse)
[ "$rc1" = 0 ] && ran grok && ok || bad "M5 kimi-on-grok rc=$rc1 or grok did not run"
[ "$(mm_alerts)" = 0 ] && [ "$(mm_failovers)" = 0 ] && ok || bad "M5 unknown family raised a mismatch"
# and a bare alias like `opus` is unknown too
reset
rc1=$(call opus RUNNER_TRIAGE=grok AGENT_CALL_MODEL_MISMATCH=refuse)
[ "$rc1" != 74 ] && [ "$(mm_alerts)" = 0 ] && ok || bad "M5 'opus' on grok was judged a mismatch (rc=$rc1)"

# ---- M6: grok as the fallback of a failed claude primary
reset
touch "$T/sink.claude-fails"
rc1=$(call "$CLAUDE_M" RUNNER_TRIAGE_FALLBACK=grok AGENT_CALL_MODEL_MISMATCH=refuse)
ran claude && ran grok && ok || bad "M6 want claude then grok fallback, sink: $(paste -sd, "$T/sink" 2>/dev/null) rc=$rc1"
[ "$(mm_alerts)" = 0 ] && [ "$(mm_failovers)" = 0 ] && ok || bad "M6 a fallback rung raised a mismatch"
# AGENT_CALL_RUNNERS=claude narrows RUNNER_TRIAGE=grok to claude: no mismatch
reset
rc1=$(call "$CLAUDE_M" RUNNER_TRIAGE=grok AGENT_CALL_RUNNERS=claude AGENT_CALL_MODEL_MISMATCH=refuse)
[ "$rc1" = 0 ] && ran claude && ! ran grok && ok || bad "M6 AGENT_CALL_RUNNERS=claude rc=$rc1 sink: $(paste -sd, "$T/sink" 2>/dev/null)"
[ "$(mm_alerts)" = 0 ] && ok || bad "M6 a runner narrowed to claude raised a mismatch"

# ---- M7: the named block
blk=$(sed -n '/# >>> model-runner-match/,/# <<< model-runner-match/p' "$DIR/bin/agent-call.sh")
[ -n "$blk" ] && ok || bad "M7 no '# >>> model-runner-match' block in bin/agent-call.sh"
grep -q 'exit 74' <<<"$blk" && ok || bad "M7 the model-runner-match block has no 'exit 74'"

echo "agent-call-model-mismatch: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
