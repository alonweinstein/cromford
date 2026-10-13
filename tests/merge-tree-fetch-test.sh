#!/bin/bash
# tests/merge-tree-fetch-test.sh — THE MERGE-TREE TEST FETCHES WHAT IT IS ABOUT
# TO MERGE (2026-09-16, lever 5 of the project-5 acceleration).
#
# THE BUG. mc_merge_tree asks `git merge-tree --write-tree origin/main <head>`
# about two commits, and neither one is in the conductor's clone by accident:
# a PR head arrives there only if something fetched it, and origin/main is only
# as fresh as the last fetch. When either is missing the function answered rc 2
# and the conductor logged ONE line for every cause it has —
#   "MERGE_TREE could not be computed on <sha> (no token, an unknown sha, or
#    git older than 2.38) — rebasing, as before"
# — 177 times on the hub on 2026-09-16, on a box whose git is 2.43. Every one
# of those lines is a rebase the merge-tree test exists to avoid: a lease, a
# push that moves the head, and the re-review the move buys.
#
# WHAT IS ASSERTED HERE
#   1. the fixture is the real thing: a clone that does NOT have the head and
#      whose origin/main is stale, exactly like a conductor clone meeting a PR
#      it has never fetched;
#   2. mc_merge_tree now brings both sides in first, and answers clean/conflict
#      on a head it did not have;
#   3. the explicit main refspec: a clone whose configured refspec does not
#      cover main keeps a STALE origin/main under the old `fetch origin main`,
#      and merge-tree would then answer about the wrong main — a wrong answer,
#      not a missing one;
#   4. the refs/pull/<n>/head fallback, for a remote that will not serve a head
#      by sha (`uploadpack.allowAnySHA1InWant` off, or a fork's head);
#   5. the three causes are three log lines, so a fetch that has been failing
#      all day can never again read as a box with an old git;
#   6. a fetch that cannot be made still rebases, exactly as before.
#
# Real git, real merges, a real bare origin, no network: the fake remote url is
# pointed back at a local bare repo with url.<path>.insteadOf, as the merge
# funnel test does.
#
# Run from anywhere: tests/merge-tree-fetch-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

SLUG=example-org/demo-os
PROJ=demo-os
NUM=21

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add

# --- the origin, and a clone taken BEFORE the PR branches existed ------------
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
mkdir -p "$T/seed/src"
printf 'A1\n' > "$T/seed/src/a.ts"
printf 'B1\n' > "$T/seed/src/b.ts"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm base && git -C "$T/seed" push -q origin main
BASE=$(git -C "$T/seed" rev-parse HEAD)

mkdir -p "$T/repos"
# THE CLONE THE CONDUCTOR MEETS THE PR WITH: taken at BASE, before the branch
# was pushed and before main moved. This is the whole point of the fixture.
git clone -q "$T/origin.git" "$T/repos/$PROJ" 2>/dev/null

# ticket/clean — a new file nothing else touches.
git -C "$T/seed" checkout -q -b ticket/clean "$BASE"
printf 'export const c = 1\n' > "$T/seed/src/c.ts"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm clean && git -C "$T/seed" push -q origin ticket/clean
CLEAN_HEAD=$(git -C "$T/seed" rev-parse HEAD)

# ticket/dirty — edits the line main is about to edit.
git -C "$T/seed" checkout -q -b ticket/dirty "$BASE"
printf 'A-branch\n' > "$T/seed/src/a.ts"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm dirty && git -C "$T/seed" push -q origin ticket/dirty
DIRTY_HEAD=$(git -C "$T/seed" rev-parse HEAD)

# main moves under both of them.
git -C "$T/seed" checkout -q main
printf 'A2\n' > "$T/seed/src/a.ts"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm advance && git -C "$T/seed" push -q origin main
MAIN_HEAD=$(git -C "$T/seed" rev-parse HEAD)

# GitHub serves every open PR's head at refs/pull/<n>/head; the fixture does too.
git -C "$T/origin.git" update-ref "refs/pull/$NUM/head" "$CLEAN_HEAD"

# --- the harness tree --------------------------------------------------------
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/locks" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
: > "$T/h/env/global.env"
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
case "$*" in *"auth token"*) echo faketoken ;; *) echo "" ;; esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
export MC_REPOS="$T/repos"
LOG="$T/h/logs/merge-conductor.log"

mc_git_has_merge_tree || { echo "git $(git --version | awk '{print $3}') has no merge-tree --write-tree — nothing here applies; skipping"; exit 0; }

echo "== 1. the fixture: the clone does not have the head, and its main is stale =="
git -C "$T/repos/$PROJ" cat-file -e "${CLEAN_HEAD}^{commit}" 2>/dev/null \
  && bad "the fixture clone already has the PR head — it proves nothing about fetching" || ok
[ "$(git -C "$T/repos/$PROJ" rev-parse origin/main)" = "$BASE" ] && ok \
  || bad "the fixture clone's origin/main is not the stale one the test needs"

echo "== 2. a head the clone never had gets an answer, not a shrug =="
OUT=$(mc_merge_tree "$SLUG" "$PROJ" "$CLEAN_HEAD" "$NUM"); RC=$?
[ "$RC" = 0 ] && ok || bad "a clean head absent from the clone answered rc $RC ($OUT) instead of rc 0"
git -C "$T/repos/$PROJ" cat-file -e "${CLEAN_HEAD}^{commit}" 2>/dev/null && ok \
  || bad "the head was never fetched into the clone"
[ "$(git -C "$T/repos/$PROJ" rev-parse origin/main)" = "$MAIN_HEAD" ] && ok \
  || bad "origin/main was not refreshed before the merge-tree call"

OUT=$(mc_merge_tree "$SLUG" "$PROJ" "$DIRTY_HEAD" "$NUM"); RC=$?
[ "$RC" = 1 ] && ok || bad "a head that really conflicts answered rc $RC ($OUT) instead of rc 1"
grep -q 'src/a.ts' <<<"$OUT" && ok || bad "the conflict answer does not name the conflicting path: $OUT"

echo "== 3. the explicit main refspec: a narrowed clone must not be judged against a stale main =="
# A clone whose configured refspec does not cover main. `fetch origin main`
# puts main in FETCH_HEAD and leaves refs/remotes/origin/main alone — which is
# the shape that turns a conflict into a clean answer.
NARROW=demo-narrow
git clone -q "$T/origin.git" "$T/repos/$NARROW" 2>/dev/null
git -C "$T/repos/$NARROW" config --unset-all remote.origin.fetch
git -C "$T/repos/$NARROW" update-ref refs/remotes/origin/main "$BASE"
git -C "$T/repos/$NARROW" fetch -q origin main "$DIRTY_HEAD" 2>/dev/null
[ "$(git -C "$T/repos/$NARROW" rev-parse origin/main)" = "$BASE" ] && ok \
  || bad "the fixture is wrong: 'fetch origin main' DID refresh a refspec-less clone, so this section proves nothing"
# Against the stale main this head merges clean; against the real one it does not.
git -C "$T/repos/$NARROW" merge-tree --write-tree --name-only origin/main "$DIRTY_HEAD" >/dev/null 2>&1 \
  && ok || bad "the fixture is wrong: the stale main already conflicts, so a stale answer is indistinguishable"
OUT=$(mc_merge_tree "$SLUG" "$NARROW" "$DIRTY_HEAD" "$NUM"); RC=$?
[ "$RC" = 1 ] && ok || bad "a narrowed clone answered rc $RC ($OUT) — merge-tree was run against a stale origin/main"
[ "$(git -C "$T/repos/$NARROW" rev-parse origin/main)" = "$MAIN_HEAD" ] && ok \
  || bad "the explicit refspec did not refresh origin/main in a clone whose configured refspec misses it"

echo "== 4. refs/pull/<n>/head, for a remote that will not serve a head by sha =="
# A local origin always serves a sha, so the refusal GitHub makes when
# uploadpack.allowAnySHA1InWant is off (and for every fork head) is made here
# by a git on PATH that refuses exactly that one fetch shape and passes
# everything else through. It is the server's answer that is being faked, not
# git's behaviour.
mkdir -p "$T/shastub"
cat > "$T/shastub/git" <<EOF
#!/bin/bash
fetch=0; sha=0
for a in "\$@"; do
  [ "\$a" = fetch ] && fetch=1
  case "\$a" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ "\${#a}" = 40 ] && sha=1 ;; esac
done
if [ "\$fetch" = 1 ] && [ "\$sha" = 1 ]; then
  echo "fatal: remote error: upload-pack: not our ref \$*" >&2; exit 128
fi
exec /usr/bin/git "\$@"
EOF
chmod +x "$T/shastub/git"
PULLPROJ=demo-pull
# --no-local: a local clone HARDLINKS every object in the origin, branches the
# clone never asked for included, and the head would be there before any fetch.
PULLHEAD=$(git -C "$T/origin.git" rev-parse "refs/pull/$NUM/head")
( export PATH="$T/shastub:$PATH"
  /usr/bin/git clone -q --no-local --single-branch --branch main "$T/origin.git" "$T/repos/$PULLPROJ" 2>/dev/null
  /usr/bin/git -C "$T/repos/$PULLPROJ" cat-file -e "${PULLHEAD}^{commit}" 2>/dev/null && { echo "SETUP: the head is already in the single-branch clone"; exit 9; }
  OUT=$(mc_merge_tree "$SLUG" "$PULLPROJ" "$PULLHEAD" "$NUM"); RC=$?
  [ "$RC" = 0 ] || { echo "GOT rc=$RC out=$OUT"; exit 1; }
  /usr/bin/git -C "$T/repos/$PULLPROJ" cat-file -e "${PULLHEAD}^{commit}" 2>/dev/null || { echo "the PR ref did not bring the head in"; exit 2; }
  exit 0 )
case "$?" in
  0) ok ;;
  *) bad "a head the remote refuses by sha must come in through refs/pull/$NUM/head" ;;
esac
# With no PR number there is no second name to try: that is a fetch failure,
# and a fetch failure says so.
( export PATH="$T/shastub:$PATH"
  NOPULL=demo-nopull
  /usr/bin/git clone -q --no-local --single-branch --branch main "$T/origin.git" "$T/repos/$NOPULL" 2>/dev/null
  OUT=$(mc_merge_tree "$SLUG" "$NOPULL" "$PULLHEAD"); RC=$?
  [ "$RC" = 3 ] || { echo "GOT rc=$RC out=$OUT"; exit 1; }
  grep -q 'not in the clone' <<<"$OUT" || { echo "reason does not name the cause: $OUT"; exit 2; }
  exit 0 )
[ "$?" = 0 ] && ok || bad "an unfetchable head must be rc 3 with a reason that names the fetch, not a bare 'could not tell'"

echo "== 5. the three causes are three answers =="
# An old git is rc 2 and nothing else — never confused with a fetch.
( mkdir -p "$T/oldgit"
  printf '#!/bin/bash\n[ "$1" = --version ] && { echo "git version 2.30.2"; exit 0; }\nexec /usr/bin/git "$@"\n' > "$T/oldgit/git"
  chmod +x "$T/oldgit/git"
  PATH="$T/oldgit:$PATH" mc_merge_tree "$SLUG" "$PROJ" "$CLEAN_HEAD" "$NUM" >/dev/null 2>&1
  [ "$?" = 2 ] ) && ok || bad "git 2.30 must answer rc 2 (no merge-tree --write-tree), not a fetch failure"
# A sha nothing has is a fetch failure (rc 3), never "clean" and never rc 2.
OUT=$(mc_merge_tree "$SLUG" "$PROJ" 0000000000000000000000000000000000000000 "$NUM" 2>/dev/null); RC=$?
[ "$RC" = 3 ] && ok || bad "an unknown sha must answer rc 3 (could not be fetched), got rc $RC"
[ -n "$OUT" ] && ok || bad "rc 3 must print why; it printed nothing"
# No head at all is a caller error, and it is still never an answer.
mc_merge_tree "$SLUG" "$PROJ" "-" "$NUM" >/dev/null 2>&1
[ "$?" = 3 ] && ok || bad "an empty head must not reach merge-tree"

echo "== 6. merge_tree_clean: the conductor's side of it =="
# merge_tree_clean lives in bin/merge-conductor.sh, which runs a whole tick when
# sourced, so the function is lifted out by name and called directly.
sed -n '/^merge_tree_clean() {/,/^}/p' "$DIR/bin/lib/mc/rebase.sh" > "$T/mtc.sh"
grep -q 'mc_merge_tree' "$T/mtc.sh" && ok || bad "merge_tree_clean could not be lifted out of bin/lib/mc/rebase.sh"
# shellcheck source=/dev/null
. "$T/mtc.sh"

FRESH=demo-fresh
git clone -q "$T/origin.git" "$T/repos/$FRESH" 2>/dev/null
git -C "$T/repos/$FRESH" update-ref refs/remotes/origin/main "$BASE"
: > "$LOG"
merge_tree_clean "$SLUG#$NUM" "$SLUG" "$FRESH" "$CLEAN_HEAD" "$NUM"; RC=$?
[ "$RC" = 0 ] && ok || bad "merge_tree_clean must leave a cleanly-merging head alone (rc $RC): $(tail -2 "$LOG")"
grep -q 'MERGE_TREE clean' "$LOG" && ok || bad "no MERGE_TREE clean line: $(tail -2 "$LOG")"
grep -q 'could not be computed' "$LOG" && bad "the old catch-all line is still being logged" || ok

: > "$LOG"
merge_tree_clean "$SLUG#$NUM" "$SLUG" "$FRESH" "$DIRTY_HEAD" "$NUM"; RC=$?
[ "$RC" = 1 ] && ok || bad "a real conflict must still take the rebase path (rc $RC)"
grep -q 'MERGE_TREE conflict' "$LOG" && ok || bad "no MERGE_TREE conflict line: $(tail -2 "$LOG")"

# A fetch that cannot be made: today's behaviour (rebase), tomorrow's log line.
: > "$LOG"
merge_tree_clean "$SLUG#$NUM" "$SLUG" "$FRESH" 0000000000000000000000000000000000000000 "$NUM"; RC=$?
[ "$RC" = 1 ] && ok || bad "a failed fetch must keep today's behaviour and rebase (rc $RC)"
grep -q 'MERGE_TREE fetch failed' "$LOG" && ok || bad "a failed fetch must say so: $(tail -2 "$LOG")"
# The WORDING moved with BH-764 and the CLAIM did not: this arm still takes the
# rebase path (the rc 1 above), and the line still says so — but it no longer
# says "rebasing", because the tick spawns a detached job and three of the arm's
# exits then rebase nothing at all. A line that is false in the state that
# prints it is the bug that rename closed.
grep -q 'this head needs a rebase, as before' "$LOG" && ok || bad "the fetch-failure line must still say this head takes the rebase path, as before"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
