#!/bin/bash
# tests/evidence-no-staging-test.sh — "evidence is never staged to match the
# expected outcome" (#527), the half of the scorer that reads the DIFF.
#
# WHY THIS SUITE EXISTS. A build can make any claim pass by weakening the test
# that proves it: delete the assertions, keep the file, record `exit 0`. The
# scorer's answer is to count ASSERT_RE lines in the named test at <base> and in
# the working tree, and to REFUTE the claim when the count dropped — whatever
# validate.txt says about it. The negatives matter as much: a file the diff
# never touched, a count that rose, and a retitled case that kept its count are
# all honest work and must never read as staging.
#
# Every assertion drives the real `evidence_score` against a real scratch git
# repo (no git stubs — the staging check is a git question). The one source-text
# assertion is §3, the ASSERT_RE parity pin, and it is guarded so an absent line
# fails rather than passing on two empty greps.
#
# Run: bash tests/evidence-no-staging-test.sh   (exit 0 = all pass)
set -uo pipefail
if [ -f "$(dirname "$0")/lib/scratch.sh" ]; then
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib/scratch.sh" || exit 1
else
  T=$(mktemp -d "${TMPDIR:-/tmp}/scratch.XXXXXX") || exit 1
  trap 'rm -rf "$T"' EXIT
fi
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/evidence.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }

# shellcheck source=../bin/lib/evidence.sh
. "$LIB" || { echo "evidence-no-staging: cannot source bin/lib/evidence.sh"; exit 1; }

G="-c user.name=t -c user.email=t@example.com"
# shellcheck disable=SC2086
gc() { git -C "$1" $G commit -q -m "$2" >/dev/null 2>&1; }

three() { # three <file> — the honest test: three assertion lines
  { printf '#!/bin/bash\n'
    printf 'ok "the reader prints the counts"\n'
    printf 'assert_eq 1 1\n'
    printf 'bad "the gate did not demote"\n'; } > "$1"
}
newrepo() { # newrepo <dir> — main holds tests/feat-test.sh with three assertions
  mkdir -p "$1/tests"
  git -C "$1" init -q -b main >/dev/null 2>&1
  three "$1/tests/feat-test.sh"
  git -C "$1" add tests/feat-test.sh >/dev/null 2>&1
  gc "$1" base
}
newbuild() { # newbuild <dir> [recorded-exit] — a one-claim plan naming the test
  mkdir -p "$1"
  printf '## Acceptance tests\n- the reader prints the counts, proven by `tests/feat-test.sh`\n' \
    > "$1/plan.md"
  printf 'COMMAND: bash tests/feat-test.sh\nexit %s\n' "${2:-0}" > "$1/validate.txt"
}
score() { # score <build> <base> <repo> — the production entry point
  SOUT=$(evidence_score "$1" "$1/plan.md" "$2" "$3" 2>&1); SRC=$?
}
j() { jq -r "$2" "$1/evidence.json" 2>/dev/null; }

# ── §1 the assertions were deleted and the run recorded exit 0 ──────────────
R="$T/r1"; newrepo "$R"
git -C "$R" checkout -q -b feature >/dev/null 2>&1
printf '#!/bin/bash\nexit 0\n' > "$R/tests/feat-test.sh"
git -C "$R" add tests/feat-test.sh >/dev/null 2>&1
gc "$R" "make it pass"
B="$T/b1"; newbuild "$B" 0
score "$B" main "$R"
eq "§1 the scorer returns 0" "$SRC" "0"
eq "§1 a test whose assertions were deleted REFUTES its claim" "$(j "$B" '.claims[0].verdict')" "REFUTED"
has "§1 the note names the drop" "$(j "$B" '.claims[0].note')" "staged: assertions 3->0"
eq "§1 the artifact is the test file itself" "$(j "$B" '.claims[0].artifact')" "tests/feat-test.sh"
eq "§1 the CLAIM line carries the same verdict" "$(grep -c '^CLAIM 1: REFUTED ' <<<"$SOUT")" "1"

# Mutation: put the three assertions back on the branch — nothing else changes.
three "$R/tests/feat-test.sh"
git -C "$R" add tests/feat-test.sh >/dev/null 2>&1
gc "$R" "restore the assertions"
B="$T/b1r"; newbuild "$B" 0
score "$B" main "$R"
eq "§1 mutation: restoring the assertions CONFIRMS the claim" "$(j "$B" '.claims[0].verdict')" "CONFIRMED"

# ── §2 the negatives: honest work must never read as staging ────────────────
R="$T/r2"; newrepo "$R"
B="$T/b2"; newbuild "$B" 0
score "$B" main "$R"
eq "§2 a file the diff never touched is not staged" "$(j "$B" '.claims[0].verdict')" "CONFIRMED"

R="$T/r3"; newrepo "$R"
git -C "$R" checkout -q -b feature >/dev/null 2>&1
three "$R/tests/feat-test.sh"
printf 'ok "one more"\nassert_eq 2 2\n' >> "$R/tests/feat-test.sh"
git -C "$R" add tests/feat-test.sh >/dev/null 2>&1
gc "$R" "add two assertions"
B="$T/b3"; newbuild "$B" 0
score "$B" main "$R"
eq "§2 a count that rose 3->5 is not staged" "$(j "$B" '.claims[0].verdict')" "CONFIRMED"

R="$T/r4"; newrepo "$R"
git -C "$R" checkout -q -b feature >/dev/null 2>&1
sed 's/the gate did not demote/the gate stayed put/' "$R/tests/feat-test.sh" > "$R/tests/feat-test.sh.new"
mv -f "$R/tests/feat-test.sh.new" "$R/tests/feat-test.sh"
git -C "$R" add tests/feat-test.sh >/dev/null 2>&1
gc "$R" "retitle one case"
B="$T/b4"; newbuild "$B" 0
score "$B" main "$R"
eq "§2 a retitled case with the same count 3->3 is not staged" "$(j "$B" '.claims[0].verdict')" "CONFIRMED"

R="$T/r5"; newrepo "$R"
git -C "$R" checkout -q -b feature >/dev/null 2>&1
git -C "$R" rm -q tests/feat-test.sh >/dev/null 2>&1
gc "$R" "delete the test"
B="$T/b5"; newbuild "$B" 0
score "$B" main "$R"
eq "§2 a named test deleted in the diff is INCONCLUSIVE, never CONFIRMED" \
  "$(j "$B" '.claims[0].verdict')" "INCONCLUSIVE"
has "§2 and says the test was deleted" "$(j "$B" '.claims[0].note')" "deleted"

R="$T/r6"; newrepo "$R"
B="$T/b6"; newbuild "$B" 0
printf 'COMMAND: bash tests/feat-tests.sh\nexit 0\n' > "$B/validate.txt"
score "$B" main "$R"
eq "§2 a validate line for tests/feat-tests.sh does not locate tests/feat-test.sh" \
  "$(j "$B" '.claims[0].verdict')" "INCONCLUSIVE"

R="$T/r7"; newrepo "$R"
B="$T/b7"; newbuild "$B" 0
score "$B" no-such-base "$R"
eq "§2 a base that does not resolve is INCONCLUSIVE, never CONFIRMED" \
  "$(j "$B" '.claims[0].verdict')" "INCONCLUSIVE"
has "§2 and says the staging check could not run" "$(j "$B" '.claims[0].note')" \
  "staging check could not run"

# ── §4 counted at the MERGE-BASE, never a base that moved on (finding #4) ───
# main keeps advancing after a branch forks. The branch here genuinely GROWS
# the test 3->5 and never touches it again; main independently grows the SAME
# test past that, to 10. Counting against main's current tip (10) instead of
# the merge-base (3) reads the branch's honest growth as a drop (10->5,
# REFUTED) — comparing against a base state the branch never saw.
R="$T/r8"; newrepo "$R"
git -C "$R" checkout -q -b feature >/dev/null 2>&1
three "$R/tests/feat-test.sh"
printf 'ok "one more"\nassert_eq 2 2\n' >> "$R/tests/feat-test.sh"
git -C "$R" add tests/feat-test.sh >/dev/null 2>&1
gc "$R" "feature grows the test 3->5"
git -C "$R" checkout -q main >/dev/null 2>&1
{ for i in 1 2 3 4 5 6 7; do printf 'ok "main extra %s"\n' "$i"; done; } \
  >> "$R/tests/feat-test.sh"
git -C "$R" add tests/feat-test.sh >/dev/null 2>&1
gc "$R" "main independently grows the same test to 10"
git -C "$R" checkout -q feature >/dev/null 2>&1
B="$T/b8"; newbuild "$B" 0
score "$B" main "$R"
eq "§4 the branch's own 3->5 growth is not staged, even though main is now at 10" \
  "$(j "$B" '.claims[0].verdict')" "CONFIRMED"

# ── §3 parity with the tamper scan's own regex (source pin, guarded) ────────
SCAN="$DIR/bin/test-tamper-scan.sh"
EV_LINE=$(grep -m1 '^ASSERT_RE=' "$LIB" 2>/dev/null)
SCAN_LINE=$(grep -m1 '^ASSERT_RE=' "$SCAN" 2>/dev/null)
[ -n "$EV_LINE" ] && ok || bad "§3 bin/lib/evidence.sh must carry an ^ASSERT_RE= line at column 0"
[ -n "$SCAN_LINE" ] && ok || bad "§3 bin/test-tamper-scan.sh must carry an ^ASSERT_RE= line at column 0"
eq "§3 the two ASSERT_RE lines are byte-identical" "$EV_LINE" "$SCAN_LINE"

echo "evidence-no-staging: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
