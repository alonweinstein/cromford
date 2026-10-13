#!/bin/bash
# tests/llm-runner-stage.bh-2581-test.sh — BH-2581 (part 4 of #2533): a
# per-stage runner allow-list for the build lane.
#
# WHY. BH-2578 made every run-build call name fly-pool, so fly-pool's lane-wide
# LLM_RUNNER_ALLOWED binds a build. But that list is one list for plan, execute,
# review, fix and qa, and the rung an operator wants to switch off (metered
# openrouter/fireworks fallback on execute, for one project) is not the rung
# they want to switch off everywhere. So llm_gate_runner_ok also reads
# LLM_RUNNER_ALLOWED_<STAGE>, and a rung has to pass BOTH lists.
#
#   1  the gate itself: a fly-pool (lane, project) execute row refuses the rungs
#      it does not name, names the stage in the reason, and binds nothing else;
#      the lane-wide list is checked first and keeps its own reason
#   2  adversarial negatives: no row, another stage's row, a spaced list,
#      substring rungs both ways, an odd stage name, a lane-less fix
#   3  the production entry point: bin/agent-call.sh with a row refusing its
#      runner calls nothing and leaves a refused row naming the stage
#   4  the registered knob set is exactly the set of stages CC() is called with
#
# Run from anywhere: bash tests/llm-runner-stage.bh-2581-test.sh  (exit 0 = all pass)
# As root next to a live harness: HARNESS_TEST_SANDBOX=1 bash tests/…
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

REG=$(rendered_registry)
mkdir -p "$T/state" "$T/logs" "$T/locks" "$T/flags" "$T/fakebin" "$T/bin"
PINNED=1789000000   # determinism: ok a fixed epoch, the only time this file knows

# rows <key=value>... — the settings cache lane_knob reads, fresh at $PINNED so
# _lg_settings_refresh never asks a worker. No argument = an empty cache.
rows() {
  local a obj='{}'
  for a in "$@"; do obj=$(jq -c --arg k "${a%%=*}" --arg v "${a#*=}" '.[$k]=$v' <<<"$obj"); done
  jq -nc --argjson f "$PINNED" --argjson v "$obj" '{fetched_at:$f, values:$v}' > "$T/state/settings-cache.json"
}
K=lane.fly-pool.lproj.llm_runner_allowed_execute

# gate [ENV=val...] -- <stage> <project> <runner> — prints "rc|reason|lane".
gate() {
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  env -i PATH="$PATH" HOME="$T" HARNESS="$T" LANE_REGISTRY="$REG" \
    LANE_GATE_NOW="$PINNED" LLM_GATE_NOW="$PINNED" LIB="$DIR/bin/lib/llm-gate.sh" \
    "${envs[@]}" bash -c '. "$LIB"; llm_gate_runner_ok "$1" "$2" "$3"; rc=$?
      printf "%s|%s|%s" "$rc" "$LLM_GATE_REASON" "$LLM_GATE_LANE"' _ "$@" 2>/dev/null
}
FP=AGENT_CALL_LANE=fly-pool

# ---- 1  the gate ----
rows "$K=claude,codex"
R=$(gate $FP -- execute lproj openrouter)
case "$R" in 2\|*stage=execute*) ok ;; *) bad "1: execute/lproj/openrouter not refused with stage=execute: '$R'" ;; esac
case "$R" in *lane=fly-pool*) ok ;; *) bad "1: refusal does not name lane=fly-pool: '$R'" ;; esac
case "$R" in *"runner-not-allowed openrouter not in [claude,codex]"*) ok ;; *) bad "1: refusal reason shape: '$R'" ;; esac
R=$(gate $FP -- execute lproj fireworks);  [ "${R%%|*}" = 2 ] && ok || bad "1: fireworks on execute/lproj allowed: '$R'"
R=$(gate $FP -- execute lproj claude);     [ "${R%%|*}" = 0 ] && ok || bad "1: claude on execute/lproj refused: '$R'"
R=$(gate $FP -- execute lproj codex);      [ "${R%%|*}" = 0 ] && ok || bad "1: codex on execute/lproj refused: '$R'"
R=$(gate $FP -- execute otherproj openrouter); [ "${R%%|*}" = 0 ] && ok || bad "1: another project's execute refused by lproj's row: '$R'"
R=$(gate $FP -- plan lproj openrouter);    [ "${R%%|*}" = 0 ] && ok || bad "1: plan refused by the execute row: '$R'"
# intersection: the lane-wide list is checked first and keeps its own reason
rows "$K=claude,codex" "lane.fly-pool.llm_runner_allowed=claude"
R=$(gate $FP -- execute lproj codex)
[ "${R%%|*}" = 2 ] && ok || bad "1: codex allowed although the lane-wide list is claude: '$R'"
[ "$(cut -d'|' -f2 <<<"$R")" = "runner-not-allowed codex not in [claude] lane=fly-pool" ] && ok \
  || bad "1: lane-wide refusal string changed: '$R'"
R=$(gate $FP -- execute lproj claude);     [ "${R%%|*}" = 0 ] && ok || bad "1: claude refused though both lists allow it: '$R'"
# ...and the lane-wide list allowing a rung does not override the stage list
rows "$K=claude" "lane.fly-pool.llm_runner_allowed=claude,openrouter"
R=$(gate $FP -- execute lproj openrouter)
case "$R" in 2\|*stage=execute*) ok ;; *) bad "1: stage list not applied after a lane-wide allow: '$R'" ;; esac
# no rows at all: every rung, every stage
rows
for s in plan execute review fix qa; do for r in claude codex openrouter fireworks grok; do
  R=$(gate $FP -- "$s" lproj "$r"); [ "${R%%|*}" = 0 ] && ok || bad "1: empty cache refused $s/$r: '$R'"
done; done

# ---- 2  adversarial negatives ----
rows "$K=claude,codex"
R=$(gate $FP -- execute noproj openrouter); [ "${R%%|*}" = 0 ] && ok || bad "2: project with no row refused: '$R'"
R=$(gate $FP -- plan lproj openrouter);     [ "${R%%|*}" = 0 ] && ok || bad "2: plan refused when only _EXECUTE is set: '$R'"
rows "$K= claude , codex "
R=$(gate $FP -- execute lproj claude);      [ "${R%%|*}" = 0 ] && ok || bad "2: spaced list ' claude , codex ' refused claude: '$R'"
R=$(gate $FP -- execute lproj openrouter);  [ "${R%%|*}" = 2 ] && ok || bad "2: spaced list allowed openrouter: '$R'"
rows "$K=openrouter"
R=$(gate $FP -- execute lproj openrouter-floor); [ "${R%%|*}" = 2 ] && ok || bad "2: rung openrouter-floor matched list openrouter (substring): '$R'"
rows "$K=openrouter-floor"
R=$(gate $FP -- execute lproj openrouter);  [ "${R%%|*}" = 2 ] && ok || bad "2: rung openrouter matched list openrouter-floor (substring): '$R'"
# a stage that cannot name a knob reads none — even a settings row spelled
# after it, whose key (lane.fly-pool.lproj.llm_runner_allowed_ex.ec) the
# settings reader would otherwise accept
rows "$K=claude" "lane.fly-pool.lproj.llm_runner_allowed_ex.ec=claude"
R=$(gate $FP -- ex.ec lproj openrouter); [ "${R%%|*}" = 0 ] && ok || bad "2: stage ex.ec refused: '$R'"
R=$(gate $FP -- a/b lproj openrouter);      [ "${R%%|*}" = 0 ] && ok || bad "2: stage a/b refused: '$R'"
# a lane-less fix (bin/lander.sh) is stage-fix, and fly-pool's _FIX row is not its row
rows "lane.fly-pool.lproj.llm_runner_allowed_fix=claude"
R=$(gate -- fix lproj openrouter)
[ "${R%%|*}" = 0 ] && ok || bad "2: lane-less fix refused by fly-pool's _FIX row: '$R'"
[ "${R##*|}" = stage-fix ] && ok || bad "2: lane-less fix resolved '${R##*|}', want stage-fix"
# ...while the same row does bind a fly-pool fix (the negative above is not vacuous)
R=$(gate $FP -- fix lproj openrouter)
case "$R" in 2\|*stage=fix*) ok ;; *) bad "2: fly-pool fix row did not refuse openrouter: '$R'" ;; esac
# LLM_GATE_DISABLE and an empty runner keep their early return
R=$(gate $FP LLM_GATE_DISABLE=1 -- fix lproj openrouter); [ "${R%%|*}" = 0 ] && ok || bad "2: LLM_GATE_DISABLE=1 still refused: '$R'"
R=$(gate $FP -- fix lproj "");              [ "${R%%|*}" = 0 ] && ok || bad "2: empty runner refused: '$R'"

# ---- 3  the production entry point ----
for R in claude codex grok gemini; do
  cat > "$T/fakebin/$R" <<EOF
#!/bin/bash
touch "\$SENTINEL_DIR/$R-ran"
printf '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}\n'
EOF
  chmod +x "$T/fakebin/$R"
done
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/timeout"
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"; chmod +x "$T/bin/billing-mode.sh"
cp "$T/bin/billing-mode.sh" "$T/fakebin/billing-mode.sh"
mkdir -p "$T/.codex"; echo '{}' > "$T/.codex/auth.json"   # codex is "ready" only with an auth file
printf '#!/bin/bash\n_jobs_req() { return 1; }\n' > "$T/bin/jobs-client.sh"
# agent-call reads each rung's model from model_routes; this worker-less box
# carries the resolver's cache of the seeded table (BH-1510.2).
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T" lproj || exit 1
call() { # call <env...> — runs the real agent-call as a fly-pool execute for lproj
  rm -f "$T"/*-ran "$T/out.txt" "$T/out.txt.err" "$T/logs/cost.csv"
  ( export SENTINEL_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
      LANE_REGISTRY="$REG" LANE_GATE_NOW="$PINNED" LLM_GATE_NOW="$PINNED" \
      CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" AGENT_CALL_LANE=fly-pool
    "$@" bash "$DIR/bin/agent-call.sh" execute lproj claude-fable-5 60 "$T/out.txt" hello >/dev/null 2>&1 )
  echo $?
}
rows "$K=claude"
RC=$(call env RUNNER_EXECUTE=codex RUNNER_EXECUTE_FALLBACK=claude)
[ -f "$T/codex-ran" ] && bad "3: codex ran although lproj's execute list is claude" || ok
RROW=$(grep ',refused,' "$T/logs/cost.csv" 2>/dev/null | grep ',codex,' | head -1)
[ -n "$RROW" ] && ok || bad "3: no refused row for codex; cost.csv: $(cat "$T/logs/cost.csv" 2>/dev/null)"
case "$RROW" in *refused:runner-not-allowed*stage=execute*) ok ;; *) bad "3: refused row does not name the stage: '$RROW'" ;; esac
# TEST-CHANGE BH-2666: lane_id read by position ($25), not $NF — guard_fp is
# now the 26th column on a refused row, and $NF is a position that moves.
[ "$(awk -F, '{print $25}' <<<"$RROW")" = fly-pool ] && ok || bad "3: refused row lane_id is not fly-pool: '$RROW'"
[ -f "$T/claude-ran" ] && ok || bad "3: the allowed fallback claude did not run (rc=$RC)"
# the negative: no row, and codex runs as it does today
rows
RC=$(call env RUNNER_EXECUTE=codex RUNNER_EXECUTE_FALLBACK=claude)
[ -f "$T/codex-ran" ] && ok || bad "3: with no row codex did not run (rc=$RC)"
grep -q ',refused,' "$T/logs/cost.csv" 2>/dev/null && bad "3: with no row a refused row was written" || ok

# ---- 4  the knob set is the CC() stage set ----
# The pipeline as one text, in its original order (tests/lib/rb-all.sh): run-build
# plus every bin/lib/rb/ module it sources.
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { bad "4: rb_all failed"; RB_ALL=/dev/null; }
STAGES=$(grep -hE '^[^#]*\bCC [a-z]+ ' "$RB_ALL" | grep -v 'CC()' \
  | grep -oE '\bCC [a-z]+ ' | awk '{print toupper($2)}' | sort -u)
[ -n "$STAGES" ] && [ "$(wc -l <<<"$STAGES")" -ge 3 ] && ok || bad "4: found no CC stages ('$STAGES') — the comparison below would be empty against empty"
KNOBS=$(jq -r '.lanes[] | select(.id=="fly-pool") | .knobs[].env | select(test("^LLM_RUNNER_ALLOWED_")) | sub("^LLM_RUNNER_ALLOWED_";"")' "$REG" | sort -u)
[ "$STAGES" = "$KNOBS" ] && ok || bad "4: CC stages [$(echo $STAGES)] != fly-pool per-stage knobs [$(echo $KNOBS)]"
for s in $STAGES; do
  m=$(jq -c --arg e "LLM_RUNNER_ALLOWED_$s" '.lanes[] | select(.id=="fly-pool") | .knobs[] | select(.env==$e) | [.type,.default,.read_in,.prefix]' "$REG")
  [ "$m" = '["string","","bin/lib/llm-gate.sh","LLM_RUNNER_ALLOWED_"]' ] && ok || bad "4: LLM_RUNNER_ALLOWED_$s is '$m'"
done
[ "$(jq -r '.lanes[] | select(.id=="fly-pool") | .stats.cost_stage' "$REG")" = execute ] && ok || bad "4: fly-pool cost_stage moved off execute"
LW=$(jq -c '[.lanes[] | select(.id=="fly-pool") | .knobs[] | select(.env=="LLM_LANE_ENABLED" or .env=="LLM_RUNNER_ALLOWED" or .env=="LLM_USD_CAP_DAY") | [.env,.type,.default]]' "$REG")
[ "$LW" = '[["LLM_LANE_ENABLED","int",1],["LLM_RUNNER_ALLOWED","string",""],["LLM_USD_CAP_DAY","float",0]]' ] && ok || bad "4: lane-wide knobs changed: $LW"

echo "llm-runner-stage.bh-2581: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
