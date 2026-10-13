#!/bin/bash
# tests/scratch-closure-lint-grace.bh-4632-test.sh — BH-4632. The BH-4552
# scratch-closure lint goes red when a diff raises a suite's hand-copy count. A
# PR cut before the lint landed could not have known about it, passed its own
# PR checks (the corpus does not run there) and then turned its Mergify batch
# red, ejecting every other member. bin/lib/scratch-closure-grace.sh grants such
# a head a grace: its findings print as WARN and the suite does not fail, until
# the branch is rebased or merged with post-lint main, or
# lib.scratch-closure-grace.scratch_closure_grace_days (default 14) days pass
# after the commit that added the lint.
#
# Every case drives the real lint() from tests/lib/scratch-closure-lint.sh
# against a hermetic repo whose origin/main gains the lint file in a commit
# backdated relative to now (GIT_COMMITTER_DATE), never an absolute date.
# Run from anywhere: tests/scratch-closure-lint-grace.bh-4632-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
. "$(dirname "$0")/lib/scratch-closure-lint.sh" || exit 1
NOTE="docs/notes/2026-10-05-BH-4552-scratch-install-closure.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

L='bin/''lib'
LINT_REL=tests/scratch-closure-lint.bh-4552-test.sh
NOW=$(date -u +%s)
DAY=86400

# Fixture writers. Built from pieces so this suite's own lines never count.
put_lint()   { printf '%s\n' "#!/bin/bash" "echo lint" > "$1/$LINT_REL"; }
edit_lint()  { echo 'echo edited' >> "$1/$LINT_REL"; }
hand_new()   { printf '%s\n' "#!/bin/bash" "for f in a.sh b.sh; do cp \"\$DIR/$L/\$f\" \"\$T/$L/\"; done" > "$1/tests/new.bh-2-test.sh"; }
hand_other() { printf '%s\n' "#!/bin/bash" "cp \"\$DIR/$L/x.sh\" \"\$T/$L/\"" > "$1/tests/other.bh-5-test.sh"; }
clean_other() { printf '%s\n' "#!/bin/bash" "scratch_install_closure bin/lane.sh \"\$T\" || exit 1" > "$1/tests/other.bh-5-test.sh"; }
filler()     { { echo "#!/bin/bash"; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "echo $i"; done; } > "$1/tests/shared.bh-6-test.sh"; }
hand_tail()  { printf '%s\n' "cp \"\$DIR/$L/tail.sh\" \"\$T/$L/\"" >> "$1/tests/shared.bh-6-test.sh"; }
hand_head()  { sed -i "1a cp \"\$DIR/$L/head.sh\" \"\$T/$L/\"" "$1/tests/shared.bh-6-test.sh"; }
commit()     { rd_git "$1" add -A && rd_git "$1" commit -qm "$2"; }

# repo <R> — origin/main = work = B, with a 0-count shared suite on B.
repo() { mkdir -p "$1/tests" && filler "$1" && rd_fixture_repo "$1" >/dev/null; }
# land_lint <R> <age-days> — the lint commit L on origin/main, committed <age> days ago.
land_lint() {
  local ts=$(( NOW - $2 * DAY ))
  GIT_COMMITTER_DATE="$ts +0000" GIT_AUTHOR_DATE="$ts +0000" rd_main_commit "$1" 'add the lint' put_lint
}

# run_lint <R> [VAR=val...] — lint as the real run makes it; sets OUT and RC.
run_lint() {
  local R="$1"; shift
  OUT=$(export RATCHET_BASE='' TI_BASE='' GITHUB_HEAD_REF=feature SCRATCH_CLOSURE_GRACE_DAYS=''
        for a in "$@"; do export "${a?}"; done
        cd "$R" && lint "$R" 2>&1)
  RC=$?
}
want() { # want <name> <rc>
  [ "$RC" = "$2" ] && ok || bad "$1: rc=$RC want $2: $OUT"
}
has()  { grep -qF -- "$2" <<< "$OUT" && ok || bad "$1: output lacks '$2': $OUT"; }
lacks() { grep -qF -- "$2" <<< "$OUT" && bad "$1: output has '$2': $OUT" || ok; }

# pre_lint <R> <age> — work cut at B (before L) adds a hand-copy suite.
pre_lint() { repo "$1" && land_lint "$1" "$2" && hand_new "$1" && commit "$1" pr; }

# --- pre-lint-warn ----------------------------------------------------------------
R="$T/pre-warn"; pre_lint "$R" 2 || bad "pre-warn fixture"
run_lint "$R"
want pre-lint-warn 0
has pre-lint-warn "WARN scratch-closure grace: tests/new.bh-2-test.sh +1 hand-copies (head "
has pre-lint-warn "cut before lint $(git -C "$R" rev-parse --short=12 origin/main)"
has pre-lint-warn "WARN tests/new.bh-2-test.sh:2: hand-copies"
[ "$(grep -c '^WARN scratch-closure grace:' <<< "$OUT")" = 1 ] && ok || bad "pre-lint-warn: want exactly one grace line: $OUT"
end_iso=$(date -u -d "@$(( NOW - 2*DAY + 14*DAY ))" +%Y-%m-%dT%H:%MZ)
has pre-lint-warn "grace ends $end_iso)"

# --- pre-lint-merged-main: merging post-lint main ends the grace --------------------
R="$T/pre-merged"; pre_lint "$R" 2 && rd_git "$R" merge -q --no-edit refs/remotes/origin/main || bad "pre-merged fixture"
run_lint "$R"
want pre-lint-merged-main 1
lacks pre-lint-merged-main "WARN scratch-closure grace"
has pre-lint-merged-main "tests/new.bh-2-test.sh:2: hand-copies"

# --- pre-lint-rebased --------------------------------------------------------------
R="$T/pre-rebased"; pre_lint "$R" 2 && rd_git "$R" rebase -q refs/remotes/origin/main || bad "pre-rebased fixture"
run_lint "$R"
want pre-lint-rebased 1
lacks pre-lint-rebased "WARN scratch-closure grace"

# --- pre-lint that merged a main from BEFORE L: still graced -------------------------
R="$T/pre-old-merge"; repo "$R" && rd_main_commit "$R" 'pre-lint main' clean_other \
  && rd_git "$R" update-ref refs/heads/old-main refs/remotes/origin/main \
  && land_lint "$R" 2 && hand_new "$R" && commit "$R" pr && rd_git "$R" merge -q --no-edit old-main || bad "pre-old-merge fixture"
run_lint "$R"
want pre-lint-merged-old-main 0

# --- post-lint-red ------------------------------------------------------------------
R="$T/post"; repo "$R" && land_lint "$R" 2 && rd_git "$R" reset -q --hard refs/remotes/origin/main \
  && hand_new "$R" && commit "$R" pr || bad "post fixture"
run_lint "$R"
want post-lint-red 1
lacks post-lint-red "WARN"

# --- grace-expired / grace-off / knob read ---------------------------------------------
R="$T/expired"; pre_lint "$R" 20 || bad "expired fixture"
run_lint "$R"
want grace-expired 1
lacks grace-expired "WARN scratch-closure grace"
run_lint "$R" SCRATCH_CLOSURE_GRACE_DAYS=30
want grace-knob-widened 0
R="$T/off"; pre_lint "$R" 2 || bad "off fixture"
run_lint "$R" SCRATCH_CLOSURE_GRACE_DAYS=0
want grace-off 1
lacks grace-off "WARN scratch-closure grace"
run_lint "$R" SCRATCH_CLOSURE_GRACE_DAYS=1
want grace-knob-narrowed 1
run_lint "$R" SCRATCH_CLOSURE_GRACE_DAYS=junk
want grace-knob-junk-falls-to-default 0

# --- no-lint-commit -----------------------------------------------------------------
R="$T/nolint"; repo "$R" && rd_main_commit "$R" 'not the lint' clean_other && hand_new "$R" && commit "$R" pr || bad "nolint fixture"
run_lint "$R"
want no-lint-commit 1
lacks no-lint-commit "WARN scratch-closure grace"

# --- lint-commit-from-git: the commit that ADDED the path, not a later edit -----------
R="$T/fromgit"; repo "$R" && land_lint "$R" 2 || bad "fromgit fixture"
added=$(git -C "$R" rev-parse refs/remotes/origin/main)
rd_main_commit "$R" 'edit the lint' edit_lint || bad "fromgit edit"
got=$(cd "$R" && bash -c '. "$0/bin/lib/scratch-closure-grace.sh" || exit 1; scg_lint_commit "$1" origin/main "$2"' "$DIR" "$R" "$LINT_REL" 2>&1)
[ "$got" = "$added" ] && ok || bad "lint-commit-from-git: got '$got' want $added"
# deleted and added again: L is still the OLDEST add.
drop_lint() { rm "$1/$LINT_REL"; }
rd_main_commit "$R" 'drop the lint' drop_lint && rd_main_commit "$R" 're-add the lint' put_lint || bad "fromgit re-add"
got=$(cd "$R" && bash -c '. "$0/bin/lib/scratch-closure-grace.sh" || exit 1; scg_lint_commit "$1" origin/main "$2"' "$DIR" "$R" "$LINT_REL" 2>&1)
[ "$got" = "$added" ] && ok || bad "lint-commit-from-git: re-added path: got '$got' want $added"
got=$(cd "$R" && bash -c '. "$0/bin/lib/scratch-closure-grace.sh" || exit 1; scg_lint_commit "$1" origin/main tests/absent.sh' "$DIR" "$R" 2>&1); rc=$?
[ "$rc" = 1 ] && [ -z "$got" ] && ok || bad "lint-commit-from-git: absent path rc=$rc out='$got'"

# --- uncommitted-on-pre-lint: working-tree edits belong to no head ----------------------
R="$T/uncommitted"; repo "$R" && land_lint "$R" 2 && hand_new "$R" || bad "uncommitted fixture"
run_lint "$R"
want uncommitted-untracked 1
lacks uncommitted-untracked "WARN scratch-closure grace"
R="$T/uncommitted2"; pre_lint "$R" 2 || bad "uncommitted2 fixture"
printf '%s\n' "cp \"\$DIR/$L/more.sh\" \"\$T/$L/\"" >> "$R/tests/new.bh-2-test.sh"
run_lint "$R"
want uncommitted-modified 1
lacks uncommitted-modified "WARN scratch-closure grace"

# --- Mergify batch drafts -------------------------------------------------------------------
# batch <R> <post-step> — pre-lint member `pre` (hand_new at B), lint on main,
# post-lint member `post` (cut after L, <post-step>), and HEAD = a draft off
# main that --no-ff merges both.
batch() {
  local R="$1" step="$2"
  repo "$R" || return 1
  rd_git "$R" checkout -q -b pre work && hand_new "$R" && commit "$R" pre-member || return 1
  [ "${3:-}" = pre-shared ] && { hand_tail "$R" && commit "$R" pre-shared || return 1; }
  rd_git "$R" checkout -q work && land_lint "$R" 2 || return 1
  rd_git "$R" checkout -q -b post refs/remotes/origin/main && "$step" "$R" && commit "$R" post-member || return 1
  rd_git "$R" checkout -q -b draft refs/remotes/origin/main \
    && rd_git "$R" merge -q --no-ff --no-edit pre >/dev/null && rd_git "$R" merge -q --no-ff --no-edit post >/dev/null
}
MQ=GITHUB_HEAD_REF=mergify/merge-queue/x

R="$T/batch-pre"; batch "$R" clean_other || bad "batch-pre fixture"
run_lint "$R" "$MQ"
want batch-pre-lint-only 0
has batch-pre-lint-only "WARN scratch-closure grace: tests/new.bh-2-test.sh +1"
has batch-pre-lint-only "(head $(git -C "$R" rev-parse --short=12 pre) cut before lint"
lacks batch-pre-lint-only "other.bh-5"
run_lint "$R" GITHUB_HEAD_REF=feature
want batch-draft-outside-the-queue-is-red 1

R="$T/batch-same"; batch "$R" hand_head pre-shared || bad "batch-same fixture"
run_lint "$R" "$MQ"
want batch-mixed-same-suite 1
has batch-mixed-same-suite "WARN scratch-closure grace: tests/new.bh-2-test.sh +1"
lacks batch-mixed-same-suite "grace: tests/shared.bh-6-test.sh"
grep -q '^tests/shared.bh-6-test.sh:2: hand-copies' <<< "$OUT" && ok || bad "batch-mixed-same-suite: shared suite not red: $OUT"

R="$T/batch-other"; batch "$R" hand_other || bad "batch-other fixture"
run_lint "$R" "$MQ"
want batch-mixed-other-suite 1
grep -q '^tests/other.bh-5-test.sh:2: hand-copies' <<< "$OUT" && ok || bad "batch-mixed-other-suite: post-lint suite not red: $OUT"
has batch-mixed-other-suite "WARN scratch-closure grace: tests/new.bh-2-test.sh +1"
lacks batch-mixed-other-suite "grace: tests/other.bh-5"

R="$T/batch-tm"; batch "$R" clean_other && rd_git "$R" checkout -q --detach refs/remotes/origin/main \
  && rd_git "$R" merge -q --no-ff --no-edit draft || bad "batch-test-merge fixture"
run_lint "$R" "$MQ"
want batch-test-merge 0
has batch-test-merge "(head $(git -C "$R" rev-parse --short=12 pre) cut before lint"

# a suite raised by a commit on the draft itself, which no member touches: red.
hand_direct() { printf '%s\n' "#!/bin/bash" "cp \"\$DIR/$L/y.sh\" \"\$T/$L/\"" > "$1/tests/direct.bh-7-test.sh"; }
R="$T/batch-direct"; batch "$R" clean_other && hand_direct "$R" && commit "$R" direct || bad "batch-direct fixture"
run_lint "$R" "$MQ"
want batch-direct-commit 1
grep -q '^tests/direct.bh-7-test.sh:2: hand-copies' <<< "$OUT" && ok || bad "batch-direct-commit: unowned suite not red: $OUT"
has batch-direct-commit "WARN scratch-closure grace: tests/new.bh-2-test.sh +1"

R="$T/batch-linear"; repo "$R" && land_lint "$R" 2 && rd_git "$R" reset -q --hard refs/remotes/origin/main \
  && hand_new "$R" && commit "$R" linear || bad "batch-no-members fixture"
run_lint "$R" "$MQ"
want batch-no-members 1
lacks batch-no-members "WARN scratch-closure grace"

# --- knob-registered ----------------------------------------------------------------------
if HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --to "$T/l.json" >/dev/null 2>&1; then
  k=$(jq -c '.libs[] | select(.id=="scratch-closure-grace") | {file, k: [.knobs[] | select(.env=="SCRATCH_CLOSURE_GRACE_DAYS") | {default, min, zero_means}]}' "$T/l.json")
  [ "$k" = '{"file":"bin/lib/scratch-closure-grace.sh","k":[{"default":14,"min":0,"zero_means":"off"}]}' ] && ok || bad "knob-registered: $k"
else
  bad "knob-registered: lanes-build.sh --to failed"
fi
if [ -f "$DIR/bin/lib/scratch-closure-grace.sh" ] && ! grep -qE 'SCRATCH_CLOSURE_GRACE_DAYS:-[0-9]' "$DIR/bin/lib/scratch-closure-grace.sh"; then ok; else bad "lib missing or carries a literal default"; fi

echo "scratch-closure-lint-grace.bh-4632: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
