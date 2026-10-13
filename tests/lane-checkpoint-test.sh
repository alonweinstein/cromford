#!/bin/bash
# tests/lane-checkpoint-test.sh — assertions for bin/lane-checkpoint.sh.
# Run from anywhere: tests/lane-checkpoint-test.sh   (exit 0 = all pass)
#
# Everything here runs against a REAL git repo and a REAL bare origin in a temp
# dir, because the thing under test is git behaviour: what gets committed, what
# gets refused, and whether the branch actually reached the remote. A stubbed
# git would have proved the script's control flow and nothing about the file
# that matters — the tree surviving the machine.
#
# No network, no gh (except a PATH shim where an open PR is the point), no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait for the watcher, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
LC="$DIR/bin/lane-checkpoint.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HOME="$T/home"; mkdir -p "$HOME"
git config --global user.email harness@localhost >/dev/null 2>&1
git config --global user.name  harness           >/dev/null 2>&1
git config --global init.defaultBranch main      >/dev/null 2>&1
git config --global protocol.file.allow always   >/dev/null 2>&1

N=0
fresh() { # fresh [branch] -> WT, ORIGIN, BUILD set; a repo with one base commit
  N=$((N+1))
  ORIGIN="$T/origin$N.git"; WT="$T/wt$N"; BUILD="$T/build$N"
  git init --bare -q "$ORIGIN"
  git init -q "$WT"
  mkdir -p "$BUILD"
  printf '{"project":"project-5","ticket_id":"7","key":"TK-1156"}\n' > "$BUILD/job.json"
  ( cd "$WT"
    echo base > base.txt
    # node_modules is DELIBERATELY not ignored here: CHECKPOINT_EXCLUDE exists
    # for exactly the repo that forgot to ignore it, and a fixture that ignores
    # it would grade `git add -A` as if the exclude were doing the work.
    printf 'secrets.txt\n' > .gitignore
    git add -A >/dev/null 2>&1
    git commit -qm "base" >/dev/null 2>&1
    git remote add origin "$ORIGIN"
    git push -q -u origin main >/dev/null 2>&1
    git checkout -qb "${1:-ticket/TK-1156}" >/dev/null 2>&1 )
}
CK() { CHECKPOINTS=1 HARNESS="$T/h" "$LC" "$BUILD" "$WT" "${CKBR:-ticket/TK-1156}" "${CKSTAGE:-execute}" 2>&1; }
plog() { cat "$BUILD/pipeline.log" 2>/dev/null; }
alerts() { cat "$T/h/logs/ALERTS.log" 2>/dev/null; }
remote_subjects() { git -C "$ORIGIN" log --format=%s "${1:-ticket/TK-1156}" 2>/dev/null; }
mkdir -p "$T/h/logs" "$T/h/flags"
# BH-2504: every checkpoint push reads the ticket's hold first. FIXTURE:
# project-5 is an issues lane and its ticket is open and unheld.
. "$DIR/tests/lib/hold-fixture.sh" || exit 1
hold_fixture_gh "$T/ghbin" || exit 1
export PATH="$T/ghbin:$PATH"
printf 'project-5 example-org/project-5 - - 2 box-ts\n' > "$T/fleet.conf"
export FLEET_CONF="$T/fleet.conf"

# ---------- 1. clean tree, nothing pushed yet: the branch still reaches origin
# A lane that committed and died is the project-5 #1156 shape — clean tree, real
# commits, nothing on the remote. "Clean" must not mean "nothing to do".
fresh
( cd "$WT"; echo one > one.txt; git add -A >/dev/null; git commit -qm "feat: real work" >/dev/null )
OUT=$(CK); RC=$?
[ "$RC" = 0 ] && ok || bad "a clean-but-unpushed tree must checkpoint cleanly (rc=$RC, $OUT)"
grep -q '^feat: real work$' <<<"$(remote_subjects)" && ok || bad "the committed work never reached origin: $(remote_subjects)"
[ "$(remote_subjects | grep -c '^wip:')" = 0 ] && ok || bad "nothing was uncommitted — no wip commit should have been made"
grep -q 'CHECKPOINT execute pushed' <<<"$(plog)" && ok || bad "no CHECKPOINT line for the push (log: $(plog))"
grep -q '\[project-5/TK-1156\]' <<<"$(plog)" && ok || bad "the CHECKPOINT line must name project/key from job.json (log: $(plog))"

# ---------- 2. the no-op: a second run changes nothing -----------------------
BEFORE=$(git -C "$WT" rev-parse HEAD)
OUT=$(CK); RC=$?
[ "$RC" = 0 ] && ok || bad "an already-checkpointed tree must be a clean no-op (rc=$RC)"
[ "$(git -C "$WT" rev-parse HEAD)" = "$BEFORE" ] && ok || bad "the no-op created a commit"
grep -q 'CHECKPOINT execute clean' <<<"$(plog)" && ok || bad "the no-op must still say so in pipeline.log (log: $(plog))"

# ---------- 3. dirty tree: commit + push, .gitignore and excludes respected --
fresh
( cd "$WT"
  echo work > feature.ts
  mkdir -p sub && echo more > sub/deep.ts
  echo TOKEN=xyz > secrets.txt                 # .gitignore'd
  mkdir -p node_modules/pkg && echo junk > node_modules/pkg/index.js )
OUT=$(CK); RC=$?
[ "$RC" = 0 ] && ok || bad "a dirty tree must checkpoint (rc=$RC, $OUT)"
SUBJ=$(remote_subjects | head -1)
grep -qE '^wip: checkpoint execute [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}Z$' <<<"$SUBJ" \
  && ok || bad "the wip commit subject must be 'wip: checkpoint <stage> <ISO time>' (got: $SUBJ)"
FILES=$(git -C "$WT" show --name-only --format= HEAD)
grep -qx 'feature.ts'   <<<"$FILES" && ok || bad "the new file was not committed: $FILES"
grep -qx 'sub/deep.ts'  <<<"$FILES" && ok || bad "a nested new file was not committed: $FILES"
grep -q  'secrets.txt'  <<<"$FILES" && bad "a .gitignore'd file was committed: $FILES" || ok
grep -q  'node_modules' <<<"$FILES" && bad "node_modules was committed: $FILES" || ok
grep -q 'CHECKPOINT execute committed 2 file(s)' <<<"$(plog)" && ok || bad "the CHECKPOINT line must count the files (log: $(plog))"
# Everything but the excluded build junk, which stays untracked on purpose.
[ -z "$(git -C "$WT" status --porcelain | grep -v node_modules)" ] \
  && ok || bad "the worktree should be clean after a checkpoint: $(git -C "$WT" status --porcelain)"

# ---------- 4. idempotence after a dirty checkpoint --------------------------
BEFORE=$(git -C "$WT" rev-parse HEAD)
CK >/dev/null 2>&1
[ "$(git -C "$WT" rev-parse HEAD)" = "$BEFORE" ] && ok || bad "a repeat checkpoint made a second empty wip commit"

# ---------- 5. secrets: env/ and *.env are refused, whole stop ---------------
for SECRET in "env/global.env" ".env" "config/app.env" "env/accounts.d/a.json"; do
  fresh
  ( cd "$WT"; mkdir -p "$(dirname "$SECRET")" 2>/dev/null; echo "TOKEN=live" > "$SECRET"; echo work > feature.ts )
  OUT=$(CK); RC=$?
  [ "$RC" = 4 ] && ok || bad "$SECRET in the tree must REFUSE with rc 4 (got rc=$RC)"
  [ "$(git -C "$WT" rev-list --count HEAD)" = 1 ] && ok || bad "$SECRET: a commit was made despite the refusal"
  [ -z "$(remote_subjects)" ] && ok || bad "$SECRET: the branch was pushed despite the refusal"
  grep -q 'CHECKPOINT execute REFUSED' <<<"$(plog)" && ok || bad "$SECRET: no refusal line in pipeline.log"
done
# ...and the refusal is an ALERT, once, not a per-tick whisper.
grep -q 'checkpoint REFUSED' <<<"$(alerts)" && ok || bad "a secret refusal must reach ALERTS.log (got: $(alerts))"
BEFORE_N=$(alerts | grep -c 'checkpoint REFUSED')
CK >/dev/null 2>&1; CK >/dev/null 2>&1
[ "$(alerts | grep -c 'checkpoint REFUSED')" = "$BEFORE_N" ] && ok || bad "the refusal alert must fire once per build, not once per tick"

# ---------- 5b. .env.example is NOT a secret --------------------------------
fresh
( cd "$WT"; echo "TOKEN=" > .env.example; echo work > feature.ts )
OUT=$(CK); RC=$?
[ "$RC" = 0 ] && ok || bad ".env.example must not be mistaken for a credential (rc=$RC, $OUT)"
grep -q '.env.example' <<<"$(git -C "$WT" show --name-only --format= HEAD)" && ok || bad ".env.example should have been committed"

# ---------- 6. never on main -------------------------------------------------
fresh
( cd "$WT"; git checkout -q main; echo work > feature.ts )
OUT=$(CKBR=main CK); RC=$?
[ "$RC" = 4 ] && ok || bad "a checkpoint on main must REFUSE (rc=$RC, $OUT)"
[ "$(git -C "$WT" rev-list --count main)" = 1 ] && ok || bad "a commit landed on main"
grep -qi 'trunk branch' <<<"$(plog)" && ok || bad "the refusal must say why (log: $(plog))"

# 6b. a worktree sitting on main while the caller names a feature branch
fresh
( cd "$WT"; git checkout -q main; echo work > feature.ts )
OUT=$(CK); RC=$?
[ "$RC" = 4 ] && ok || bad "a worktree on main must REFUSE even when the caller names a branch (rc=$RC)"

# 6c. detached HEAD — a commit there is unreachable, so refuse
fresh
( cd "$WT"; git checkout -q --detach; echo work > feature.ts )
OUT=$(CK); RC=$?
[ "$RC" = 4 ] && ok || bad "a detached HEAD must REFUSE (rc=$RC, $OUT)"
grep -qi 'detached' <<<"$(plog)" && ok || bad "the detached refusal must say so (log: $(plog))"

# 6d. the worktree is on some OTHER feature branch
fresh
( cd "$WT"; git checkout -qb ticket/other; echo work > feature.ts )
OUT=$(CK); RC=$?
[ "$RC" = 4 ] && ok || bad "a branch mismatch must REFUSE (rc=$RC, $OUT)"

# ---------- 7. the kill switch ----------------------------------------------
fresh
( cd "$WT"; echo work > feature.ts )
OUT=$(CHECKPOINTS=0 HARNESS="$T/h" "$LC" "$BUILD" "$WT" ticket/TK-1156 execute 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "CHECKPOINTS=0 must be a silent success (rc=$RC)"
[ "$(git -C "$WT" rev-list --count HEAD)" = 1 ] && ok || bad "CHECKPOINTS=0 still committed"
touch "$T/h/flags/lane-checkpoints-off"
CK >/dev/null 2>&1
[ "$(git -C "$WT" rev-list --count HEAD)" = 1 ] && ok || bad "flags/lane-checkpoints-off still committed"
rm -f "$T/h/flags/lane-checkpoints-off"

# ---------- 8. the exit-trap shape: a killed stage still checkpoints ---------
# What run-build.sh's trap does, reproduced exactly: a long-running stage is
# SIGKILLed mid-edit and the trap fires the checkpoint by hand afterwards.
fresh
( cd "$WT"; echo half-written > feature.ts )
( CKSTAGE=execute-exit CK ) >/dev/null 2>&1
grep -q '^wip: checkpoint execute-exit ' <<<"$(remote_subjects | head -1)" \
  && ok || bad "the exit-trap checkpoint did not land (got: $(remote_subjects | head -1))"
grep -q 'CHECKPOINT execute-exit committed' <<<"$(plog)" && ok || bad "no exit-trap CHECKPOINT line (log: $(plog))"

# ---------- 9. --watch: the timer fires, and it dies with its parent ---------
fresh
( cd "$WT"; echo work > feature.ts )
# CHECKPOINT_EVERY_MIN is minutes; the watcher sleeps every*60s, so this test
# drives the same loop through a 1-minute setting would be 60s of wall clock.
# Instead: assert the watcher arms and self-terminates when its parent dies,
# which is the property that keeps orphans off a box, and cover the timer body
# by calling do_checkpoint directly (rows 1-8).
CHECKPOINTS=1 HARNESS="$T/h" CHECKPOINT_EVERY_MIN=1 CHECKPOINT_PARENT_PID=999999 \
  "$LC" --watch "$BUILD" "$WT" ticket/TK-1156 execute >/dev/null 2>&1 &
WPID=$!
armed() { grep -q 'CHECKPOINT execute watcher armed' <<<"$(plog)"; }
wait_for 10 armed
grep -q 'CHECKPOINT execute watcher armed' <<<"$(plog)" && ok || bad "the watcher must announce itself in pipeline.log (log: $(plog))"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
# a zero interval is a second kill switch, and must not busy-loop
OUT=$(CHECKPOINTS=1 HARNESS="$T/h" CHECKPOINT_EVERY_MIN=0 timeout 5 "$LC" --watch "$BUILD" "$WT" ticket/TK-1156 execute 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "CHECKPOINT_EVERY_MIN=0 must return immediately, not spin (rc=$RC)"

# ---------- 10. resume detection --------------------------------------------
# The branch a dead lane left on origin, found from a FRESH worktree that has
# never seen it — which is the real situation: the machine that built it is gone.
fresh
( cd "$WT"; echo work > feature.ts; git add -A >/dev/null; git commit -qm "feat: real work" >/dev/null
  echo more > feature2.ts; git add -A >/dev/null
  git commit -qm "wip: checkpoint execute 2026-09-15 12:00:00Z" >/dev/null
  git push -q -u origin ticket/TK-1156 )
FRESHWT="$T/fresh$N"; git clone -q "$ORIGIN" "$FRESHWT"
OUT=$(HARNESS="$T/h" "$LC" --resume-branch "$FRESHWT" ticket/TK-1156 main 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "a wip-tipped branch on origin must be found (rc=$RC, out=$OUT)"
[ "$OUT" = "ticket/TK-1156|1|2" ] && ok || bad "resume must report branch|wip-count|total-commits (got: $OUT)"

# 10b. a branch with NO wip commits is a finished lane — never adopted
git -C "$ORIGIN" branch -D ticket/TK-1156 >/dev/null 2>&1
( cd "$WT"; git reset -q --hard HEAD~1; git push -q -f -u origin ticket/TK-1156 )
FRESHWT2="$T/fresh2$N"; git clone -q "$ORIGIN" "$FRESHWT2"
OUT=$(HARNESS="$T/h" "$LC" --resume-branch "$FRESHWT2" ticket/TK-1156 main 2>/dev/null); RC=$?
[ "$RC" != 0 ] && ok || bad "a branch with no wip commits must not be offered for resume (got: $OUT)"

# 10c. the NEWEST attempt wins: ticket/x-r3 beats ticket/x
fresh
( cd "$WT"; echo a > a.ts; git add -A >/dev/null; git commit -qm "wip: checkpoint execute t1" >/dev/null
  git push -q -u origin ticket/TK-1156
  git checkout -q -b ticket/TK-1156-r3 main
  echo b > b.ts; git add -A >/dev/null; git commit -qm "wip: checkpoint execute t2" >/dev/null
  git push -q -u origin ticket/TK-1156-r3 )
FRESHWT3="$T/fresh3$N"; git clone -q "$ORIGIN" "$FRESHWT3"
OUT=$(HARNESS="$T/h" "$LC" --resume-branch "$FRESHWT3" ticket/TK-1156 main 2>/dev/null)
[ "${OUT%%|*}" = "ticket/TK-1156-r3" ] && ok || bad "the newest attempt must win (got: $OUT)"

# 10d. a branch with an OPEN PR belongs to the dispatcher, not to resume
mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/sh
# gh pr list --head <branch> --state open --json number -q ...
case "$*" in *ticket/TK-1156-r3*) echo 42 ;; esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
OUT=$(PATH="$T/fakebin:$PATH" HARNESS="$T/h" "$LC" --resume-branch "$FRESHWT3" ticket/TK-1156 main 2>/dev/null)
[ "${OUT%%|*}" = "ticket/TK-1156" ] && ok || bad "a branch with an open PR must be skipped, falling through to the older attempt (got: $OUT)"

# 10e. the kill switch reaches resume too
OUT=$(CHECKPOINTS=0 HARNESS="$T/h" "$LC" --resume-branch "$FRESHWT3" ticket/TK-1156 main 2>/dev/null); RC=$?
[ "$RC" != 0 ] && [ -z "$OUT" ] && ok || bad "CHECKPOINTS=0 must offer no resume branch (rc=$RC, out=$OUT)"

# ---------- 11. a dead remote is reported, never swallowed -------------------
fresh
( cd "$WT"; echo work > feature.ts; git remote set-url origin "$T/does-not-exist.git" )
OUT=$(CK); RC=$?
[ "$RC" = 1 ] && ok || bad "an unpushable branch must return rc 1, not success (rc=$RC)"
grep -q 'did NOT land' <<<"$(plog)" && ok || bad "a failed push must say so in pipeline.log (log: $(plog))"
[ "$(git -C "$WT" rev-list --count HEAD)" = 2 ] && ok || bad "the work must still be COMMITTED locally when the push fails"
grep -q 'could not be pushed' <<<"$(alerts)" && ok || bad "an unpushable checkpoint must reach ALERTS.log"

echo "lane-checkpoint-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
