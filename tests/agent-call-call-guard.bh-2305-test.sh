#!/bin/bash
# tests/agent-call-call-guard.bh-2305-test.sh — BH-2305: the K3 pre-call guard
# is ON by default for plan, preplan, execute, fix, triage, prodqa and
# lead-review, each with an explicit K in the default map, and a repeat
# identical call on each of those stages is refused rc 74 before the vendor.
#
#   A. the lib's defaults (call_guard_enabled / call_guard_max), sourced
#   B. the lane registry's documented default == the code default
#   C. the REAL bin/agent-call.sh against a fake worker `curl` and fake
#      `claude`: calls 1..K run, call K+1 is refused and never reaches the
#      vendor; with <stage>=1 the SECOND identical call is refused
#      (C8, BH-3930: review-head / lead-head refuse the second call on one
#      head's review_fp / lead_fp; a ~rereq fp is one more paid call)
#   D. run-build's `execute result` block: a call-guard refusal of the execute
#      call is BUILD_DEFERRED, not EXECUTE_EMPTY
#   E. run-build's `plan empty-output verdict` names the call-guard refusal
#
# The fake worker is the k3 suite's shape (tests/agent-call-call-guard.k3-test.sh),
# trimmed to claim/settle; the worker's own SQL is proven in worker/jobs/test.
# Run from anywhere: tests/agent-call-call-guard.bh-2305-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NEW_STAGES="plan preplan execute fix triage prodqa lead-review"
declare -A WANT_K=([plan]=3 [preplan]=2 [execute]=3 [fix]=3 [triage]=2 [prodqa]=2 [lead-review]=2
                   [review]=2 [triage-shard]=2 [mc-rereview]=5
                   [orchestrator]=6 [box-chat]=3 [greenfield]=2
                   [review-head]=1 [lead-head]=1)

# --- A. the lib's defaults ---------------------------------------------------
libq() { # libq <shell text> — run against the sourced lib with every knob unset
  ( unset CALL_GUARD CALL_GUARD_STAGES CALL_GUARD_MAX_MAP AGENT_CALL_GUARD_STAGE
    export HARNESS="$T/libh"; mkdir -p "$HARNESS"
    . "$DIR/bin/lib/call-guard.sh" || exit 9
    eval "$1" )
}
# BH-2603: the raw-claude families bin/claude-cost.sh serves are guarded too.
# BH-3930: the head-bound review stages, K=1 per head.
for s in $NEW_STAGES review triage-shard mc-rereview orchestrator box-chat greenfield review-head lead-head; do
  libq "call_guard_enabled '$s'" && ok || bad "A1 stage '$s' is not guarded by default"
  k=$(libq "call_guard_max '$s'")
  [ "$k" = "${WANT_K[$s]}" ] && ok || bad "A2 default K for '$s' is '$k', want ${WANT_K[$s]}"
done
# `orchestrator` left this list in BH-2603 (the ticket: enforce K3 on the
# orchestrator). `chat` stays: it is bin/product-cmd.sh's stage too, and the
# chat pane is guarded as the family box-chat instead.
for s in chat decompose preplan-files synth remediate repro qa plan-repair lead prodqa2 "execute " ""; do
  libq "call_guard_enabled '$s'" && bad "A3 stage '$s' is guarded by default (must not be)" || ok
done
( libq "CALL_GUARD_STAGES=review; call_guard_enabled plan" ) && bad "A4 an operator row CALL_GUARD_STAGES=review still guards plan" || ok
( libq "CALL_GUARD_STAGES=none; call_guard_enabled execute" ) && bad "A4 CALL_GUARD_STAGES=none still guards execute" || ok

# --- B. the registry documents the default the code enforces ---------------
CAT="$DIR/catalog/lanes.d/_lib.call-guard.json"
cat_st=$(jq -r '.libs[0].knobs[] | select(.env=="CALL_GUARD_STAGES") | .default' "$CAT")
cat_mm=$(jq -r '.libs[0].knobs[] | select(.env=="CALL_GUARD_MAX_MAP") | .default' "$CAT")
code_st=$(libq 'printf %s "$CALL_GUARD_STAGES_DEFAULT"')
code_mm=$(libq 'printf %s "$CALL_GUARD_MAX_MAP_DEFAULT"')
[ -n "$code_st" ] && [ "$cat_st" = "$code_st" ] && ok || bad "B1 catalog CALL_GUARD_STAGES '$cat_st' != code '$code_st'"
[ -n "$code_mm" ] && [ "$cat_mm" = "$code_mm" ] && ok || bad "B2 catalog CALL_GUARD_MAX_MAP '$cat_mm' != code '$code_mm'"

# --- C. the production entry point: bin/agent-call.sh -----------------------
mkdir -p "$T/bin/lib/jobs" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state"
mrs_fixture "$T" testproj
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR/bin/lib/jobs/"*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$T/bin/lib/env-path.sh"
cp "$DIR/bin/billing-mode.sh" "$T/bin/billing-mode.sh"
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
echo '{"result":"the answer","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}'
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
# THE FAKE WORKER (k3's shape). Rows: call_id<TAB>project<TAB>stage<TAB>fp<TAB>status.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary) data="$2"; shift 2 ;;
    -X|-m|--connect-timeout|-w|-H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$data" in @*) data=$(cat "${data#@}") ;; esac
case "$url" in */api/call-guard/*) ;; *) exit 7 ;; esac
echo "${url##*/api/call-guard/}" >> "$CG_REQS"
touch "$CG_ROWS"
case "$url" in
  */claim)
    id=$(jq -r .call_id <<<"$data"); p=$(jq -r .project <<<"$data"); s=$(jq -r .stage <<<"$data")
    f=$(jq -r .fp <<<"$data"); m=$(jq -r .max <<<"$data")
    n=$(awk -F'\t' -v p="$p" -v s="$s" -v f="$f" '$2==p && $3==s && $4==f && ($5=="claimed"||$5=="ok"||$5=="empty"||$5=="failed"){c++} END{print c+0}' "$CG_ROWS")
    if [ "$n" -lt "$m" ]; then
      printf '%s\t%s\t%s\t%s\tclaimed\n' "$id" "$p" "$s" "$f" >> "$CG_ROWS"
      printf '{"allowed":true,"count":%s,"max":%s,"call_id":"%s"}\n200' "$((n+1))" "$m" "$id"
    else
      printf '%s\t%s\t%s\t%s\trefused\n' "$id" "$p" "$s" "$f" >> "$CG_ROWS"
      printf '{"allowed":false,"count":%s,"max":%s,"call_id":"%s","top":[{"fp":"%s","paid":%s,"refused":1}]}\n200' "$n" "$m" "$id" "$f" "$n"
    fi ;;
  */settle)
    id=$(jq -r .call_id <<<"$data"); o=$(jq -r .outcome <<<"$data")
    awk -F'\t' -v OFS='\t' -v id="$id" -v o="$o" '$1==id && $5=="claimed"{$5=o} {print}' "$CG_ROWS" > "$CG_ROWS.tmp" && mv "$CG_ROWS.tmp" "$CG_ROWS"
    printf '{"settled":true}\n200' ;;
  *) printf '{"error":"unknown endpoint","worker":"harness-jobs"}\n404' ;;
esac
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh

ROWS="$T/cg.rows"
reset() { : > "$T/order"; : > "$ROWS"; : > "$T/cg.reqs"; rm -f "$T/logs/"* "$T"/flags/alerted-* 2>/dev/null; }
# call <out-name> <stage> <prompt> [VAR=VAL ...] -> prints the rc. A SUBSCRIPTION
# claude box, no CALL_GUARD_* knob set, the stage's runner pinned to claude.
call() {
  local out="$1" stage="$2" prompt="$3" su; shift 3
  su=$(printf '%s' "$stage" | tr '[:lower:]' '[:upper:]' | tr -c '[:alnum:]_' '_')
  ( unset AGENT_CALL_GUARD_STAGE AGENT_CALL_TICKET AGENT_CALL_GUARD_FORCE HARNESS_TICKET \
          CALL_GUARD CALL_GUARD_STAGES CALL_GUARD_MAX_MAP CALL_GUARD_FAIL_CLOSED_METERED
    export ORDER_SINK="$T/order" CG_ROWS="$ROWS" CG_REQS="$T/cg.reqs" \
           PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           JOBS_URL="https://jobs.test" HARNESS_SECRET="test-secret" JOBS_RETRIES=0 JOBS_BOX=testbox \
           CLAUDE_CODE_OAUTH_TOKEN=tok ANTHROPIC_API_KEY= \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= ACCOUNT_ROUTING=0 \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 \
           AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 "RUNNER_$su=claude" "RUNNER_${su}_FALLBACK=" \
           LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" "$@"
    cd "$T" && bash "$DIR/bin/agent-call.sh" "$stage" testproj claude-fable-5-1 60 "$T/$out" "$prompt" \
      >/dev/null 2>&1 )
  echo $?
}
vendor_calls() { grep -c . "$T/order" 2>/dev/null || true; }

for s in $NEW_STAGES; do
  K=${WANT_K[$s]}; FP="bh2305:$s:work-1"
  reset; rcs=""
  for i in $(seq 1 "$K"); do rcs="$rcs $(call "c-$s-$i" "$s" "same $s prompt" AGENT_CALL_FP="$FP")"; done
  last=$(call "c-$s-over" "$s" "same $s prompt" AGENT_CALL_FP="$FP")
  want=""; for i in $(seq 1 "$K"); do want="$want 0"; done
  [ "$rcs" = "$want" ] && ok || bad "C1[$s] calls 1..$K rcs '$rcs', want '$want'"
  [ "$last" = 74 ] && ok || bad "C2[$s] call $((K+1)) under the default K=$K rc=$last, want 74"
  [ "$(vendor_calls)" = "$K" ] && ok || bad "C3[$s] vendor reached $(vendor_calls) times, want $K"
  head -1 "$T/c-$s-over" 2>/dev/null | grep -q "^AGENT_CALL_REFUSED call-guard repeat $s " && ok \
    || bad "C4[$s] refusal marker: '$(head -1 "$T/c-$s-over" 2>/dev/null)'"
  # the ticket's literal sentence: with the stage capped at 1, the SECOND identical call is refused
  reset
  r1=$(call "k1-$s-1" "$s" "second $s" AGENT_CALL_FP="$FP" CALL_GUARD_MAX_MAP="$s=1")
  r2=$(call "k1-$s-2" "$s" "second $s" AGENT_CALL_FP="$FP" CALL_GUARD_MAX_MAP="$s=1")
  [ "$r1" = 0 ] && [ "$r2" = 74 ] && [ "$(vendor_calls)" = 1 ] && ok \
    || bad "C5[$s] with $s=1: rcs $r1 $r2 vendor $(vendor_calls), want 0 74 1"
done
# C-neg: an unnamed stage stays unguarded — the worker is never asked
reset
for i in 1 2 3; do n[$i]=$(call "neg$i" chat "same chat"); done
[ "${n[*]}" = "0 0 0" ] && [ "$(vendor_calls)" = 3 ] && ok || bad "C6 chat was refused: rcs ${n[*]} vendor $(vendor_calls)"
grep -q claim "$T/cg.reqs" && bad "C7 an unguarded stage asked the worker for a claim: $(cat "$T/cg.reqs")" || ok
# C-head (BH-3930): a review lane naming review-head / lead-head with the shared
# per-head fp from bin/lib/review-bought.sh buys ONE review per head under the
# default map; a named ~reason fp is its own key, so one more paid call.
SHA=0123456789abcdef0123456789abcdef01234567
for g in review-head lead-head; do
  p=${g%-head}
  fp=$( . "$DIR/bin/lib/review-bought.sh" && "${p}_fp" o/r 7 "$SHA" )
  fpr=$( . "$DIR/bin/lib/review-bought.sh" && "${p}_fp" o/r 7 "$SHA" rereq )
  reset
  h1=$(call "h-$g-1" review "head $g" AGENT_CALL_GUARD_STAGE="$g" AGENT_CALL_FP="$fp")
  h2=$(call "h-$g-2" review "head $g" AGENT_CALL_GUARD_STAGE="$g" AGENT_CALL_FP="$fp")
  h3=$(call "h-$g-3" review "head $g" AGENT_CALL_GUARD_STAGE="$g" AGENT_CALL_FP="$fpr")
  [ "$h1 $h2 $h3" = "0 74 0" ] && [ "$(vendor_calls)" = 2 ] && ok \
    || bad "C8[$g] fp '$fp' then ~rereq: rcs $h1 $h2 $h3 vendor $(vendor_calls), want 0 74 0 and 2"
  head -1 "$T/h-$g-2" 2>/dev/null | grep -q "^AGENT_CALL_REFUSED call-guard repeat $g " && ok \
    || bad "C8[$g] refusal marker: '$(head -1 "$T/h-$g-2" 2>/dev/null)'"
done

# --- D. run-build: a refused execute call is a deferral ----------------------
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
cut_block() { awk -v n="$1" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' "$RB_ALL" > "$2"; }
cut_block "execute result" "$T/exec.sh"
cut_block "plan empty-output verdict" "$T/plan.sh"
[ -s "$T/exec.sh" ] && [ -s "$T/plan.sh" ] && ok || bad "D0 could not extract the run-build blocks"
W="$T/wt"; mkdir -p "$W"
( cd "$W" && git init -q -b main . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base \
  && git checkout -qb ticket/x ) || bad "D0 scratch repo"
drive_exec() { # drive_exec <execute-run.txt first line> -> sets D_RC, D_RESULT
  local B="$T/b-exec"; scratch_rm "$B"; mkdir -p "$B"
  printf '%s\nmore text\n' "$1" > "$B/execute-run.txt"
  ( PROJECT=p; KEY=BH-1; BASE=main; BRANCH=ticket/x; BUILD="$B"
    STAMP() { echo now; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }
    CKPT_STOP() { :; }; CKPT_NONWIP_COUNT() { echo 0; }; CKPT_WIP_COUNT() { echo 0; }
    CKPT_SQUASH_WIP() { :; }; CKPT_SQUASH_REFUSED() { :; }; STAGE_LANE_DEFER() { :; }
    cd "$W" || exit 9
    . "$T/exec.sh"; exit 0 )
  D_RC=$?; D_RESULT=$(cat "$B/RESULT" 2>/dev/null)
}
drive_exec "AGENT_CALL_REFUSED call-guard repeat execute paid=3/3 fp=x"
[ "$D_RC" = 3 ] && ok || bad "D1 refused execute exited $D_RC, want 3"
case "$D_RESULT" in "BUILD_DEFERRED execute refused by the call-guard"*AGENT_CALL_REFUSED*) ok ;; *) bad "D1 RESULT '$D_RESULT'" ;; esac
drive_exec "I looked at the plan and changed nothing."
[ "$D_RC" = 5 ] && case "$D_RESULT" in EXECUTE_EMPTY*) true ;; *) false ;; esac && ok \
  || bad "D2 a genuine empty execute: rc $D_RC RESULT '$D_RESULT', want 5 EXECUTE_EMPTY"
drive_exec "AGENT_CALL_REFUSED llm-gate paused"
[ "$D_RC" = 5 ] && case "$D_RESULT" in EXECUTE_EMPTY*) true ;; *) false ;; esac && ok \
  || bad "D3 a non-call-guard refusal was read as the call-guard: rc $D_RC RESULT '$D_RESULT'"

# --- E. run-build: the empty-plan verdict names the call-guard ---------------
drive_plan() { # drive_plan [plan-run.txt first line] -> sets E_RC, E_RESULT
  local B="$T/b-plan"; scratch_rm "$B"; mkdir -p "$B"
  [ -n "${1:-}" ] && printf '%s\n' "$1" > "$B/plan-run.txt"
  ( BUILD="$B"; BB() { :; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }
    . "$T/plan.sh"; exit 0 )
  E_RC=$?; E_RESULT=$(cat "$B/RESULT" 2>/dev/null)
}
drive_plan "AGENT_CALL_REFUSED call-guard repeat plan paid=3/3 fp=y"
[ "$E_RC" = 3 ] && case "$E_RESULT" in "BUILD_DEFERRED "*call-guard*) true ;; *) false ;; esac && ok \
  || bad "E1 refused plan: rc $E_RC RESULT '$E_RESULT', want 3 BUILD_DEFERRED naming the call-guard"
drive_plan ""
[ "$E_RC" = 3 ] && [ "$E_RESULT" = "BUILD_DEFERRED plan session produced no output" ] && ok \
  || bad "E2 no refusal: rc $E_RC RESULT '$E_RESULT'"

echo "agent-call-call-guard.bh-2305: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
