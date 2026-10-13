#!/bin/bash
# tests/llm-build-lane.bh-2578-test.sh — BH-2578 (part 1 of #2533): every
# run-build model call names the fly-pool lane, and fly-pool carries the three
# lane-wide LLM knobs.
#
# WHY. Every build stage call goes through CC() in bin/lib/rb/plan.sh, and
# bin/run-build.sh drops an inherited AGENT_CALL_LANE at entry (BH-2303). So a
# build call resolved to a synthetic stage-<stage> lane and a knob registered on
# fly-pool bound nothing (the BH-1132 dead-knob shape).
#
#   1  the REAL CC() hands bin/agent-call.sh AGENT_CALL_LANE=fly-pool, and the
#      caller's shell still has no AGENT_CALL_LANE after it returns (call-scoped,
#      so run-decompose / prebuild-repro launched from plan.sh keep theirs)
#   2  run-build's head drops a launching lane's exported LLM caps
#      (LLM_LANE_ENABLED, LLM_RUNNER_ALLOWED, LLM_USD_CAP_DAY, LLM_RUNNER_ALLOWED_*)
#   3  the rendered registry's fly-pool carries the three knobs, read in
#      bin/lib/llm-gate.sh, at defaults that change nothing; cost_stage stays execute
#   4  negatives: a lane-less fix (bin/lander.sh) still resolves stage-fix, a
#      named prebuild-repro call keeps its lane, plan.sh exports no lane
# Run from anywhere: tests/llm-build-lane.bh-2578-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
. "$DIR/tests/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ---- 1  CC() names fly-pool, call-scoped ----
mkdir -p "$T/bin"
cat > "$T/bin/agent-call.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "${AGENT_CALL_LANE-<unset>}" > "$REC"
EOF
chmod +x "$T/bin/agent-call.sh"
CC_SRC=$(awk '/^CC\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DIR/bin/lib/rb/plan.sh")
[ -n "$CC_SRC" ] || bad "1: no CC() found in bin/lib/rb/plan.sh"
S1=$(env -i PATH="$PATH" HARNESS="$T" REC="$T/lane.rec" CC_SRC="$CC_SRC" bash -c '
  set -u; PROJECT=x CG_ORIENT= VMAP_ORIENT=; unset AGENT_CALL_LANE
  eval "$CC_SRC"
  CC execute m 1 "$HARNESS/out" p
  printf "%s" "${AGENT_CALL_LANE-<unset>}"')
[ "$(cat "$T/lane.rec" 2>/dev/null)" = "fly-pool" ] && ok \
  || bad "1: agent-call.sh saw AGENT_CALL_LANE='$(cat "$T/lane.rec" 2>/dev/null)', want fly-pool"
[ "$S1" = "<unset>" ] && ok || bad "1: AGENT_CALL_LANE leaked into the caller after CC: '$S1'"

# ---- 2  run-build drops inherited LLM caps ----
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { bad "2: rb_all failed"; RB_ALL=/dev/null; }
# Sliced to the new unset line, which sits above the argument parse: without the
# line the slice would be the whole pipeline, so it is only evaluated when present.
S2=""; S2b=""
if grep -q '^unset LLM_LANE_ENABLED ' "$RB_ALL"; then
S2=$(env -i PATH="$PATH" LLM_USD_CAP_DAY=1 LLM_RUNNER_ALLOWED_EXECUTE=claude LLM_RUNNER_ALLOWED_PLAN=codex \
  LLM_LANE_ENABLED=0 LLM_RUNNER_ALLOWED=claude AGENT_CALL_LANE=blocked-resolver \
  bash -c 'eval "$(sed -n "1,/^unset LLM_LANE_ENABLED /p" "$1" | grep -v "^set -")"
    for v in LLM_USD_CAP_DAY LLM_RUNNER_ALLOWED_EXECUTE LLM_RUNNER_ALLOWED_PLAN LLM_LANE_ENABLED LLM_RUNNER_ALLOWED AGENT_CALL_LANE; do
      printf "%s=%s " "$v" "${!v-<unset>}"; done' _ "$RB_ALL" 2>/dev/null)
for v in LLM_USD_CAP_DAY LLM_RUNNER_ALLOWED_EXECUTE LLM_RUNNER_ALLOWED_PLAN LLM_LANE_ENABLED LLM_RUNNER_ALLOWED AGENT_CALL_LANE; do
  case " $S2" in *" $v=<unset> "*) ok ;; *) bad "2: $v survived run-build's entry ($S2)" ;; esac
done
# nothing inherited: the prefix expansion is empty and set -u must not trip
S2b=$(env -i PATH="$PATH" bash -c 'set -u; eval "$(sed -n "1,/^unset LLM_LANE_ENABLED /p" "$1" | grep -v "^set -")" && echo clean' _ "$RB_ALL" 2>&1)
else
  bad "2: no 'unset LLM_LANE_ENABLED' line in bin/run-build.sh"
fi
[ "$S2b" = clean ] && ok || bad "2: head fails with nothing inherited: $S2b"

# ---- 3  fly-pool carries the three knobs ----
REG=$(rendered_registry)
fp() { jq -c --arg e "$1" '.lanes[] | select(.id=="fly-pool") | .knobs[] | select(.env==$e) | {type,default,read_in}' "$REG"; }
[ "$(fp LLM_LANE_ENABLED)"   = '{"type":"int","default":1,"read_in":"bin/lib/llm-gate.sh"}' ] && ok || bad "3: LLM_LANE_ENABLED is '$(fp LLM_LANE_ENABLED)'"
[ "$(fp LLM_RUNNER_ALLOWED)" = '{"type":"string","default":"","read_in":"bin/lib/llm-gate.sh"}' ] && ok || bad "3: LLM_RUNNER_ALLOWED is '$(fp LLM_RUNNER_ALLOWED)'"
[ "$(fp LLM_USD_CAP_DAY)"    = '{"type":"float","default":0,"read_in":"bin/lib/llm-gate.sh"}' ] && ok || bad "3: LLM_USD_CAP_DAY is '$(fp LLM_USD_CAP_DAY)'"
# same bounds as the lane they were copied from
for e in LLM_LANE_ENABLED LLM_USD_CAP_DAY; do
  a=$(jq -c --arg e "$e" '.lanes[] | select(.id=="fly-pool") | .knobs[] | select(.env==$e) | [.min,.max,.unit,.zero_means]' "$REG")
  b=$(jq -c --arg e "$e" '.lanes[] | select(.id=="review-autopilot") | .knobs[] | select(.env==$e) | [.min,.max,.unit,.zero_means]' "$REG")
  [ -n "$a" ] && [ "$a" = "$b" ] && ok || bad "3: $e bounds '$a' differ from review-autopilot '$b'"
done
[ "$(jq -r '.lanes[] | select(.id=="fly-pool") | .stats.cost_stage' "$REG")" = execute ] && ok || bad "3: fly-pool cost_stage moved off execute"
[ "$(jq -r '.sites[] | select(.id=="rb-plan") | .lane' "$DIR/catalog/llm-sites.json")" = fly-pool ] && ok || bad "3: llm-sites rb-plan does not name fly-pool"

# ---- 4  adversarial negatives ----
gate() { env -i PATH="$PATH" HOME="$T" HARNESS="$T/h" LANE_REGISTRY="$REG" LIB="$DIR/bin/lib/llm-gate.sh" "$@"; }
L=$(gate bash -c '. "$LIB"; llm_gate_lane_id fix project-4')
[ "$L" = stage-fix ] && ok || bad "4: lane-less fix resolved '$L', want stage-fix"
L=$(gate AGENT_CALL_LANE=prebuild-repro bash -c '. "$LIB"; llm_gate_lane_id execute x')
[ "$L" = prebuild-repro ] && ok || bad "4: a named prebuild-repro call resolved '$L'"
grep -Eq 'export[[:space:]].*AGENT_CALL_LANE|^[[:space:]]*AGENT_CALL_LANE=[^[:space:]]*[[:space:]]*(;|#|$)' "$DIR/bin/lib/rb/plan.sh" \
  && bad "4: bin/lib/rb/plan.sh exports or sets AGENT_CALL_LANE outside a command prefix" || ok
N=$(grep -c 'AGENT_CALL_LANE=fly-pool' "$DIR/bin/lib/rb/plan.sh")
[ "$N" = 1 ] && grep 'AGENT_CALL_LANE=fly-pool' "$DIR/bin/lib/rb/plan.sh" | grep -q 'AGENT_CALL_ARTIFACT_KIND=' \
  && ok || bad "4: AGENT_CALL_LANE=fly-pool is not exactly once, on the agent-call prefix ($N)"

echo "llm-build-lane.bh-2578: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
