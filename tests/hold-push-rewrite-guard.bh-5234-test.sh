#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/hold-push-rewrite-guard.bh-5234-test.sh — BH-5234: a push that REWRITES
# a PR branch never orphans the PRs stacked on it.
#
# A PR branch with open children (PRs whose base is this branch) is a parent.
# Rewriting it (an amend, a rebase: the lease is no longer an ancestor of what
# is pushed) leaves every child based on commits that are no longer on its
# base. So:
#   G  bin/lib/hold-push.sh — after the hold verdict, before the push, a
#      rewrite reads the branch's open children through sp_open_children
#      (bin/lib/stale-parent.sh) and refuses with rc 5 when there are any,
#      rc 4 when the read fails. A fast-forward, a `new` lease,
#      HOLD_PUSH_CHILDREN=follow and HOLD_PUSH_REWRITE_GUARD=0 read nothing
#      or push anyway.
#   G8 bin/lib/rb/pr.sh's pre-PR update (`# >>> rebase verify`) — a branch
#      that is already published and has children (or whose children cannot
#      be read) is updated by MERGING origin/$BASE, never by a rebase.
# Both are driven against real git; only gh_rest (a shell function) is faked.
# Run from anywhere: tests/hold-push-rewrite-guard.bh-5234-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

# An isolated git identity: nothing from the box's own config leaks in.
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email fixture@example.invalid
git config --global user.name FIXTURE
git config --global commit.gpgsign false
git config --global init.defaultBranch main

# --- the sources under test --------------------------------------------------------
[ -f "$DIR/bin/lib/hold-push.sh" ] && ok || bad "bin/lib/hold-push.sh is missing"
[ -f "$DIR/bin/lib/rb/pr.sh" ] && ok || bad "bin/lib/rb/pr.sh is missing"
# Not an early exit: the lib is the feature, and its absence is a red, not a skip.
[ -f "$DIR/bin/lib/stale-parent.sh" ] && ok || bad "bin/lib/stale-parent.sh does not exist — nothing can read a branch's open children"

# --- the scratch harness: hold-push.sh as it ships, fleet-conf.sh one dir up -------
mkdir -p "$T/h/bin/lib"
scratch_install_closure bin/lib/hold-push.sh "$T/h" >/dev/null || bad "could not install bin/lib/hold-push.sh's closure"
scratch_install_closure bin/fleet-conf.sh "$T/h" >/dev/null || bad "could not install bin/fleet-conf.sh"
if [ -f "$DIR/bin/lib/stale-parent.sh" ]; then
  scratch_install_closure bin/lib/stale-parent.sh "$T/h" >/dev/null || bad "could not install bin/lib/stale-parent.sh's closure"
fi
# A BOARD project (board_prefix is a path, not "-"): no GitHub-issue hold read.
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
[ "$(bash "$T/h/bin/fleet-conf.sh" demo-os repo)" = example-org/demo-os ] && ok || bad "fixture: fleet-conf.sh must answer demo-os -> example-org/demo-os"
BP=$(bash "$T/h/bin/fleet-conf.sh" demo-os board_prefix)
[ -n "$BP" ] && [ "$BP" != - ] && ok || bad "fixture: demo-os must be a board project (board_prefix '$BP')"
HP="$T/h/bin/lib/hold-push.sh"

# --- the fake GitHub: one REST read, answered per $T/kids-mode ---------------------
gh_rest() {
  printf '%s\n' "$*" >> "$T/rest-calls.txt"
  case "$*" in
    *'pulls?state=open&base=ticket%2Fbh-1&per_page=100'*)
      case "$(cat "$T/kids-mode" 2>/dev/null)" in
        11)   printf '%s\n' '[{"number":11}]'; return 0 ;;
        none) printf '%s\n' '[]'; return 0 ;;
        500)  printf '%s\n' '{"message":"boom"}'; return 75 ;;
      esac ;;
  esac
  return 75
}
kids() { printf '%s\n' "$1" > "$T/kids-mode"; }
pulls_read() { grep -q 'pulls?state=open' "$T/rest-calls.txt" 2>/dev/null; }

# ============================================================================
# G — bin/lib/hold-push.sh
# ============================================================================
O="$T/origin.git"; WT="$T/wt"; BR=ticket/bh-1
git init -q --bare "$O"
git clone -q "$O" "$WT" 2>/dev/null
echo base > "$WT/f.txt"; git -C "$WT" add f.txt; git -C "$WT" commit -qm base
git -C "$WT" push -q origin HEAD:refs/heads/main
git -C "$WT" checkout -qb "$BR"
echo pr > "$WT/pr.txt"; git -C "$WT" add pr.txt; git -C "$WT" commit -qm "BH-1: the PR"
git -C "$WT" push -q origin "HEAD:refs/heads/$BR"
B1=$(git -C "$O" rev-parse "refs/heads/$BR")
remote_tip() { git -C "$O" rev-parse -q --verify "refs/heads/$1" 2>/dev/null; }
[ -n "$B1" ] && ok || bad "fixture: origin has no $BR"

# reset — origin's branch back to B1, the worktree on B1, no calls recorded.
reset() {
  git -C "$O" update-ref "refs/heads/$BR" "$B1"
  git -C "$O" update-ref -d refs/heads/ticket/bh-77 2>/dev/null
  git -C "$WT" checkout -q -B "$BR" "$B1"
  git -C "$WT" fetch -q origin 2>/dev/null
  : > "$T/rest-calls.txt"
}
amend() { git -C "$WT" commit -q --amend -m "BH-1: the PR, amended ($1)"; NEW=$(git -C "$WT" rev-parse HEAD); }
PUSH() { # PUSH <branch> <lease> [env...] -> rc; stderr in $T/push.err
  local b="$1" l="$2"; shift 2
  ( for a in "$@"; do export "${a?}"; done
    . "$HP" 2>/dev/null || exit 99
    hold_push demo-os - "$WT" "$O" HEAD "$b" "$l" ) 2>"$T/push.err"
}

# G1 — a fast-forward pushes and never reads children
reset; kids 11
echo more >> "$WT/pr.txt"; git -C "$WT" commit -qam "BH-1: more"; NEW=$(git -C "$WT" rev-parse HEAD)
PUSH "$BR" "$B1"; RC=$?
[ "$RC" = 0 ] && ok || bad "G1 a fast-forward must push (rc $RC: $(cat "$T/push.err"))"
[ "$(remote_tip "$BR")" = "$NEW" ] && ok || bad "G1 origin must hold the new head"
pulls_read && bad "G1 a fast-forward must not read children: $(cat "$T/rest-calls.txt")" || ok

# G2 — a rewrite of a branch with an open child is refused, rc 5
reset; kids 11; amend g2
PUSH "$BR" "$B1"; RC=$?
[ "$RC" = 5 ] && ok || bad "G2 a rewrite with open child #11 must be refused with rc 5 (got $RC: $(cat "$T/push.err"))"
[ "$(remote_tip "$BR")" = "$B1" ] && ok || bad "G2 nothing may reach origin when a rewrite would orphan #11"
[ "$(grep -c "NOT rewriting $BR.*#11" "$T/push.err")" = 1 ] && ok \
  || bad "G2 exactly one line 'NOT rewriting $BR: open stacked children #11' on stderr: $(cat "$T/push.err")"
pulls_read && ok || bad "G2 a rewrite must read the branch's open children"

# G3 — a rewrite of a branch with no children pushes as today
reset; kids none; amend g3
PUSH "$BR" "$B1"; RC=$?
[ "$RC" = 0 ] && ok || bad "G3 a rewrite with no children must push (rc $RC: $(cat "$T/push.err"))"
[ "$(remote_tip "$BR")" = "$NEW" ] && ok || bad "G3 origin must hold the amended head"

# G4 — children unreadable: nothing pushed, rc 4
reset; kids 500; amend g4
PUSH "$BR" "$B1"; RC=$?
[ "$RC" = 4 ] && ok || bad "G4 a rewrite whose children cannot be read must return rc 4 (got $RC: $(cat "$T/push.err"))"
[ "$(remote_tip "$BR")" = "$B1" ] && ok || bad "G4 nothing may reach origin when the children are unreadable"

# G5 — HOLD_PUSH_CHILDREN=follow: the caller takes the children along, push
reset; kids 11; amend g5
PUSH "$BR" "$B1" HOLD_PUSH_CHILDREN=follow; RC=$?
[ "$RC" = 0 ] && ok || bad "G5 HOLD_PUSH_CHILDREN=follow must push the rewrite (rc $RC: $(cat "$T/push.err"))"
[ "$(remote_tip "$BR")" = "$NEW" ] && ok || bad "G5 origin must hold the amended head"

# G6 — HOLD_PUSH_REWRITE_GUARD=0: guard off, nothing read, push
reset; kids 11; amend g6
PUSH "$BR" "$B1" HOLD_PUSH_REWRITE_GUARD=0; RC=$?
[ "$RC" = 0 ] && ok || bad "G6 HOLD_PUSH_REWRITE_GUARD=0 must push the rewrite (rc $RC: $(cat "$T/push.err"))"
[ "$(remote_tip "$BR")" = "$NEW" ] && ok || bad "G6 origin must hold the amended head"
pulls_read && bad "G6 the guard switched off must read nothing: $(cat "$T/rest-calls.txt")" || ok

# G7 — lease `new` is never a rewrite
reset; kids 11; amend g7
PUSH ticket/bh-77 new; RC=$?
[ "$RC" = 0 ] && ok || bad "G7 a new branch must push (rc $RC: $(cat "$T/push.err"))"
[ "$(remote_tip ticket/bh-77)" = "$NEW" ] && ok || bad "G7 origin must hold ticket/bh-77"
pulls_read && bad "G7 lease 'new' must read nothing: $(cat "$T/rest-calls.txt")" || ok

# ============================================================================
# G8 — bin/lib/rb/pr.sh: the pre-PR update of a published parent MERGES
# ============================================================================
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> rebase verify/{f=1;next} /^# <<< rebase verify/{exit} f' "$RB_ALL" > "$T/stage.sh"
[ -s "$T/stage.sh" ] && ok || bad "G8 could not extract the rebase-verify block — markers missing?"

R="$T/g8"
g8_repo() { # main moved past the branch; the branch is already on origin
  scratch_rm "$R"; mkdir -p "$R"
  ( cd "$R" || exit 1
    git init -q -b main
    echo base > a.txt; git add -A; git commit -qm base
    git checkout -qb "$BR"
    echo w > w.txt; git add -A; git commit -qm "BH-1: work"
    git update-ref "refs/remotes/origin/$BR" HEAD
    git checkout -q main
    echo m > m.txt; git add -A; git commit -qm "main moved"
    git checkout -q "$BR"
    git remote add origin https://github.com/example-org/demo-os.git
    # The block's fetch must fail fast, never touch the network; it is `|| true`.
    git config protocol.https.allow never
    git update-ref refs/remotes/origin/main main
  ) >/dev/null 2>&1
  W=$(git -C "$R" rev-parse HEAD)
  M=$(git -C "$R" rev-parse refs/remotes/origin/main)
}
run_g8() { # run_g8 <kids-mode>
  kids "$1"; g8_repo; : > "$T/rest-calls.txt"
  scratch_rm "$T/build"; mkdir -p "$T/build"
  ( cd "$R" || exit 1
    BASE=main BRANCH="$BR" STACK_ON="" PROJECT=demo-os KEY=BH-1 BUILD="$T/build" HARNESS="$T/h"
    STAMP() { echo TS; }
    REBASE_NOTE=""
    . "$T/stage.sh"
  ) > "$T/g8.out" 2>&1
}
log_has() { grep -q "$1" "$T/build/pipeline.log" 2>/dev/null; }
merged_case() { # merged_case <kids-mode> <why>
  run_g8 "$1"
  git -C "$R" rev-parse -q --verify HEAD^2 >/dev/null 2>&1 && ok \
    || bad "G8 $2: HEAD must be a merge commit (log: $(cat "$T/build/pipeline.log" 2>/dev/null))"
  [ "$(git -C "$R" rev-parse HEAD^1 2>/dev/null)" = "$W" ] && ok \
    || bad "G8 $2: the merge's first parent must be the pre-update head"
  git -C "$R" merge-base --is-ancestor "$W" HEAD && ok \
    || bad "G8 $2: the published origin/$BR head must stay an ancestor of HEAD"
  git -C "$R" merge-base --is-ancestor "$M" HEAD && ok \
    || bad "G8 $2: origin/main must be merged in"
  log_has 'pre-PR update by MERGE' && ok || bad "G8 $2: pipeline.log must say 'pre-PR update by MERGE'"
}
merged_case 11  "open child #11"
merged_case 500 "children unreadable"

# no children: the rebase path, exactly as today
run_g8 none
git -C "$R" rev-parse -q --verify HEAD^2 >/dev/null 2>&1 \
  && bad "G8 no children: HEAD must not be a merge commit" || ok
[ "$(git -C "$R" rev-parse HEAD^ 2>/dev/null)" = "$M" ] && ok \
  || bad "G8 no children: the branch must be rebased onto origin/main (log: $(cat "$T/build/pipeline.log" 2>/dev/null))"
log_has 'rebased onto origin/main' && ok || bad "G8 no children: pipeline.log must say 'rebased onto origin/main'"
log_has 'by MERGE' && bad "G8 no children: must not take the MERGE path" || ok

echo "hold-push-rewrite-guard: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
