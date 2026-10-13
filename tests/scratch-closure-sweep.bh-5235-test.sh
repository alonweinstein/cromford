#!/bin/bash
# tests/scratch-closure-sweep.bh-5235-test.sh — BH-5235.3. Two halves of one
# job: stop new hand-copied bin/lib lists, and convert the old ones.
#
#   L-cases drive the real lint() from tests/lib/scratch-closure-lint.sh in a
#   hermetic repo. The new-line rule is red on a hand line whose trimmed text
#   the base does not have, even when the suite's count does not move. A
#   delete, a verbatim move, a re-indent and an unrelated edit stay green.
#   S-cases run the real bin/closure-sweep.sh against a fixture repo: dry run,
#   --apply with its before/after proof, the skip verdicts, and a revert.
#   S4 runs `bash -n` on every suite this branch rewrote (wave 1).
#
# Every fixture line is built from pieces (L='bin/''lib'), so this suite's own
# lines never count as hand copies.
# Run from anywhere: tests/scratch-closure-sweep.bh-5235-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
. "$(dirname "$0")/lib/scratch-closure-lint.sh" || exit 1
NOTE="docs/notes/2026-10-07-BH-5235-closure-sweep.md"
SWEEP="$DIR/bin/closure-sweep.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

L='bin/''lib'
# Not graced: the grace lib keys on the commit that added this path, and no
# fixture repo has it.
SCL_LINT_REL=tests/no-such-lint.bh-0-test.sh

# --- L: the new-line rule in lint() ------------------------------------------------
hand2="cp \"\$DIR/$L/a.sh\" \"\$DIR/$L/b.sh\" \"\$H/$L/\""
hand3="cp \"\$DIR/$L/a.sh\" \"\$DIR/$L/b.sh\" \"\$DIR/$L/deployment.sh\" \"\$H/$L/\""
base_s()   { printf '%s\n' "#!/bin/bash" "H=\"\$T/h\"" "$hand2" "echo one" "echo two" > "$1/tests/s.sh"; }
edit_add() { printf '%s\n' "#!/bin/bash" "H=\"\$T/h\"" "$hand3" "echo one" "echo two" > "$1/tests/s.sh"; }
del_line() { printf '%s\n' "#!/bin/bash" "H=\"\$T/h\"" "echo one" "echo two" > "$1/tests/s.sh"; }
move_line() { printf '%s\n' "#!/bin/bash" "H=\"\$T/h\"" "echo one" "if true; then" "    $hand2" "fi" "echo two" > "$1/tests/s.sh"; }
edit_other() { printf '%s\n' "#!/bin/bash" "H=\"\$T/h\"" "$hand2" "echo ONE" "echo two" > "$1/tests/s.sh"; }
harmless() {
  printf '%s\n' "#!/bin/bash" "H=\"\$T/h\"" "$hand2" "echo one" "# cp \"\$DIR/$L/c.sh\" \"\$H/$L/\"" \
    "scratch_install_closure bin/x.sh \"\$H\" >/dev/null || exit 1" "cp \"\$DIR/bin/foo.sh\" \"\$H/bin/\"" "echo two" > "$1/tests/s.sh"
}
add_allow() { edit_add "$1"; echo "# scratch-closure-allow: stub swap" >> "$1/tests/s.sh"; }
grow()     { printf '%s\n' "#!/bin/bash" "H=\"\$T/h\"" "$hand2" "cp \"\$DIR/$L/c.sh\" \"\$H/$L/\"" "echo one" "echo two" > "$1/tests/s.sh"; }
dup_line() { printf '%s\n' "#!/bin/bash" "H=\"\$T/h\"" "$hand2" "echo one" "$hand2" "echo two" > "$1/tests/s.sh"; }
new_suite() { printf '%s\n' "#!/bin/bash" "$hand2" > "$1/tests/n.sh"; }
commit()   { rd_git "$1" add -A && rd_git "$1" commit -qm pr; }

# lcase <name> <want_rc> <step...> — origin/main holds base_s; the PR's steps run
# on top; lint runs as the real run makes it. Sets OUT.
lcase() {
  local name="$1" want="$2" R="$T/lrepo-$1" rc step; shift 2
  mkdir -p "$R/tests" && base_s "$R" && rd_fixture_repo "$R" >/dev/null || { bad "$name: fixture repo"; return; }
  for step in "$@"; do "$step" "$R" >/dev/null 2>&1 || { bad "$name: step $step failed"; return; }; done
  OUT=$(cd "$R" && RATCHET_BASE='' TI_BASE='' GITHUB_HEAD_REF=feature lint "$R" 2>&1); rc=$?
  [ "$rc" = "$want" ] && ok || bad "$name: rc=$rc want $want: $OUT"
}

lcase L1-edit-same-count 1 edit_add commit
grep -q '^tests/s.sh:3: new or edited hand-copied bin/lib list: use scratch_install_closure' <<< "$OUT" \
  && ok || bad "L1 names tests/s.sh:3 and the fix: $OUT"
lcase L1-uncommitted 1 edit_add
lcase L2-new-suite 1 new_suite
[ "$(grep -c '^tests/n.sh:2:' <<< "$OUT")" = 1 ] && ok || bad "L2 prints the new suite's line once: $OUT"
lcase L3a-delete 0 del_line commit
lcase L3b-move-reindent 0 move_line commit
lcase L3c-unrelated-edit 0 edit_other commit
lcase L3d-comment-helper-nonlib 0 harmless commit
lcase L4-allow 0 add_allow commit
lcase L5-count-rule 1 grow commit
grep -q 'tests/s.sh:4: hand-copies bin/lib files (2 such lines, base fewer)' <<< "$OUT" \
  && ok || bad "L5 keeps the bh-4552 message: $OUT"
lcase L5-duplicate 1 dup_line commit
grep -q '^tests/s.sh:5: hand-copies' <<< "$OUT" && ok || bad "duplicate line is red: $OUT"

# new_hand_lines directly: a multiset, trimmed.
printf '%s\n' "x" "  $hand2" > "$T/nb"; printf '%s\n' "$hand2" "y" "$hand2" > "$T/nh"
[ "$(new_hand_lines "$T/nb" "$T/nh" | tr '\n' ' ')" = "3 " ] && ok || bad "new_hand_lines multiset: $(new_hand_lines "$T/nb" "$T/nh")"
[ "$(new_hand_lines - "$T/nh" | tr '\n' ' ')" = "1 3 " ] && ok || bad "new_hand_lines no base: $(new_hand_lines - "$T/nh")"

# --- S: bin/closure-sweep.sh ---------------------------------------------------------
R="$T/r"
mkdir -p "$R/tests/lib" "$R/bin/lib"
cp "$DIR/tests/lib/scratch.sh" "$DIR/tests/lib/scratch-closure-lint.sh" "$DIR/tests/lib/ratchet-delta.sh" "$R/tests/lib/"
printf '%s\n' '#!/bin/bash' '. "$(dirname "$0")/lib/a.sh" || exit 1' 'a_fn' > "$R/bin/x.sh"
printf '%s\n' '#!/bin/bash' '. "$(dirname "${BASH_SOURCE[0]}")/b.sh" 2>/dev/null || :' 'a_fn() { echo ok; }' > "$R/$L/a.sh"
printf '%s\n' '#!/bin/bash' 'b_fn() { :; }' > "$R/$L/b.sh"
printf '%s\n' '#!/bin/bash' 'z_fn() { :; }' > "$R/$L/z.sh"
chmod +x "$R/bin/x.sh"

# suite <name> <hand line...> [-- <extra line...>] — a fixture suite that
# installs bin/x.sh and the hand lines into $H, runs x, then the extra lines.
suite() {
  local f="$R/tests/$1" h=() x=() seen=0; shift
  for a in "$@"; do if [ "$a" = -- ]; then seen=1; elif [ "$seen" = 0 ]; then h+=("$a"); else x+=("$a"); fi; done
  {
    printf '%s\n' '#!/bin/bash' 'DIR=$(cd "$(dirname "$0")/.." && pwd)' '. "$(dirname "$0")/lib/scratch.sh" || exit 1' \
      'H="$T/h"' "mkdir -p \"\$H/$L\"" 'cp "$DIR/bin/x.sh" "$H/bin/"'
    printf '  %s\n' "${h[@]}"
    printf '%s\n' "${x[@]}"
    printf '%s\n' 'out=$(bash "$H/bin/x.sh") || { echo "FAIL: x"; exit 1; }' '[ "$out" = ok ] || { echo "FAIL: x said $out"; exit 1; }' \
      'echo "f: 1 passed, 0 failed"'
  } > "$f"
}
HA="cp \"\$DIR/$L/a.sh\" \"\$H/$L/\" || exit 1"
suite f.sh "$HA"
suite s3.sh "$HA" -- "[ ! -f \"\$H/$L/b.sh\" ] || { echo \"FAIL: b present\"; exit 1; }"
suite p.sh "$HA" -- "rm -f \"\$H/$L/b.sh\""
suite p2.sh "$HA" -- "echo \"keep $L/b.sh missing here\""
suite p3.sh "$HA" -- "M=\"\$T/mut\""
suite jq.sh "$HA" -- 'command -v jq >/dev/null || { echo "jq missing, skipping"; exit 0; }'
suite al.sh "$HA" -- "# scratch-closure-allow: unit-tests a.sh"
suite lp.sh "for f in a.sh; do cp \"\$DIR/$L/\$f\" \"\$H/$L/\"; done"
suite var.sh "LIB=\"\$DIR/$L/a.sh\"" "cp \"\$LIB\" \"\$H/$L/a.sh\""
suite ch.sh "mkdir -p \"\$H/$L\" && $HA"
suite z.sh "$HA" "cp \"\$DIR/$L/z.sh\" \"\$H/$L/\""
rd_fixture_repo "$R" >/dev/null || bad "S fixture repo"
sha() { sha256sum "$R/tests/$1" | cut -d' ' -f1; }

# The fixture runs green as written, before any sweep.
(cd "$R" && HARNESS_TEST_SANDBOX=1 bash tests/f.sh >/dev/null 2>&1) && ok || bad "S0 fixture f.sh is red before the sweep"

# S1 dry run: a rewrite row, file untouched.
s0=$(sha f.sh)
out=$(HARNESS_TEST_SANDBOX=1 "$SWEEP" --root "$R" tests/f.sh 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "S1 dry run rc=$rc: $out"
grep -qP '^tests/f.sh\trewrite\t1 lines -> bin/x.sh$' <<< "$out" && ok || bad "S1 dry-run row: $out"
[ "$(sha f.sh)" = "$s0" ] && ok || bad "S1 dry run edited the file"

# S1 --apply: rewritten, the helper line replaces the hand line, the suite is green.
out=$(HARNESS_TEST_SANDBOX=1 "$SWEEP" --root "$R" --apply --report "$T/rep.tsv" tests/f.sh 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "S1 apply rc=$rc: $out"
grep -qP '^tests/f.sh\trewritten\t' <<< "$out" && ok || bad "S1 apply row: $out"
grep -qP '^tests/f.sh\trewritten\t' "$T/rep.tsv" && ok || bad "S1 --report holds the row: $(cat "$T/rep.tsv" 2>&1)"
grep -qxF '  scratch_install_closure bin/x.sh "$H" >/dev/null || { echo "FAIL: closure bin/x.sh"; exit 1; }' "$R/tests/f.sh" \
  && ok || bad "S1 helper line: $(cat "$R/tests/f.sh")"
[ -z "$(hand_copy_lines "$R/tests/f.sh")" ] && ok || bad "S1 a hand line is left: $(cat "$R/tests/f.sh")"
(cd "$R" && HARNESS_TEST_SANDBOX=1 bash tests/f.sh >/dev/null 2>&1) && ok || bad "S1 rewritten suite is red"
[ "$(rd_git "$R" status --porcelain)" = " M tests/f.sh" ] && ok || bad "S1 git status: $(rd_git "$R" status --porcelain)"
[ "$(rd_git "$R" rev-list --count HEAD)" = 1 ] && ok || bad "S1 the sweep made a commit"

# S2: each skip verdict, file bytes unchanged under --apply.
s2case() {
  local f="$1" want="$2" before out
  before=$(sha "$f")
  out=$(HARNESS_TEST_SANDBOX=1 "$SWEEP" --root "$R" --apply "tests/$f" 2>&1)
  grep -qP "^tests/$f\t\Q$want\E(\t|$)" <<< "$out" && ok || bad "S2 $f want $want: $out"
  [ "$(sha "$f")" = "$before" ] && ok || bad "S2 $f was edited"
}
s2case p.sh skip:partial
s2case p2.sh skip:partial
s2case p3.sh skip:partial
# A tool-missing guard that names no bin/lib file is not a partial install.
out=$(HARNESS_TEST_SANDBOX=1 "$SWEEP" --root "$R" tests/jq.sh 2>&1)
grep -qP '^tests/jq.sh\trewrite\t' <<< "$out" && ok || bad "S2 jq-missing guard is not partial: $out"
s2case al.sh skip:allow
s2case lp.sh skip:shape
s2case var.sh skip:shape
s2case ch.sh skip:shape
s2case z.sh "skip:not-in-closure:$L/z.sh"

# S3: the closure adds b.sh, the suite asserts it absent: reverted, bytes restored.
s0=$(sha s3.sh)
out=$(HARNESS_TEST_SANDBOX=1 "$SWEEP" --root "$R" --apply tests/s3.sh 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "S3 rc=$rc: $out"
grep -qP '^tests/s3.sh\treverted:0/1' <<< "$out" && ok || bad "S3 row: $out"
[ "$(sha s3.sh)" = "$s0" ] && ok || bad "S3 bytes not restored"

# Usage: no suite, or a root without tests/lib/scratch.sh, is rc 2.
HARNESS_TEST_SANDBOX=1 "$SWEEP" --root "$R" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "no suite rc=$rc want 2"
HARNESS_TEST_SANDBOX=1 "$SWEEP" --root "$T/nowhere" tests/f.sh >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "bad root rc=$rc want 2"

# --- S4: every suite this branch rewrote parses ------------------------------------------
# Own-slice gate: only the branch that carries BH-5263's spec runs this arm.
# On any other PR the diff holds someone else's suites, not wave 1.
TOUCHED=$(git -C "$DIR" diff --name-only origin/main 2>/dev/null || :)
WAVE1=()
if grep -qE '^\.harness/specs/BH-5263/' <<< "$TOUCHED"; then
  mapfile -t WAVE1 < <(grep -E '^tests/.*\.sh$' <<< "$TOUCHED" \
    | grep -vE 'scratch-closure-sweep|lib/scratch-closure-lint|README' || :)
fi
if [ "${#WAVE1[@]}" = 0 ]; then
  echo "S4: not BH-5263's branch, or no rewritten suite in its diff (vacuous pass)"; ok
fi
for f in "${WAVE1[@]}"; do
  [ -f "$DIR/$f" ] || continue
  bash -n "$DIR/$f" && ok || bad "S4 bash -n $f"
done

echo "scratch-closure-sweep.bh-5235: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
