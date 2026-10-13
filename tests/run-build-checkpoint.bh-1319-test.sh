#!/bin/bash
# tests/run-build-checkpoint.bh-1319-test.sh — BH-1319: the three checkpoint
# follow-ups from the review of #1317, driven against real git repositories and
# a real bare origin over file:// (so `--depth` actually applies).
#
# What is proven here, and why each one cost something:
#
#   A. THE ADOPT PATH HEALS A SHALLOW CLONE. Pool warm repos are
#      `git clone --depth 50` (fly/Dockerfile). A checkpoint branch adopted into
#      such a clone whose fork point is older than the boundary has NO merge-base
#      with $BASE at all: `git diff main...HEAD` exits 128 and the squash refuses.
#      One `git fetch --unshallow origin`, gated on `--is-shallow-repository` AND
#      on the merge-base actually being unresolved, restores it — and the resume
#      logs the distance (main N past the fork, the branch M on top) so an
#      operator reading pipeline.log can see which side moved.
#   B. BOTH FAILED PATHS OF CKPT_SQUASH_WIP RETURN 1. The unresolved-merge-base
#      path returned 1; the reset/commit path logged the same FAILED word and
#      returned 0, so half the refusals were invisible to every caller.
#   C. THE CALLERS CONSUME THAT RC. A refusal is still NEVER FATAL (the build
#      goes on with its wip commits, docs/CHECKPOINTS.md) — what changes is that
#      it is RECORDED as the step that failed: a `squash` phase row closed failed
#      rc 1 on the job, fail-open when no jobs client is loaded.
#
# The blocks are cut from the flatten by their markers and EXECUTED; every
# assertion is on git state, pipeline.log or the stubbed phase log — never on
# source text. No network, no gh, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
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

# --- the four blocks, lifted verbatim ----------------------------------------
cut_block() { # cut_block <marker-word...> <outfile>
  local name="$1" out="$2"
  awk -v n="$name" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' \
    "$RB_ALL" > "$out"
}
cut_block "lane checkpoints" "$T/ckpt.sh"
cut_block "checkpoint adopt" "$T/adopt.sh"
cut_block "execute result"   "$T/exec.sh"
cut_block "pre-pr squash"    "$T/prpr.sh"
for B in ckpt adopt exec prpr; do
  [ -s "$T/$B.sh" ] && ok || bad "could not extract the '$B' block from bin/run-build.sh — markers missing?"
  bash -n "$T/$B.sh" 2>/dev/null && ok || bad "the extracted '$B' block does not parse on its own"
done

# --- a git shim: the real binary for everything except the one subcommand a
# case needs to fail. GIT_SHIM_FAIL names it; unset, the shim is transparent.
REAL_GIT=$(command -v git)
SHIM="$T/shim"; mkdir -p "$SHIM"
cat > "$SHIM/git" <<EOF
#!/bin/bash
case "\${GIT_SHIM_FAIL:-}" in
  unshallow)
    for a in "\$@"; do [ "\$a" = --unshallow ] && exit 128; done ;;
  merge-base|commit)
    for a in "\$@"; do [ "\$a" = "\$GIT_SHIM_FAIL" ] && exit 1; done ;;
esac
exec $REAL_GIT "\$@"
EOF
chmod +x "$SHIM/git"

# --- fixtures ----------------------------------------------------------------
N=0
build_origin() { # build_origin <commits-before-fork> <commits-after-fork>
  N=$((N+1))
  ORIGIN="$T/origin$N.git"; SRC="$T/src$N"
  git init --bare -q "$ORIGIN"; git init -q "$SRC"
  ( cd "$SRC"
    git remote add origin "$ORIGIN"
    for i in $(seq 1 "$1"); do echo "$i" > "f$i.txt"; git add -A >/dev/null; git commit -qm "c$i"; done
    git checkout -qb ticket/TK-1156 >/dev/null 2>&1
    echo half-written > w.ts; git add -A >/dev/null
    git commit -qm "wip: checkpoint execute 2026-09-22 10:00:00Z" >/dev/null
    echo real > r.ts; git add -A >/dev/null
    git commit -qm "feat(x): the real commit" >/dev/null
    git checkout -q main
    for i in $(seq $(( $1 + 1 )) $(( $1 + $2 ))); do
      echo "$i" > "f$i.txt"; git add -A >/dev/null; git commit -qm "c$i" >/dev/null
    done
    git push -q origin main ticket/TK-1156 >/dev/null 2>&1 )
  FORK=$(git -C "$SRC" merge-base main ticket/TK-1156)
}
clone_pool() { # clone_pool [extra clone args...] — sets WT and BUILD
  WT="$T/pool$N"; BUILD="$T/build$N"; mkdir -p "$BUILD"
  printf '{"project":"project-5","ticket_id":"7","key":"TK-1156"}\n' > "$BUILD/job.json"
  git clone -q "$@" "file://$ORIGIN" "$WT"
}
plog() { cat "$BUILD/pipeline.log" 2>/dev/null; }
shallow_p() { git -C "$WT" rev-parse --is-shallow-repository 2>/dev/null; }

# The environment every extracted block is evaluated in. STAMP is stubbed: a
# suite that reads the wall clock picks its own red day.
ADOPT() { # ADOPT -> prints "<branch>|<wip-n>|<start-point>"
  ( set -uo pipefail
    PATH="$SHIM:$PATH"
    PROJECT=project-5; KEY=TK-1156; BASE=main; BRANCH="${ABR:-ticket/TK-1156}"
    BUILD="$BUILD"; WT="$WT"
    STAMP() { echo TS; }
    cd "$WT" || exit 9
    # shellcheck disable=SC1090
    . "$T/adopt.sh"
    echo "$BRANCH|$CKPT_WIP_N|$CKPT_START_POINT" )
}
DRIVE() { # DRIVE <script-text-to-run-after-sourcing-ckpt.sh>
  ( set -uo pipefail
    PATH="$SHIM:$PATH"
    PROJECT=project-5; KEY=TK-1156; BASE=main; BRANCH=ticket/TK-1156
    BUILD="$BUILD"; WT="$WT"
    STAMP() { echo TS; }
    RESULT() { echo "$*" > "$BUILD/RESULT"; }
    cd "$WT" || exit 9
    # shellcheck disable=SC1090
    . "$T/ckpt.sh"
    eval "$1" )
}
CALLER() { # CALLER <exec|prpr> [stubs] -> "<rc>"; sources ckpt.sh then the block
  local which="$1" stubs="${2:-}"
  ( set -uo pipefail
    PATH="$SHIM:$PATH"
    PROJECT=project-5; KEY=TK-1156; BASE=main; BRANCH=ticket/TK-1156
    BUILD="$BUILD"; WT="$WT"
    STAMP() { echo TS; }
    RESULT() { echo "$*" > "$BUILD/RESULT"; }
    cd "$WT" || exit 9
    # shellcheck disable=SC1090
    . "$T/ckpt.sh"
    CKPT_STOP() { :; }          # the stage's own end-checkpoint is asserted next door
    SQUASH_OK=1
    eval "$stubs"
    # shellcheck disable=SC1090
    . "$T/$which.sh" ) >/dev/null 2>&1
  echo "$?"
}
PHASE_STUBS='job_phase_open()  { echo "open $*"  >> "$BUILD/phases.log"; }
             job_phase_close() { echo "close $*" >> "$BUILD/phases.log"; }'

# ---------- A1. a shallow adopt heals the clone before anything diffs --------
# 5 commits, the branch forks there (1 wip + 1 real), then 65 more on main: the
# fork point is 65 commits back and a depth-50 clone cannot see it.
build_origin 5 65
clone_pool --depth 50 --single-branch --branch main
[ "$(shallow_p)" = true ] && ok || bad "A1 setup: the pool clone should be shallow"
OUT=$(ADOPT)
[ "$OUT" = "ticket/TK-1156|1|origin/ticket/TK-1156" ] \
  && ok || bad "A1: a wip-tipped branch must still be adopted on a shallow clone (got $OUT)"
[ "$(shallow_p)" = false ] \
  && ok || bad "A1: the adopt path must unshallow the clone (still shallow=$(shallow_p))"
MB=$(git -C "$WT" merge-base main origin/ticket/TK-1156 2>/dev/null)
[ "$MB" = "$FORK" ] \
  && ok || bad "A1: merge-base must resolve to the fork point $FORK after the heal (got '$MB')"
L=$(plog)
grep -q "CHECKPOINT resume: no merge-base(main, origin/ticket/TK-1156) in this clone and it is SHALLOW" <<<"$L" \
  && ok || bad "A1: the unshallow must announce itself BEFORE the fetch (log: $L)"
grep -q "CHECKPOINT resume: merge-base ${FORK:0:8} — main is 65 commit(s) past the fork, origin/ticket/TK-1156 carries 2 commit(s) on top of it" <<<"$L" \
  && ok || bad "A1: the resume must log the merge-base distance (log: $L)"
# ...and the squash the heal exists for now collapses onto the real fork point.
git -C "$WT" checkout -qb ticket/TK-1156 origin/ticket/TK-1156 2>/dev/null
OUT=$(DRIVE 'SQUASH_OK=1; CKPT_SQUASH_WIP; echo "rc=$?"')
grep -q '^rc=0$' <<<"$OUT" \
  && ok || bad "A1: the squash must succeed once the clone is healed (got: $OUT)"
[ "$(git -C "$WT" rev-list --count main..HEAD)" = 1 ] \
  && ok || bad "A1: the squash left $(git -C "$WT" rev-list --count main..HEAD) commit(s)"
[ "$(git -C "$WT" rev-parse HEAD^)" = "$FORK" ] \
  && ok || bad "A1: the squashed commit must parent onto the fork point $FORK"

# ---------- A2. a complete clone: no fetch, distance line only ---------------
build_origin 5 65
clone_pool
[ "$(shallow_p)" = false ] && ok || bad "A2 setup: a plain clone should not be shallow"
OUT=$(ADOPT)
[ "$OUT" = "ticket/TK-1156|1|origin/ticket/TK-1156" ] \
  && ok || bad "A2: the adoption itself is unchanged on a complete clone (got $OUT)"
L=$(plog)
grep -q 'SHALLOW' <<<"$L" \
  && bad "A2: a complete clone must never trigger the unshallow (log: $L)" || ok
grep -q "CHECKPOINT resume: merge-base ${FORK:0:8} — main is 65 commit(s) past the fork, origin/ticket/TK-1156 carries 2 commit(s) on top of it" <<<"$L" \
  && ok || bad "A2: the distance line must be logged on every adoption (log: $L)"

# ---------- A3. the unshallow fails: logged with its rc, never fatal ---------
build_origin 5 65
clone_pool --depth 50 --single-branch --branch main
OUT=$(GIT_SHIM_FAIL=unshallow ADOPT)
[ "$OUT" = "ticket/TK-1156|1|origin/ticket/TK-1156" ] \
  && ok || bad "A3: a failed heal must not stop the adoption (got $OUT)"
[ "$(shallow_p)" = true ] \
  && ok || bad "A3: a failed fetch must leave the clone shallow, not claim it healed"
L=$(plog)
grep -q 'git fetch --unshallow origin failed (rc 128)' <<<"$L" \
  && ok || bad "A3: the failure must carry git's real rc (log: $L)"
grep -q 'merge-base(main, origin/ticket/TK-1156) UNRESOLVED' <<<"$L" \
  && ok || bad "A3: an unresolved merge-base must say so instead of a distance line (log: $L)"
[ -e "$BUILD/RESULT" ] && bad "A3: a failed heal must never write a RESULT" || ok

# ---------- A4. shallow, but the merge-base is already there: no fetch -------
build_origin 67 3
clone_pool --depth 50 --single-branch --branch main
[ "$(shallow_p)" = true ] && ok || bad "A4 setup: the pool clone should be shallow"
OUT=$(ADOPT)
[ "$OUT" = "ticket/TK-1156|1|origin/ticket/TK-1156" ] \
  && ok || bad "A4: the adoption is unchanged (got $OUT)"
[ "$(shallow_p)" = true ] \
  && ok || bad "A4: a resolvable merge-base must NOT trigger a fetch — the clone should still be shallow"
L=$(plog)
grep -q 'SHALLOW' <<<"$L" \
  && bad "A4: nothing to heal, so nothing to log about shallowness (log: $L)" || ok
grep -q "main is 3 commit(s) past the fork" <<<"$L" \
  && ok || bad "A4: the distance line must count against the real fork point (log: $L)"

# ---------- B1. both FAILED paths of CKPT_SQUASH_WIP return 1 ----------------
build_origin 5 2
clone_pool
git -C "$WT" checkout -qb ticket/TK-1156 origin/ticket/TK-1156 2>/dev/null
OUT=$(GIT_SHIM_FAIL=commit DRIVE 'SQUASH_OK=1; CKPT_SQUASH_WIP; echo "rc=$?"')
grep -q '^rc=1$' <<<"$OUT" \
  && ok || bad "B1: a squash whose commit failed must return 1, like the unresolved-base path (got: $OUT)"
L=$(plog)
grep -qF 'CHECKPOINT squash FAILED — the PR ships with its 1 wip commit(s)' <<<"$L" \
  && ok || bad "B1: the log line must still be true on the rc-1 path (log: $L)"

# ---------- C1. the execute-result caller records the refusal ----------------
build_origin 5 2
clone_pool
git -C "$WT" checkout -qb ticket/TK-1156 origin/ticket/TK-1156 2>/dev/null
RC=$(GIT_SHIM_FAIL=merge-base CALLER exec "$PHASE_STUBS")
[ "$RC" = 0 ] && ok || bad "C1: a refused squash must NEVER be fatal to the build (rc $RC)"
[ -e "$BUILD/RESULT" ] && bad "C1: a refused squash must write no RESULT ($(cat "$BUILD/RESULT"))" || ok
[ "$(git -C "$WT" rev-list --count main..HEAD)" = 2 ] \
  && ok || bad "C1: the wip commits must still be there — the build ships with them"
P1=$(sed -n 1p "$BUILD/phases.log" 2>/dev/null)
P2=$(sed -n 2p "$BUILD/phases.log" 2>/dev/null)
case "$P1" in
  "open squash "*) grep -q 'before execute' <<<"$P1" \
       && ok || bad "C1: the phase must name where the refusal happened (got: $P1)" ;;
  *) bad "C1: the refusal must open a 'squash' phase on the job (got: $P1)" ;;
esac
case "$P2" in
  "close 1 "*) grep -q 'could not resolve merge-base' <<<"$P2" \
       && ok || bad "C1: the close must carry the reason the squash refused (got: $P2)" ;;
  *) bad "C1: the phase must be closed FAILED with rc 1 (got: $P2)" ;;
esac
grep -q 'CHECKPOINT squash refused before execute — recorded as the failed step' <<<"$(plog)" \
  && ok || bad "C1: the refusal must be one pipeline.log line too (log: $(plog))"

# ---------- C2. the pre-PR caller records it the same way --------------------
build_origin 5 2
clone_pool
git -C "$WT" checkout -qb ticket/TK-1156 origin/ticket/TK-1156 2>/dev/null
RC=$(GIT_SHIM_FAIL=merge-base CALLER prpr "$PHASE_STUBS")
[ "$RC" = 0 ] && ok || bad "C2: the pre-PR squash refusal must not be fatal either (rc $RC)"
P1=$(sed -n 1p "$BUILD/phases.log" 2>/dev/null)
P2=$(sed -n 2p "$BUILD/phases.log" 2>/dev/null)
case "$P1" in
  "open squash "*) grep -q 'before pr' <<<"$P1" \
       && ok || bad "C2: the pre-PR refusal must record where=pr (got: $P1)" ;;
  *) bad "C2: the pre-PR call site must record the refusal (got: $P1)" ;;
esac
case "$P2" in "close 1 "*) ok ;; *) bad "C2: the phase must be closed FAILED with rc 1 (got: $P2)" ;; esac

# ---------- C3. no jobs client loaded: fail-open, log line only --------------
build_origin 5 2
clone_pool
git -C "$WT" checkout -qb ticket/TK-1156 origin/ticket/TK-1156 2>/dev/null
RC=$(GIT_SHIM_FAIL=merge-base CALLER exec 'unset -f job_phase_open job_phase_close 2>/dev/null; true')
[ "$RC" = 0 ] && ok || bad "C3: with no jobs client the block must still exit 0 (rc $RC)"
[ -e "$BUILD/RESULT" ] && bad "C3: still no RESULT" || ok
[ -e "$BUILD/phases.log" ] && bad "C3: nothing to record against — no phase file may appear" || ok
grep -q 'CHECKPOINT squash refused before execute' <<<"$(plog)" \
  && ok || bad "C3: the pipeline.log line is the fail-open floor (log: $(plog))"

echo "run-build-checkpoint.bh-1319-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
