#!/bin/bash
# tests/cost-attribution.bh-2539-test.sh — BH-2539. Two operator scripts billed
# their model calls to somebody else's cost row:
#   bin/cost-readout.sh  a FLEET read-out, billed as review/project-1, so it
#                        landed in project-1's review spend;
#   bin/runner-bench.sh  billed as triage/bench, which bin/lib/llm-gate.sh
#                        resolves to run-triage, so bench spend counted against
#                        run-triage's LLM_USD_CAP_DAY.
# They now bill readout/fleet (lane cost-rollup) and bench/bench (the gate's
# synthetic stage-bench). This drives the REAL scripts against a stub
# agent-call and asserts the argv it received, then drives the real gate.
#
#   A  bin/cost-readout.sh end to end in a sandbox HARNESS (since BH-2550 it
#      makes no model call at all, so the assertion is that none happens)
#   B  run() from bin/runner-bench.sh, with and without an env hint
#   C  llm_gate_lane_id against a registry rendered from catalog/lanes.d
#
#   bash tests/cost-attribution.bh-2539-test.sh          exit 0 = pass
# As root next to a live harness: HARNESS_TEST_SANDBOX=1 bash tests/…
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The stub agent-call: records argv, the lane/role/runner env it was handed,
# and writes a non-empty answer to its outfile ($5), like a real call.
mkstub() { # mkstub <harness-root>
  mkdir -p "$1/bin/lib"
  cat > "$1/bin/agent-call.sh" <<EOF
#!/bin/bash
{ echo "ARGV \${1:-} \${2:-} \${3:-} \${4:-}"
  echo "LANE=\${AGENT_CALL_LANE-<unset>}"
  echo "ROLE=\${AGENT_CALL_ROLE-<unset>}"
  echo "RUNNER_BENCH=\${RUNNER_BENCH-<unset>}"
  echo "RUNNER_TRIAGE=\${RUNNER_TRIAGE-<unset>}"
  echo "HINT=\${BENCH_HINT-<unset>}"
  echo "ALL \$*"; } > "$1/argv"
printf 'ok\n' > "\$5"
EOF
  chmod +x "$1/bin/agent-call.sh"
}

# ── A: cost-readout ──────────────────────────────────────────────────────────
# BH-2550 took the model out of cost-readout: it renders summary.json and makes
# no agent-call, so it can bill nothing to project-1 (or anyone). The real
# script runs in a sandbox HARNESS beside a stub agent-call that must never fire.
A="$T/a"; mkstub "$A"; mkdir -p "$A/logs" "$A/state/cost" "$A/path"
cp "$DIR/bin/cost-readout.sh" "$A/bin/cost-readout.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" > "%s/beat.out"\n' "$A" > "$A/bin/beat.sh"
printf '{"generated_at":"%s","projects":{"p":{"cost_24h":0.5}}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$A/state/cost/summary.json"
# A crontab that records any write, and an ssh that reaches nothing.
printf '#!/bin/bash\nif [ "${1:-}" = -l ]; then printf "0 9 * * * /x/cost-readout.sh\\n"; else cat > "%s/crontab.out"; fi\n' "$A" > "$A/path/crontab"
printf '#!/bin/bash\nexit 255\n' > "$A/path/ssh"
chmod +x "$A/bin/cost-readout.sh" "$A/bin/beat.sh" "$A/path/crontab" "$A/path/ssh"
env -u AGENT_CALL_ROLE PATH="$A/path:$PATH" HARNESS="$A" \
  bash "$A/bin/cost-readout.sh" > "$A/run.out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "A: cost-readout exited $RC: $(cat "$A/run.out")"
[ ! -e "$A/argv" ] && ok || bad "A: cost-readout called agent-call (BH-2550 removed the model): $(cat "$A/argv")"
[ -s "$A/beat.out" ] && ok || bad "A: cost-readout posted no beat"
[ ! -e "$A/crontab.out" ] && ok || bad "A: cost-readout rewrote the crontab: $(cat "$A/crontab.out")"

# ── B: runner-bench run() ────────────────────────────────────────────────────
RB="$T/b"; mkstub "$RB"; mkdir -p "$RB/b"
RUNFN=$(sed -n '/^run() {/,/^}/p' "$DIR/bin/runner-bench.sh")
if [ -z "$RUNFN" ]; then
  bad "B: no run() in bin/runner-bench.sh"
else
  printf 'ts,task,runner,model,rc,seconds,notes\n' > "$RB/bench.csv"
  ( unset RUNNER_BENCH RUNNER_TRIAGE AGENT_CALL_LANE
    HARNESS="$RB" B="$RB/b" CSV="$RB/bench.csv" BENCH_MODEL=m-bench
    eval "$RUNFN"; run code claude "" 60 "prompt" )
  grep -qx "ARGV bench bench m-bench 60" "$RB/argv" 2>/dev/null && ok \
    || bad "B: agent-call was not called as bench/bench: $(grep ARGV "$RB/argv" 2>/dev/null || echo 'never called')"
  grep -qx "RUNNER_BENCH=claude" "$RB/argv" 2>/dev/null && ok || bad "B: RUNNER_BENCH not claude: $(grep RUNNER_BENCH "$RB/argv" 2>/dev/null)"
  grep -qx "RUNNER_TRIAGE=<unset>" "$RB/argv" 2>/dev/null && ok || bad "B: RUNNER_TRIAGE still set: $(grep RUNNER_TRIAGE "$RB/argv" 2>/dev/null)"
  [ "$(wc -l < "$RB/bench.csv")" = 2 ] && grep -q ',code,claude,,0,' "$RB/bench.csv" && ok \
    || bad "B: expected one rc-0 CSV row: $(cat "$RB/bench.csv")"
  # B2: with an env hint the call goes through `env <hint>` and bills the same.
  rm -f "$RB/argv"
  ( unset RUNNER_BENCH RUNNER_TRIAGE AGENT_CALL_LANE
    HARNESS="$RB" B="$RB/b" CSV="$RB/bench.csv" BENCH_MODEL=m-bench
    eval "$RUNFN"; run code codex "BENCH_HINT=h1" 60 "prompt" )
  grep -qx "ARGV bench bench m-bench 60" "$RB/argv" 2>/dev/null && grep -qx "HINT=h1" "$RB/argv" \
    && grep -qx "RUNNER_BENCH=codex" "$RB/argv" && ok \
    || bad "B2: a hinted run did not bill bench/bench with the hint: $(cat "$RB/argv" 2>/dev/null)"
fi

# ── C: the gate ──────────────────────────────────────────────────────────────
mkdir -p "$T/reg/catalog"; cp -r "$DIR/catalog/lanes.d" "$T/reg/catalog/"
if ! "$DIR/bin/lanes-build.sh" --root "$T/reg" --write >/dev/null 2>&1; then
  bad "C: could not render a lane registry from catalog/lanes.d"
else
  gate() { ( unset AGENT_CALL_LANE; [ -n "${3:-}" ] && export AGENT_CALL_LANE="$3"
             HARNESS="$DIR" LANE_REGISTRY="$T/reg/catalog/lanes.json"
             . "$DIR/bin/lib/llm-gate.sh" >/dev/null 2>&1; llm_gate_lane_id "$1" "$2" ); }
  G=$(gate triage bench); [ "$G" = run-triage ] && ok || bad "C: control triage/bench = '$G', expected run-triage (registry not live?)"
  G=$(gate bench bench);  [ "$G" = stage-bench ] && ok || bad "C: bench/bench resolved to '$G', expected stage-bench"
  G=$(gate readout fleet cost-rollup); [ "$G" = cost-rollup ] && ok || bad "C: readout/fleet under AGENT_CALL_LANE=cost-rollup = '$G'"
  G=$(gate readout fleet); [ "$G" = stage-readout ] && ok || bad "C: readout/fleet with no lane = '$G', expected stage-readout (never a review lane)"
fi

echo "cost-attribution: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
