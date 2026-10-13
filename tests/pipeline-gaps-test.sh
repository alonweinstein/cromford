#!/bin/bash
# tests/pipeline-gaps-test.sh — the dead gap between the execute push and the
# review, and the STAGE-TIMING lines that prove it is gone.
#
# What changed, and therefore what has to be pinned here. The E2E preview smoke
# ran to completion BEFORE the first lens was launched: measured on real builds,
# 2m36s (project-4 TK-1273), 3m15s (project-3 TK-131) and 5m01s (project-3 TK-53) of a pipeline
# doing nothing but waiting for Vercel to build a preview and a browser to load
# it. Nothing the lenses do depends on its verdict — it never blocks, and its
# only consequence is a tier demotion that fires long after — so it now runs as
# a read-only LANE beside the review and is JOINED before the fix round.
#
# WHY DRIVEN AND NOT GREPPED. `grep -q GATES_PARALLEL bin/run-build.sh` passes
# just as happily on a version that launches the lane and then never collects
# it, or that collects it AFTER a fix round has already rewritten the tree the
# lane was reading, or that quietly drops E2E_VERDICT so the tier demoter below
# stops seeing a failed smoke. What is under test is the ordering: that the lane
# really does overlap the review, that it really is joined before the first
# commit-producing stage, that its verdict reaches the parent shell, and that
# GATES_PARALLEL=0 reproduces the order every build in this fleet has taken.
#
# The blocks are extracted VERBATIM from bin/run-build.sh by their markers, so a
# regression in the real lines fails here rather than in a paraphrase.
# Run from anywhere: tests/pipeline-gaps-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/bin" "$T/logs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

awk '/^# >>> stage timing/{f=1;next} /^# <<< stage timing/{exit} f' \
  "$RB_ALL" > "$T/timing.sh"
[ -s "$T/timing.sh" ] && ok || bad "could not extract the stage-timing block — markers missing?"
awk '/^# >>> e2e smoke/{f=1;next} /^# <<< e2e smoke/{exit} f' \
  "$RB_ALL" > "$T/e2e.sh"
[ -s "$T/e2e.sh" ] && ok || bad "could not extract the e2e-smoke block — markers missing?"
grep -q 'GATES_PARALLEL' "$T/e2e.sh" \
  && ok || bad "the extracted block carries no GATES_PARALLEL switch — wrong markers, or the switch is missing"
grep -q 'GATES_JOIN' "$T/e2e.sh" \
  && ok || bad "the extracted block defines no joiner — a lane nobody collects is a lane"

# vercel.conf decides whether this project can have a preview at all; without a
# row the stage skips before touching the network and this test would prove
# nothing about the lane.
printf 'p\tsomeproj\n' > "$T/vercel.conf"

# The stubbed smoke. It records when it STARTED and when it FINISHED, so overlap
# is a fact in the log rather than a wall-clock guess.
cat > "$T/bin/e2e-smoke.sh" <<'STUB'
#!/bin/bash
printf "%s e2e-start\n" "$(date +%s)" >> "$ORDER"
sleep "${E2E_SLEEP:-3}"
{ echo "loaded / on the preview"
  echo "E2E COVERAGE: routes=1 failed=0"
  echo "E2E: ${E2E_STUB_LINE:-PASS}"; } > "$4/e2e.md"
printf "%s e2e-end\n" "$(date +%s)" >> "$ORDER"
exit "${E2E_STUB_RC:-0}"
STUB
chmod +x "$T/bin/e2e-smoke.sh"

# The block sources both contract libs out of $HARNESS/bin/lib, and $HARNESS is
# $T here. Without them the block takes its fail-open paths and sections 11-13
# would be measuring the fallback instead of the cap.
mkdir -p "$T/bin/lib"
cp "$DIR/bin/lib/e2e-ui-paths.sh" "$DIR/bin/lib/e2e-join.sh" "$T/bin/lib/"

# The `gh` the late settle reaches for. It records the verb and the URL on one
# line and the --body text after it, so "exactly one comment per run" is a line
# count and not a guess. GH_STUB_RC makes it fail the way a rate-limited gh
# does, because a comment that could not be sent must not change what the build
# recorded.
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
printf '%s %s %s\n' "$1" "$2" "$3" >> "$GH_LOG"
prev=""; body=""
for a in "$@"; do [ "$prev" = "--body" ] && body="$a"; prev="$a"; done
printf '%s\n' "$body" >> "$GH_LOG"
[ "${GH_STUB_RC:-0}" = 0 ] || { echo "gh: stubbed failure" >&2; exit "$GH_STUB_RC"; }
STUB
chmod +x "$T/bin/gh"

# A real repo with a real remote: the stage pushes the branch, because a preview
# is Vercel's response to a pushed branch and a stage that refused to push could
# only ever record SKIP.
REPO="$T/repo"
git init -q --bare "$T/remote"
( mkdir -p "$REPO" && cd "$REPO" || exit 1
  git init -q -b main
  git config user.email t@example.com; git config user.name tester
  echo base > README.md
  git add -A; git -c commit.gpgsign=false commit -qm base
  git remote add origin "$T/remote"
  git push -q origin main
  git checkout -q -b feat
  mkdir -p app; echo 'export default function P(){return null}' > app/page.tsx
  git add -A; git -c commit.gpgsign=false commit -qm work ) >/dev/null 2>&1

# The driver. It stands in for the stages either side of the lane: a "lens"
# stage that takes time, the join, and a "fix round" — the first stage in the
# real pipeline that writes to the tree, and therefore the deadline the lane
# has to land before.
run() { # run <env assignments...>
  rm -rf "$T/build"; mkdir -p "$T/build"
  : > "$T/order.log"; : > "$T/fix-prompt.txt"; : > "$T/alerts.log"; : > "$T/gh.log"
  : > "$T/lane-pid.txt"; : > "$T/late-verdict.txt"
  ( cd "$REPO" || exit 1
    env HARNESS="$T" BUILD="$T/build" ALERTS="$T/alerts.log" \
        PROJECT=p KEY=K BASE=main BRANCH=feat GATES_NOTE="" \
        ORDER="$T/order.log" OUTDIR="$T" \
        PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" \
        E2E_SLEEP="${E2E_SLEEP:-4}" LENS_SLEEP="${LENS_SLEEP:-2}" \
        "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      track_pushed() { :; }
      # BH-2504: the pipeline pushes through RB_PUSH (bin/lib/rb/gates.sh ->
      # bin/lib/hold-push.sh). This suite is about the stage timing, so the
      # push is the plain one the block made before the hold read existed.
      RB_PUSH() { git push -q -u origin "$BRANCH"; }
      . "$1"
      . "$2"
      # Stands in for job_beat_start: a background child of THIS shell that
      # outlives the lane. The join may never wait on it.
      [ "${BEATER:-0}" = 1 ] && { sleep 60 & }
      # What the REVIEWER is handed, captured at the moment the lenses launch.
      printf "%s" "$GATES_NOTE" > "$OUTDIR/note-at-review.txt"
      printf "%s lens-start\n" "$(date +%s)" >> "$ORDER"
      sleep "$LENS_SLEEP"
      printf "%s lens-end\n" "$(date +%s)" >> "$ORDER"
      GATES_JOIN
      printf "%s join-done e2e=%s\n" "$(date +%s)" "${E2E_VERDICT:-none}" >> "$ORDER"
      # The first stage that writes to the tree.
      printf "%s fix-start\n" "$(date +%s)" >> "$ORDER"
      printf "%s" "${GATES_ASYNC_FINDINGS:-}" > "$OUTDIR/fix-prompt.txt"
      printf "%s" "$GATES_NOTE" > "$OUTDIR/note-after-join.txt"
      # Calling it twice must be free, because three different call sites in the
      # lens block reach it and only the first may pay the wait.
      GATES_JOIN
      printf "%s second-join\n" "$(date +%s)" >> "$ORDER"
      # Everything from here stands in for the stretch between the fix round and
      # the tier decision: the PR is open, and a lane that was capped at the join
      # is settled one line above the demoter. LATE_AFTER is how long the build
      # spent in there, so LATE_AFTER=0 is the lane that never landed at all.
      printf "%s" "${E2E_PID:-}" > "$OUTDIR/lane-pid.txt"
      [ -n "${LATE_AFTER:-}" ] && sleep "$LATE_AFTER"
      # gates.json exactly as run-build.sh writes it one line above gh pr create:
      # with the verdict AS IT STANDS AT THE CAP. bin/evidence-summary.sh reads
      # this field, and the evidence block is rendered again after the tier
      # decision, so a late verdict that never reaches it leaves a PR whose
      # table and whose e2e.md disagree.
      printf "{\"tamper\":\"0\",\"repro\":\"0\",\"intent\":\"0\",\"e2e\":\"%s\",\"migration\":\"none\"}\n" \
        "${E2E_VERDICT:-not-run}" > "$BUILD/gates.json"
      PR_URL=https://x/pull/1
      E2E_LATE_SETTLE
      printf "%s" "${E2E_VERDICT:-none}" > "$OUTDIR/late-verdict.txt"
      # Called twice on purpose: it is one line in a script that a resumed build
      # can re-enter, and a second comment on the same PR is not free.
      E2E_LATE_SETTLE
      # A lane killed mid-flight leaves no rc file. That is "could not run",
      # never a pass.
      rm -f "$BUILD/e2e-rc"; GATES_NOTE=""; E2E_SETTLE
      printf "%s" "${E2E_VERDICT:-none}" > "$OUTDIR/norc-verdict.txt"
    ' _ "$T/timing.sh" "$T/e2e.sh" >/dev/null 2>&1 )
  # Every verdict this run settled on, collected for the vocabulary check at the
  # end: the one the join reached, the one the late settle reached, and the one a
  # missing rc file produces. gates.json, bin/evidence-summary.sh, the tier
  # demoter and bin/merge-sweep.sh all read this word, so a new one is a silent
  # break rather than a test failure.
  awk '$2=="join-done"{sub(/^e2e=/,"",$3); print $3}' "$T/order.log" >> "$T/verdicts.log"
  for f in late-verdict norc-verdict; do
    [ -s "$T/$f.txt" ] && printf '%s\n' "$(cat "$T/$f.txt")" >> "$T/verdicts.log"
  done
}
order() { awk '{print $2}' "$T/order.log" | paste -sd, -; }
at()    { awk -v w="$1" '$2==w{print NR; exit}' "$T/order.log"; }
# Both events happened AND the first one happened first. An event that never
# happened must fail the assertion, not compare as 0.
before() { local x y; x=$(at "$1"); y=$(at "$2")
           [ -n "$x" ] && [ -n "$y" ] && [ "$x" -lt "$y" ]; }
: > "$T/verdicts.log"

# ============================================================================
# 1. DEFAULT ON: the smoke overlaps the review instead of preceding it
# ============================================================================
run
grep -q 'e2e-start' "$T/order.log" && ok || bad "the smoke never ran at all: $(order)"
[ "$(at lens-start)" -lt "$(at e2e-end)" ] \
  && ok || bad "the review did not start until the smoke had finished — the gap is still there: $(order)"
# THE PROPERTY, stated as the pipeline cares about it: an instant existed when
# both were running. Anything weaker passes on a lane launched and immediately
# waited on.
[ "$(at e2e-start)" -lt "$(at lens-end)" ] \
  && ok || bad "no instant existed when the smoke and the review were both running: $(order)"
# ...and the smoke is deliberately the SLOWER of the two here, so the join has
# to really wait. A join that returned early would leave e2e-end after fix-start
# and the row below would catch it, but this says the wait itself happened.
[ "$(at lens-end)" -lt "$(at e2e-end)" ] \
  && ok || bad "the review outlasted the smoke — this row proves nothing about the join: $(order)"

# ============================================================================
# 2. THE JOIN: the lane lands before anything writes to the tree
# ============================================================================
[ "$(at e2e-end)" -lt "$(at fix-start)" ] \
  && ok || bad "the fix round began with the lane still running — it was reading the tree the fix rewrites: $(order)"
grep -q 'join-done e2e=pass' "$T/order.log" \
  && ok || bad "E2E_VERDICT did not reach the parent shell after the join: $(order)"
# The evidence block and the tier demoter read E2E_VERDICT out of the parent,
# so a lane whose verdict stayed in the subshell is a demoter that stopped
# firing — silently, which is the worst shape this pipeline has.
grep -q 'E2E SMOKE: the preview deployment was loaded' "$T/note-after-join.txt" \
  && ok || bad "the real E2E note never reached GATES_NOTE after the join"
# Idempotent: the second join costs nothing and cannot hang.
grep -q 'second-join' "$T/order.log" && ok || bad "a second GATES_JOIN did not return: $(order)"

# ============================================================================
# 3. THE REVIEWER IS TOLD. A lens that sees no E2E line must not read that as
#    a pass — the rule every SKIP in run-build.sh is written to.
# ============================================================================
grep -qi 'RUNNING RIGHT NOW' "$T/note-at-review.txt" \
  && ok || bad "the review prompt does not say the smoke is still running"
grep -qi 'NOT a pass' "$T/note-at-review.txt" \
  && ok || bad "the review prompt lets an absent E2E verdict read as a pass"
grep -qi 'do not wait for it' "$T/note-at-review.txt" \
  && ok || bad "the reviewer is not told to proceed without the smoke"

# ============================================================================
# 4. A FAILING SMOKE reaches the fix round the lenses share
# ============================================================================
run E2E_STUB_RC=4 E2E_STUB_LINE=FAIL
grep -q 'join-done e2e=fail' "$T/order.log" \
  && ok || bad "a failed smoke did not settle as fail: $(order)"
grep -qi 'E2E SMOKE FAILED' "$T/fix-prompt.txt" \
  && ok || bad "a failed smoke never reached the fix round: '$(cat "$T/fix-prompt.txt")'"
grep -q 'e2e.md' "$T/fix-prompt.txt" \
  && ok || bad "the fix round is told a route failed but not where the evidence is"
# ...and a smoke that PASSED adds nothing. A fix prompt that grows a paragraph
# on every build is a fix prompt nobody reads.
run
[ ! -s "$T/fix-prompt.txt" ] \
  && ok || bad "a passing smoke wrote itself into the fix round: '$(cat "$T/fix-prompt.txt")'"
# Same for a SKIP, which is the common case: no Vercel lane, no UI in the diff.
run E2E_STUB_RC=3 E2E_STUB_LINE=SKIP
[ ! -s "$T/fix-prompt.txt" ] \
  && ok || bad "a skipped smoke wrote itself into the fix round: '$(cat "$T/fix-prompt.txt")'"

# ============================================================================
# 5. NO BARE `wait`. run-build.sh owns job_beat_start's heartbeat child, which
#    never exits; a bare wait in the join would hang every build until the
#    claim timed out.
# ============================================================================
HANG0=$(date +%s)
run BEATER=1
HANGD=$(( $(date +%s) - HANG0 ))
grep -q 'second-join' "$T/order.log" \
  && ok || bad "the join did not complete with a long-lived background sibling: $(order)"
[ "$HANGD" -lt 30 ] \
  && ok || bad "the join waited on a background sibling it does not own (${HANGD}s — a bare 'wait'?)"

# ============================================================================
# 6. A LANE THAT LEFT NO ANSWER is "could not run", never a pass
# ============================================================================
[ "$(cat "$T/norc-verdict.txt")" = skip ] \
  && ok || bad "a missing rc file settled as '$(cat "$T/norc-verdict.txt")' instead of skip"

# ============================================================================
# 7. GATES_PARALLEL=0 IS TODAY'S ORDER, VERBATIM
# ============================================================================
run GATES_PARALLEL=0
[ "$(at e2e-end)" -lt "$(at lens-start)" ] \
  && ok || bad "the kill flag did not restore the serial order: $(order)"
# The reviewer gets the REAL verdict in their prompt, as they always did —
# not the "still running" placeholder.
grep -q 'E2E SMOKE: the preview deployment was loaded' "$T/note-at-review.txt" \
  && ok || bad "with the flag off the reviewer did not get the real E2E note"
grep -qi 'RUNNING RIGHT NOW' "$T/note-at-review.txt" \
  && bad "with the flag off the reviewer was told the smoke is still running" || ok
# ...and nothing is fed to the fix round, even on a failure: that is the note
# the reviewer already read, and today's flow never wrote it into a fix prompt.
run GATES_PARALLEL=0 E2E_STUB_RC=4 E2E_STUB_LINE=FAIL
[ ! -s "$T/fix-prompt.txt" ] \
  && ok || bad "the kill flag still fed the fix round: '$(cat "$T/fix-prompt.txt")'"
grep -q 'join-done e2e=fail' "$T/order.log" \
  && ok || bad "with the flag off the verdict is still E2E's own: $(order)"

# ============================================================================
# 8. THE SWITCH IS READ THE WAY PEOPLE WRITE IT — and defaults ON, so a typo
#    falls back to ON rather than silently taking the old serial path.
# ============================================================================
for V in 1 true yes on; do
  run "GATES_PARALLEL=$V"
  [ "$(at lens-start)" -lt "$(at e2e-end)" ] || bad "GATES_PARALLEL=$V did not run the lane: $(order)"
done
ok
for V in 0 false no off; do
  run "GATES_PARALLEL=$V"
  [ "$(at e2e-end)" -lt "$(at lens-start)" ] || bad "GATES_PARALLEL=$V did not restore the serial order: $(order)"
done
ok
run GATES_PARALLEL=maybe
[ "$(at lens-start)" -lt "$(at e2e-end)" ] \
  && ok || bad "an unrecognised GATES_PARALLEL took the serial path instead of the default: $(order)"
grep -q "GATES_PARALLEL='maybe'" "$T/alerts.log" \
  && ok || bad "an unrecognised GATES_PARALLEL value was accepted silently"

# ============================================================================
# 9. STAGE-TIMING: the win has to be measurable on the next real build
# ============================================================================
run
grep -qE 'STAGE-TIMING e2e start=[0-9]+ end=[0-9]+ secs=[0-9]+' "$T/build/pipeline.log" \
  && ok || bad "no STAGE-TIMING line for the e2e stage: $(grep -c . "$T/build/pipeline.log") log lines"
SECS=$(sed -n 's/.*STAGE-TIMING e2e .*secs=\([0-9]*\).*/\1/p' "$T/build/pipeline.log" | tail -1)
[ "${SECS:-0}" -ge 3 ] \
  && ok || bad "the e2e stage timed ${SECS:-?}s for a 4s stage — the numbers are not real"
# Its own kill flag, separate from GATES_PARALLEL on purpose: turning the
# reorder off must not also blind the comparison that judges it.
run STAGE_TIMING=0
grep -q 'STAGE-TIMING' "$T/build/pipeline.log" \
  && bad "STAGE_TIMING=0 still wrote timing lines" || ok
run STAGE_TIMING=0 GATES_PARALLEL=0
grep -q 'STAGE-TIMING' "$T/build/pipeline.log" \
  && bad "both kill flags set and the log still differs from today's" || ok

# ============================================================================
# 10. THE ORDER IN THE REAL FILE. The driver above proves the block behaves;
#     these prove bin/run-build.sh calls it in the right places, which no
#     extracted block can see.
# ============================================================================
SCRIPT="$RB_ALL"
LENS_JOIN=$(awk '/^# >>> review lenses/{f=1} f && /GATES_JOIN/{print NR; exit}' "$SCRIPT")
LENS_FIX=$(awk '/^# >>> review lenses/{f=1} f && /CC fix /{print NR; exit}' "$SCRIPT")
{ [ -n "$LENS_JOIN" ] && [ -n "$LENS_FIX" ] && [ "$LENS_JOIN" -lt "$LENS_FIX" ]; } \
  && ok || bad "the lens block buys a fix round (line ${LENS_FIX:-?}) before joining the lane (line ${LENS_JOIN:-?})"
# Both lens flows reach it: the sequential per-lens round and the merged one.
[ "$(awk '/^# >>> review lenses/{f=1} /^# <<< review lenses/{f=0} f && /GATES_JOIN/' "$SCRIPT" | wc -l)" -ge 2 ] \
  && ok || bad "only one of the two lens flows joins the lane"
# The backstop, for a build whose lenses all hit their checkpoint and reached
# neither call site — the rebase below it rewrites the worktree the lane reads.
BACK_JOIN=$(awk '/^# <<< review lenses/{f=1} f && /^GATES_JOIN$/{print NR; exit}' "$SCRIPT")
REBASE=$(awk '/^# <<< review lenses/{f=1} f && /git rebase /{print NR; exit}' "$SCRIPT")
{ [ -n "$BACK_JOIN" ] && [ -n "$REBASE" ] && [ "$BACK_JOIN" -lt "$REBASE" ]; } \
  && ok || bad "nothing joins the lane between the lens block (${BACK_JOIN:-?}) and the rebase (${REBASE:-?})"
# The stages that can BLOCK a build stay in front of the lane: a diff that is
# about to be refused must never pay for a preview deployment, and the lane is
# only legal at all because the diff above it is immutable.
GATES_END=$(grep -n '^# <<< mechanical gates' "$SCRIPT" | cut -d: -f1)
LANE=$(grep -n '^  E2E_STAGE >/dev/null 2>&1 &$' "$SCRIPT" | cut -d: -f1)
{ [ -n "$GATES_END" ] && [ -n "$LANE" ] && [ "$GATES_END" -lt "$LANE" ]; } \
  && ok || bad "the lane is launched before the gates that can block the build (gates ${GATES_END:-?}, lane ${LANE:-?})"

# ============================================================================
# 11. THE JOIN CAP (A7). The lane stopped being in front of the review; it must
#     not become a new place to wait. A lane that outlives E2E_JOIN_MAX_S loses
#     the build's attention, and the record says STILL RUNNING — a word nothing
#     downstream can read as a pass.
# ============================================================================
run LATE_AFTER=10 E2E_JOIN_MAX_S=1 E2E_SLEEP=8
before join-done e2e-end \
  && ok || bad "the join waited out a lane that was past its cap: $(order)"
grep -q 'join-done e2e=skip' "$T/order.log" \
  && ok || bad "a capped join did not settle as skip: $(order)"
grep -q 'STILL RUNNING at the join cap' "$T/note-after-join.txt" \
  && ok || bad "after a capped join the note does not say the smoke is still running: '$(cat "$T/note-after-join.txt")'"
[ ! -s "$T/fix-prompt.txt" ] \
  && ok || bad "a capped join invented a finding for the fix round: '$(cat "$T/fix-prompt.txt")'"
grep -q 'second-join' "$T/order.log" \
  && ok || bad "a second GATES_JOIN did not return after a capped join: $(order)"
grep -q 'still running after E2E_JOIN_MAX_S=1s' "$T/build/pipeline.log" \
  && ok || bad "pipeline.log does not record the cap firing"

# ============================================================================
# 12. WHEN THERE IS NO CAP (A8). 0 is uncapped by the same convention as
#     BUILD_SLOTS=0; an unusable value falls back to 600 and SAYS so; and a box
#     whose render lost bin/lib/e2e-join.sh waits exactly as it did before.
# ============================================================================
run E2E_JOIN_MAX_S=0 E2E_SLEEP=8
before e2e-end join-done \
  && ok || bad "E2E_JOIN_MAX_S=0 capped a join that must be uncapped: $(order)"
run E2E_JOIN_MAX_S=abc E2E_SLEEP=8
grep -q "E2E_JOIN_MAX_S='abc'" "$T/alerts.log" \
  && ok || bad "an unusable E2E_JOIN_MAX_S was accepted silently"
before e2e-end join-done \
  && ok || bad "an unusable E2E_JOIN_MAX_S did not fall back to the 600 s default: $(order)"
rm -f "$T/bin/lib/e2e-join.sh"
run E2E_JOIN_MAX_S=1 E2E_SLEEP=8
before e2e-end join-done \
  && ok || bad "the join capped with bin/lib/e2e-join.sh missing — the fallback is today's wait, not a guess: $(order)"
grep -q 'e2e-join.sh' "$T/alerts.log" \
  && ok || bad "an uncapped join caused by a missing lib was not reported to ALERTS"
cp "$DIR/bin/lib/e2e-join.sh" "$T/bin/lib/"

# ============================================================================
# 13. THE LATE SETTLE (A9). A cap is a deferral, not a verdict. Whatever the
#     lane found has to reach the tier decision if it lands in time, and the
#     record has to close honestly if it does not.
# ============================================================================
run LATE_AFTER=10 E2E_JOIN_MAX_S=1 E2E_SLEEP=8 E2E_STUB_RC=4 E2E_STUB_LINE=FAIL
[ "$(cat "$T/late-verdict.txt")" = fail ] \
  && ok || bad "a FAIL that landed after the cap settled as '$(cat "$T/late-verdict.txt")' — the tier demoter below reads this variable"
[ "$(grep -c '^pr comment https://x/pull/1$' "$T/gh.log")" = 1 ] \
  && ok || bad "want exactly one PR comment for a late verdict, got $(grep -c '^pr comment' "$T/gh.log")"
grep -q 'E2E: FAIL' "$T/gh.log" \
  && ok || bad "the late comment does not carry the verdict itself"
grep -q 'join cap' "$T/gh.log" \
  && ok || bad "the late comment does not say why the review did not wait for it"
# The guard is not decoration: an absent e2e-sha makes the pattern EMPTY, and an
# empty -F pattern matches every line, so without it this row passes loudest
# exactly when the sha it is about was never written.
{ [ -s "$T/build/e2e-sha" ] && grep -qF "$(cat "$T/build/e2e-sha")" "$T/gh.log"; } \
  && ok || bad "the late comment does not name the sha the smoke actually drove (e2e-sha: '$(cat "$T/build/e2e-sha" 2>/dev/null)')"
# ...and the evidence block is rendered again AFTER the tier decision, off the
# gates.json field. A late FAIL that leaves it saying skip ships a PR whose own
# table contradicts its e2e.md.
if command -v jq >/dev/null 2>&1; then
  [ "$(jq -r .e2e "$T/build/gates.json" 2>/dev/null)" = fail ] \
    && ok || bad "gates.json says e2e='$(jq -r .e2e "$T/build/gates.json" 2>/dev/null)' after a late FAIL — bin/evidence-summary.sh renders the block from that field"
else
  echo "SKIP: no jq on this box, so the gates.json re-emit was not checked"
fi
run LATE_AFTER=0 E2E_JOIN_MAX_S=1 E2E_SLEEP=8
[ "$(cat "$T/late-verdict.txt")" = skip ] \
  && ok || bad "a lane with no answer at the tier decision settled as '$(cat "$T/late-verdict.txt")'"
[ "$(tail -1 "$T/build/e2e.md")" = "E2E: SKIP" ] \
  && ok || bad "e2e.md's last line is '$(tail -1 "$T/build/e2e.md")' — merge-sweep and the evidence block read that line"
[ ! -s "$T/gh.log" ] \
  && ok || bad "a lane that never produced a verdict still commented on the PR: '$(cat "$T/gh.log")'"
LPID=$(cat "$T/lane-pid.txt")
LN=0
while [ -n "$LPID" ] && [ "$LN" -lt 5 ] && kill -0 "$LPID" 2>/dev/null; do
  sleep 1; LN=$((LN+1))
done
{ [ -n "$LPID" ] && ! kill -0 "$LPID" 2>/dev/null; } \
  && ok || bad "the lane (pid '$LPID') was still running after the build recorded it as stopped"
# ...and the SMOKE, which is the process that actually writes the record. The
# lane is a subshell and bin/e2e-smoke.sh is its CHILD: stop the parent first and
# the child is orphaned rather than stopped, finishes on its own time and writes
# its own verdict line over the SKIP this build just recorded — after the tier
# decision, from a smoke nobody joined. E2E_SLEEP=8 here, so that write would
# land seconds after the settle: this row waits the whole window out and then
# reads the record, because a read taken earlier is right for the wrong reason.
command -v pgrep >/dev/null 2>&1 \
  && ok || bad "pgrep is missing, so this suite cannot tell a stopped smoke from an orphaned one"
SN=0
while [ "$SN" -lt 15 ] && pgrep -f "$T/bin/e2e-smoke.sh" >/dev/null 2>&1; do
  sleep 1; SN=$((SN+1))
done
pgrep -f "$T/bin/e2e-smoke.sh" >/dev/null 2>&1 \
  && bad "the smoke outlived the lane it was launched from — still running ${SN}s after the build stopped it" || ok
[ "$(tail -1 "$T/build/e2e.md")" = "E2E: SKIP" ] \
  && ok || bad "an orphaned smoke rewrote the record after the settle: e2e.md now ends '$(tail -1 "$T/build/e2e.md")'"
# ...and the real file calls it, above the demoter that reads the verdict it
# settles. The driver above proves the function behaves; only this sees whether
# bin/run-build.sh ever reaches it. Delete that one call line and a late verdict
# is computed by nobody.
LATE_CALL=$(awk '/^# <<< e2e smoke/{f=1} f && /^E2E_LATE_SETTLE$/{print NR; exit}' "$SCRIPT")
E2E_DEMOTE=$(awk '/E2E_VERDICT:-not-run}" = "fail"/{print NR; exit}' "$SCRIPT")
{ [ -n "$LATE_CALL" ] && [ -n "$E2E_DEMOTE" ] && [ "$LATE_CALL" -lt "$E2E_DEMOTE" ]; } \
  && ok || bad "the tier demoter (line ${E2E_DEMOTE:-?}) reads E2E_VERDICT without a late settle above it (line ${LATE_CALL:-?})"

# ...and the comment is a COPY of a record that is already written. A gh that
# fails the way a rate-limited one does (this box hit exactly that today) must
# leave the verdict, e2e.md and the pipeline.log line exactly as they were.
run LATE_AFTER=10 E2E_JOIN_MAX_S=1 E2E_SLEEP=8 E2E_STUB_RC=4 E2E_STUB_LINE=FAIL GH_STUB_RC=1
[ "$(cat "$T/late-verdict.txt")" = fail ] \
  && ok || bad "a gh that could not post the comment changed the recorded verdict to '$(cat "$T/late-verdict.txt")'"
grep -q 'verdict arrived after the join cap: fail' "$T/build/pipeline.log" \
  && ok || bad "the record was not written before the comment was attempted"

# ============================================================================
# 14. THE VOCABULARY. Every run above settled on one of pass/fail/skip. A new
#     word here silently breaks gates.json, bin/evidence-summary.sh, the tier
#     demoter and bin/merge-sweep.sh's E2E: FAIL refusal.
# ============================================================================
BADV=$(grep -cvE '^(pass|fail|skip)$' "$T/verdicts.log")
[ "${BADV:-0}" -eq 0 ] && [ -s "$T/verdicts.log" ] \
  && ok || bad "${BADV:-?} of $(wc -l < "$T/verdicts.log") settled verdicts are outside pass/fail/skip: $(sort -u "$T/verdicts.log" | paste -sd, -)"

echo "pipeline-gaps-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
