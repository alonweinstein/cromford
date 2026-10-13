#!/bin/bash
# tests/config-slice-cost-mc.bh-1939-test.sh — BH-1939 (BH-1511.2): the
# cost/billing and mission-control config slice.
#
# Fifteen `${VAR:-literal}` defaults in bin/lib/gh-budget.sh,
# bin/transcript-cost.sh, bin/lib/main-red-gate.sh and bin/lib/mc/queue.sh moved
# to four per-lib registry files (catalog/lanes.d/_lib.<id>.json, required:
# true). Each file now resolves them through lib_env_apply in a SUBSHELL and
# keeps no literal. Every case goes through the production entry point: the
# libs are sourced the way lanes source them (merge-conductor-lib.sh,
# gh-budget.sh) and transcript-cost.sh is RUN as the CLI.
#   D   no row, no env, HARNESS with no registry: each var = the literal at the
#       base commit (D-git parses it out of `git show $BASE:<file>`);
#   D2  HARNESS carrying its own registry wins over the lib's own checkout;
#   R   a fresh lib.<id>.<env> row beats the env; R-neg: a settable:false knob
#       ignores its lib row;
#   S2  a lane row lane_env_apply exported before the source still reaches it;
#   Z   a row of 0 is a value: no wait (a `sleep` shim logs "nap N"), no cache (gh rate_limit and the queue
#       provider are re-read);
#   C   worker down + a stale cache with a row: the row, no ALERTS line;
#   G   LANE_GATE_DISABLE=1 still applies the env;
#   F   a required knob with no default: ONE ALERTS line however often the lib
#       is sourced, the caller survives, and the empty value takes the branch
#       that does less (no exemption, one Mergify pass);
#   S   a suite's lane_knob stub survives sourcing merge-conductor-lib.sh;
#   L1  config-literal-lint prints no line for the five files; L2-L5 scope.
# Run from anywhere: tests/config-slice-cost-mc.bh-1939-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
BASE=8b524f0
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# eq <label> <want> <got>
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }

NOW=1758300000
REALPY=$(command -v python3)
MC_VARS="MC_QUEUE_TTL MC_MERGE_SETTLE MC_ENQUEUE_SETTLE MC_MERGIFY_SETTLE MC_MERGIFY_WAIT_S MC_EJECT_REBASE MC_MERGIFY_STUCK_SECS MC_MERGIFY_REFRESH_WINDOW_SECS MC_MERGIFY_STUCK_ALERT_SECS BATCH_TRAIN_MIN"
MRG_VARS="MC_MAIN_RED_TEST_PATHS MC_MAIN_RED_LABEL"
GHB_VARS="GH_BUDGET_TTL_S GH_BUDGET_DB_TIMEOUT_S"
TC_VARS="COST_TRANSCRIPT_SCAN_MAX COST_CACHE_TTL"

# A HARNESS tree with NO catalog/: what nearly every fixture suite runs with.
newh() { scratch_rm "$1" || return 1; mkdir -p "$1/state" "$1/logs" "$1/flags" "$1/tmp"; }
# cache <harness> <age-s> <key=value>... — the box settings cache lane-gate reads.
cache() {
  local h="$1" age="$2" kv v='{}'; shift 2
  for kv in "$@"; do v=$(jq -c --arg k "${kv%%=*}" --arg x "${kv#*=}" '. + {($k): $x}' <<<"$v"); done
  jq -nc --argjson fa "$((NOW - age))" --argjson v "$v" '{fetched_at:$fa, values:$v, seeded:{}}' > "$h/state/settings-cache.json"
}

# The mc driver: sources merge-conductor-lib.sh as a lane does, under set -u,
# then prints every var (UNSET when unset) and runs the requested probe.
cat > "$T/mc-driver.sh" <<'SH'
#!/bin/bash
set -uo pipefail
if [ -n "${STUB_WORKER_DOWN:-}" ]; then _jobs_req() { echo "$1 $2" >> "$CALLS"; return 1; }; fi
if [ -n "${STUB_LANE_KNOB:-}" ]; then lane_knob() { echo STUB; }; fi
if [ -n "${PRE_LANE_APPLY:-}" ]; then . "$DIR/bin/lib/lane-gate.sh"; lane_env_apply merge-conductor; fi
. "$DIR/bin/lib/merge-conductor-lib.sh"
[ -n "${SOURCE_TWICE:-}" ] && . "$DIR/bin/lib/merge-conductor-lib.sh"
echo AFTER-SOURCE
for v in $VARS; do printf '%s=[%s]\n' "$v" "${!v-UNSET}"; done
[ -n "${STUB_LANE_KNOB:-}" ] && echo "LANE_KNOB=[$(lane_knob x y)]"
sleep() { echo "nap $*" >> "$CALLS"; }
gh() { echo "gh $*" >> "$CALLS"; return 0; }
case "${PROBE:-}" in
  merge)
    unset -f gh_pr_merge_rest gh_pr_merge_flag 2>/dev/null
    gh_rest_pr_state_var() { printf -v "$1" '%s' merged; }
    mc_merge "https://github.com/o/r/pull/1" abcdef12 >/dev/null; echo "MERGE_RC=$?" ;;
  provider)
    printf mergify > "$MC_H/tmp/merge-queue-o_r.provider"
    mc_queue_github_enabled() { echo probe >> "$CALLS"; return 1; }
    mc_queue_mergify_enabled() { return 1; }
    echo "PROVIDER=[$(mc_queue_provider o/r)]" ;;
  mergify)
    mc_queue_state() { echo open; }
    mc_mergify_witness() { echo witness >> "$CALLS"; return 1; }
    mc_enqueue_mergify o/r "https://github.com/o/r/pull/1" abcdef12 >/dev/null; echo "ENQ_RC=$?" ;;
  exempt)
    mc_pr_files() { printf '%s\n' tests/foo.sh; }
    for l in "" "a,,b" "fix-main-red-later" "anything" "fix-main-red"; do
      main_red_exempt o/r 1 "https://github.com/o/r/pull/1" abcdef12 "$l"; echo "EXEMPT[$l]=$?"
    done ;;
esac
echo END
SH

# The gh-budget driver: sourced as a lane does. The shared row client is
# stubbed (it records the JOBS_TIMEOUT it was called under) and `gh` is a PATH
# shim that counts rate_limit reads.
cat > "$T/ghb-driver.sh" <<'SH'
#!/bin/bash
gh_budget_row_get() { echo "rowget T=$JOBS_TIMEOUT" >> "$CALLS"; return 1; }
gh_budget_row_put() { echo "rowput T=$JOBS_TIMEOUT" >> "$CALLS"; return 0; }
. "$DIR/bin/lib/gh-budget.sh"
echo AFTER-SOURCE
for v in $VARS; do printf '%s=[%s]\n' "$v" "${!v-UNSET}"; done
if [ -n "${PROBE:-}" ]; then gh_budget_refresh; echo "R1=$?"; gh_budget_refresh; echo "R2=$?"; fi
echo END
SH
mkdir -p "$T/shim"
cat > "$T/shim/gh" <<'SH'
#!/bin/bash
echo "gh $*" >> "$CALLS"
if [ "$1 $2" = "api rate_limit" ]; then
  echo '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":1},"graphql":{"remaining":4000,"limit":5000,"reset":1}}}'
fi
SH
# python3 shim: transcript-cost.sh hands MAXSCAN / CACHE_TTL to `python3 -`;
# capture them there. Anything else goes to the real python3.
cat > "$T/shim/python3" <<SH
#!/bin/bash
if [ "\${1:-}" = - ]; then printf 'MAXSCAN=[%s] CACHE_TTL=[%s]\n' "\${MAXSCAN-UNSET}" "\${CACHE_TTL-UNSET}" >> "\$CALLS"; cat >/dev/null; exit 3; fi
exec "$REALPY" "\$@"
SH
chmod +x "$T/shim/gh" "$T/shim/python3" "$T/mc-driver.sh" "$T/ghb-driver.sh"

# run_mc <harness> [VAR=val…] — the mc driver's output in $OUT, calls in $T/calls.
run_mc() {
  local h="$1"; shift
  : > "$T/calls"
  OUT=$(env -u LANE_REGISTRY -u MC_QUEUE_TTL -u MC_MERGE_SETTLE -u MC_ENQUEUE_SETTLE -u MC_MERGIFY_SETTLE -u MC_MERGIFY_WAIT_S \
        -u MC_EJECT_REBASE -u MC_MERGIFY_STUCK_SECS -u MC_MERGIFY_REFRESH_WINDOW_SECS \
        -u MC_MERGIFY_STUCK_ALERT_SECS -u BATCH_TRAIN_MIN -u MC_MAIN_RED_TEST_PATHS -u MC_MAIN_RED_LABEL \
        -u LANE_GATE_DISABLE HARNESS="$h" H="$h" DIR="$DIR" CALLS="$T/calls" \
        LANE_GATE_NOW="$NOW" VARS="${VARS:-$MC_VARS $MRG_VARS}" "$@" timeout 60 bash "$T/mc-driver.sh" 2>"$T/err"); RC=$?
}
run_ghb() {
  local h="$1"; shift
  : > "$T/calls"
  OUT=$(env -u LANE_REGISTRY -u GH_BUDGET_TTL_S -u GH_BUDGET_DB_TIMEOUT_S -u GH_BUDGET_DB \
        HARNESS="$h" H="$h" DIR="$DIR" CALLS="$T/calls" LANE_GATE_NOW="$NOW" GH_TOKEN=fixture-tok \
        PATH="$T/shim:$PATH" VARS="$GHB_VARS" "$@" bash "$T/ghb-driver.sh" 2>"$T/err"); RC=$?
}
run_tc() {
  local h="$1"; shift
  : > "$T/calls"
  env -u LANE_REGISTRY -u COST_TRANSCRIPT_SCAN_MAX -u COST_CACHE_TTL \
      HARNESS="$h" H="$h" CALLS="$T/calls" LANE_GATE_NOW="$NOW" PATH="$T/shim:$PATH" "$@" \
      bash "$DIR/bin/transcript-cost.sh" "$T/none.jsonl" --prices /dev/null >/dev/null 2>"$T/err"; RC=$?
  OUT=$(cat "$T/calls")
}
val() { printf '%s\n' "$OUT" | sed -n "s/^$1=\[\(.*\)\]\$/\1/p" | head -1; }
ex()  { printf '%s\n' "$OUT" | sed -n "s/^EXEMPT\[$1\]=//p" | head -1; }
REG=$(bash -c '. "$1/bin/lib/lanes-registry.sh" && lanes_json_path "$1"' _ "$DIR")

# --- D-git: the literal each var carried at the base commit ------------------
# The table is the suite's own copy of those literals, so D still has something
# to compare against once $BASE is gone. This repo squash-merges, so a feature
# branch's commit is not in main's history for ever, and the gate's isolated
# snapshot has no .git at all. D-git checks the table against
# `git show $BASE:<file>` whenever that object exists (CI checks out with
# fetch-depth 0, and a build's own clone has it). When it does not, the line
# says SKIP and is not counted as a pass.
declare -A LIT=(
  [MC_QUEUE_TTL]=300 [MC_MERGE_SETTLE]=5 [MC_ENQUEUE_SETTLE]=2 [MC_MERGIFY_SETTLE]=15
  [MC_MERGIFY_WAIT_S]=90 [MC_EJECT_REBASE]=1 [MC_MERGIFY_STUCK_SECS]=300
  [MC_MERGIFY_REFRESH_WINDOW_SECS]=3600 [MC_MERGIFY_STUCK_ALERT_SECS]=600 [BATCH_TRAIN_MIN]=1
  [MC_MAIN_RED_TEST_PATHS]='tests/* worker/*/test/*' [MC_MAIN_RED_LABEL]=fix-main-red
  [GH_BUDGET_TTL_S]=60 [GH_BUDGET_DB_TIMEOUT_S]=4
  [COST_TRANSCRIPT_SCAN_MAX]=400 [COST_CACHE_TTL]=auto
)
HAVE_BASE=0; git -C "$DIR" cat-file -e "$BASE^{commit}" 2>/dev/null && HAVE_BASE=1
lit_of() { # lit_of <file> <VAR> — the literal of the first ${VAR:-literal} in the base file
  git -C "$DIR" show "$BASE:$1" 2>/dev/null | grep -oE "\\\$\\{$2:-[^}]+\\}" | head -1 | sed -E "s/^\\\$\\{$2:-(.*)\\}\$/\\1/"
}
if [ "$HAVE_BASE" = 1 ]; then
  for v in $MC_VARS; do eq "D-git $v" "${LIT[$v]}" "$(lit_of bin/lib/mc/queue.sh "$v")"; done
  for v in $MRG_VARS; do eq "D-git $v" "${LIT[$v]}" "$(lit_of bin/lib/main-red-gate.sh "$v")"; done
  for v in $GHB_VARS; do eq "D-git $v" "${LIT[$v]}" "$(lit_of bin/lib/gh-budget.sh "$v")"; done
  for v in $TC_VARS; do eq "D-git $v" "${LIT[$v]}" "$(lit_of bin/transcript-cost.sh "$v")"; done
else
  echo "SKIP (not a pass): D-git, base commit $BASE is not in this clone; D compares against the table above"
fi

# --- D: defaults, HARNESS with no registry (the own-checkout fallback) --------
H0="$T/h0"; newh "$H0"
run_mc "$H0"
eq "D mc rc" 0 "$RC"
for v in $MC_VARS $MRG_VARS; do eq "D $v" "${LIT[$v]:-?}" "$(val "$v")"; done
run_ghb "$H0"
eq "D ghb rc" 0 "$RC"
for v in $GHB_VARS; do eq "D $v" "${LIT[$v]:-?}" "$(val "$v")"; done
eq "D _GHB_TTL" 60 "$(env -u GH_BUDGET_TTL_S HARNESS="$H0" bash -c '. "$1/bin/lib/gh-budget.sh"; printf %s "$_GHB_TTL"' _ "$DIR" 2>/dev/null)"
run_tc "$H0"
eq "D transcript-cost" "MAXSCAN=[${LIT[COST_TRANSCRIPT_SCAN_MAX]:-?}] CACHE_TTL=[${LIT[COST_CACHE_TTL]:-?}]" "$OUT"
# The default reaches BEHAVIOUR: mc_merge sleeps 5, the gh-budget shared row is
# asked under a 4 s timeout.
run_mc "$H0" PROBE=merge
grep -qx 'nap 5' "$T/calls" && ok || bad "D mc_merge settle: $(tr '\n' ' ' < "$T/calls")"
run_ghb "$H0" PROBE=1
grep -qx 'rowget T=4' "$T/calls" && ok || bad "D gh-budget row timeout: $(tr '\n' ' ' < "$T/calls")"
eq "D gh-budget one rate_limit read under TTL 60" 1 "$(grep -c 'gh api rate_limit' "$T/calls")"
# A test-only PR with the default globs IS exempt; the real label is exempt.
run_mc "$H0" PROBE=exempt
eq "D exempt test-only diff" 0 "$(ex anything)"
eq "D exempt real label" 0 "$(ex fix-main-red)"

# --- D2: HARNESS's own registry wins over the lib checkout's ------------------
H2="$T/h2"; newh "$H2"; mkdir -p "$H2/catalog"
jq '(.libs[]|select(.id=="mc-queue")|.knobs[]|select(.env=="MC_QUEUE_TTL")|.default) = 301' \
  "$REG" > "$H2/catalog/lanes.json" 2>/dev/null
[ -s "$H2/catalog/lanes.json" ] && ok || bad "D2 fixture: could not copy the registry"
run_mc "$H2"
eq "D2 MC_QUEUE_TTL from \$HARNESS's registry" 301 "$(val MC_QUEUE_TTL)"

# --- R: a fresh row wins over the env; R-neg: settable:false ignores it -------
HR="$T/hr"; newh "$HR"
cache "$HR" 0 lib.mc-queue.mc_queue_ttl=111 lib.mc-queue.mc_merge_settle=7 lib.mc-queue.mc_enqueue_settle=8 \
  lib.mc-queue.mc_mergify_settle=9 lib.mc-queue.mc_mergify_wait_s=33 lib.main-red-gate.mc_main_red_test_paths='spec/*' \
  lib.gh-budget.gh_budget_ttl_s=45 lib.gh-budget.gh_budget_db_timeout_s=6 \
  lib.transcript-cost.cost_transcript_scan_max=12 lib.transcript-cost.cost_cache_ttl=1h \
  lib.main-red-gate.mc_main_red_label=anything lib.mc-queue.mc_eject_rebase=0 lib.mc-queue.mc_mergify_stuck_secs=1 \
  lib.mc-queue.mc_mergify_refresh_window_secs=2 lib.mc-queue.mc_mergify_stuck_alert_secs=61 lib.mc-queue.batch_train_min=9
run_mc "$HR" MC_QUEUE_TTL=222 MC_MERGE_SETTLE=1 MC_MAIN_RED_TEST_PATHS='x/*'
eq "R MC_QUEUE_TTL row over env" 111 "$(val MC_QUEUE_TTL)"
eq "R MC_MERGE_SETTLE row over env" 7 "$(val MC_MERGE_SETTLE)"
eq "R MC_ENQUEUE_SETTLE" 8 "$(val MC_ENQUEUE_SETTLE)"
eq "R MC_MERGIFY_SETTLE" 9 "$(val MC_MERGIFY_SETTLE)"
eq "R MC_MERGIFY_WAIT_S" 33 "$(val MC_MERGIFY_WAIT_S)"
eq "R MC_MAIN_RED_TEST_PATHS row over env" 'spec/*' "$(val MC_MAIN_RED_TEST_PATHS)"
for v in MC_MAIN_RED_LABEL MC_EJECT_REBASE MC_MERGIFY_STUCK_SECS MC_MERGIFY_REFRESH_WINDOW_SECS MC_MERGIFY_STUCK_ALERT_SECS BATCH_TRAIN_MIN; do
  eq "R-neg $v: a lib row is ignored (settable:false)" "${LIT[$v]:-?}" "$(val "$v")"
done
run_mc "$HR" PROBE=exempt
eq "R-neg a lib row for the label does not make it the label" 1 "$(ex anything)"
eq "R-neg the real label still exempts" 0 "$(ex fix-main-red)"
run_ghb "$HR" GH_BUDGET_TTL_S=99
eq "R GH_BUDGET_TTL_S row over env" 45 "$(val GH_BUDGET_TTL_S)"
eq "R GH_BUDGET_DB_TIMEOUT_S" 6 "$(val GH_BUDGET_DB_TIMEOUT_S)"
run_tc "$HR" COST_CACHE_TTL=5m
eq "R transcript-cost rows over env" "MAXSCAN=[12] CACHE_TTL=[1h]" "$OUT"

# --- S2: the conductor's lane row, exported before the lib is sourced ---------
HS="$T/hs"; newh "$HS"
cache "$HS" 0 lane.merge-conductor.mc_mergify_stuck_secs=120
run_mc "$HS" PRE_LANE_APPLY=1 LANE_REGISTRY="$REG"
eq "S2 lane row reaches MC_MERGIFY_STUCK_SECS" 120 "$(val MC_MERGIFY_STUCK_SECS)"

# --- Z: a row of 0 is a value, observed as behaviour --------------------------
HZ="$T/hz"; newh "$HZ"
cache "$HZ" 0 lib.mc-queue.mc_merge_settle=0 lib.mc-queue.mc_queue_ttl=0 lib.gh-budget.gh_budget_ttl_s=0
run_mc "$HZ" PROBE=merge
eq "Z MC_MERGE_SETTLE" 0 "$(val MC_MERGE_SETTLE)"
if grep -qx 'nap 0' "$T/calls" && ! grep -qE '^nap [1-9]' "$T/calls"; then ok; else bad "Z mc_merge must not wait: $(tr '\n' ' ' < "$T/calls")"; fi
run_mc "$HZ" PROBE=provider
eq "Z MC_QUEUE_TTL=0 re-probes instead of answering from the cache file" none "$(val PROVIDER)"
grep -qx probe "$T/calls" && ok || bad "Z provider probe not called"
run_mc "$H0" PROBE=provider
eq "Z control: the default TTL answers from the cache file" mergify "$(val PROVIDER)"
run_ghb "$HZ" PROBE=1
eq "Z GH_BUDGET_TTL_S" 0 "$(val GH_BUDGET_TTL_S)"
eq "Z GH_BUDGET_TTL_S=0: every refresh reads rate_limit" 2 "$(grep -c 'gh api rate_limit' "$T/calls")"

# --- C: worker down, stale cache with a row -> the row, no ALERTS -------------
HC="$T/hc"; newh "$HC"
cache "$HC" 3600 lib.mc-queue.mc_queue_ttl=42
run_mc "$HC" STUB_WORKER_DOWN=1
eq "C stale cached row served" 42 "$(val MC_QUEUE_TTL)"
grep -q 'GET /api/settings' "$T/calls" && ok || bad "C the worker was not asked (the fixture is not testing an outage)"
[ ! -s "$HC/logs/ALERTS.log" ] && ok || bad "C ALERTS written on an outage with a cached row: $(cat "$HC/logs/ALERTS.log")"

# --- G: LANE_GATE_DISABLE=1 still applies the env -----------------------------
run_mc "$H0" LANE_GATE_DISABLE=1 MC_QUEUE_TTL=77
eq "G env under LANE_GATE_DISABLE" 77 "$(val MC_QUEUE_TTL)"

# --- F: fail closed -----------------------------------------------------------
HF="$T/hf"; newh "$HF"
jq '(.libs[]|select(.id=="mc-queue")|.knobs[]|select(.env=="MC_MERGIFY_SETTLE" or .env=="MC_MERGIFY_WAIT_S" or .env=="MC_QUEUE_TTL")) |= del(.default)
  | (.libs[]|select(.id=="main-red-gate")|.knobs[]) |= del(.default)' "$REG" > "$T/reg-f.json"
run_mc "$HF" LANE_REGISTRY="$T/reg-f.json" SOURCE_TWICE=1 PROBE=mergify
eq "F caller rc" 0 "$RC"
case "$OUT" in *AFTER-SOURCE*END*) ok ;; *) bad "F the sourcing shell did not run on: $OUT" ;; esac
eq "F MC_MERGIFY_SETTLE: nothing guessed, nothing assigned" UNSET "$(val MC_MERGIFY_SETTLE)"
eq "F other knobs of the lib still resolve" 5 "$(val MC_MERGE_SETTLE)"
eq "F one ALERTS line for mc-queue" 1 "$(grep -c 'mc-queue' "$HF/logs/ALERTS.log" 2>/dev/null || echo 0)"
grep -q 'mc-queue.*MC_MERGIFY_SETTLE' "$HF/logs/ALERTS.log" 2>/dev/null && ok || bad "F the ALERTS line does not name the knob"
eq "F one ALERTS line for main-red-gate" 1 "$(grep -c 'main-red-gate' "$HF/logs/ALERTS.log" 2>/dev/null || echo 0)"
eq "F empty wait: ONE Mergify witness pass" 1 "$(grep -cx witness "$T/calls")"
grep -q '^nap' "$T/calls" && bad "F empty wait slept: $(grep '^nap' "$T/calls" | tr '\n' ' ')" || ok
[ -s "$T/err" ] && bad "F mergify wait wrote stderr: $(head -3 "$T/err")" || ok
# Only the step unresolved, the bound at its default: still no spin.
HF3="$T/hf3"; newh "$HF3"
jq '(.libs[]|select(.id=="mc-queue")|.knobs[]|select(.env=="MC_MERGIFY_SETTLE")) |= del(.default)' "$REG" > "$T/reg-f3.json"
run_mc "$HF3" LANE_REGISTRY="$T/reg-f3.json" PROBE=mergify
eq "F3 empty step, bound 90: ONE witness pass" 1 "$(grep -cx witness "$T/calls")"
eq "F3 rc" 0 "$RC"
[ -s "$T/err" ] && bad "F3 empty step wrote stderr: $(head -3 "$T/err")" || ok
run_mc "$HF" LANE_REGISTRY="$T/reg-f.json" PROBE=provider
eq "F empty MC_QUEUE_TTL: no answer from the cache file" none "$(val PROVIDER)"
grep -qx probe "$T/calls" && ok || bad "F empty MC_QUEUE_TTL: the provider was not probed"
grep -q 'integer expression' "$T/err" && bad "F empty MC_QUEUE_TTL reached a numeric test: $(cat "$T/err")" || ok
run_mc "$HF" LANE_REGISTRY="$T/reg-f.json" PROBE=exempt
eq "F second run: still one mc-queue ALERTS line" 1 "$(grep -c 'mc-queue' "$HF/logs/ALERTS.log" 2>/dev/null || echo 0)"
for l in "" "a,,b" "fix-main-red-later"; do
  eq "F (c) empty paths: labels [$l] must NOT exempt" 1 "$(ex "$l")"
done
# The label is BH-1770's one knob (lib.main-red-label, bin/lib/main-red-label.sh),
# not this lib's, so deleting main-red-gate's defaults cannot empty it.
eq "F (c) the label still resolves through main-red-label" 0 "$(ex fix-main-red)"
cat > "$T/rf.sh" <<'SH'
. "$DIR/bin/lib/merge-conductor-lib.sh"
main_red_test_path tests/foo.sh; echo "TP=$?"
SH
eq "F (c) empty MC_MAIN_RED_TEST_PATHS matches nothing" TP=1 \
  "$(env -u MC_MAIN_RED_TEST_PATHS HARNESS="$HF" DIR="$DIR" LANE_REGISTRY="$T/reg-f.json" bash -u "$T/rf.sh" 2>/dev/null | tail -1)"

# --- S: a suite's lane_knob stub survives the source --------------------------
run_mc "$H0" STUB_LANE_KNOB=1
eq "S lane_knob stub survives" STUB "$(val LANE_KNOB)"
eq "S rc" 0 "$RC"

# --- L1: the lint prints nothing for the five files ---------------------------
LINT=$(HARNESS_TEST_SANDBOX=1 bash "$DIR/tests/config-literal-lint.sh" "$DIR" 2>&1); LRC=$?
eq "L1 lint rc" 0 "$LRC"
HITS=$(printf '%s\n' "$LINT" | grep -E '^bin/(lib/gh-budget|transcript-cost|deploy-request|lib/main-red-gate|lib/mc/queue)\.sh:')
[ -z "$HITS" ] && ok || bad "L1 literals left: $(printf '%s' "$HITS" | tr '\n' ' ')"
# --- L2: GH_BUDGET_DB is left in place and not registered ---------------------
eq "L2 GH_BUDGET_DB not registered" 0 "$(jq '[.libs[].knobs[]|select(.env=="GH_BUDGET_DB")]|length' "$REG")"
grep -q 'GH_BUDGET_DB:-1' "$DIR/bin/lib/gh-budget.sh" && ok || bad "L2 gh-budget.sh no longer reads GH_BUDGET_DB"
for id in gh-budget transcript-cost main-red-gate mc-queue; do
  eq "L2 lib $id registered" 1 "$(jq --arg i "$id" '[.libs[]|select(.id==$i)]|length' "$REG")"
done
eq "L2 MC_MAIN_RED_LABEL stays one lib knob (BH-1770's main-red-label)" main-red-label \
  "$(jq -r '[.libs[]|select(any(.knobs[]?; .env=="MC_MAIN_RED_LABEL"))|.id]|join(",")' "$REG")"
# --- L3: no secret-shaped name, no box path, in the four libs -----------------
eq "L3 no secret/path names" "" "$(jq -r '.libs[]|select(.id|test("^(gh-budget|transcript-cost|main-red-gate|mc-queue)$"))|.knobs[].env
  |select(test("(TOKEN|SECRET|KEY|PASSWORD|PAT)$") or .=="HARNESS")' "$REG")"
# --- L4/L5: _lib.json and lane-gate.sh untouched ------------------------------
# By THIS branch: compared with where it meets main, since main itself keeps
# editing both files after $BASE (BH-1770 added main-red-label to _lib.json).
# Own slice ONLY (the BH-983 A11 pattern): a later ticket that edits lane-gate.sh
# or _lib.json for its OWN work (BH-2327's per-box lane switch did) must not be
# judged by BH-1939's "untouched" rule, and a Mergify batch carries sibling PRs'
# files. So L4/L5 bite only when this branch carries BH-1939's own spec.
MB=$(git -C "$DIR" merge-base HEAD origin/main 2>/dev/null)
L45REF="${GITHUB_HEAD_REF:-$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)}"
L45OWN=0
if [ -n "$MB" ]; then
  # pr-scoped: ok slice-gated: inert unless this branch carries BH-1939's own slice
  L45FILES=$(git -C "$DIR" diff --name-only "$MB" HEAD 2>/dev/null)
  grep -qE '^\.harness/specs/BH-1939/' <<<"$L45FILES" && L45OWN=1
fi
case "$L45REF" in mergify/merge-queue/*) L45OWN=0 ;; esac
if [ -n "$MB" ] && [ "$L45OWN" = 0 ]; then
  echo "SKIP (scoped): L4/L5 judge only BH-1939's own branch; this diff is another ticket's"
elif [ -n "$MB" ]; then
  # pr-scoped: ok slice-gated: inert unless this branch carries BH-1939's own slice
  git -C "$DIR" diff --quiet "$MB" -- catalog/lanes.d/_lib.json && ok || bad "L4 catalog/lanes.d/_lib.json was edited"
  # pr-scoped: ok slice-gated: inert unless this branch carries BH-1939's own slice
  git -C "$DIR" diff --quiet "$MB" -- bin/lib/lane-gate.sh && ok || bad "L5 bin/lib/lane-gate.sh was edited"
else
  echo "SKIP (not a pass): L4/L5, no origin/main in this clone to diff the branch against"
fi

echo "config-slice-cost-mc: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
