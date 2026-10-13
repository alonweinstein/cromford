#!/bin/bash
# tests/run-build-stage-lane.bh-1853-test.sh — a stage that ended because the
# RUNNER LANE was out is a deferral the pool reap can read, in EVERY stage
# (BH-1853 item 1), not only plan.
#
# Before this, only plan-run.txt.class reached the RESULT line. An account that
# ran out during execute wrote `EXECUTE_EMPTY no changes produced`, and one that
# ran out in a review lens or its fix round wrote `*_BLOCKED`. The reap never
# cooled or unpinned that account, and the ticket was charged a deferral. The
# blocks are lifted out of the flattened driver (tests/lib/rb-all.sh) and RUN,
# not grepped:
#   S1-S4 stage_lane_class: which sidecar lines blame the lane, and which do not
#   E1-E3c the execute result block: exhausted -> BUILD_DEFERRED (exit 3);
#          an ordinary empty execute is still EXECUTE_EMPTY (exit 5); real
#          commits are never deferred
#   E4    E1's RESULT through the REAL bin/fly-pool.sh reap: the account is
#          cooled until its reset and unpinned, deferrals unchanged
#   L1-L4 LENS_REFUSE: a lens, fix round or re-review that ran out defers
#          instead of writing *_BLOCKED; with no sidecar it still blocks
#   P1    the plan verdict keeps `exhausted=` on a long class line
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rb-all.sh" || exit 1
. "$(dirname "$0")/lib/pool-reap-fixture.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

cut_block() { # cut_block <marker> <outfile>
  awk -v n="$1" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' "$RB_ALL" > "$2"
}
cut_fn() { # cut_fn <name> — one column-0 function out of the flattened driver
  awk -v f="$1" 'index($0, f "() {")==1{p=1} p{print} p&&/^}/{exit}' "$RB_ALL"
}
cut_block "stage lane verdict"        "$T/lane.sh"
cut_block "execute result"            "$T/exec.sh"
cut_block "plan empty-output verdict" "$T/plan.sh"
{ cut_fn LENS_ART; cut_fn LENS_VARS; cut_fn LENS_REFUSE; } > "$T/lens.sh"
[ -s "$T/lane.sh" ] && ok || bad "the 'stage lane verdict' block is not in the pipeline text"
for B in exec plan lens; do [ -s "$T/$B.sh" ] && ok || bad "could not extract '$B' from the pipeline text"; done

RESET=1790000000
EXH="RUNNER_EXHAUSTED class=account-exhausted(quota) seen=account-exhausted runner=claude rc=1 exhausted=claude resets_at=$RESET"
LONGSEEN=$(printf 'real-failure,%.0s' $(seq 1 50))account-exhausted   # ~650 chars
EXH_LONG="RUNNER_EXHAUSTED class=account-exhausted(quota) seen=$LONGSEEN runner=claude rc=1 exhausted=claude resets_at=$RESET"

# DRIVE <build-dir> <script> — the driver's environment around the blocks.
DRIVE() {
  local B="$1"
  ( BUILD="$B"; PROJECT=project-5; KEY=BH-1016; BASE=main; BRANCH=ticket/bh-1016
    REVIEW_MODEL=m; FIX_MODEL=m; RISKY=1; HIGHRISK=1
    STAMP() { echo 2026-09-24T00:00:00Z; }
    RESULT() { echo "$*" > "$B/RESULT"; }
    BB() { :; }
    # shellcheck disable=SC1090
    . "$T/lane.sh"; . "$T/lens.sh"
    eval "$2" ) >/dev/null 2>&1
  echo "$? $(cat "$B/RESULT" 2>/dev/null || echo none)"
}
NB=0
fresh() { NB=$((NB+1)); B="$T/b$NB"; mkdir -p "$B"; }
cls() { printf '%s\n' "$2" > "$B/$1.class"; }  # cls <outfile-name> <line>

# ── S: stage_lane_class ───────────────────────────────────────────────────
fresh; cls execute-run.txt "$EXH"
OUT=$(DRIVE "$B" 'stage_lane_class "$BUILD/execute-run.txt" > "$BUILD/RESULT"')
[ "$OUT" = "0 $EXH" ] && ok || bad "S1: an exhausted sidecar was not reported: $OUT"
fresh; cls execute-run.txt "$EXH_LONG"
OUT=$(DRIVE "$B" 'stage_lane_class "$BUILD/execute-run.txt" > "$BUILD/RESULT"')
[[ "$OUT" == "0 "*"exhausted=claude resets_at=$RESET" ]] && ok || bad "S2: a long seen= list cut off exhausted=: $OUT"
for NEG in "RUNNER_ERROR class=unknown seen=unknown runner=claude rc=1" \
           "RUNNER_RATE_LIMITED class=rate-limited seen=rate-limited runner=claude rc=1" \
           "RUNNER_ERROR class=real-failure seen=auth,real-failure runner=claude rc=1" \
           ""; do
  fresh; cls execute-run.txt "$NEG"
  OUT=$(DRIVE "$B" 'stage_lane_class "$BUILD/execute-run.txt" > "$BUILD/RESULT"')
  [ "$OUT" = "1 " ] && ok || bad "S3: '$NEG' was read as a lane failure: $OUT"
done
fresh   # no sidecar at all, and a review body that QUOTES the token
echo "the runner said RUNNER_EXHAUSTED class=auth once" > "$B/review.md"
OUT=$(DRIVE "$B" 'stage_lane_class "$BUILD/execute-run.txt" "$BUILD/review.md" "$BUILD/review" > "$BUILD/RESULT"')
[ "$OUT" = "1 " ] && ok || bad "S3: a missing sidecar or a review body was read as a lane failure: $OUT"
fresh; cls execute-run.txt "RUNNER_ERROR class=auth(credential) seen=auth runner=claude rc=1"
OUT=$(DRIVE "$B" 'stage_lane_class "$BUILD/execute-run.txt" > "$BUILD/RESULT"')
[[ "$OUT" == "0 RUNNER_ERROR class=auth"* ]] && ok || bad "S4: class=auth was not read as a lane failure: $OUT"

# ── E: the execute result block ───────────────────────────────────────────
# EXEC <empty:1|0> <nonwip-count>
EXEC() {
  DRIVE "$B" "
    CKPT_STOP() { :; }
    git() { [ '$1' = 1 ]; }
    CKPT_NONWIP_COUNT() { echo $2; }
    CKPT_WIP_COUNT() { echo 2; }
    CKPT_SQUASH_WIP() { echo SQUASHED > \"\$BUILD/RESULT\"; }
    CKPT_SQUASH_REFUSED() { :; }
    . '$T/exec.sh'"
}
fresh; cls execute-run.txt "$EXH"
OUT=$(EXEC 1 0)
[ "$OUT" = "3 BUILD_DEFERRED execute session ended $EXH" ] && ok || bad "E1: an exhausted execute did not defer: $OUT"
E1_RESULT="${OUT#3 }"
fresh
OUT=$(EXEC 1 0)
[ "$OUT" = "5 EXECUTE_EMPTY no changes produced" ] && ok || bad "E2: an empty execute with no sidecar changed: $OUT"
fresh; cls execute-run.txt "RUNNER_ERROR class=unknown seen=unknown runner=claude rc=1"
OUT=$(EXEC 1 0)
[ "$OUT" = "5 EXECUTE_EMPTY no changes produced" ] && ok || bad "E3: class=unknown was deferred: $OUT"
fresh; cls execute-run.txt "$EXH"
OUT=$(EXEC 0 0)
[[ "$OUT" == "3 BUILD_DEFERRED execute session ended RUNNER_EXHAUSTED"* ]] && ok || bad "E3b: a checkpoint-only exhausted execute did not defer: $OUT"
fresh; cls execute-run.txt "$EXH"
OUT=$(EXEC 0 1)
[ "$OUT" = "0 SQUASHED" ] && ok || bad "E3c: an execute that committed real work was deferred: $OUT"
fresh
OUT=$(EXEC 0 0)
[[ "$OUT" == "5 EXECUTE_EMPTY the execute session committed nothing"* ]] && ok || bad "E3d: checkpoint-only with no sidecar changed: $OUT"

# ── E4: E1's RESULT through the real pool reap ────────────────────────────
prf_setup
RESET=1790000000   # prf_setup sets its own; E1's line carries this one
if [[ "$E1_RESULT" == BUILD_DEFERRED* ]]; then
  prf_reset
  write_fly_stub "m-exh=$E1_RESULT"
  machine_json m-exh BH-1016 2 max3
  prf_run_pool
  grep -qx "cooldown max3 pool-project-5-BH-1016 $RESET" "$T/acct-calls" \
    && ok || bad "E4: the reap did not cool the account until the reset ($(tr '\n' '|' < "$T/acct-calls"))"
  grep -qx "unpin project-5 BH-1016 max3" "$T/acct-calls" \
    && ok || bad "E4: the reap did not unpin the exhausted account ($(tr '\n' '|' < "$T/acct-calls"))"
  [ "$(qdef)" = 2 ] && ok || bad "E4: the ticket was charged a deferral (2 -> $(qdef))"
else
  bad "E4: E1 wrote no BUILD_DEFERRED line for the reap to read ($E1_RESULT)"
fi

# ── L: LENS_REFUSE ────────────────────────────────────────────────────────
fresh; cls security-review-run.txt "$EXH"
OUT=$(DRIVE "$B" 'LENS_REFUSE security')
[[ "$OUT" == "3 BUILD_DEFERRED security review session ended RUNNER_EXHAUSTED"* ]] && ok || bad "L1: an exhausted security lens was SECURITY_BLOCKED: $OUT"
fresh; cls fix-run.txt "$EXH"
OUT=$(DRIVE "$B" 'LENS_REFUSE review')
[[ "$OUT" == "3 BUILD_DEFERRED review review session ended RUNNER_EXHAUSTED"* ]] && ok || bad "L2: an exhausted fix round was REVIEW_BLOCKED: $OUT"
fresh; cls refute-review2-run.txt "RUNNER_ERROR class=auth(credential) seen=auth runner=claude rc=1"
OUT=$(DRIVE "$B" 'LENS_REFUSE refute')
[[ "$OUT" == "3 BUILD_DEFERRED refute review session ended RUNNER_ERROR class=auth"* ]] && ok || bad "L3: a de-authed refute re-review was REFUTE_BLOCKED: $OUT"
fresh; echo "VERDICT: BLOCK RUNNER_EXHAUSTED" > "$B/security-review.md"
OUT=$(DRIVE "$B" 'LENS_REFUSE security')
[ "$OUT" = "6 SECURITY_BLOCKED $B/security-review.md" ] && ok || bad "L4: a genuine BLOCK with no sidecar changed: $OUT"
fresh; cls review2-run.txt "$EXH"
OUT=$(DRIVE "$B" 'LENS_REFUSE refute')
[[ "$OUT" == "3 BUILD_DEFERRED refute review session ended RUNNER_EXHAUSTED"* ]] && ok || bad "L5: an exhausted merged re-review was REFUTE_BLOCKED: $OUT"

# ── P1: the plan verdict keeps exhausted= ─────────────────────────────────
fresh; : > "$B/plan.md"; cls plan-run.txt "$EXH_LONG"
OUT=$(DRIVE "$B" ". '$T/plan.sh'")
[[ "$OUT" == "3 BUILD_DEFERRED plan session ended "*"exhausted=claude resets_at=$RESET" ]] && ok || bad "P1: the plan verdict cut exhausted= off a long class line: ${OUT:0:80}…${OUT: -60}"

echo "run-build-stage-lane: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
