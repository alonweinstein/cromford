#!/bin/bash
# tests/schema-build-merge-edit.bh-5918-test.sh — bin/schema-build.sh --write
# does not refuse a statement that a merge commit on the branch edited.
#
# WHAT THIS PINS (BH-5918, seen on #5892). The --write guard (NO STATEMENT IS
# EVER DROPPED) reads the branch history for statements a commit added to
# schema.sql. It read only non-merge commits, so a merge that edited a
# statement (fragment and render together) never marked the old text as
# removed. A pre-split commit that added the old text to schema.sql then made
# every later --write refuse it, while --check was green on the same tree.
#
#   M1 the #5892 shape: pre-split add, moved into a fragment, edited in a merge,
#      one more commit, one more main merge — --write rc 0, writes nothing new,
#      no refusal, one CREATE TABLE x; --check rc 0
#   M2 the literal ticket shape: a fragment plus its render, edited in a merge,
#      then another merge — --write and --check rc 0
#   N1 a pre-split statement a merge dropped with --theirs (no fragment held
#      it) is still refused
#   N2 a pre-split statement that a merge dropped from schema.sql while no
#      fragment of the merge's first parent held it is still refused
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export GIT_AUTHOR_DATE="@1790000000 +0000" GIT_COMMITTER_DATE="@1790000000 +0000"
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"; mkdir -p "$HOME"

BASE='CREATE TABLE a (id INTEGER PRIMARY KEY, name TEXT);
-- b holds the second thing
CREATE TABLE b (id INTEGER PRIMARY KEY);'
XOLD='CREATE TABLE x (id INTEGER, note TEXT);'
XNEW='CREATE TABLE x (id INTEGER);'
SQL=worker/jobs/schema.sql
FRD=worker/jobs/schema.d

# run <args...> — the script installed under $W, stdout/stderr/rc kept.
run() { ( cd "$W" && bin/schema-build.sh "$@" ) >"$T/out" 2>"$T/err"; RC=$?; }
g()   { git -C "$W" "$@"; }
sum() { sha256sum "$1" | cut -d' ' -f1; }
die() { echo "fixture: $1"; exit 1; }
# frag <name> <text> — write a fragment and render schema.sql the normal way.
frag() { printf '%s\n' "$2" > "$W/$FRD/$1"; run --write; [ "$RC" = 0 ] || die "--write of $1 rc=$RC: $(cat "$T/err")"; }
# main_adds <name> — main gains a fragment; origin/main follows it.
main_adds() {
  g checkout -q main || die "checkout main"
  frag "$1" "CREATE TABLE ${1:5:2} (id INTEGER PRIMARY KEY);"
  g add -A; g commit -qm "main adds $1"; g update-ref refs/remotes/origin/main main
  g checkout -q br || die "checkout br"
}
# init <tag> <split> — W: a git repo on main with the script's closure and the
# base tables in schema.sql. <split>=1 adds schema.d/0000-base.sql in the base
# commit; 0 leaves it pre-split.
init() {
  W="$T/$1"; mkdir -p "$W/worker/jobs"
  scratch_install_closure bin/schema-build.sh "$W" >/dev/null || die "closure install failed"
  printf '%s\n' "$BASE" > "$W/$SQL"
  if [ "$2" = 1 ]; then mkdir -p "$W/$FRD"; frag 0000-base.sql "$BASE"; fi
  g init -q -b main
  g config user.email t@t; g config user.name t; g config commit.gpgsign false
  g add -A; g commit -qm base; g update-ref refs/remotes/origin/main main
}
# presplit_branch <tag> — branch br adds XOLD to schema.sql before the split,
# main splits, br merges main cleanly.
presplit_branch() {
  init "$1" 0
  g checkout -q -b br
  printf '%s\n' "$XOLD" >> "$W/$SQL"; g commit -qam "branch appends x to schema.sql (pre-split)"
  g checkout -q main
  mkdir -p "$W/$FRD"; frag 0000-base.sql "$BASE"
  g add -A; g commit -qm "split: schema.d/"; g update-ref refs/remotes/origin/main main
  g checkout -q br
  g merge -q --no-edit main >/dev/null 2>&1 || die "$1: merging the split into br must be clean"
}
# edit_merge <text-or-empty> — br merges main without committing; x is set to
# <text> in its fragment (or left out of the render when empty), schema.sql is
# rendered with --to, and the merge is committed.
edit_merge() {
  g merge -q --no-commit --no-ff main >/dev/null 2>&1
  [ -n "$1" ] && printf '%s\n' "$1" > "$W/$FRD/0001-x.sql"
  ( cd "$W" && bin/schema-build.sh --worker jobs --to "$SQL" ) || die "--to rc=$?"
  g add -A; g commit -q --no-edit >/dev/null 2>&1 || die "edit merge must commit"
  g rev-parse -q --verify MERGE_HEAD >/dev/null && die "edit merge left MERGE_HEAD"
  [ "$(g rev-list --count --merges -1 HEAD)" = 1 ] || die "edit merge must be a merge commit"
}
# tail_and_merge — one more non-merge commit, main gains a fragment, br merges it;
# drop the --write record so the full check runs.
tail_and_merge() {
  echo note > "$W/notes.txt"; g add notes.txt; g commit -qm "unrelated branch commit"
  main_adds 0006-mb.sql
  g merge -q --no-edit main >/dev/null 2>&1 || die "final main merge must be clean: $(g status --short)"
  rm -f "$(g rev-parse --path-format=absolute --git-path schema-build/jobs.last)"
}

# =============================================================================
# M1 the #5892 shape (red before BH-5918).
# =============================================================================
presplit_branch m1
frag 0001-x.sql "$XOLD"
g add -A; g commit -qm "move x into its fragment"
main_adds 0005-ma.sql
edit_merge "$XNEW"
tail_and_merge
grep -qF "$XNEW" "$W/$SQL" && ! grep -qF "$XOLD" "$W/$SQL" || die "M1 schema.sql must hold the edited x only"
M1SUM=$(sum "$W/$SQL")
run --write
[ "$RC" = 0 ] && ok || bad "M1 --write after a merge edited x must exit 0, got $RC: $(cat "$T/err")"
grep -q 'in no fragment' "$T/err" && bad "M1 --write must print no refusal: $(cat "$T/err")" || ok
[ "$(sum "$W/$SQL")" = "$M1SUM" ] && ok || bad "M1 --write must write nothing new"
[ "$(grep -c 'CREATE TABLE x ' "$W/$SQL")" = 1 ] && ok || bad "M1 schema.sql must hold exactly one CREATE TABLE x: $(grep 'TABLE x ' "$W/$SQL")"
run --check
[ "$RC" = 0 ] && ok || bad "M1 --check must exit 0, got $RC: $(cat "$T/err")"

# =============================================================================
# M2 the literal ticket shape: fragment plus render, then a merge edits it.
# =============================================================================
init m2 1
g checkout -q -b br
frag 0001-x.sql "$XOLD"
g add -A; g commit -qm "branch adds x as a fragment"
main_adds 0005-ma.sql
edit_merge "$XNEW"
tail_and_merge
run --write
[ "$RC" = 0 ] && ok || bad "M2 --write must exit 0, got $RC: $(cat "$T/err")"
run --check
[ "$RC" = 0 ] && ok || bad "M2 --check must exit 0, got $RC: $(cat "$T/err")"

# =============================================================================
# N1 a --theirs merge that dropped a pre-split statement is still refused.
# =============================================================================
presplit_branch n1
main_adds 0005-ma.sql
g merge -q --no-edit main >/dev/null 2>&1
g checkout --theirs -- "$SQL" && g add "$SQL" && g commit -q --no-edit >/dev/null 2>&1 \
  || die "N1 the --theirs resolution must commit"
grep -qF "$XOLD" "$W/$SQL" && die "N1 --theirs must have dropped x from schema.sql"
rm -f "$(g rev-parse --path-format=absolute --git-path schema-build/jobs.last)"
N1SUM=$(sum "$W/$SQL")
run --write
[ "$RC" = 1 ] && ok || bad "N1 --write must refuse a pre-split statement a --theirs merge dropped, got $RC"
grep -qF "$XOLD" "$T/err" && ok || bad "N1 the refusal must name x: $(cat "$T/err")"
[ "$(sum "$W/$SQL")" = "$N1SUM" ] && ok || bad "N1 a refused --write must leave schema.sql untouched"

# =============================================================================
# N2 the M1 shape, but x was never moved into a fragment: the merge's render
# drops it, and no fragment of the merge's first parent held it.
# =============================================================================
presplit_branch n2
echo pre > "$W/notes.txt"; g add notes.txt; g commit -qm "branch commit, x stays in schema.sql only"
main_adds 0005-ma.sql
edit_merge ""
grep -qF "$XOLD" "$W/$SQL" && die "N2 the edit merge must have dropped x from schema.sql"
tail_and_merge
N2SUM=$(sum "$W/$SQL")
run --write
[ "$RC" = 1 ] && ok || bad "N2 --write must refuse a pre-split statement no fragment held, got $RC"
grep -qF "$XOLD" "$T/err" && ok || bad "N2 the refusal must name x: $(cat "$T/err")"
[ "$(sum "$W/$SQL")" = "$N2SUM" ] && ok || bad "N2 a refused --write must leave schema.sql untouched"

echo "schema-build-merge-edit.bh-5918: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
