#!/bin/bash
# tests/run-build-blocked-artifact.bh-531-test.sh — the `blocking artifact body`
# block of bin/run-build.sh's _job_finish, extracted VERBATIM and driven (BH-531).
#
# WHAT IS ACTUALLY BROKEN, and why this is the block that fixes it. A build that
# ends PLAN_BLOCKED writes its questions into $BUILD/plan.md and records ONE
# LINE — `PLAN_BLOCKED /root/harness/builds/<x>/plan.md` — as the job's `result`
# artifact. On a pool machine that path dies with the machine, so the watcher
# box stages a RESULT pointing into a host that no longer exists and the client
# never sees the questions. The fix is to hand the BODY to the ledger before the
# result row goes up.
#
# THREE PROPERTIES, none of them greppable:
#   1. the three blocking terminals each hand over the RIGHT file, source and
#      stage, and they do it BEFORE the result artifact is recorded (a body that
#      lands after the row can be missed by the very next triage tick);
#   2. nothing else hands over anything — PLAN_MALFORMED, PLAN_STALE, DECOMPOSED,
#      RESULT_UNVERIFIED, PR_CREATED and friends all share a prefix or a word
#      with the three, and a loose matcher would push a plan for a build that
#      opened a PR;
#   3. it is fail-open: no file, an empty file, or no bin/transcript-push.sh at
#      all, and the block does nothing and still returns 0 — _job_finish is an
#      EXIT trap and must never be the reason a build's close-out is lost.
# Run from anywhere: tests/run-build-blocked-artifact.bh-531-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

BUILD="$T/b"; HARNESS="$T/h"
mkdir -p "$BUILD" "$HARNESS/bin" "$HARNESS/logs"
SINK="$T/sink.txt"

# --- the block, lifted verbatim ----------------------------------------------
# Column-1 markers, same helper as tests/run-build-checkpoint-test.sh.
awk 'index($0,"# >>> blocking artifact body")==1{f=1;next}
     index($0,"# <<< blocking artifact body")==1{exit} f' \
  "$RB_ALL" > "$T/blk.sh"
[ -s "$T/blk.sh" ] \
  && ok || bad "could not extract the 'blocking artifact body' block from bin/run-build.sh — markers missing?"
bash -n "$T/blk.sh" 2>/dev/null && ok || bad "the extracted block does not parse on its own"

# It lives inside _job_finish, so it is driven inside a function: `local` is a
# runtime error at top level and $r is the caller's variable.
{ printf 'blkfn() {\n  local r="$1"\n'; cat "$T/blk.sh"
  printf '  echo "artifact-put" >> "$SINK"\n  return 0\n}\n'; } > "$T/blkfn.sh"

# The stub stands in for bin/transcript-push.sh and records exactly the three
# things this block is responsible for: the source it declared, the phase id it
# forced empty, and the arguments it passed.
cat > "$HARNESS/bin/transcript-push.sh" <<'STUB'
#!/bin/bash
printf '%s|%s|%s\n' "${TRANSCRIPT_SOURCE:-}" "${JOB_PHASE_ID:-}" "$*" >> "$SINK"
exit 0
STUB
chmod +x "$HARNESS/bin/transcript-push.sh"

drive() { # drive <result-line> [extra-env-assignment...]
  : > "$SINK"; : > "$BUILD/pipeline.log"
  ( export SINK BUILD HARNESS
    bash -c '
      set -uo pipefail
      STAMP() { echo t; }
      PROJECT=project-3; KEY=TK-77; JOB_ID=build-project-3-TK-77-1
      '"${2:-:}"'
      . "'"$T"'/blkfn.sh"
      blkfn "$1"' _ "$1" ) >/dev/null 2>&1
  echo $?
}
sink()  { cat "$SINK" 2>/dev/null; }
pushes() { grep -cv '^artifact-put$' "$SINK" 2>/dev/null || true; }

printf 'Q1: which fee does the rep set?\n' > "$BUILD/plan.md"
printf 'BLOCK: the diff has no test for the new branch\n' > "$BUILD/review.md"
printf 'decompose refused: the ticket is one change\n' > "$BUILD/decompose-run.txt"

# ══ 1. PLAN_BLOCKED hands over plan.md, as plan_md, before the result row ════
RC=$(drive "PLAN_BLOCKED $BUILD/plan.md")
[ "$RC" = 0 ] && ok || bad "the block exited $RC on a PLAN_BLOCKED result"
[ "$(sed -n 1p "$SINK")" = "plan_md||plan pipeline  $BUILD/plan.md" ] \
  && ok || bad "PLAN_BLOCKED must hand plan.md to transcript-push as source=plan_md, stage=plan, runner=pipeline, no phase id: got '$(sed -n 1p "$SINK")'"
[ "$(sed -n 2p "$SINK")" = "artifact-put" ] \
  && ok || bad "the block itself must not defer the hand-over: $(sink)"
# ...and the block SITS before the result row in the file, which the extraction
# above cannot see — it lifts the block out of its context, so ordering is a
# property of bin/run-build.sh itself. Both line numbers are required, so a
# renamed marker or a moved put fails loudly instead of comparing two blanks.
MARK=$(grep -n '^# >>> blocking artifact body$' "$RB_ALL" | head -1 | cut -d: -f1)
PUT=$(grep -n 'job_artifact_put result' "$RB_ALL" | head -1 | cut -d: -f1)
[ -n "$MARK" ] && [ -n "$PUT" ] \
  && ok || bad "could not locate both the marker (line '$MARK') and the result artifact put (line '$PUT') in bin/run-build.sh"
[ -n "$MARK" ] && [ -n "$PUT" ] && [ "$MARK" -lt "$PUT" ] \
  && ok || bad "the body must be handed over BEFORE the result row is recorded (marker line $MARK, artifact put line $PUT) — a box that reads the row on its very next tick must already be able to fetch the body"
grep -q 'handed to transcript-push.sh as plan_md' "$BUILD/pipeline.log" \
  && ok || bad "the build record must say the artifact was handed over: $(cat "$BUILD/pipeline.log")"
grep -q 'pushed' "$BUILD/pipeline.log" \
  && bad "the log line must not CLAIM a push — the push is fail-open inside transcript-push.sh" || ok

# The phase id is forced empty even when the trap inherits one, or the artifact
# lands on a real session's slot and overwrites a transcript.
RC=$(drive "PLAN_BLOCKED $BUILD/plan.md" 'JOB_PHASE_ID=77')
[ "$(sed -n 1p "$SINK")" = "plan_md||plan pipeline  $BUILD/plan.md" ] \
  && ok || bad "an ambient JOB_PHASE_ID must not reach the push: got '$(sed -n 1p "$SINK")'"

# ══ 2. REVIEW_BLOCKED hands over review.md ══════════════════════════════════
drive "REVIEW_BLOCKED $BUILD/review.md" >/dev/null
[ "$(sed -n 1p "$SINK")" = "review_md||review pipeline  $BUILD/review.md" ] \
  && ok || bad "REVIEW_BLOCKED must hand review.md over as review_md: got '$(sed -n 1p "$SINK")'"
[ "$(sed -n 2p "$SINK")" = "artifact-put" ] \
  && ok || bad "review.md must be handed over before the result artifact: $(sink)"

# ══ 3. DECOMPOSE_FAILED hands over decompose-run.txt ════════════════════════
drive "DECOMPOSE_FAILED see $BUILD/decompose-run.txt" >/dev/null
[ "$(sed -n 1p "$SINK")" = "decompose_run||decompose pipeline  $BUILD/decompose-run.txt" ] \
  && ok || bad "DECOMPOSE_FAILED must hand decompose-run.txt over as decompose_run: got '$(sed -n 1p "$SINK")'"

# ══ 4. THE NEGATIVES ════════════════════════════════════════════════════════
# Every one of these shares a prefix or a word with a blocking terminal. A
# matcher loose by one character pushes a plan for a build that opened a PR.
while IFS= read -r LINE; do
  [ -n "$LINE" ] || continue
  drive "$LINE" >/dev/null
  [ "$(pushes)" = 0 ] \
    && ok || bad "a non-blocking result must hand over nothing: '$LINE' produced $(sink)"
done <<NEG
PLAN_MALFORMED $BUILD/plan.md
PLAN_STALE $BUILD/plan.md
BUILD_DEFERRED plan session produced no output
DECOMPOSED #12,#13
RESULT_UNVERIFIED PLAN_BLOCKED $BUILD/plan.md
PR_CREATED https://github.com/o/r/pull/9 (see plan.md)
PR_MERGED https://github.com/o/r/pull/9
SECURITY_BLOCKED $BUILD/security-review.md
REFUTE_BLOCKED $BUILD/refute-review.md
NEG
drive "" >/dev/null
[ "$(pushes)" = 0 ] && ok || bad "an EMPTY result must hand over nothing: $(sink)"

# ══ 5. FAIL-OPEN: nothing to send, nothing sent, rc still 0 ═════════════════
: > "$BUILD/plan.md"
RC=$(drive "PLAN_BLOCKED $BUILD/plan.md")
[ "$RC" = 0 ] && ok || bad "an empty plan.md made the block exit $RC"
[ "$(pushes)" = 0 ] && ok || bad "an EMPTY plan.md was pushed anyway: $(sink)"
grep -q 'handed to' "$BUILD/pipeline.log" \
  && bad "the log claimed a hand-over that never happened" || ok
printf 'Q1: which fee does the rep set?\n' > "$BUILD/plan.md"

rm -f "$BUILD/review.md"
RC=$(drive "REVIEW_BLOCKED $BUILD/review.md")
[ "$RC" = 0 ] && ok || bad "a MISSING review.md made the block exit $RC"
[ "$(pushes)" = 0 ] && ok || bad "a missing review.md was pushed anyway: $(sink)"
printf 'BLOCK: the diff has no test for the new branch\n' > "$BUILD/review.md"

mv "$HARNESS/bin/transcript-push.sh" "$T/transcript-push.sh.away"
RC=$(drive "PLAN_BLOCKED $BUILD/plan.md")
[ "$RC" = 0 ] && ok || bad "a box with no bin/transcript-push.sh made the EXIT trap exit $RC — that loses the close-out"
[ "$(pushes)" = 0 ] && ok || bad "something was pushed with no pusher on the box: $(sink)"
[ "$(sed -n 1p "$SINK")" = "artifact-put" ] \
  && ok || bad "the result artifact must still be recorded when there is no pusher: $(sink)"
mv "$T/transcript-push.sh.away" "$HARNESS/bin/transcript-push.sh"

echo "run-build-blocked-artifact.bh-531-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
