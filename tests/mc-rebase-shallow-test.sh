#!/bin/bash
# tests/mc-rebase-shallow-test.sh — a failed `git merge` inside mc_rebase is a
# CONFLICT or a FATAL, never both, and a SHALLOW hub clone heals itself once.
#
# WHAT THIS PINS (BH-517). The hub's /root/repos/<project> was restored by hand
# with a --depth, so it had no merge base with origin/main for any PR that
# forked before the boundary. mc_rebase's merge died "fatal: refusing to merge
# unrelated histories", `git diff --diff-filter=U` listed ZERO paths, so
# mc_resolve_conflicts answered "everything resolved" and the commit of a merge
# that never happened returned rc 4 — with NOT ONE LOG LINE. The conductor
# logged "rebase setup failed (rc 4)", blocked-resolver parked it
# br_setup_blocked, and seven PRs looped NEEDS_REBASE in a day while nothing
# anywhere named the git fatal.
#
# WHY REAL GIT AND NOT A FAKE. The whole question is what git does with a
# shallow clone's history and what its index holds when the merge is refused
# outright. A fake git that echoes the answer this test wants would pin nothing:
# every section below builds a real bare origin, a real (shallow, single-branch
# or full) clone of it, and asserts on the real rc, the real stdout, the real
# bytes in logs/merge-conductor.log and the real refs in the bare origin.
#
# THE NEGATIVES CARRY THE WEIGHT. Section 2 is a fatal on a COMPLETE clone
# (`git fetch --unshallow` on one is itself a fatal, so the heal must not fire),
# section 3 is a real conflict (still rc 1 with its file list, no "merge
# failed" line), section 4 is the same classification in mc_restack, and
# section 5 runs bin/bootstrap-machine.sh's own guard block verbatim.
#
# Run from anywhere: tests/mc-rebase-shallow-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# The scratch lib owns $T where the box has it; where it does not (it is not
# tracked on main yet) this suite owns its own tree. An `|| exit 1` here would
# make the suite unrunnable for a reason that has nothing to do with the defect.
# shellcheck source=/dev/null
[ -r "$(dirname "$0")/lib/scratch.sh" ] && . "$(dirname "$0")/lib/scratch.sh"
if [ -z "${T:-}" ]; then T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fi
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ONE clock read, and every fixture commit is stamped from it: a suite whose
# fixtures carry the wall clock picks its own red day.
NOW=$(date +%s)
export GIT_AUTHOR_DATE="@$NOW +0000" GIT_COMMITTER_DATE="@$NOW +0000"

# The library runs against a SCRATCH harness. Nothing here may read or write
# /root/harness (tests/*.sh run as root; the 2026-09-15 trap wiped it).
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state" "$T/h/locks" "$T/h/flags" "$T/h/builds"
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh"
mc_init
: > "$MC_LOG"   # so a section that logs NOTHING reads as zero lines, not as a missing file

# The ONLY seam replaced: the credential half. Everything else — the fetch, the
# worktree, the merge, the push, the cleanup — is the production code path.
REMOTE=""
mc_git_auth()       { MC_REMOTE="$REMOTE"; return 0; }
mc_git_auth_clear() { :; }

# mk_origin <tag> [mode] — a bare origin at $T/<tag>/origin.git with main (40
# commits), a branch forked at commit 5 with one commit of its own, and the
# parent-old/parent-new pair section 4 restacks between. Sets REMOTE, ORIGIN,
# BRANCH, BR_HEAD. mode `conflict` = both sides edit src/a.ts (a REAL conflict);
# mode `generated` = both sides add .harness/specs/BH-601/plan.md, the add/add
# class mc_resolve_conflicts resolves on its own. Never `git push` to build it:
# the act-time iron-law guard refuses that text in a harness file, and
# `git clone --bare` is the same fixture.
mk_origin() { # <tag> [conflict|generated]
  local tag="$1" mode="${2:-}" w i fork
  w="$T/$tag/work"
  BRANCH=ticket/x
  [ "$mode" = generated ] && BRANCH=ticket/bh-600
  mkdir -p "$w"
  git init -q -b main "$w"
  git -C "$w" config user.email t@t
  git -C "$w" config user.name t
  git -C "$w" config commit.gpgsign false
  mkdir -p "$w/src"; echo base > "$w/src/a.ts"
  for i in $(seq 1 40); do
    echo "c$i" > "$w/f$i"
    [ "$i" = 40 ] && [ "$mode" = conflict ] && echo main-side > "$w/src/a.ts"
    [ "$i" = 40 ] && [ "$mode" = generated ] && { mkdir -p "$w/.harness/specs/BH-601"; echo "main copy" > "$w/.harness/specs/BH-601/plan.md"; }
    git -C "$w" add -A; git -C "$w" commit -qm "c$i"
    [ "$i" = 5 ] && fork=$(git -C "$w" rev-parse HEAD)
  done
  git -C "$w" branch -q parent-old "$fork"
  git -C "$w" branch -q parent-new main
  git -C "$w" checkout -q -b "$BRANCH" "$fork"
  echo branch > "$w/b.ts"
  [ "$mode" = conflict ] && echo branch-side > "$w/src/a.ts"
  [ "$mode" = generated ] && { mkdir -p "$w/.harness/specs/BH-601"; echo "branch copy" > "$w/.harness/specs/BH-601/plan.md"; }
  git -C "$w" add -A; git -C "$w" commit -qm "branch work"
  BR_HEAD=$(git -C "$w" rev-parse HEAD)
  git -C "$w" checkout -q main
  ORIGIN="$T/$tag/origin.git"
  git clone -q --bare "$w" "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  REMOTE="file://$ORIGIN"
}

# Every section gets its own hub clone; MC_REPOS is read inside mc_rebase, so
# pointing it at the section's tree is enough.
hub_clone() { # <tag> <clone-args...>
  local tag="$1"; shift
  mkdir -p "$T/$tag/repos"
  git clone -q "$@" "file://$ORIGIN" "$T/$tag/repos/demo-os"
  git -C "$T/$tag/repos/demo-os" config user.email t@t
  git -C "$T/$tag/repos/demo-os" config user.name t
  git -C "$T/$tag/repos/demo-os" config commit.gpgsign false
  export MC_REPOS="$T/$tag/repos"
}

shallow() { [ "$(git -C "$1" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; }
logn()    { grep -c "$1" "$MC_LOG" 2>/dev/null || true; }

# ============================================================================
# (1) A SHALLOW hub clone: the fatal is named, the clone is unshallowed ONCE,
#     the merge is retried in the SAME call, and the PR lands rebased.
# ============================================================================
mk_origin s1
hub_clone s1 --depth 10 --no-single-branch
shallow "$T/s1/repos/demo-os" && ok || bad "(1) fixture: the clone should be shallow to begin with"
N0=$(logn "pull/1")
OUT=$(mc_rebase o/r demo-os ticket/x "$BR_HEAD" https://github.com/o/r/pull/1); RC=$?
[ "$RC" = 0 ] && ok || bad "(1) a shallow clone must heal and rebase, got rc $RC (log: $(grep 'pull/1' "$MC_LOG" | tail -3))"
[ -n "$OUT" ] && [ "$OUT" = "$(git -C "$ORIGIN" rev-parse ticket/x)" ] \
  && ok || bad "(1) stdout must be the new head that was pushed: '$OUT' vs $(git -C "$ORIGIN" rev-parse ticket/x)"
git -C "$ORIGIN" merge-base --is-ancestor main ticket/x \
  && ok || bad "(1) origin/main must be an ancestor of the pushed branch — the merge did not land"
[ "$(logn 'is a SHALLOW clone')" = 1 ] \
  && ok || bad "(1) exactly one line must name the shallow clone, got $(logn 'is a SHALLOW clone')"
[ "$(logn unshallowed)" = 1 ] \
  && ok || bad "(1) the unshallow must be logged exactly once, got $(logn unshallowed)"
grep -q "$T/s1/repos/demo-os is a SHALLOW clone (1 boundary commit(s))" "$MC_LOG" \
  && ok || bad "(1) the line must name the repo and the boundary count: $(grep SHALLOW "$MC_LOG")"
shallow "$T/s1/repos/demo-os" && bad "(1) the hub clone must not still be shallow" || ok
[ "$(logn 'pull/1')" -ge $(( N0 + 1 )) ] \
  && ok || bad "(1) the PR's rebase must say something in the log (was $N0, now $(logn 'pull/1'))"
[ "$(git -C "$T/s1/repos/demo-os" worktree list | wc -l)" = 1 ] \
  && ok || bad "(1) the scratch worktree must be cleaned up: $(git -C "$T/s1/repos/demo-os" worktree list)"

# ============================================================================
# (2) NEGATIVE — a COMPLETE clone with a fatal merge: logged, rc 4, and the
#     heal must NOT fire (git fetch --unshallow on a complete repo is itself a
#     fatal, and a second fatal is not a diagnosis).
# ============================================================================
mk_origin s2
hub_clone s2 --single-branch --branch ticket/x
shallow "$T/s2/repos/demo-os" && bad "(2) fixture: this clone must be complete" || ok
BEFORE=$(git -C "$ORIGIN" rev-parse ticket/x)
OUT=$(mc_rebase o/r demo-os ticket/x "$BR_HEAD" https://github.com/o/r/pull/2); RC=$?
[ "$RC" = 4 ] && ok || bad "(2) a merge git refused is rc 4, got $RC"
[ -z "$OUT" ] && ok || bad "(2) a fatal prints NOTHING on stdout (never an empty conflict list): '$OUT'"
grep -q 'pull/2 rebase: merge failed — merge: origin/main - not something we can merge' "$MC_LOG" \
  && ok || bad "(2) the fatal must be logged with git's own words: $(grep 'pull/2' "$MC_LOG")"
[ "$(grep 'pull/2' "$MC_LOG" | grep -c 'SHALLOW\|unshallowed')" = 0 ] \
  && ok || bad "(2) a complete clone must never be unshallowed: $(grep 'pull/2' "$MC_LOG")"
[ "$(git -C "$ORIGIN" rev-parse ticket/x)" = "$BEFORE" ] \
  && ok || bad "(2) nothing may be pushed when the merge never happened"
[ "$(git -C "$T/s2/repos/demo-os" worktree list | wc -l)" = 1 ] \
  && ok || bad "(2) the scratch worktree must be cleaned up after a fatal"

# ============================================================================
# (3) NEGATIVE — a REAL conflict is unchanged: rc 1, the file list on stdout,
#     and no "merge failed" line (it is not a fatal and must not read as one).
# ============================================================================
mk_origin s3 conflict
hub_clone s3
BEFORE=$(git -C "$ORIGIN" rev-parse ticket/x)
OUT=$(mc_rebase o/r demo-os ticket/x "$BR_HEAD" https://github.com/o/r/pull/3); RC=$?
[ "$RC" = 1 ] && ok || bad "(3) a real conflict is still rc 1, got $RC"
[ "$OUT" = "src/a.ts" ] && ok || bad "(3) stdout must be the conflict list: '$OUT'"
[ "$(grep 'pull/3' "$MC_LOG" | grep -c 'merge failed')" = 0 ] \
  && ok || bad "(3) a conflict must not be logged as a fatal: $(grep 'pull/3' "$MC_LOG")"
[ "$(git -C "$ORIGIN" rev-parse ticket/x)" = "$BEFORE" ] \
  && ok || bad "(3) a conflicted rebase pushes nothing"

# ============================================================================
# (4) mc_restack: a rebase git refused outright is a FATAL too — logged, rc 4,
#     stdout EMPTY. Before BH-517 it answered rc 1 with a conflict list of zero
#     files, which reads downstream as "a conflict nobody can name".
# ============================================================================
mk_origin s4
hub_clone s4 --single-branch --branch ticket/x
OUT=$(mc_restack o/r demo-os ticket/x "$BR_HEAD" parent-old parent-new https://github.com/o/r/pull/4); RC=$?
[ "$RC" = 4 ] && ok || bad "(4) a rebase git refused is rc 4, got $RC"
[ -z "$OUT" ] && ok || bad "(4) a fatal restack prints NOTHING on stdout: '$OUT'"
grep -q 'pull/4 restack: rebase --onto failed — fatal: invalid upstream' "$MC_LOG" \
  && ok || bad "(4) the restack fatal must be logged with git's own words: $(grep 'pull/4' "$MC_LOG")"

# ============================================================================
# (5) bin/bootstrap-machine.sh's guard, extracted VERBATIM by its markers and
#     driven against a scratch /root/repos: a shallow clone ends complete, a
#     complete one is left alone, rc 0 both.
# ============================================================================
mk_origin s5
mkdir -p "$T/boot/repos"
awk '/^# >>> repo not shallow/{f=1;next} /^# <<< repo not shallow/{exit} f' \
  "$DIR/bin/bootstrap-machine.sh" | sed "s|/root/repos|$T/boot/repos|g" > "$T/boot/block.sh"
[ -s "$T/boot/block.sh" ] && ok || bad "(5) could not extract the bootstrap block — markers missing?"
git clone -q --depth 5 --no-single-branch "file://$ORIGIN" "$T/boot/repos/demo-os"
shallow "$T/boot/repos/demo-os" && ok || bad "(5) fixture: the bootstrap clone must start shallow"
PROJECT=demo-os bash "$T/boot/block.sh" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "(5) the guard must heal a shallow clone and exit 0, got $RC"
shallow "$T/boot/repos/demo-os" && bad "(5) the guard left the clone shallow" || ok
git clone -q "file://$ORIGIN" "$T/boot/repos/full-os"
PROJECT=full-os bash "$T/boot/block.sh" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "(5) a complete clone must pass the guard untouched, got $RC"

# ============================================================================
# (6) The OTHER silent rc 4: the conflicts resolve, and the commit of the
#     resolved merge is what fails. Induced with a real pre-commit hook that
#     refuses, because the failure has to come from git rather than from the
#     test's opinion of it. Before BH-517 this arm returned 4 having said
#     nothing at all.
# ============================================================================
mk_origin s6 generated
hub_clone s6
mkdir -p "$T/s6/hooks"
printf '#!/bin/sh\nexit 1\n' > "$T/s6/hooks/pre-commit"; chmod +x "$T/s6/hooks/pre-commit"
git -C "$T/s6/repos/demo-os" config core.hooksPath "$T/s6/hooks"
BEFORE=$(git -C "$ORIGIN" rev-parse "$BRANCH")
OUT=$(mc_rebase o/r demo-os "$BRANCH" "$BR_HEAD" https://github.com/o/r/pull/6); RC=$?
[ "$RC" = 4 ] && ok || bad "(6) a commit that fails is rc 4, got $RC"
[ -z "$OUT" ] && ok || bad "(6) a failed commit prints nothing on stdout: '$OUT'"
grep -q 'pull/6 rebase: commit of the resolved merge failed — ' "$MC_LOG" \
  && ok || bad "(6) the commit failure must say so: $(grep 'pull/6' "$MC_LOG")"
[ "$(git -C "$ORIGIN" rev-parse "$BRANCH")" = "$BEFORE" ] \
  && ok || bad "(6) nothing may be pushed when the merge was never committed"

echo "mc-rebase-shallow: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
