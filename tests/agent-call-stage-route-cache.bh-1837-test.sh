#!/bin/bash
# tests/agent-call-stage-route-cache.bh-1837-test.sh — the BH-1765 follow-ups in
# bin/agent-call.sh and bin/lib/model-route.sh (BH-1837), driven for real.
#
# Every agent-call reads its stage.<stage> route. Before this, a stage with no
# row paid a worker round trip on every call, and with the worker down each
# call could wait ~17 s (8 s timeout, one retry, 8 s again). Now the answer,
# the negative one included, is cached on the box for AGENT_CALL_STAGE_ROUTE_TTL_S
# and the wait is capped at AGENT_CALL_STAGE_ROUTE_TIMEOUT_S with no retry.
# And the warn-mode MODEL/RUNNER MISMATCH failovers line is once per
# (stage, runner, model) per UTC day instead of once per call.
#
# bin/agent-call.sh runs for real with stub CLIs that write their own name into
# a sink; the worker is tests/lib/model-route-stub.sh's fake curl, which logs
# every model-routes GET into $MRS_SINK.
#   S1  no route: 2 calls -> 1 GET, claude both times, .ans holds "-"
#   S2  grok route cached: route deleted inside TTL -> grok, 0 GETs; stale -> GET, claude
#   S3  worker hangs, timeout 1: < 10 s wall, ONE curl with -m 1, claude ran
#   S4  TTL 0: 2 calls -> 2 GETs, no .ans
#   S5  stage_runner_for's bounded wait does not leak JOBS_TIMEOUT/JOBS_RETRIES
#   S6  worker hangs, RUNNER_TRIAGE=codex -> codex ran
#   K1  the three knobs are registered on the agent-call lib, and compose
#   D1  warn: 2 calls -> 1 failovers line, 1 ALERTS line
#   D2  another project, same (stage, runner, model) -> still 1 failovers line
#   D3  another model -> 2
#   D4  a new day (flags gone) -> a line again
#   D5  refuse: 2 calls -> 2 failovers lines, rc 74 both
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/bin" "$T/fakebin" "$T/hangbin" "$T/routes"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mrs_install "$T/fakebin"
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$SINK"
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
# A worker that HANGS on model-routes: logs its -m and URL, sleeps the -m value it was
# given (what curl itself would wait) and exits 28 (curl's timeout). Every
# other URL is the stub's 404, so only the route read is slow.
cat > "$T/hangbin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/model-routes/*)
    m=""; prev=""
    for a in "$@"; do [ "$prev" = -m ] && m="$a"; prev="$a"; done
    # one line per invocation (argv itself carries a newline in -w)
    printf 'curl -m %s %s\n' "$m" "$URL" >> "$HANG_SINK"
    m="${m:-8}"
    sleep "$m"; exit 28 ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
chmod +x "$T/fakebin/"* "$T/hangbin/"* "$T/bin/"*

CLAUDE_M=claude-fable-5-1
CLAUDE_M2=claude-opus-5-5
GROK_M=grok-test-9
ANS="$T/state/model-routes/stage-runner/stage.triage@testproj.ans"

reset() {
  rm -rf "$T/routes" "$T/state/model-routes" "$T"/flags/* "$T/sink" "$T/gets" "$T/hang" "$T/out.txt" "$T/out.txt.err"
  mkdir -p "$T/routes"; : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"
}
ENVV=(PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid
      MRS_ROUTES="$T/routes" MRS_SINK="$T/gets" HANG_SINK="$T/hang" SINK="$T/sink"
      LADDER_BACKOFF_SECS=0 AGENT_CALL_LEDGER=0 GROK_MODEL="$GROK_M" CODEX_MODEL=codex-test-1 CODEX_API_KEY=x
      CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json")
# call <project> <model> [VAR=value...] — one real agent-call on stage triage; echoes rc.
call() {
  local p="$1" m="$2"; shift 2
  ( unset RUNNER_TRIAGE RUNNER_TRIAGE_FALLBACK AGENT_CALL_MODEL_MISMATCH AGENT_CALL_RUNNERS \
          AGENT_CALL_STAGE_ROUTE_TTL_S AGENT_CALL_STAGE_ROUTE_TIMEOUT_S OPENROUTER_API_KEY FIREWORKS_API_KEY \
          JOBS_TIMEOUT JOBS_RETRIES
    for kv in "${ENVV[@]}" "$@"; do export "${kv?}"; done
    bash "$DIR/bin/agent-call.sh" triage "$p" "$m" 60 "$T/out.txt" "hello" >/dev/null 2>&1 )
  echo $?
}
gets() { local n; n=$(grep -c '/api/model-routes/stage\.triage' "$T/gets" 2>/dev/null); echo "${n:-0}"; }
ran()  { grep -qx "$1" "$T/sink" 2>/dev/null; }
nran() { local n; n=$(grep -cx "$1" "$T/sink" 2>/dev/null); echo "${n:-0}"; }
mm_alerts()    { grep -c 'MODEL/RUNNER MISMATCH' "$T/logs/ALERTS.log" 2>/dev/null; }
mm_failovers() { grep -c 'MODEL/RUNNER MISMATCH' "$T/logs/failovers.log" 2>/dev/null; }

# ---- S1: no route — the negative answer is cached
reset
rc1=$(call testproj "$CLAUDE_M"); rc2=$(call testproj "$CLAUDE_M")
[ "$rc1" = 0 ] && [ "$rc2" = 0 ] && ok || bad "S1 rc=$rc1,$rc2, want 0,0"
[ "$(nran claude)" = 2 ] && ok || bad "S1 claude ran $(nran claude) time(s), want 2"
[ "$(gets)" = 1 ] && ok || bad "S1 want exactly 1 GET for stage.triage over 2 calls, got $(gets)"
[ "$(cat "$ANS" 2>/dev/null)" = "-" ] && ok || bad "S1 $ANS does not hold '-': '$(cat "$ANS" 2>/dev/null)'"

# ---- S2: a positive answer is cached, and goes stale after the TTL
reset
mrs_route "$T/routes" stage.triage "$GROK_M:grok"
call testproj "$GROK_M" >/dev/null
ran grok && ok || bad "S2 grok route: grok did not run, sink: $(paste -sd, "$T/sink" 2>/dev/null)"
g0=$(gets)
rm -f "$T/routes/stage.triage.json"; rm -f "$T/sink"
call testproj "$GROK_M" >/dev/null
ran grok && ok || bad "S2 inside the TTL the cached grok answer must serve, sink: $(paste -sd, "$T/sink" 2>/dev/null)"
[ "$(gets)" = "$g0" ] && ok || bad "S2 a cached answer still did a GET ($g0 -> $(gets))"
touch -d '-10 min' "$ANS" 2>/dev/null
rm -f "$T/sink"
call testproj "$GROK_M" >/dev/null
[ "$(gets)" = $((g0+1)) ] && ok || bad "S2 a stale answer must refetch once ($g0 -> $(gets))"
ran claude && ! ran grok && ok || bad "S2 after the refetch (no route) claude must run, sink: $(paste -sd, "$T/sink" 2>/dev/null)"

# ---- S3: the worker hangs — bounded wait, one attempt, env/claude fallback
reset
t0=$(date +%s)
rc1=$(call testproj "$CLAUDE_M" PATH="$T/hangbin:$T/fakebin:$PATH" AGENT_CALL_STAGE_ROUTE_TIMEOUT_S=1)
t1=$(date +%s)
[ $((t1-t0)) -lt 10 ] && ok || bad "S3 a hanging worker cost $((t1-t0)) s wall, want < 10"
[ "$rc1" = 0 ] && ran claude && ok || bad "S3 rc=$rc1 or claude did not run, sink: $(paste -sd, "$T/sink" 2>/dev/null)"
nh=$(wc -l < "$T/hang" 2>/dev/null | tr -d ' '); nh=${nh:-0}
[ "$nh" = 1 ] && ok || bad "S3 want ONE model-routes curl attempt (no retry), got $nh"
grep -q '^curl -m 1 .*/api/model-routes/stage\.triage' "$T/hang" 2>/dev/null && ok || bad "S3 the curl was not given -m 1: $(head -c 300 "$T/hang" 2>/dev/null)"
[ "$(cat "$ANS" 2>/dev/null)" = "-" ] && ok || bad "S3 a timeout with nothing cached must cache '-', got '$(cat "$ANS" 2>/dev/null)'"

# ---- S4: TTL 0 is no cache at all
reset
call testproj "$CLAUDE_M" AGENT_CALL_STAGE_ROUTE_TTL_S=0 >/dev/null
call testproj "$CLAUDE_M" AGENT_CALL_STAGE_ROUTE_TTL_S=0 >/dev/null
[ "$(gets)" = 2 ] && ok || bad "S4 TTL=0 want 2 GETs over 2 calls, got $(gets)"
[ ! -e "$ANS" ] && ok || bad "S4 TTL=0 wrote $ANS"

# ---- S5: the bounded wait is scoped to stage_runner_for
reset
out=$( unset JOBS_TIMEOUT JOBS_RETRIES
       for kv in "${ENVV[@]}"; do export "${kv?}"; done
       . "$DIR/bin/lib/model-route.sh" || exit 99
       stage_runner_for triage p 60 1 >/dev/null
       echo "$JOBS_TIMEOUT/$JOBS_RETRIES" )
[ "$out" = "8/1" ] && ok || bad "S5 after stage_runner_for JOBS_TIMEOUT/JOBS_RETRIES = '$out', want 8/1"
grep -q 'stage\.triage?project=p' "$T/gets" 2>/dev/null && ok || bad "S5 stage_runner_for triage p did not read the route"

# ---- S6: the worker hangs and an env runner is set — the env runner runs
reset
rc1=$(call testproj codex-test-1 PATH="$T/hangbin:$T/fakebin:$PATH" AGENT_CALL_STAGE_ROUTE_TIMEOUT_S=1 RUNNER_TRIAGE=codex)
[ "$rc1" = 0 ] && ran codex && ! ran claude && ok || bad "S6 rc=$rc1, want codex only, sink: $(paste -sd, "$T/sink" 2>/dev/null)"

# ---- K1: the knobs are registered where agent-call's rows are read from
LIB="$DIR/catalog/lanes.d/_lib.json"
jq -e '.libs[]|select(.id=="agent-call" and .file=="bin/agent-call.sh")|.knobs[]|select(.env=="AGENT_CALL_MODEL_MISMATCH" and .type=="string" and .default=="warn")' "$LIB" >/dev/null \
  && ok || bad "K1 AGENT_CALL_MODEL_MISMATCH (string, default warn) is not on the agent-call lib"
jq -e '.libs[]|select(.id=="agent-call")|.knobs[]|select(.env=="AGENT_CALL_STAGE_ROUTE_TTL_S" and .type=="int" and .default==120)' "$LIB" >/dev/null \
  && ok || bad "K1 AGENT_CALL_STAGE_ROUTE_TTL_S (int, 120) is not on the agent-call lib"
jq -e '.libs[]|select(.id=="agent-call")|.knobs[]|select(.env=="AGENT_CALL_STAGE_ROUTE_TIMEOUT_S" and .type=="int" and .default==3 and .max<=8)' "$LIB" >/dev/null \
  && ok || bad "K1 AGENT_CALL_STAGE_ROUTE_TIMEOUT_S (int, 3, max <= 8) is not on the agent-call lib"
COMPOSED="$T/lanes.json"
if HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$COMPOSED" >/dev/null 2>&1; then
  n=$(jq '[.libs[]|select(.id=="agent-call")|.knobs[]|select(.env|IN("AGENT_CALL_MODEL_MISMATCH","AGENT_CALL_STAGE_ROUTE_TTL_S","AGENT_CALL_STAGE_ROUTE_TIMEOUT_S"))]|length' "$COMPOSED")
  [ "$n" = 3 ] && ok || bad "K1 the composed lanes.json carries $n of the 3 knobs"
else
  bad "K1 bin/lanes-build.sh --to failed"
fi

# ---- D1..D4: warn — one failovers line per (stage, runner, model) per day
reset
call testproj "$CLAUDE_M" RUNNER_TRIAGE=grok >/dev/null
call testproj "$CLAUDE_M" RUNNER_TRIAGE=grok >/dev/null
[ "$(mm_failovers)" = 1 ] && ok || bad "D1 warn: want 1 failovers MISMATCH line for 2 calls, got $(mm_failovers)"
[ "$(mm_alerts)" = 1 ] && ok || bad "D1 warn: want 1 ALERTS MISMATCH line for 2 calls, got $(mm_alerts)"
ran grok && ok || bad "D1 warn: grok did not run"
call otherproj "$CLAUDE_M" RUNNER_TRIAGE=grok >/dev/null
[ "$(mm_failovers)" = 1 ] && ok || bad "D2 another project on the same (stage, runner, model): failovers went to $(mm_failovers), want 1"
[ "$(mm_alerts)" = 2 ] && ok || bad "D2 ALERTS stays per project: want 2, got $(mm_alerts)"
call testproj "$CLAUDE_M2" RUNNER_TRIAGE=grok >/dev/null
[ "$(mm_failovers)" = 2 ] && ok || bad "D3 another model must get its own line: want 2, got $(mm_failovers)"
rm -f "$T"/flags/noted-model-runner-mismatch-*
call testproj "$CLAUDE_M" RUNNER_TRIAGE=grok >/dev/null
[ "$(mm_failovers)" = 3 ] && ok || bad "D4 a new day (flags gone) must write a line again: want 3, got $(mm_failovers)"

# ---- D5: refuse still writes a line per refused call
reset
rc1=$(call testproj "$CLAUDE_M" RUNNER_TRIAGE=grok AGENT_CALL_MODEL_MISMATCH=refuse)
rc2=$(call testproj "$CLAUDE_M" RUNNER_TRIAGE=grok AGENT_CALL_MODEL_MISMATCH=refuse)
[ "$rc1" = 74 ] && [ "$rc2" = 74 ] && ok || bad "D5 refuse rc=$rc1,$rc2, want 74,74"
[ "$(mm_failovers)" = 2 ] && ok || bad "D5 refuse: want 2 failovers lines for 2 refused calls, got $(mm_failovers)"

echo "agent-call-stage-route-cache: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
