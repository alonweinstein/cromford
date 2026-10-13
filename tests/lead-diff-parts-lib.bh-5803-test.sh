#!/bin/bash
# tests/lead-diff-parts-lib.bh-5803-test.sh — bin/lib/lead-diff-parts.sh on
# small real git fixtures: the classifier, the packing order, the coverage
# section, the split proposal and the failure rc.
#   U1  ldp_class: generated files, lockfiles and fixtures are digest
#   U2  a binary file is digest, listed with its size, and its bytes never reach the parts file
#   U3  ldp_class: tests are test; look-alikes (bin/test-impact.sh, src/latest.ts) are rest
#   U4  order plan, test, rest; a test the plan names goes in the plan tier
#   U5  a file over the budget is skipped, a later small file is still read, the skip is listed
#   U6  split pairing: a test naming bin/alpha.sh rides in alpha's part; an unpaired test is its own unit
#   U7  a unit over the budget alone is its own part, marked
#   U8  oversize with no test files: rc 0, "no test files in this diff", no split file
#   U9  250 unread files: 200 rows and "+50 more"; no plan file; a bad base ref is rc 1
#   U10 the coverage lists outgrow LDP_RESERVE (lead review BLOCK at b5426ef9d):
#       rc 0, the parts file fits the budget, and the files that no longer fit
#       move to the not-read list, never rc 1 and a cut diff
#   U11 the 7th arg `any` (the operator, #5803: nothing merges unread): an unread file
#       that is not a test is rc 2 with a proposed split, not rc 0
#   M1  mutation: a copy of the lib with the tier order reversed makes U4 red
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-diff-parts-lib.bh-5803-test.sh
# scratch-closure-allow: unit test of one pure lib
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
LIB="$SRC/bin/lib/lead-diff-parts.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$LIB" ] || { echo "FAIL: bin/lib/lead-diff-parts.sh does not exist"; exit 1; }
# shellcheck source=/dev/null
. "$LIB" || { echo "FAIL: the lib does not source"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# fill <file> <bytes> <tag> — deterministic text lines of about <bytes>
fill() {
  mkdir -p "$(dirname "$1")"
  awk -v n="$2" -v t="$3" 'BEGIN { l = 0; while (l < n) { s = sprintf("%s line %07d filler text\n", t, l); printf "%s", s; l += length(s) } }' > "$1"
}
# repo <dir> — a base commit; files are added by the caller, then `head` commits
repo() { git init -q -b main "$1"; echo base > "$1/README"; git -C "$1" add -A; git -C "$1" commit -qm base; git -C "$1" checkout -q -b pr; }
head_commit() { git -C "$1" add -A; git -C "$1" commit -qm head; git -C "$1" rev-parse HEAD; }
# build <dir> <budget> — runs ldp_build, sets RC, P (parts) and S (split)
build() {
  P="$T/parts.$2"; S="$T/split.$2"; rm -f "$P" "$S"
  ldp_build "$1" main HEAD "$2" "$P" "$S"; RC=$?
}
off() { grep -bF -- "$1" "$P" 2>/dev/null | head -n 1 | cut -d: -f1; }

# ── U1 / U3: the classifier ──
for p in tests/fixtures/big.json a/__snapshots__/x.snap package-lock.json go.sum dist.min.js src/generated/a.ts x.generated.ts web/testdata/in.txt; do
  [ "$(ldp_class "$p")" = digest ] && ok || bad "U1 $p is $(ldp_class "$p"), want digest"
done
[ "$(ldp_class bin/x.sh 1)" = digest ] && ok || bad "U1 the digest flag is ignored"
for p in tests/a-test.sh src/__tests__/a.ts src/a.test.ts pkg/a_test.go e2e/login.spec.ts tests/mc/b.sh; do
  [ "$(ldp_class "$p")" = test ] && ok || bad "U3 $p is $(ldp_class "$p"), want test"
done
for p in bin/test-impact.sh bin/test-impact-gate.sh src/latest.ts docs/testing.md catalog/tests.json scripts/migrations/001.sql bin/share/mapping.py; do
  [ "$(ldp_class "$p")" = rest ] && ok || bad "U3 $p is $(ldp_class "$p"), want rest"
done

# ── U4: order plan, test, rest ──
R="$T/r4"; repo "$R"
mkdir -p "$R/.harness/specs/BH-9001" "$R/bin" "$R/tests"
printf '# plan\n\nTouch bin/planned.sh and tests/named-test.sh.\n' > "$R/.harness/specs/BH-9001/plan.md"
fill "$R/bin/aaa-rest.sh" 3000 RESTA
fill "$R/bin/planned.sh" 3000 PLANNED
fill "$R/tests/a-test.sh" 3000 TESTA
fill "$R/tests/named-test.sh" 3000 NAMED
head_commit "$R" >/dev/null
build "$R" 100000
[ "$RC" = 0 ] && ok || bad "U4 rc=$RC, want 0"
o_plan=$(off 'diff --git a/.harness/specs/BH-9001/plan.md'); o_p=$(off 'diff --git a/bin/planned.sh')
o_named=$(off 'diff --git a/tests/named-test.sh'); o_t=$(off 'diff --git a/tests/a-test.sh'); o_r=$(off 'diff --git a/bin/aaa-rest.sh')
[ -n "$o_plan" ] && [ -n "$o_p" ] && [ -n "$o_named" ] && [ -n "$o_t" ] && [ -n "$o_r" ] \
  && [ "$o_p" -lt "$o_t" ] && [ "$o_named" -lt "$o_t" ] && [ "$o_t" -lt "$o_r" ] \
  && ok || bad "U4 order plan=$o_plan planned=$o_p named=$o_named test=$o_t rest=$o_r"
grep -qx 'Plan file: .harness/specs/BH-9001/plan.md' "$P" && ok || bad "U4 plan file line: $(grep '^Plan file' "$P")"
cv=$(off '## Diff coverage'); df=$(grep -bx '## Diff' "$P" | cut -d: -f1)
[ "$cv" = 0 ] && [ -n "$df" ] && [ "$df" -gt 0 ] && ok || bad "U4 coverage=$cv diff=$df"
grep -qx 'Not read: none.' "$P" && ok || bad "U4 not-read line: $(grep '^Not read' "$P")"
[ ! -e "$S" ] && ok || bad "U4 a split file was written with every test read"

# ── U2 / U5: a binary digest, a skipped big file, a later small file still read ──
R="$T/r5"; repo "$R"; mkdir -p "$R/bin" "$R/assets"
fill "$R/bin/big.sh" 80000 BIG
fill "$R/bin/small.sh" 2000 SMALL
printf 'BINMARK\000\001\002%.0s' $(seq 1 300) > "$R/assets/logo.png"
head_commit "$R" >/dev/null
build "$R" 70000      # cap 70000 - 32768 = 37232
[ "$RC" = 0 ] && ok || bad "U5 rc=$RC, want 0"
grep -q 'diff --git a/bin/small.sh' "$P" && ok || bad "U5 the small file after the skipped one was not read"
grep -q 'diff --git a/bin/big.sh' "$P" && bad "U5 the big file was read past the cap" || ok
bsz=$(git -C "$R" diff main...HEAD -- bin/big.sh | wc -c | tr -d ' ')
grep -qxF -- "- bin/big.sh (rest, $bsz bytes)" "$P" && ok || bad "U5 skip row missing ($bsz): $(sed -n '/^Not read/,/^Digest/p' "$P")"
[ "$LDP_UNREAD" = bin/big.sh ] && ok || bad "U5 LDP_UNREAD='$LDP_UNREAD'"
[ "$(wc -c < "$P")" -le 70000 ] && ok || bad "U5 parts file is $(wc -c < "$P") bytes, over the budget"
lsz=$(wc -c < "$R/assets/logo.png" | tr -d ' ')
grep -qxF -- "- assets/logo.png ($lsz bytes, binary)" "$P" && ok || bad "U2 binary digest row missing ($lsz): $(sed -n '/^Digest/,$p' "$P" | head -5)"
grep -q 'BINMARK\|diff --git a/assets/logo.png' "$P" && bad "U2 binary content reached the parts file" || ok
grep -qx 'Tests: no test files in this diff.' "$P" && ok || bad "U8 (no tests) line: $(grep '^Tests' "$P")"
[ ! -e "$S" ] && ok || bad "U8 a split file was written with no test files"
grep -qx 'Plan file: no plan file in this diff' "$P" && ok || bad "U9 no-plan line: $(grep '^Plan file' "$P")"

# ── U6 / U7: split pairing, unpaired test, over-alone ──
R="$T/r6"; repo "$R"; mkdir -p "$R/bin" "$R/tests"
fill "$R/bin/alpha.sh" 15000 ALPHA
fill "$R/bin/huge.sh" 60000 HUGE
{ echo 'run bin/alpha.sh'; } > "$R/tests/alpha-test.sh"; fill "$T/x" 15000 ATEST; cat "$T/x" >> "$R/tests/alpha-test.sh"
fill "$R/tests/lone-test.sh" 25000 LONE
head_commit "$R" >/dev/null
build "$R" 70000      # cap 37232: alpha-test 15K + lone 25K do not both fit, so a test is unread
[ "$RC" = 2 ] && ok || bad "U6 rc=$RC, want 2"
[ -s "$S" ] && ok || bad "U6 no split file"
grep -E '^- Part [0-9]+ ' "$S" | grep -F 'bin/alpha.sh' | grep -qF 'tests/alpha-test.sh' && ok || bad "U6 alpha-test not with alpha: $(cat "$S")"
grep -E '^- Part [0-9]+ ' "$S" | grep -F 'tests/lone-test.sh' | grep -qvF 'alpha' && ok || bad "U6 lone test not its own unit: $(cat "$S")"
grep -E '^- Part [0-9]+ ' "$S" | grep -F 'bin/huge.sh' | grep -qF 'over the limit alone' && ok || bad "U7 huge not marked over alone: $(cat "$S")"
al=$(grep -E '^- Part [0-9]+ ' "$S" | grep -F 'bin/alpha.sh')
grep -qF 'over the limit alone' <<<"$al" && bad "U6 alpha's part is marked over alone: $(cat "$S")" || ok
awk '/^- Part [0-9]+ \(/ { n = $4; gsub(/[^0-9]/, "", n); if (n > 37232 && $0 !~ /over the limit alone/) exit 1 }' "$S" \
  && ok || bad "U6 a part over the cap is not marked: $(cat "$S")"

# ── U9: 250 unread files, capped list; bad base ref = rc 1 ──
R="$T/r9"; repo "$R"; mkdir -p "$R/src"
for i in $(seq -w 1 250); do fill "$R/src/f$i.txt" 300 "F$i"; done
fill "$R/src/aaa-first.txt" 200 FIRST
head_commit "$R" >/dev/null
build "$R" 33100      # cap 332 bytes: at most one file fits
[ "$RC" = 0 ] && ok || bad "U9 rc=$RC, want 0"
rows=$(sed -n '/^Not read/,/^Digest/p' "$P" | grep -c '^- ')
[ "$rows" = 200 ] && ok || bad "U9 $rows rows listed, want 200"
nu=$(printf '%s\n' "$LDP_UNREAD" | grep -c .)
grep -qx "+$((nu - 200)) more files, not listed" "$P" && ok || bad "U9 no exact remainder line for $nu unread: $(grep 'more files' "$P")"
[ "$nu" -ge 250 ] && ok || bad "U9 only $nu files unread"
ldp_build "$R" no-such-ref HEAD 400000 "$T/p.bad" "$T/s.bad"; rc=$?
[ "$rc" = 1 ] && ok || bad "U9 bad base ref rc=$rc, want 1"
ldp_build "$R" main HEAD 1000 "$T/p.small" "$T/s.small"; rc=$?
[ "$rc" = 1 ] && ok || bad "U9 a budget under the reserve rc=$rc, want 1"

# ── U10: the coverage lists outgrow the reserve: shrink the read part, keep the coverage ──
R="$T/r10"; repo "$R"; mkdir -p "$R/src/a-quite-long-directory-name-for-the-coverage-rows/and-a-second-level"
for i in $(seq -w 1 60); do fill "$R/src/a-quite-long-directory-name-for-the-coverage-rows/and-a-second-level/file-$i.txt" 2000 "G$i"; done
head_commit "$R" >/dev/null
( LDP_RESERVE=200
  ldp_build "$R" main HEAD 60000 "$T/p.u10" "$T/s.u10"; echo "rc=$? read=$LDP_READ_FILES unread=$(printf '%s\n' "$LDP_UNREAD" | grep -c .)" ) > "$T/u10.out"
grep -q '^rc=0 ' "$T/u10.out" && ok || bad "U10 an overflowing coverage list must still be rc 0: $(cat "$T/u10.out")"
[ -s "$T/p.u10" ] && [ "$(wc -c < "$T/p.u10" | tr -d ' ')" -le 60000 ] && ok || bad "U10 the parts file must fit the 60000 budget: $(wc -c < "$T/p.u10" 2>/dev/null)"
grep -qx '## Diff coverage' "$T/p.u10" 2>/dev/null && ok || bad "U10 no ## Diff coverage"
n_listed=$(sed -n '/^Not read/,/^Digest/p' "$T/p.u10" 2>/dev/null | grep -c '^- ')
n_unread=$(sed -n 's/.* unread=\([0-9]*\)$/\1/p' "$T/u10.out")
[ -n "$n_unread" ] && [ "$n_listed" = "$n_unread" ] && ok || bad "U10 every unread file is listed ($n_listed listed, $n_unread unread)"
n_read=$(grep -c '^diff --git ' "$T/p.u10" 2>/dev/null)
[ "$n_read" = "$(sed -n 's/.* read=\([0-9]*\) .*/\1/p' "$T/u10.out")" ] && ok || bad "U10 LDP_READ_FILES must count the files in the parts file ($n_read)"

# ── U11: `any` makes an unread non-test file split required too ──
ldp_build "$T/r5" main HEAD 70000 "$T/p.u11" "$T/s.u11" any; rc=$?
[ "$rc" = 2 ] && ok || bad "U11 an unread bin/ file with \`any\`: rc=$rc, want 2"
[ -s "$T/s.u11" ] && grep -qF 'bin/big.sh (' "$T/s.u11" && ok || bad "U11 the proposed split must name bin/big.sh: $(cat "$T/s.u11" 2>/dev/null)"
[ "$LDP_TEST_UNREAD" = 0 ] && [ "$LDP_UNREAD" = bin/big.sh ] && ok || bad "U11 unread='$LDP_UNREAD' test_unread=$LDP_TEST_UNREAD"
ldp_build "$T/r5" main HEAD 70000 "$T/p.u11b" "$T/s.u11b"; rc=$?
[ "$rc" = 0 ] && ok || bad "U11 without \`any\` the old rc 0 stands: rc=$rc"

# ── M1: tier order reversed -> U4 red ──
sed 's/for t in plan test rest; do/for t in rest test plan; do/' "$LIB" > "$T/mut.sh"
if cmp -s "$T/mut.sh" "$LIB"; then bad "M1 mutation anchor missing"
else
  ( . "$T/mut.sh"; ldp_build "$T/r4" main HEAD 100000 "$T/pm" "$T/sm" >/dev/null
    a=$(grep -bF 'diff --git a/bin/planned.sh' "$T/pm" | cut -d: -f1); b=$(grep -bF 'diff --git a/bin/aaa-rest.sh' "$T/pm" | cut -d: -f1)
    [ "$a" -lt "$b" ] ) && bad "M1 the order assertion stayed green under the mutation" || ok
fi

echo "lead-diff-parts-lib.bh-5803: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
