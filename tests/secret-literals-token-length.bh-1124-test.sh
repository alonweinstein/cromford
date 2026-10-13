#!/bin/bash
# tests/secret-literals-token-length.bh-1124-test.sh — a GitHub token is a
# LENGTH, not a prefix.
#
# THE INCIDENT (BH-1124). checks/secret-literals/check.sh matched
# gh[pousr]_ followed by six alphanumerics, which is the exact shape of
# `ghs_author`. Every file under bin/lib/gh-shim/ is full of those names, so
# PR #882 answered "42 hit(s) — secret-literals(x42)" on a diff carrying no
# credential at all, and the merge conductor held it in BLOCKED_HUMAN for 617
# minutes. The fix bounds the run at 24 characters (the 4-char prefix plus the
# 20 alphanumerics bin/transcript-scrub.sh and tests/evals/* already use) and
# excludes runs that are being defined, called or piped as symbols.
#
# Every case here drives the REAL runner, bin/checks-run.sh, over a diff and
# asserts on its rc and its CHECK-HIT lines — never on the text of the pattern
# (D3). The runner is the production entry point: bin/merge-sweep.sh's iron-law
# scan, mc_iron_law_scan in bin/lib/merge-conductor-lib.sh and bin/run-build.sh's
# review gates all reach the check through it and through nothing else.
#
# Sections:
#   A  the gh-shim namespace is silent — the standing #882 case
#   B  a token-LENGTH run is still caught, in every shape that is a literal
#      — including the shapes the shape clauses quiet below 40 characters
#   C  the shape exclusions, each clause on its own
#   D  mutation: sabotage the copy under $T and watch a green case go red (D1)
#
# The catalog is COPIED into $T so section D can sabotage check.sh without
# touching the tracked file. Section A also runs once against the REAL catalog,
# so a pass here cannot come from the copy alone.
#
# Run from anywhere: tests/secret-literals-token-length.bh-1124-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RUN="$DIR/bin/checks-run.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cp -r "$DIR/checks" "$T/checks"
CHK="$T/checks/secret-literals/check.sh"
cp "$CHK" "$T/pristine-check.sh"
restore() { cp "$T/pristine-check.sh" "$CHK"; }

# A 37-character run: comfortably past the 24-character floor, so only a SHAPE
# clause can keep it quiet. That is what makes section C prove the shape clauses
# rather than the bound.
#
# Both fixture strings below carry the word FIXTURE inside the matched run on
# purpose. bin/share/leakcheck.py and bin/share/overlay/tests/no-client-identifiers-test.sh
# refuse to publish a gh[pousr]_ run of 20+ alnum unless the marker sits INSIDE
# the string, and the first draft of this file (ghs_ + a plain alphabet run)
# turned tests/share-mirror-clean-test.sh red for exactly that reason. A marker
# is the mechanism those scanners document; a shorter fixture would have stopped
# proving the branch.
RLONG=ghs_FIXTUREbh1124SHAPEPROBEnotatoken0
# A fixture token of the real installation-token shape: 4-char prefix + 36
# alphanumerics = 40. Obviously a fixture, and it never existed on GitHub.
T40=ghs_FIXTUREbh1124NOTAREALTOKEN0123456789

# mkdiff <path> <added line>... — a unified diff the runner's normalizer accepts.
mkdiff() {
  local p="$1"; shift
  {
    printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -0,0 +1,%d @@\n' "$p" "$p" "$p" "$p" "$#"
    local L
    for L in "$@"; do printf '+%s\n' "$L"; done
  } > "$T/d.diff"
}

# quiet <name> [<catalog>] — rc 0 and NOTHING fired, from any check in the
# catalog. A sibling check firing on these lines is as wrong as this one firing.
quiet() {
  local name="$1" cat="${2:-$T/checks}" out rc
  out=$(CHECKS_DIR="$cat" "$RUN" "$T/d.diff" 2>&1); rc=$?
  if [ "$rc" = 0 ] && ! grep -q '^CHECK-HIT ' <<<"$out"; then ok
  else bad "$name: expected rc 0 and no CHECK-HIT, got rc=$rc:
$out"; fi
}

# fires <name> <n> — rc 1 and exactly n secret-literals hits.
fires() {
  local name="$1" n="$2" out rc got
  out=$(CHECKS_DIR="$T/checks" "$RUN" "$T/d.diff" 2>&1); rc=$?
  got=$(grep -c '^CHECK-HIT secret-literals ' <<<"$out")
  if [ "$rc" = 1 ] && [ "$got" = "$n" ]; then ok
  else bad "$name: expected rc 1 and $n secret-literals hit(s), got rc=$rc hits=$got:
$out"; fi
}

# ── A. the gh-shim namespace is silent ──────────────────────────────────────
# The three lines are copied verbatim from the #882 diff, not invented (D26).
shim_diff() {
  mkdiff bin/lib/gh-shim/read-maps.sh \
    'def ghs_labels:' \
    '  author: (.user | ghs_author),' \
    '    raw=$(ghs_paginate "repos/$GHS_SLUG/issues?$q" "$fetch") || exit $?'
}
shim_diff
quiet shim-identifiers-silent
# ... and once against the catalog this repo actually ships, so the pass is not
# an artefact of the scratch copy.
quiet shim-identifiers-silent-production-catalog "$DIR/checks"

# ── B. a token-LENGTH run is still caught ───────────────────────────────────
mkdiff src/lib/vendor.ts "const GH_APP_TOKEN = \"$T40\""
fires bare-40-char-literal-hits 1

# The 34-char PAT shape four redactors in this repo already treat as a token.
mkdiff bin/lib/deploy.sh "export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz1234"
fires short-pat-fixture-still-hits 1

# An identifier EARLIER on the line must not hide a literal later on it: the
# check walks every gh[pousr]_ run, it does not stop at the first match().
mkdiff bin/lib/gh-shim/pr-read.sh "  ghs_author \"ghp_abcdefghijklmnopqrstuvwxyz1234\""
fires identifier-does-not-hide-a-literal 1

# ... and an identifier CONCATENATED to the literal must not hide it either.
# `[A-Za-z0-9]+` stops at the underscore, so `ghs_ghs` is a run of its own that
# the `_` shape clause rejects. If the scan resumed after that run it would land
# past the real prefix and see nothing. The six-class pattern this check
# replaces caught this shape, so losing it would be a narrowing regression.
mkdiff src/lib/vendor.ts "const T = \"ghs_$T40\""
fires nested-prefix-does-not-hide-a-literal 1

# The shape clauses arbitrate the 24-39 band ONLY. At a real token length the
# surrounding punctuation stops mattering: `| ` in front or `=` behind is how a
# 40-char credential gets pasted into a markdown table, a log line or a .env
# sample, and main's six-class pattern fired on all three. Silencing them was
# the narrowing the review of this PR caught -- the same class this file's
# header calls a regression, now pinned from the other direction.
mkdiff docs/notes/leak.md "| $T40 |"
fires token-in-table-cell 1

mkdiff docs/notes/leak.md "the value we found was | $T40"
fires token-after-trailing-pipe 1

mkdiff bin/lib/deploy.sh "TOKEN=$T40="
fires token-with-trailing-equals 1

# ── C. the shape exclusions, one clause at a time ────────────────────────────
mkdiff src/lib/shim.ts "  const v = $RLONG(arg)"
quiet long-run-followed-by-paren

mkdiff src/lib/shim.ts "  const v = ${RLONG}_suffix"
quiet long-run-followed-by-underscore

mkdiff src/lib/shim.ts "  $RLONG=fetchAll"
quiet long-run-followed-by-equals

mkdiff src/lib/shim.ts "  echo \"\$$RLONG\$ARG\""
quiet long-run-followed-by-dollar

mkdiff bin/lib/gh-shim/read-maps.sh "def $RLONG:"
quiet long-run-after-def

mkdiff bin/lib/gh-shim/read-maps.sh "  x: (.y | $RLONG),"
quiet long-run-after-pipe

# ── D. mutation: each half of the rule is load-bearing on its own (D1) ───────
# D1a. Drop the length bound and the standing #882 case goes red again. Without
# this, a bound that matched nothing would look exactly like a clean diff.
sed -i 's/RLENGTH >= 24/RLENGTH >= 1/' "$CHK"
if grep -q 'RLENGTH >= 1' "$CHK"; then ok; else bad "mutation-threshold: the sed did not apply — the bound is not spelled 'RLENGTH >= 24'"; fi
shim_diff
OUT=$(CHECKS_DIR="$T/checks" "$RUN" "$T/d.diff" 2>&1); RC=$?
if [ "$RC" = 1 ] && grep -q '^CHECK-HIT secret-literals bin/lib/gh-shim/read-maps.sh:' <<<"$OUT"; then ok
else bad "mutation-threshold: with the length bound removed, shim-identifiers-silent stayed GREEN (rc=$RC) — the bound is not what keeps it quiet:
$OUT"; fi
restore
shim_diff
quiet mutation-threshold-restored

# D1b. Disable ONE shape clause — the `(` exclusion — and the 37-char call goes
# red, which proves the shape clauses carry their own weight rather than riding
# on the length bound.
sed -i 's/post != "("/post != "\\a"/' "$CHK"
if grep -q 'post != "\\a"' "$CHK"; then ok; else bad "mutation-shape: the sed did not apply — the paren clause is not spelled 'post != \"(\"'"; fi
mkdiff src/lib/shim.ts "  const v = $RLONG(arg)"
OUT=$(CHECKS_DIR="$T/checks" "$RUN" "$T/d.diff" 2>&1); RC=$?
if [ "$RC" = 1 ] && grep -q '^CHECK-HIT secret-literals src/lib/shim.ts:' <<<"$OUT"; then ok
else bad "mutation-shape: with the '(' exclusion disabled, long-run-followed-by-paren stayed GREEN (rc=$RC) — that clause is doing nothing:
$OUT"; fi
restore
mkdiff src/lib/shim.ts "  const v = $RLONG(arg)"
quiet mutation-shape-restored

# D1c. Put the advance back to where the first draft had it — past the whole
# rejected run instead of two characters in — and the nested-prefix literal goes
# quiet. That is the regression this clause exists to prevent, and without this
# case the +2 could be silently reverted by anyone tidying the loop.
sed -i -e 's/RSTART + 2)/RSTART + RLENGTH)/' -e 's/abs + 1$/abs + RLENGTH - 1/' "$CHK"
if grep -q 'substr(rest, RSTART + RLENGTH)' "$CHK"; then ok; else bad "mutation-advance: the sed did not apply — the advance is not spelled 'RSTART + 2)'"; fi
mkdiff src/lib/vendor.ts "const T = \"ghs_$T40\""
OUT=$(CHECKS_DIR="$T/checks" "$RUN" "$T/d.diff" 2>&1); RC=$?
if [ "$RC" = 0 ] && ! grep -q '^CHECK-HIT secret-literals ' <<<"$OUT"; then ok
else bad "mutation-advance: with the advance back past the whole run, the nested prefix still fired (rc=$RC) — the two-character advance is doing nothing:
$OUT"; fi
restore
mkdiff src/lib/vendor.ts "const T = \"ghs_$T40\""
fires mutation-advance-restored 1

# D1d. Raise the real-length branch out of reach and the table-cell token goes
# quiet again — which is the review finding this round closed, and without this
# case the `RLENGTH >= 40 ||` could be folded back into the shape clause by
# anyone tidying the condition.
sed -i 's/RLENGTH >= 40/RLENGTH >= 9999/' "$CHK"
if grep -q 'RLENGTH >= 9999' "$CHK"; then ok; else bad "mutation-real-length: the sed did not apply — the unconditional branch is not spelled 'RLENGTH >= 40'"; fi
mkdiff docs/notes/leak.md "| $T40 |"
OUT=$(CHECKS_DIR="$T/checks" "$RUN" "$T/d.diff" 2>&1); RC=$?
if [ "$RC" = 0 ] && ! grep -q '^CHECK-HIT secret-literals ' <<<"$OUT"; then ok
else bad "mutation-real-length: with the real-length branch raised, the piped table cell still fired (rc=$RC) — that branch is doing nothing:
$OUT"; fi
restore
mkdiff docs/notes/leak.md "| $T40 |"
fires mutation-real-length-restored 1

echo "secret-literals-token-length.bh-1124-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
