#!/bin/bash
# tests/cost-live-reap.bh-4750-test.sh — agent-call reaps its live cost meter
# (BH-4750): no fork of agent-call outlives the call.
#
# The meter spends most of a poll inside a $(...) (a transcript read, a push's
# curl), and each of those is a fork of agent-call carrying its command line.
# A TERM with no trap killed the meter and orphaned that fork, so it ran on
# after agent-call returned (cost-live C7's flake under load) and could land a
# live row after the final one.
#
#   R0 the call ended while the meter was inside its transcript read
#   R1 the call itself is unchanged: rc 0, $OUT is the result
#   R2 the instant agent-call returns, no process carries $OUT
#   R3 the in-flight read FINISHED before the return, it was not cut off
#   R4 a TERM during the meter's nap ends it at once: with COST_LIVE_POLL_S=30
#      the call still returns in well under 30 s
#
# Everything goes through the REAL bin/agent-call.sh with stub vendors; the
# curl is a shim answering for http://jobs.invalid. No network, no clock reads.
# Run from anywhere: tests/cost-live-reap.bh-4750-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/state" "$T/logs" "$T/locks" "$T/fakebin" "$T/bin/lib/jobs" "$T/.claude/projects/-work"
echo box-t > "$T/state/box-id"
cat > "$T/budgets.json" <<'EOF'
{"_units":"input_toks + cache_read","lanes":[
 {"lane":"free-lane","stage":"execute","project":"freeproj","ceiling_tokens":200000,
  "target_tokens":1000,"composition":[],"bounds":["[lane:none] none, by design PENDING"]}]}
EOF
# claude: STUB_WAIT_READ=1 waits (<= 10 s) until the meter is inside its slow
# transcript read and only then answers, so the call ends mid-$(...) every run.
# Otherwise it naps STUB_NAP and answers.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
sid=""; prev=""
for a in "$@"; do
  case "$prev" in --session-id|--resume) sid="$a" ;; esac
  prev="$a"
done
if [ "${STUB_WAIT_READ:-0}" = 1 ]; then
  n=200; while [ "$n" -gt 0 ] && [ ! -e "$T_DIR/reading" ]; do sleep 0.05; n=$((n-1)); done
else
  sleep "${STUB_NAP:-0}"
fi
printf '{"result":"CLEAN DONE","usage":{"input_tokens":50,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"session_id":"%s","total_cost_usd":0.01}\n' "$sid"
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '{}\n200'
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
# The jobs client the real agent-call sources from $HARNESS/bin: _jobs_req is
# real and its curl is the shim.
scratch_install_closure bin/jobs-client.sh "$T" >/dev/null || exit 1
chmod +x "$T/fakebin/"* "$T/bin/"*.sh

# The tree under test, with a transcript reader beside the lib (where the
# meter looks first). Armed by $T/slow-armed, its first call marks $T/reading,
# takes 3 s and marks $T/read.done; every other call answers at once.
# REAP_BIN=<base checkout>/bin runs the same cases on a base tree (red-first).
rm -rf "$T/tree"; mkdir -p "$T/tree"; cp -R "${REAP_BIN:-$DIR/bin}" "$T/tree/bin"
cat > "$T/tree/bin/transcript-cost.sh" <<EOF
#!/bin/bash
if [ -e "$T/slow-armed" ] && [ ! -e "$T/reading" ]; then
  touch "$T/reading"; sleep 3; touch "$T/read.done" # determinism: ok the slow read under test, not synchronisation: the claude stub waits on $T/reading
fi
echo '5000|10|0|0|0.05|claude-fable-5-1|1|1|'
EOF
chmod +x "$T/tree/bin/transcript-cost.sh"

OUT1="$T/builds/freeproj-BH-1-1/execute.out"
OUT2="$T/builds/freeproj-BH-1-2/execute.out"
cleanup() { pkill -f "$OUT1" 2>/dev/null; pkill -f "$OUT2" 2>/dev/null; }
trap cleanup EXIT

# ac <out> [VAR=VAL ...] -> rc; the real agent-call, stub vendors, live cost on
ac() {
  local o="$1"; shift
  mkdir -p "$(dirname "$o")"
  ( unset HARNESS_TEST_SANDBOX AGENT_CALL_TICKET AGENT_CALL_PR AGENT_CALL_FP JOB_ID COST_RUN_ID OUT KEY HARNESS_TICKET
    export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" T_DIR="$T" \
           CONTEXT_BUDGETS="$T/budgets.json" COST_TRANSCRIPT_ROWS=1 CALL_GUARD=0 \
           CLAUDE_CODE_OAUTH_TOKEN=tok ANTHROPIC_API_KEY= ACCOUNT_ROUTING=0 LADDER_TIER2_GROK=0 \
           LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 \
           LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 IRON_LAW_LANES=none \
           HARNESS_SECRET=x JOBS_URL=http://jobs.invalid COST_ROWS_PUSH_AT_BOUNDARY=0 COST_LIVE_PUSH_S=1 "$@"
    cd "$T" && bash "$T/tree/bin/agent-call.sh" execute freeproj claude-fable-5-1 60 "$o" "hi" >/dev/null 2>"$T/ac.err" )
  echo $?
}

# =============================================================================
# R0-R3 — the call ends while the meter is inside a $(...)
# =============================================================================
rm -f "$T/reading" "$T/read.done"; touch "$T/slow-armed"
R1=$(ac "$OUT1" COST_LIVE_POLL_S=1 STUB_WAIT_READ=1)
# No sleep: what is still running now outlived agent-call.
SURV=$(pgrep -af "$OUT1" | grep -v pgrep)
[ -e "$T/read.done" ]; DONE=$?
[ -e "$T/reading" ] && ok || bad "R0 the meter never entered its transcript read (the case proves nothing): $(head -c 400 "$T/ac.err")"
[ "$R1" = 0 ] && [ "$(cat "$OUT1" 2>/dev/null)" = "CLEAN DONE" ] && ok || bad "R1 rc=$R1 out='$(cat "$OUT1" 2>/dev/null)': $(head -c 400 "$T/ac.err")"
[ -z "$SURV" ] && ok || bad "R2 a fork of agent-call survived its return: $SURV"
[ "$DONE" = 0 ] && ok || bad "R3 the meter's in-flight read had not finished when agent-call returned"
cleanup

# =============================================================================
# R4 — a TERM during the nap ends the meter at once, not after COST_LIVE_POLL_S
# =============================================================================
rm -f "$T/slow-armed" "$T/reading" "$T/read.done"
SECONDS=0
R4=$(ac "$OUT2" COST_LIVE_POLL_S=30 STUB_NAP=1.5)
EL=$SECONDS
[ "$R4" = 0 ] && [ "$(cat "$OUT2" 2>/dev/null)" = "CLEAN DONE" ] && ok || bad "R4 rc=$R4 out='$(cat "$OUT2" 2>/dev/null)': $(head -c 400 "$T/ac.err")"
[ "$EL" -lt 15 ] && ok || bad "R4 agent-call took ${EL}s with COST_LIVE_POLL_S=30: the meter's nap held up its TERM"
SURV4=$(pgrep -af "$OUT2" | grep -v pgrep)
[ -z "$SURV4" ] && ok || bad "R4 a fork of agent-call survived its return: $SURV4"

echo "cost-live-reap.bh-4750-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
