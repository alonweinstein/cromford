#!/bin/bash
# tests/test-tamper-scan-test.sh — bin/test-tamper-scan.sh against real git repos.
#
# Real repos, not fixtures-in-strings: the whole script is a diff reader, so a
# test that fed it canned diff text would be testing my mock rather than git.
# Each case builds a throwaway repo, makes the tampering commit, and scans it.
#
# The contract worth pinning: tampering is FOUND (per marker class), a
# justification flips block into adjudicate, clean diffs stay silent, and a
# scanner that cannot run says so instead of passing quietly.
# Run from anywhere: tests/test-tamper-scan-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SCAN="$DIR/bin/test-tamper-scan.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# newrepo <name> — a repo with one committed test file, BASE recorded in $BASE
newrepo() {
  R="$T/$1"; mkdir -p "$R/tests"; cd "$R" || exit 1
  git init -q .; git config user.email t@t; git config user.name t
  cat > tests/thing.test.js <<'EOF'
describe('thing', () => {
  it('adds', () => { expect(add(1,2)).toBe(3) })
  it('subtracts', () => { expect(sub(3,1)).toBe(2) })
})
EOF
  echo "src" > app.js
  git add -A; git commit -qm init
  BASE=$(git rev-parse HEAD)
}
# Capture, then match. `scan | grep -q` makes grep exit on first match, the
# script takes SIGPIPE, and `set -o pipefail` reports 141 — every assertion
# would fail while the script was behaving perfectly.
scan() { "$SCAN" "$BASE" "$R" 2>/dev/null || true; }
has()  { grep -q "$1" <<<"$(scan)"; }
rc()   { "$SCAN" "$BASE" "$R" >/dev/null 2>&1; echo $?; }

# ---------- 1. a clean feature diff is silent ----------
newrepo clean
echo "more src" >> app.js
cat >> tests/thing.test.js <<'EOF'
it('multiplies', () => { expect(mul(2,3)).toBe(6) })
EOF
git add -A; git commit -qm "feat: multiply"
[ "$(rc)" = 0 ] && ok || bad "a clean diff that ADDS a test must not trip the gate (rc=$(rc))"
has 'TAMPER_COUNT: 0' && ok || bad "clean diff should report 0 (got: $(scan|head -1))"

# ---------- 2. deleting a whole test file ----------
newrepo delfile
git rm -q tests/thing.test.js; git commit -qm "drop tests"
[ "$(rc)" = 1 ] && ok || bad "deleting a test file must block (rc=$(rc))"
has 'deleted_files=1' && ok || bad "deleted file must be counted: $(scan|head -1)"
# A deleted FILE also contributes its removed cases, so the count is >0 rather
# than exactly 1 — assert the property, not an arithmetic coincidence.
has 'BLOCKING_COUNT: [1-9]' && ok || bad "a deletion must be reported as blocking: $(scan|sed -n 2p)"
has 'DELETED_TEST_FILES:.*thing.test.js' && ok || bad "the deleted file must be named"

# ---------- 3. deleting a test case from a surviving file ----------
newrepo delcase
cat > tests/thing.test.js <<'EOF'
describe('thing', () => {
  it('adds', () => { expect(add(1,2)).toBe(3) })
})
EOF
git add -A; git commit -qm "trim"
[ "$(rc)" = 1 ] && ok || bad "deleting a test case must block (rc=$(rc))"
has 'deleted_cases=1' && ok || bad "the removed case must be counted: $(scan|head -1)"

# ---------- 4. skip markers, one per stack we actually run ----------
# Each of these is a real way to make a suite green by not running it.
i=0
for MARK in \
  "it.skip('adds', () => {})" \
  "describe.skip('thing', () => {})" \
  "xit('adds', () => {})" \
  "test.todo('adds')" \
  "it.only('adds', () => {})" ; do
  i=$((i+1)); newrepo "skip$i"
  printf '%s\n' "$MARK" >> tests/thing.test.js
  git add -A; git commit -qm "skip $i"
  # Counted and reported, but NOT blocking: the pattern cannot tell code from a
  # comment or a string, and a gate that blocks on the word "skip" appearing in
  # a comment gets worked around rather than obeyed.
  [ "$(rc)" = 0 ] || bad "an added skip marker must WARN, not block: $MARK (rc=$(rc))"
  grep -q 'added_skips=1' <<<"$(scan)" || bad "skip marker not counted: $MARK"
done
ok
# ...and the warning has to be loud enough to read.
has 'may be a suite quietly switched off' && ok || bad "an added skip must be called out in the verdict"

# A "skip" inside a COMMENT must not block a build — this is precisely why the
# marker class warns instead of gating.
newrepo skipcomment
printf '// TODO: do not .only( ) this, and never use --skip here\n' >> tests/thing.test.js
git add -A; git commit -qm "comment mentioning skip"
[ "$(rc)" = 0 ] && ok || bad "a skip word inside a comment must never block (rc=$(rc))"
# python + go, which the fleet also builds
newrepo skippy; mkdir -p tests
printf '@pytest.mark.skip\ndef test_thing():\n    pass\n' > tests/test_py.py
git add -A; git commit -qm "pytest skip"
[ "$(rc)" = 0 ] && ok || bad "pytest skip marker must warn, not block (rc=$(rc))"
grep -q 'added_skips=1' <<<"$(scan)" && ok || bad "pytest skip marker not counted"
newrepo skipgo; printf 'func TestX(t *testing.T) { t.Skip("later") }\n' > tests/x_test.go
git add -A; git commit -qm "go skip"
[ "$(rc)" = 0 ] && ok || bad "go t.Skip must warn, not block (rc=$(rc))"
grep -q 'added_skips=1' <<<"$(scan)" && ok || bad "go t.Skip not counted"

# ---------- 4b. a path with a SPACE must not be invisible ----------
# The first version joined pathspecs with spaces and let the shell split them,
# so a tampered test at "tests/my suite.test.js" reported a clean bill of health.
newrepo spacedpath
git rm -q tests/thing.test.js
mkdir -p tests
cat > "tests/my suite.test.js" <<'EOF'
describe('s', () => { it('a', () => { expect(1).toBe(1) }) })
EOF
git add -A; git commit -qm "add a spaced-path suite"
BASE=$(git rev-parse HEAD)
cat > "tests/my suite.test.js" <<'EOF'
describe('s', () => {})
EOF
git add -A; git commit -qm "gut the spaced-path suite"
[ "$(rc)" = 1 ] && ok || bad "a deleted case in a SPACED path must still block (rc=$(rc))"
has 'deleted_cases=1' && ok || bad "the spaced-path deletion must be counted: $(scan|head -1)"

# ---------- 5. the justification path ----------
# The iron rule says a genuinely wrong test gets fixed AND flagged. Flagged
# means the gate stops blocking and the reviewer adjudicates — it does not mean
# the change is waved through.
newrepo just
git rm -q tests/thing.test.js
git commit -qm "remove obsolete suite

TEST-CHANGE: the adds/subtracts cases asserted the old currency rounding that
this ticket deliberately replaces; they cannot be fixed in place."
[ "$(rc)" = 2 ] && ok || bad "a justified test change must adjudicate (2), not block (got $(rc))"
has 'JUSTIFICATION: TEST-CHANGE' && ok || bad "the justification must be surfaced"
has 'currency rounding' && ok || bad "the justification TEXT must reach the reviewer, not just its presence"
# ...and the counts still travel with it: adjudicating is not hiding.
has 'deleted_files=1' && ok || bad "counts must still be reported when justified"

# A justification in plan.md counts too — that is where the plan-stage rule puts it.
newrepo justplan
git rm -q tests/thing.test.js; git commit -qm "remove suite"
mkdir -p "$T/bd"; printf 'TEST-CHANGE: superseded by the new contract tests.\n' > "$T/bd/plan.md"
BUILD_DIR="$T/bd" "$SCAN" "$BASE" "$R" >/dev/null 2>&1
[ "$?" = 2 ] && ok || bad "a TEST-CHANGE block in plan.md must also count"

# ---------- 6. the assertion delta is reported, never gated ----------
# Collapsing three asserts into a helper is routine refactoring. A gate that
# fired on it would be trained away inside a week, so it is a number the
# reviewer reads, not a block.
newrepo assertdelta
cat > tests/thing.test.js <<'EOF'
describe('thing', () => {
  it('adds', () => { expectAll([[1,2,3]]) })
})
EOF
git add -A; git commit -qm "refactor asserts into a helper"
has 'ASSERTION_DELTA' && ok || bad "the assertion delta must be reported"
has 'reported, not gated' && ok || bad "the report must say the delta is not a gate"

# ---------- 7. a scan that cannot run says so, and does not pass ----------
# Silence here would be a green build whose integrity was never checked.
"$SCAN" deadbeefdeadbeef "$R" >/dev/null 2>&1
[ "$?" = 3 ] && ok || bad "an unresolvable base must exit 3 (scan_failed), not 0"
"$SCAN" "$BASE" "$T/nonexistent-dir" >/dev/null 2>&1
[ "$?" = 3 ] && ok || bad "a missing repo dir must exit 3, not 0"
grep -q SCAN_FAILED <<<"$("$SCAN" deadbeefdeadbeef "$R" 2>/dev/null || true)" \
  && ok || bad "a failed scan must say SCAN_FAILED on stdout"

# ---------- 8. non-test files are not the gate's business ----------
# Deleting production code is a normal diff; only test integrity is scanned here.
newrepo prodonly
git rm -q app.js; git commit -qm "drop module"
[ "$(rc)" = 0 ] && ok || bad "deleting a non-test file must not trip the tamper gate (rc=$(rc))"

# ---------- 9. a retitled case is a rewrite, not a deletion ----------
# 2026-09-13: 36 builds fleet-wide ($730) were thrown away because a builder
# retitled `it('adds')` while adding forty cases around it. The rule is about
# LOSING coverage; a file that ends with at least as many cases as it started
# has lost none. Gross removals stay visible to the reviewer as a count.
newrepo retitle
cat > tests/thing.test.js <<'EOF'
describe('thing', () => {
  it('adds two integers', () => { expect(add(1,2)).toBe(3) })
  it('subtracts', () => { expect(sub(3,1)).toBe(2) })
  it('multiplies', () => { expect(mul(2,3)).toBe(6) })
})
EOF
git add -A; git commit -qm "retitle + add"
[ "$(rc)" = 0 ] && ok || bad "a retitled case with no net loss must not block (rc=$(rc))"
has 'deleted_cases=0' && ok || bad "a retitle is not a deleted case: $(scan|head -1)"
has 'REWORDED_CASES: 1' && ok || bad "the retitle must still be reported to the reviewer: $(scan)"

# ---------- 10. splitting one case into two is not a deletion either ----------
newrepo split
cat > tests/thing.test.js <<'EOF'
describe('thing', () => {
  it('adds positives', () => { expect(add(1,2)).toBe(3) })
  it('adds negatives', () => { expect(add(-1,-2)).toBe(-3) })
  it('subtracts', () => { expect(sub(3,1)).toBe(2) })
})
EOF
git add -A; git commit -qm "split adds"
[ "$(rc)" = 0 ] && ok || bad "splitting a case must not block (rc=$(rc))"

# ---------- 11. net loss in one file still blocks, however much another file adds ----------
# The count is per FILE: forty new cases in a new file do not buy the right to
# delete one in an old file. That is exactly the tamper the gate exists for.
newrepo netloss
cat > tests/thing.test.js <<'EOF'
describe('thing', () => {
  it('adds', () => { expect(add(1,2)).toBe(3) })
})
EOF
cat > tests/other.test.js <<'EOF'
describe('other', () => {
  it('a', () => { expect(1).toBe(1) })
  it('b', () => { expect(2).toBe(2) })
  it('c', () => { expect(3).toBe(3) })
})
EOF
git add -A; git commit -qm "drop subtracts, add other"
[ "$(rc)" = 1 ] && ok || bad "a net loss in one file must block even when another file grows (rc=$(rc))"
has 'deleted_cases=1' && ok || bad "the net loss must be counted per file: $(scan|head -1)"

echo "test-tamper-scan-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
