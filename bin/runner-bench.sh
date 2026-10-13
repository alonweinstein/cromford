#!/bin/bash
# bin/runner-bench.sh — head-to-head runner benchmark (the operator, 2026-08-03):
# grok (xAI best) vs codex (best available) vs claude opus (not fable).
# Same prompts, three lanes; measures wall-time + cost (claude reports cost;
# codex is subscription-flat; grok priced from xAI token rates when reported).
# Tasks: a real coding task in a THROWAWAY worktree per runner (no shared
# state), a review of a real merged diff, and a triage-style thread read.
# Results append to /root/harness/logs/runner-bench.csv; artifacts kept under
# /root/harness/state/bench/<ts>/ for quality comparison by hand/Fable.
set -uo pipefail
HARNESS=/root/harness
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
TS=$(date -u +%Y%m%d%H%M)
B="$HARNESS/state/bench/$TS"; mkdir -p "$B"
CSV="$HARNESS/logs/runner-bench.csv"
[ -f "$CSV" ] || echo "ts,task,runner,model,rc,seconds,notes" > "$CSV"
set -a; . "$HENV/global.env" 2>/dev/null; set +a
# >>> model-route (BH-1510.2): the claude rung is model_routes role `bench`
# (BENCH_CLAUDE_MODEL still wins when set). No route = rc 75, alerted by
# bin/lib/model-route.sh, before any lane is timed; nothing is guessed.
. "$HARNESS/bin/lib/lane-model.sh"
BENCH_MODEL=$(lane_model BENCH_CLAUDE_MODEL bench) || { echo "no model route for role bench" >&2; exit 75; }
# <<< model-route

run() { # run <task> <runner> <model-env-hint> <timeout> <prompt>
  local task="$1" runner="$2" hint="$3" to="$4" prompt="$5"
  local out="$B/$task-$runner.out" t0 t1 rc
  t0=$(date +%s)
  # BH-2539: stage bench, so the gate answers stage-bench and no triage lane's
  # cap counts it; agent-call picks the runner from RUNNER_BENCH.
  RUNNER_BENCH="$runner" $([ -n "$hint" ] && echo "env $hint") \
    "$HARNESS/bin/agent-call.sh" bench bench \
    "$BENCH_MODEL" "$to" "$out" "$prompt" >/dev/null 2>&1
  rc=$?; t1=$(date +%s)
  echo "$(date -u +%FT%TZ),$task,$runner,$hint,$rc,$((t1-t0))," >> "$CSV"
  echo "$task/$runner: rc=$rc $((t1-t0))s out=$(wc -c < "$out" 2>/dev/null)B" >/dev/null
}
echo "bench dir: $B (invoke runs from the orchestrator with task prompts)"
