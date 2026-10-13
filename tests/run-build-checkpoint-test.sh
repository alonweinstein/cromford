#!/bin/bash
# tests/run-build-checkpoint-test.sh — the lane-checkpoint wiring extracted
# VERBATIM from bin/run-build.sh and driven against a real git repo + a real
# bare origin. Run from anywhere: tests/run-build-checkpoint-test.sh
#
# bin/lane-checkpoint.sh is tested next door. What is tested HERE is the WIRING,
# which is where the damage would be:
#   - a checkpoint-only branch read as "the execute stage already finished", so
#     a half-done tree sails into review as a build (the expensive failure);
#   - a checkpoint-only branch on the remote read as "the name is taken", so the
#     rebuild cuts ticket/<key>-r2 beside the work it was meant to rescue (the
#     failure this whole feature exists to end — project-5 #1156);
#   - a squash that drops the commit messages bin/test-tamper-scan.sh reads
#     TEST-CHANGE justifications out of, turning a justified test edit into a
#     blocked build;
#   - a squash that rewrites a head an approval is already bound to.
# No network, no gh, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: TERM only once the trap is armed
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HOME="$T/home"; mkdir -p "$HOME"
git config --global user.email harness@localhost >/dev/null 2>&1
git config --global user.name  harness           >/dev/null 2>&1
git config --global init.defaultBranch main      >/dev/null 2>&1
git config --global protocol.file.allow always   >/dev/null 2>&1

# A HARNESS that owns flags/ and logs/ but serves the REAL script under test.
export HARNESS="$T/h"
mkdir -p "$HARNESS/bin" "$HARNESS/flags" "$HARNESS/logs"
ln -sf "$DIR/bin/lane-checkpoint.sh" "$HARNESS/bin/lane-checkpoint.sh"
# BH-2504: a checkpoint push reads the ticket's hold first (bin/lib/hold-push.sh).
# FIXTURE: project-5 is an issues lane and its ticket is open and unheld.
. "$DIR/tests/lib/hold-fixture.sh" || exit 1
hold_fixture_libs "$DIR" "$HARNESS" || exit 1
hold_fixture_gh "$T/ghbin" || exit 1
export PATH="$T/ghbin:$PATH"
printf 'project-5 example-org/project-5 - - 2 box-ts\n' > "$T/fleet.conf"
export FLEET_CONF="$T/fleet.conf"

# --- the three blocks, lifted verbatim ---------------------------------------
cut_block() { # cut_block <marker-word...> <outfile>
  local name="$1" out="$2"
  awk -v n="$name" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' \
    "$RB_ALL" > "$out"
}
cut_block "lane checkpoints" "$T/ckpt.sh"
cut_block "checkpoint adopt" "$T/adopt.sh"
cut_block "execute result"   "$T/exec.sh"
for B in ckpt adopt exec; do
  [ -s "$T/$B.sh" ] && ok || bad "could not extract the '$B' block from bin/run-build.sh — markers missing?"
  bash -n "$T/$B.sh" 2>/dev/null && ok || bad "the extracted '$B' block does not parse on its own"
done

N=0
fresh() { # fresh — a repo on ticket/TK-1156 with a bare origin; sets WT/ORIGIN/BUILD
  N=$((N+1))
  ORIGIN="$T/origin$N.git"; WT="$T/wt$N"; BUILD="$T/build$N"
  git init --bare -q "$ORIGIN"; git init -q "$WT"; mkdir -p "$BUILD"
  printf '{"project":"project-5","ticket_id":"7","key":"TK-1156"}\n' > "$BUILD/job.json"
  ( cd "$WT"
    echo base > base.txt; git add -A >/dev/null; git commit -qm base >/dev/null
    git remote add origin "$ORIGIN"; git push -q -u origin main >/dev/null 2>&1
    git checkout -qb ticket/TK-1156 >/dev/null 2>&1 )
}
commit_in() { # commit_in <file> <subject>
  # A SEQUENCE, not $RANDOM: the content only has to DIFFER from what is on disk,
  # and two equal draws in a row would make `git commit` find nothing to commit
  # and fail the case for a reason no one would reproduce (1 in 32768).
  local n; n=$(( $(cat "$T/commit-seq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/commit-seq"
  ( cd "$WT"; echo "commit-$n" > "$1"; git add -A >/dev/null; git commit -q -m "$2" >/dev/null )
}
# The environment every extracted block is evaluated in.
DRIVE() { # DRIVE <script-text-to-run-after-sourcing-ckpt.sh>
  ( set -uo pipefail
    PROJECT=project-5; KEY=TK-1156; BASE=main; BRANCH="${BRANCH:-ticket/TK-1156}"
    BUILD="$BUILD"; WT="$WT"
    STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
    RESULT() { echo "$*" > "$BUILD/RESULT"; }
    cd "$WT" || exit 9
    # shellcheck disable=SC1090
    . "$T/ckpt.sh"
    eval "$1" )
}
plog() { cat "$BUILD/pipeline.log" 2>/dev/null; }
remote_subjects() { git -C "$ORIGIN" log --format=%s "${1:-ticket/TK-1156}" 2>/dev/null; }

# ---------- 1. the two counters tell "a tree" from "real work" ---------------
fresh
commit_in a.ts "feat: real work"
commit_in b.ts "wip: checkpoint execute 2026-09-15 10:00:00Z"
commit_in c.ts "wip: checkpoint execute-exit 2026-09-15 10:15:00Z"
[ "$(DRIVE 'CKPT_WIP_COUNT')" = 2 ]    && ok || bad "CKPT_WIP_COUNT should be 2 (got $(DRIVE 'CKPT_WIP_COUNT'))"
[ "$(DRIVE 'CKPT_NONWIP_COUNT')" = 1 ] && ok || bad "CKPT_NONWIP_COUNT should be 1 (got $(DRIVE 'CKPT_NONWIP_COUNT'))"
fresh
[ "$(DRIVE 'CKPT_WIP_COUNT')" = 0 ] && [ "$(DRIVE 'CKPT_NONWIP_COUNT')" = 0 ] \
  && ok || bad "an empty branch must count 0 and 0"

# ---------- 2. the kill switch ----------------------------------------------
fresh
DRIVE 'CKPT_ON'                     && ok || bad "checkpoints should be ON by default"
DRIVE 'CHECKPOINTS=0; CKPT_ON'      && bad "CHECKPOINTS=0 must switch checkpoints OFF" || ok
DRIVE 'CHECKPOINTS=off; CKPT_ON'    && bad "CHECKPOINTS=off must switch checkpoints OFF" || ok
touch "$HARNESS/flags/lane-checkpoints-off"
DRIVE 'CKPT_ON'                     && bad "flags/lane-checkpoints-off must switch checkpoints OFF" || ok
rm -f "$HARNESS/flags/lane-checkpoints-off"

# ---------- 3. arm / disarm, and the stage's own end checkpoint --------------
# CHECKPOINT_EVERY_MIN=9 keeps the timer from firing inside the test; what is
# asserted is that the watcher RUNS while the stage does and that CKPT_STOP both
# reaps it and saves the tree once more.
fresh
( cd "$WT"; echo half-written > feature.ts )
OUT=$(DRIVE 'CHECKPOINT_EVERY_MIN=9 CKPT_START; sleep 1; kill -0 "$CKPT_PID" 2>/dev/null && echo ALIVE; CKPT_STOP; kill -0 "$CKPT_PID" 2>/dev/null && echo STILL-ALIVE')
grep -q '^ALIVE$' <<<"$OUT"        && ok || bad "CKPT_START did not leave a live watcher (out: $OUT)"
grep -q 'STILL-ALIVE' <<<"$OUT"    && bad "CKPT_STOP left the watcher running" || ok
grep -q '^wip: checkpoint execute-end ' <<<"$(remote_subjects | head -1)" \
  && ok || bad "CKPT_STOP did not push the stage's closing checkpoint (remote: $(remote_subjects))"
grep -q 'watcher armed' <<<"$(plog)" && ok || bad "the watcher must announce itself in pipeline.log"

# ---------- 4. the exit trap: a stage that dies still saves the tree ---------
# run-build.sh's own trap line, reproduced: CKPT_ON_EXIT runs FIRST, then the
# claim cleanup and the job row close.
fresh
( cd "$WT"; echo half-written > feature.ts )
DRIVE 'trap "CKPT_ON_EXIT; echo TRAP-REST >> \"$BUILD/trap.log\"" EXIT; CHECKPOINT_EVERY_MIN=9 CKPT_START; exit 7' >/dev/null 2>&1
RC=$?
[ "$RC" = 7 ] && ok || bad "the exit trap must not change the stage's rc (got $RC)"
grep -q '^wip: checkpoint execute-exit ' <<<"$(remote_subjects | head -1)" \
  && ok || bad "a stage that died did NOT checkpoint (remote: $(remote_subjects))"
grep -q TRAP-REST "$BUILD/trap.log" 2>/dev/null && ok || bad "CKPT_ON_EXIT swallowed the rest of the EXIT trap"

# ...and it is a no-op outside the stage, so a finished build never gets an
# extra wip commit pushed on top of its own PR head.
fresh
commit_in a.ts "feat: real work"
( cd "$WT"; git push -q -u origin ticket/TK-1156 >/dev/null 2>&1; echo scratch > junk.txt )
DRIVE 'trap "CKPT_ON_EXIT" EXIT; exit 0' >/dev/null 2>&1
[ "$(remote_subjects | grep -c '^wip:')" = 0 ] \
  && ok || bad "CKPT_ON_EXIT fired outside the execute stage: $(remote_subjects)"

# ---------- 5. TERM: a reaped machine still saves the tree ------------------
# A real process, not a DRIVE subshell: `f &` forks its own shell around the
# function body, so a TERM sent to $! would kill that wrapper and never reach
# the shell holding the trap. bash also defers a trap until the foreground
# command returns, which is the production shape too (a reaped machine TERMs the
# whole group, so the agent child dies first and then the trap runs).
fresh
( cd "$WT"; echo half-written > feature.ts )
rm -f "$T/armed"
cat > "$T/term-drive.sh" <<EOF
set -uo pipefail
PROJECT=project-5; KEY=TK-1156; BASE=main; BRANCH=ticket/TK-1156
BUILD="$BUILD"; WT="$WT"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
cd "\$WT" || exit 9
. "$T/ckpt.sh"
CHECKPOINT_EVERY_MIN=9 CKPT_START
: > "$T/armed"   # BH-6049: the trap is installed; the test TERMs only after this
sleep 3   # determinism: ok this sleep IS the stage under test — the drive is SIGTERM'd mid-sleep
EOF
HARNESS="$HARNESS" bash "$T/term-drive.sh" >/dev/null 2>&1 &
DPID=$!
wait_file "$T/armed"; kill -TERM "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
grep -q '^wip: checkpoint execute-exit ' <<<"$(remote_subjects | head -1)" \
  && ok || bad "a SIGTERM'd stage did not checkpoint (remote: $(remote_subjects))"

# ---------- 6. the squash: same tree, tidy history, messages carried ---------
fresh
commit_in a.ts "wip: checkpoint execute 2026-09-15 10:00:00Z"
( cd "$WT"; echo x > b.ts; git add -A >/dev/null
  git commit -q -m "feat(x): the real commit" -m "TEST-CHANGE: the old assertion was wrong because ..." >/dev/null )
commit_in c.ts "wip: checkpoint execute-end 2026-09-15 10:30:00Z"
TREE_BEFORE=$(git -C "$WT" rev-parse HEAD^{tree})
DRIVE 'SQUASH_OK=1; CKPT_SQUASH_WIP' >/dev/null 2>&1
[ "$(git -C "$WT" rev-list --count main..HEAD)" = 1 ] \
  && ok || bad "the squash left $(git -C "$WT" rev-list --count main..HEAD) commit(s)"
[ "$(git -C "$WT" rev-parse HEAD^{tree})" = "$TREE_BEFORE" ] \
  && ok || bad "the squash CHANGED the tree — every downstream gate would see different input"
MSG=$(git -C "$WT" log -1 --format=%B)
grep -q 'feat(x): the real commit' <<<"$MSG" && ok || bad "the real subject was dropped: $MSG"
grep -q 'TEST-CHANGE: the old assertion' <<<"$MSG" && ok || bad "a TEST-CHANGE justification was dropped by the squash — test-tamper-scan would block this build: $MSG"
grep -q '^wip: checkpoint' <<<"$MSG" && bad "a wip subject survived into the squashed message" || ok
grep -q 'CHECKPOINT squash: 3 commit(s) (2 wip)' <<<"$(plog)" && ok || bad "no squash line in pipeline.log (log: $(plog))"

# 6b. nothing to do: no wip commits, or a single commit
fresh
commit_in a.ts "feat: one real commit"
B4=$(git -C "$WT" rev-parse HEAD)
DRIVE 'SQUASH_OK=1; CKPT_SQUASH_WIP' >/dev/null 2>&1
[ "$(git -C "$WT" rev-parse HEAD)" = "$B4" ] && ok || bad "the squash rewrote a branch with no wip commits"

# 6c. a branch this pipeline did not cut is never rewritten
fresh
commit_in a.ts "wip: checkpoint execute t1"
commit_in b.ts "feat: real"
B4=$(git -C "$WT" rev-parse HEAD)
DRIVE 'SQUASH_OK=0; CKPT_SQUASH_WIP' >/dev/null 2>&1
[ "$(git -C "$WT" rev-parse HEAD)" = "$B4" ] && ok || bad "SQUASH_OK=0 (a dispatcher-supplied PR head) was rewritten anyway"
DRIVE 'SQUASH_OK=1; CHECKPOINT_SQUASH=0; CKPT_SQUASH_WIP' >/dev/null 2>&1
[ "$(git -C "$WT" rev-parse HEAD)" = "$B4" ] && ok || bad "CHECKPOINT_SQUASH=0 did not switch the squash off"

# 6d. an approval bound to an ANCESTOR is never orphaned
fresh
commit_in a.ts "wip: checkpoint execute t1"
commit_in b.ts "feat: real"
git -C "$WT" rev-parse HEAD > "$BUILD/review-head"
commit_in c.ts "fix: a post-review round"
B4=$(git -C "$WT" rev-parse HEAD)
DRIVE 'SQUASH_OK=1; CKPT_SQUASH_WIP' >/dev/null 2>&1
[ "$(git -C "$WT" rev-parse HEAD)" = "$B4" ] && ok || bad "a head the reviewer is bound to below was rewritten"
grep -q 'squash skipped' <<<"$(plog)" && ok || bad "the skipped squash must say why (log: $(plog))"

# 6e. an approval bound to THIS head is carried across, like the rebase does
fresh
commit_in a.ts "wip: checkpoint execute t1"
commit_in b.ts "feat: real"
git -C "$WT" rev-parse HEAD > "$BUILD/review-head"
DRIVE 'SQUASH_OK=1; CKPT_SQUASH_WIP' >/dev/null 2>&1
[ "$(cat "$BUILD/review-head")" = "$(git -C "$WT" rev-parse HEAD)" ] \
  && ok || bad "the squash orphaned the approval instead of re-binding it to the new head"

# 6f. BH-1310: main advanced past the branch's real fork point BEFORE the
# squash runs (a box that pulled main fresh mid-build, resuming a checkpoint
# branch cut earlier). The squash must parent onto merge-base($BASE, HEAD),
# never onto the fresh $BASE tip — a soft reset never changes the TREE, so a
# wrong parent shows every file main gained since the fork as DELETED in the
# diff a reviewer or gate takes, exactly what blocked TK-2937/TK-2979.
fresh
ORIG_BASE=$(git -C "$WT" rev-parse main)
commit_in a.ts "wip: checkpoint execute 2026-09-15 10:00:00Z"
( cd "$WT"; echo y > d.ts; git add -A >/dev/null
  git commit -q -m "feat(y): the real commit" >/dev/null )
commit_in c.ts "wip: checkpoint execute-end 2026-09-15 10:30:00Z"
TREE_BEFORE=$(git -C "$WT" rev-parse HEAD^{tree})
# ...another PR merges into main while this lane is still running...
TMPCLONE="$T/tmpclone$N"; git clone -q "$ORIGIN" "$TMPCLONE"
( cd "$TMPCLONE"; git checkout -q main; mkdir -p tests
  # A path under tests/ on purpose: test-tamper-scan.sh's is_test_path() only
  # scans test-shaped paths, and TK-2937/TK-2979 were flagged over exactly this
  # shape of file (tests moved onto main by other PRs mid-build).
  echo new > tests/new-on-main-test.sh; git add -A >/dev/null
  git commit -q -m "feat: unrelated merge landed on main" >/dev/null
  git push -q origin main >/dev/null 2>&1 )
# ...and this box pulls main fresh, moving the LOCAL main ref past the point
# the checkpoint branch actually forked from (main is now a SIBLING, not an
# ancestor, of HEAD — merge-base must resolve back to the true fork point).
( cd "$WT"; git fetch -q origin main:main )
MB=$(git -C "$WT" merge-base main HEAD)
[ "$MB" = "$ORIG_BASE" ] && ok || bad "test setup: expected merge-base to stay at the fork point $ORIG_BASE, got $MB"
DRIVE 'SQUASH_OK=1; CKPT_SQUASH_WIP' >/dev/null 2>&1
NEWPARENT=$(git -C "$WT" rev-parse HEAD^ 2>/dev/null)
[ "$NEWPARENT" = "$MB" ] \
  && ok || bad "the squash parented onto $NEWPARENT instead of merge-base(\$BASE,HEAD) $MB — it re-parented onto fresh main's tip"
[ "$(git -C "$WT" rev-parse HEAD^{tree})" = "$TREE_BEFORE" ] \
  && ok || bad "the squash changed the tree"
DELETED=$(git -C "$WT" diff --name-only --diff-filter=D main...HEAD)
[ -z "$DELETED" ] \
  && ok || bad "a file main gained after the branch's real fork shows as DELETED in the squash diff: $DELETED"
grep -q 'CHECKPOINT squash: 3 commit(s) (2 wip)' <<<"$(plog)" \
  && ok || bad "the squash line should still count 3 commits (2 wip) off the real fork point (log: $(plog))"
# The gate this whole incident blocked on, driven the same way run-build.sh
# drives it (bin/lib/rb/execute.sh:163: "$BASE" ., not merge-base — three-dot
# diff inside the scanner resolves merge-base itself, which only works because
# the squash above no longer corrupts HEAD's real ancestry).
TAMPER_OUT=$(cd "$WT" && BUILD_DIR="$BUILD" "$DIR/bin/test-tamper-scan.sh" main . 2>&1)
grep -q '^TAMPER_COUNT: 0 (deleted_files=0 ' <<<"$TAMPER_OUT" \
  && ok || bad "test-tamper-scan.sh still reports tamper against the fixed squash: $TAMPER_OUT"

# 6g. BH-1310: the fail-loud path — an unresolvable base must never be treated
# as "squash onto the tip" by default; it must refuse and say so.
fresh
commit_in a.ts "wip: checkpoint execute t1"
commit_in b.ts "feat: real"
B4=$(git -C "$WT" rev-parse HEAD)
OUT=$(DRIVE 'SQUASH_OK=1; BASE=refs/heads/no-such-ref; CKPT_SQUASH_WIP; echo "rc=$?"')
grep -q '^rc=1$' <<<"$OUT" \
  && ok || bad "an unresolvable base must return non-zero, not silently succeed (got: $OUT)"
[ "$(git -C "$WT" rev-parse HEAD)" = "$B4" ] \
  && ok || bad "an unresolvable base must not rewrite the branch"
grep -q 'CHECKPOINT squash FAILED.*could not resolve merge-base' <<<"$(plog)" \
  && ok || bad "the fail-loud path must name the unresolved refs in pipeline.log (log: $(plog))"

# ---------- 7. adopt: the rebuild continues the dead lane's branch -----------
ADOPT() { # ADOPT -> prints "<branch>|<wip-n>|<start-point>"; $ABR overrides BRANCH
  ( set -uo pipefail
    PROJECT=project-5; KEY=TK-1156; BASE=main; BRANCH="${ABR:-ticket/TK-1156}"
    BUILD="$BUILD"; WT="$WT"
    STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
    cd "$WT" || exit 9
    # shellcheck disable=SC1090
    . "$T/adopt.sh"
    echo "$BRANCH|$CKPT_WIP_N|$CKPT_START_POINT" )
}
fresh
commit_in a.ts "wip: checkpoint execute 2026-09-15 10:00:00Z"
( cd "$WT"; git push -q -u origin ticket/TK-1156 >/dev/null 2>&1 )
# ...from a machine that has never seen that branch, which is the real situation
FRESHWT="$T/clone$N"; git clone -q "$ORIGIN" "$FRESHWT"; WT="$FRESHWT"
[ "$(ADOPT)" = "ticket/TK-1156|1|origin/ticket/TK-1156" ] \
  && ok || bad "a wip-tipped branch on origin must be adopted (got $(ADOPT))"
grep -q 'CHECKPOINT resume: origin/ticket/TK-1156 carries 1 checkpoint commit' <<<"$(plog)" \
  && ok || bad "the adoption must be visible in pipeline.log (log: $(plog))"

# 7b. a finished lane's branch (no wip at the tip) is left alone — the -rN bump
# below it in run-build.sh keeps its old behaviour exactly.
fresh
commit_in a.ts "feat: a finished lane"
( cd "$WT"; git push -q -u origin ticket/TK-1156 >/dev/null 2>&1 )
FRESHWT="$T/clone-b$N"; git clone -q "$ORIGIN" "$FRESHWT"; WT="$FRESHWT"
[ "$(ADOPT)" = "ticket/TK-1156|0|" ] || bad "a branch with no wip commits must NOT be adopted (got $(ADOPT))"
[ "$(ADOPT)" = "ticket/TK-1156|0|" ] && ok

# 7c. no branch on the remote at all: the fresh-build path, untouched
fresh
[ "$(ADOPT)" = "ticket/TK-1156|0|" ] && ok || bad "a fresh build must not adopt anything (got $(ADOPT))"

# 7d. the kill switch reaches the adoption too
fresh
commit_in a.ts "wip: checkpoint execute t1"
( cd "$WT"; git push -q -u origin ticket/TK-1156 >/dev/null 2>&1 )
FRESHWT="$T/clone-d$N"; git clone -q "$ORIGIN" "$FRESHWT"; WT="$FRESHWT"
[ "$(CHECKPOINTS=0 ADOPT)" = "ticket/TK-1156|0|" ] \
  && ok || bad "CHECKPOINTS=0 must adopt nothing (got $(CHECKPOINTS=0 ADOPT))"

# 7e. a blocked-resolver rebuild arrives as ticket/<key>-r2 (branch_suffix=-rN)
# and must still find the dead lane's ticket/<key> — the whole point.
fresh
commit_in a.ts "wip: checkpoint execute t1"
( cd "$WT"; git push -q -u origin ticket/TK-1156 >/dev/null 2>&1 )
FRESHWT="$T/clone-e$N"; git clone -q "$ORIGIN" "$FRESHWT"; WT="$FRESHWT"
[ "$(ABR=ticket/TK-1156-r2 ADOPT)" = "ticket/TK-1156|1|origin/ticket/TK-1156" ] \
  && ok || bad "an -rN rebuild must still adopt the unsuffixed dead lane (got $(ABR=ticket/TK-1156-r2 ADOPT))"

# ---------- 8. the execute result: a checkpoint is not a build --------------
EXECRES() { # EXECRES -> "<rc> <RESULT-or-none>"
  ( set -uo pipefail
    PROJECT=project-5; KEY=TK-1156; BASE=main; BRANCH=ticket/TK-1156
    BUILD="$BUILD"; WT="$WT"
    STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
    RESULT() { echo "$*" > "$BUILD/RESULT"; }
    cd "$WT" || exit 9
    # shellcheck disable=SC1090
    . "$T/ckpt.sh"
    CKPT_STOP() { :; }      # the stage's own end-checkpoint is asserted above
    SQUASH_OK=1
    # shellcheck disable=SC1090
    . "$T/exec.sh" ) >/dev/null 2>&1
  echo "$? $(cat "$BUILD/RESULT" 2>/dev/null || echo none)"
}
fresh
OUT=$(EXECRES)
grep -q '^5 EXECUTE_EMPTY no changes produced' <<<"$OUT" \
  && ok || bad "an empty branch must still be EXECUTE_EMPTY (got: $OUT)"

fresh
commit_in a.ts "wip: checkpoint execute 2026-09-15 10:00:00Z"
commit_in b.ts "wip: checkpoint execute-exit 2026-09-15 10:15:00Z"
OUT=$(EXECRES)
grep -q '^5 EXECUTE_EMPTY' <<<"$OUT" \
  && ok || bad "a checkpoint-ONLY branch must not be read as a finished build (got: $OUT)"
grep -q 'resumes from them' <<<"$OUT" \
  && ok || bad "the EXECUTE_EMPTY detail must say where the tree is (got: $OUT)"
[ "$(git -C "$WT" rev-list --count main..HEAD)" = 2 ] \
  && ok || bad "a refused build must not have squashed anything"

fresh
commit_in a.ts "wip: checkpoint execute 2026-09-15 10:00:00Z"
commit_in b.ts "feat: the session's own commit"
OUT=$(EXECRES)
[ "${OUT%% *}" = 0 ] && grep -q 'none$' <<<"$OUT" \
  && ok || bad "a branch with real work must pass through with no RESULT (got: $OUT)"
[ "$(git -C "$WT" rev-list --count main..HEAD)" = 1 ] \
  && ok || bad "the passing path must squash its checkpoints away before the PR"

echo "run-build-checkpoint-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
