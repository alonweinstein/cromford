#!/bin/bash
# tests/scratch-closure-lint.bh-4552-test.sh — BH-4552. A suite that builds a
# scratch harness copies a lane's libs with scratch_install_closure
# (tests/lib/scratch.sh), not by a hand list of bin/lib files: a hand list
# breaks in the merge queue the day the lane sources one more lib (#4242,
# #4002, #4415). This lint stops NEW hand lists; the ones already on main are
# grandfathered.
#
# WHAT COUNTS, per tests/*.sh and tests/mc/*.sh, on lines that are not comments:
#   - a cp (or coreutils `install -...`) line naming bin/lib/<x>.sh, globs
#     too (bin/lib/*.sh, bin/lib/jobs/*.sh);
#   - a `for v in ... .sh ...` loop whose body cp/installs from bin/lib/
#     (once per loop);
#   - a swf_install line naming bin/lib/, or a swf_install inside a for loop
#     whose list names bin/lib/.
# A scratch_install_closure line counts 0, and so does a cp of anything that is
# not under bin/lib (bin/foo.sh, tests/fixtures/x) or of bin/lib as a whole
# directory.
#
# DELTA ONLY (tests/lib/ratchet-delta.sh): red when THIS diff raises a suite's
# count, a new suite with a count included. There is no absolute baseline, so
# no --strict. A base that does not resolve is red, never a skip.
#
# WHEN IT RUNS: the `scratch-closure` component of catalog/rules-pack.tsv
# (BH-4869), so the PR lint job's rules-pack step, the builder gate and every
# fix round run it before a push, and the merge-queue corpus still does.
# bin/test-impact-gate.sh also promotes it into its fast tier on any suite diff.
#
# THE ESCAPE HATCH: a suite that copies one lib to unit-test it directly
# (rather than to run a lane that sources it) carries
#   # scratch-closure-allow: <reason>
# and an empty reason is still red.
# See docs/notes/2026-10-05-BH-4552-scratch-install-closure.md.
# Run from anywhere: tests/scratch-closure-lint.bh-4552-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
. "$(dirname "$0")/lib/scratch-closure-lint.sh" || exit 1
NOTE="docs/notes/2026-10-05-BH-4552-scratch-install-closure.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

# --- self-test: the counter -----------------------------------------------------
# Fixture text is built from pieces so this suite's own lines never count.
L='bin/''lib'
S="$T/self"; mkdir -p "$S"
fx() { printf '%s\n' "${@:2}" > "$S/$1"; }
fx loop1.sh "for f in a.sh b.sh; do cp \"\$DIR/$L/\$f\" \"\$T/$L/\"; done"
fx loop2.sh "for f in a.sh b.sh; do" "  cp \"\$DIR/$L/\$f\" \"\$H/$L/\"" "done"
fx named.sh "cp \"\$DIR/$L/env-path.sh\" \"\$T/$L/\""
fx glob.sh "cp \"\$DIR\"/$L/jobs/*.sh \"\$T/$L/jobs/\""
fx swf.sh "swf_install $L/pr-health.sh || exit 1"
fx swfloop.sh "for s in \$SCRIPTS $L/x.sh; do swf_install \"\$s\" || exit 1; done"
fx helper.sh "scratch_install_closure bin/main-red-bisect.sh \"\$H\" >/dev/null || exit 1"
fx helperloop.sh "for s in bin/a.sh bin/b.sh; do scratch_install_closure \"\$s\" \"\$T\" || exit 1; done"
fx nonlib.sh "cp \"\$DIR/bin/foo.sh\" \"\$T/bin/\"" "cp \"\$DIR/tests/fixtures/x\" \"\$T/\"" "cp -r \"\$DIR/$L\" \"\$T/bin/\""
fx comment.sh "# cp \"\$DIR/$L/env-path.sh\" \"\$T/\""
fx installprose.sh "bad \"C6 install did not print $L/x.sh\""
fx installcmd.sh "install -m 755 \"\$DIR/$L/x.sh\" \"\$T/$L/\""
fx archive.sh "git -C \"\$DIR\" archive HEAD $L | tar -x -C \"\$T\""
fx loopnonlib.sh "for f in a.sh b.sh; do cp \"\$DIR/bin/\$f\" \"\$T/bin/\"; done"
got=$(cd "$S" && counts "$S" loop1.sh loop2.sh named.sh glob.sh swf.sh swfloop.sh helper.sh helperloop.sh nonlib.sh comment.sh installprose.sh installcmd.sh archive.sh loopnonlib.sh | tr '\t\n' '= ')
want="loop1.sh=1 loop2.sh=1 named.sh=1 glob.sh=1 swf.sh=1 swfloop.sh=1 helper.sh=0 helperloop.sh=0 nonlib.sh=0 comment.sh=0 installprose.sh=0 installcmd.sh=1 archive.sh=0 loopnonlib.sh=0 "
[ "$got" = "$want" ] && ok || bad "counter"$'\n'"want: $want"$'\n'"got:  $got"
[ "$(hand_copy_lines "$S/loop2.sh" | cut -f2)" = 2 ] && ok || bad "counter names the cp line of a multi-line loop"

# --- self-test: the delta, in a hermetic repo -------------------------------------
# case <name> <want_rc> <step...>: a repo with one grandfathered suite on main,
# then the PR's steps; lint as the real run makes it.
old_suite() { printf '%s\n' "#!/bin/bash" "cp \"\$DIR/$L/env-path.sh\" \"\$T/$L/\"" > "$1/tests/old.bh-1-test.sh"; }
pr_new_hand()   { printf '%s\n' "#!/bin/bash" "for f in a.sh b.sh; do cp \"\$DIR/$L/\$f\" \"\$T/$L/\"; done" > "$1/tests/new.bh-2-test.sh"; }
pr_new_allow()  { pr_new_hand "$1"; printf '%s\n' "# scratch-closure-allow: unit-tests a.sh directly, runs no lane" >> "$1/tests/new.bh-2-test.sh"; }
pr_new_empty()  { pr_new_hand "$1"; printf '%s\n' "# scratch-closure-allow:   " >> "$1/tests/new.bh-2-test.sh"; }
pr_new_helper() { printf '%s\n' "#!/bin/bash" "scratch_install_closure bin/lane.sh \"\$T\" || exit 1" > "$1/tests/new.bh-2-test.sh"; }
pr_new_nonlib() { printf '%s\n' "#!/bin/bash" "cp \"\$DIR/bin/foo.sh\" \"\$T/bin/\"" "cp \"\$DIR/tests/fixtures/x\" \"\$T/\"" > "$1/tests/new.bh-2-test.sh"; }
pr_touch_old()  { echo 'echo more' >> "$1/tests/old.bh-1-test.sh"; }
pr_grow_old()   { printf '%s\n' "cp \"\$DIR/$L/hub-box.sh\" \"\$T/$L/\"" >> "$1/tests/old.bh-1-test.sh"; }
pr_shrink_old() { printf '%s\n' "#!/bin/bash" "scratch_install_closure bin/lane.sh \"\$T\" || exit 1" > "$1/tests/old.bh-1-test.sh"; }
pr_commit()     { rd_git "$1" add -A && rd_git "$1" commit -qm pr; }
main_hand()     { printf '%s\n' "cp \"\$DIR/$L/x.sh\" \"\$T/\"" > "$1/tests/main.bh-3-test.sh"; }
main_drift()    { rd_main_commit "$1" 'main: another hand suite' main_hand && rd_git "$1" merge -q --no-edit refs/remotes/origin/main; }
dcase() {
  local name="$1" want="$2" R="$T/repo-$1" out rc step; shift 2
  mkdir -p "$R/tests" && old_suite "$R" && rd_fixture_repo "$R" >/dev/null || { bad "$name: fixture repo"; return; }
  for step in "$@"; do "$step" "$R" >/dev/null 2>&1 || { bad "$name: step $step failed"; return; }; done
  out=$(RATCHET_BASE= TI_BASE= lint "$R" 2>&1); rc=$?
  [ "$rc" = "$want" ] && ok || bad "$name rc=$rc want $want: $out"
  LAST="$out"
}
dcase new-hand-list      1 pr_new_hand pr_commit
grep -q 'tests/new.bh-2-test.sh:2: .*scratch_install_closure' <<< "$LAST" && ok || bad "red names file:line and the fix: $LAST"
dcase new-hand-uncommitted 1 pr_new_hand
dcase new-allow-reason   0 pr_new_allow pr_commit
dcase new-allow-empty    1 pr_new_empty pr_commit
dcase new-helper         0 pr_new_helper pr_commit
dcase new-nonlib-cp      0 pr_new_nonlib pr_commit
dcase grandfathered      0 pr_touch_old pr_commit
dcase old-grows          1 pr_grow_old pr_commit
dcase old-migrates       0 pr_shrink_old pr_commit
dcase main-drift         0 main_drift pr_new_helper pr_commit
dcase no-change          0
nobase() { rd_git "$1" update-ref -d refs/remotes/origin/main; }
dcase no-base            1 pr_new_helper pr_commit nobase

# --- the real tree ------------------------------------------------------------------
n=$(hand_copy_lines "$DIR/tests/"*.sh "$DIR/tests/mc/"*.sh | grep -c .)
[ "$n" -gt 0 ] && ok || bad "real: counter found no hand copies in tests/ (vacuous scan)"
out=$(lint "$DIR" 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "real (delta): $out"

echo "scratch-closure-lint.bh-4552: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
