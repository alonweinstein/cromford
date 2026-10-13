#!/bin/bash
# tests/runner-routes.bh-1765-test.sh — the per-stage runner comes from the
# stage.<stage> model route (BH-1765, part of #1749), driven for real.
#
# bin/lib/model-route.sh's stage_runner_for reads the route through the same
# client and box cache as every other role, against the fake worker in
# tests/lib/model-route-stub.sh; bin/agent-call.sh is run for real with stub
# CLIs that write their own name into a sink.
#   R1   route grok, no env: grok runs; stage_runner_for prints "grok\t"
#   R1b  a two-rung route prints "grok\tcodex"
#   R2   RUNNER_TRIAGE=claude beats a grok route; one ALERTS line per day
#   R3   no route, no env: claude runs, one failovers.log note per day
#   R4   no route: stage_runner_for rc 75, empty, no ALERTS line, no flag
#   R5   worker down, empty cache: rc 75, still no ALERTS line
#   R6   RUNNER_TRIAGE_FALLBACK=claude beats the route's rung 1 (codex)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/bin" "$T/fakebin" "$T/routes"
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
[ -f "$SINK.grok-fails" ] && { echo "grok unavailable" >&2; exit 1; }
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

GROK_M=grok-test-9
CODEX_M=codex-test-1

reset() {
  # state/runner-fastfail (BH-3224) is per-box memory like flags/: a case whose
  # grok fails at once would otherwise cool grok for the case after it.
  rm -rf "$T/routes" "$T/state/model-routes" "$T/state/runner-fastfail" "$T"/flags/* "$T/sink" "$T/sink.grok-fails" "$T/out.txt"
  mkdir -p "$T/routes"; : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"
}
ENVV=(PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid
      MRS_ROUTES="$T/routes" SINK="$T/sink" LADDER_BACKOFF_SECS=0 AGENT_CALL_LEDGER=0
      GROK_MODEL="$GROK_M" CODEX_MODEL="$CODEX_M" CODEX_API_KEY=x
      CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json")
# call <model> [VAR=value...] — one real agent-call, triage/testproj; echoes rc.
call() {
  local m="$1"; shift
  ( unset RUNNER_TRIAGE RUNNER_TRIAGE_FALLBACK AGENT_CALL_MODEL_MISMATCH AGENT_CALL_RUNNERS OPENROUTER_API_KEY FIREWORKS_API_KEY
    for kv in "${ENVV[@]}" "$@"; do export "${kv?}"; done
    bash "$DIR/bin/agent-call.sh" triage testproj "$m" 60 "$T/out.txt" "hello" >/dev/null 2>&1 )
  echo $?
}
# srf [VAR=value...] -- <args> — stage_runner_for in a subshell; stdout then "rc=N"
srf() {
  ( unset RUNNER_TRIAGE
    while [ "$1" != -- ]; do export "${1?}"; shift; done; shift
    for kv in "${ENVV[@]}"; do export "${kv?}"; done
    . "$DIR/bin/lib/model-route.sh" || exit 99
    stage_runner_for "$@"; echo "rc=$?" )
}
ran() { grep -qx "$1" "$T/sink" 2>/dev/null; }

# ---- R1: the route names grok, nothing in env
reset
mrs_route "$T/routes" stage.triage "$GROK_M:grok"
out=$(srf -- triage testproj)
[ "$out" = "$(printf 'grok\t\nrc=0')" ] && ok || bad "R1 stage_runner_for printed '$out', want 'grok<TAB>' rc 0"
rc=$(call "$GROK_M")
[ "$rc" = 0 ] && ran grok && ! ran claude && ok || bad "R1 route grok: rc=$rc sink: $(paste -sd, "$T/sink" 2>/dev/null)"

# ---- R1b: two rungs
reset
mrs_route "$T/routes" stage.triage "$GROK_M:grok" "$CODEX_M:codex"
out=$(srf -- triage)
[ "$out" = "$(printf 'grok\tcodex\nrc=0')" ] && ok || bad "R1b stage_runner_for printed '$out', want 'grok<TAB>codex' rc 0"

# ---- R2: env beats the route, and the disagreement is alerted once a day
reset
mrs_route "$T/routes" stage.triage "$GROK_M:grok"
rc1=$(call claude-fable-5-1 RUNNER_TRIAGE=claude)
rc2=$(call claude-fable-5-1 RUNNER_TRIAGE=claude)
[ "$rc1" = 0 ] && [ "$rc2" = 0 ] && ran claude && ! ran grok && ok \
  || bad "R2 env claude over route grok: rc=$rc1,$rc2 sink: $(paste -sd, "$T/sink" 2>/dev/null)"
n=$(grep -c 'RUNNER_TRIAGE env=claude overrides route stage.triage=grok' "$T/logs/ALERTS.log")
[ "$n" = 1 ] && ok || bad "R2 want 1 override ALERTS line after 2 calls, got $n: $(cat "$T/logs/ALERTS.log")"
# env agreeing with the route is no disagreement
reset
mrs_route "$T/routes" stage.triage "$GROK_M:grok"
call "$GROK_M" RUNNER_TRIAGE=grok >/dev/null
grep -q 'overrides route' "$T/logs/ALERTS.log" && bad "R2 env == route still alerted" || ok

# ---- R3: no route, no env -> claude, and a once-a-day note
reset
rc1=$(call claude-fable-5-1)
rc2=$(call claude-fable-5-1)
[ "$rc1" = 0 ] && ran claude && ! ran grok && ok || bad "R3 no route: rc=$rc1 sink: $(paste -sd, "$T/sink" 2>/dev/null)"
n=$(grep -c 'triage/testproj: no stage.triage route and no RUNNER_TRIAGE — running claude' "$T/logs/failovers.log")
[ "$n" = 1 ] && ok || bad "R3 want 1 no-route note in failovers.log after 2 calls, got $n"
grep -q 'stage\.triage' "$T/logs/ALERTS.log" && bad "R3 a missing stage route wrote ALERTS: $(grep 'stage\.triage' "$T/logs/ALERTS.log")" || ok

# ---- R4: stage_runner_for with no route never alerts
reset
out=$(srf -- triage testproj)
[ "$out" = "rc=75" ] && ok || bad "R4 no route: got '$out', want empty stdout and rc 75"
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "R4 stage_runner_for wrote ALERTS: $(cat "$T/logs/ALERTS.log")"
ls "$T"/flags/alerted-model-route-* >/dev/null 2>&1 && bad "R4 stage_runner_for set an alerted-model-route flag" || ok

# ---- R5: worker down and nothing cached -> fail open, still quiet
reset
out=$(srf MRS_MODE=down -- triage testproj)
[ "$out" = "rc=75" ] && ok || bad "R5 worker down: got '$out', want rc 75"
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "R5 stage_runner_for wrote ALERTS with the worker down: $(cat "$T/logs/ALERTS.log")"
# and agent-call behaves as today: claude
rc=$(call claude-fable-5-1 MRS_MODE=down)
[ "$rc" = 0 ] && ran claude && ok || bad "R5 worker down: agent-call rc=$rc sink: $(paste -sd, "$T/sink" 2>/dev/null)"

# ---- R6: env fallback beats the route's rung 1
reset
mrs_route "$T/routes" stage.triage "$GROK_M:grok" "$CODEX_M:codex"
touch "$T/sink.grok-fails"
rc=$(call "$GROK_M" RUNNER_TRIAGE_FALLBACK=claude)
ran grok && ran claude && ! ran codex && ok \
  || bad "R6 want grok then claude (env fallback), never codex; rc=$rc sink: $(paste -sd, "$T/sink" 2>/dev/null)"
# and without the env fallback the route's rung 1 is the fallback
reset
mrs_route "$T/routes" stage.triage "$GROK_M:grok" "$CODEX_M:codex"
touch "$T/sink.grok-fails"
rc=$(call "$GROK_M")
ran grok && ran codex && ok || bad "R6 route rung 1 (codex) was not the fallback; rc=$rc sink: $(paste -sd, "$T/sink" 2>/dev/null)"

echo "runner-routes: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
