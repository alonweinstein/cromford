#!/bin/bash
# tests/pr-self-check.bh-5798-test.sh — BH-5798: the pre-review self-check
# refuses a PR body that does not match its own head.
#
# WHY. 38 review BLOCKs (300-PR analysis, 2026-10-09): 15 bodies described an
# older head, 11 said "Closes" on a partial build, 9 missed a named acceptance
# item, 3 changed files outside the plan. bin/pr-self-check.sh decides each of
# these from git and the body text alone, before any review is bought:
#
#   A1  "Closes #N" with an acceptance item not met: refused (closes-not-met)
#   A2  "Refs #N" with the same item: passes
#   A3  "Closes #N" with every item met: passes
#   A4  a checked item whose own text says "not met": passes (the box decides)
#   B1  evidence on an older sha whose files changed later: refused (evidence-head)
#   B2  evidence on an older sha where only an allowed doc changed later: passes
#   B3  evidence on the head: passes
#   B4  evidence on a sha the repo does not have: refused
#   C1  a diff file the plan does not name, no reason: refused (plan-files)
#   C2  the same file with a reason under "## Files outside the plan": passes
#   C3  a file under an allowed glob (docs/notes/): passes
#   M1  the rule's catalog row set to `off`: C1 passes
#
# A real git fixture: main, then a PR branch with two commits.
# Run from anywhere: tests/pr-self-check.bh-5798-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
H="$T/h"; mkdir -p "$H"
scratch_install_closure bin/pr-self-check.sh "$H" >/dev/null || { echo "FAIL: closure of bin/pr-self-check.sh"; exit 1; }
cp "$DIR/catalog/pr-self-check.tsv" "$T/catalog.tsv" 2>/dev/null || : > "$T/catalog.tsv"
# TEST-CHANGE (BH-5790): the catalog now also holds the body-* section rules
# (Why, an acceptance section, ...), which these fixture bodies do not carry on
# purpose. This suite pins the three rules above, so it runs only them;
# tests/pr-body-lint.bh-5790-test.sh pins the body rules.
export PR_SELF_CHECK_ONLY='^(closes-not-met|evidence-head|plan-files)$'

# ── the fixture repo: main M0; the PR: P1 (bin/a.sh + the plan), P2 (bin/a.sh again,
# bin/extra.sh, docs/notes/n.md), P3 (docs/notes/n.md only)
R="$T/repo"; mkdir -p "$R"
git -C "$R" init -q -b main
echo base > "$R/README"; git -C "$R" add -A; git -C "$R" commit -qm M0
git -C "$R" checkout -qb ticket/bh-1
mkdir -p "$R/bin" "$R/.harness/specs/BH-1" "$R/docs/notes"
printf '# plan\n\n## Files to touch\n- `bin/a.sh`\n\n## Acceptance tests\n- a test\n' > "$R/.harness/specs/BH-1/plan.md"
echo one > "$R/bin/a.sh"; git -C "$R" add -A; git -C "$R" commit -qm P1; P1=$(git -C "$R" rev-parse HEAD)
echo two > "$R/bin/a.sh"; echo x > "$R/bin/extra.sh"; echo n > "$R/docs/notes/n.md"
git -C "$R" add -A; git -C "$R" commit -qm P2; P2=$(git -C "$R" rev-parse HEAD)
echo n2 > "$R/docs/notes/n.md"; git -C "$R" commit -qam P3; P3=$(git -C "$R" rev-parse HEAD)

check() { # check <body-text> [head] — sets RC and OUT
  printf '%s\n' "$1" > "$T/body.md"
  OUT=$(PR_SELF_CHECK_CATALOG="$T/catalog.tsv" bash "$H/bin/pr-self-check.sh" check \
          --repo "$R" --base main --head "${2:-$P3}" --body "$T/body.md" 2>&1); RC=$?
}
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
REASON=$'## Files outside the plan\n- `bin/extra.sh`: the helper the plan forgot to list'
MET=$'## Acceptance self-check\n- [x] a test: met @'"$P3"
NOTMET=$'## Acceptance self-check\n- [ ] a test: not met (the seed returned 0 rows)'

# ── A: Closes on a partial build
check "Closes #1"$'\n\n'"$NOTMET"$'\n\n'"$REASON"
[ "$RC" = 1 ] && has "REFUSE closes-not-met" && ok || bad "A1: Closes with an item not met must be refused (rc=$RC) [$OUT]"
check "Refs #1"$'\n\n'"$NOTMET"$'\n\n'"$REASON"
[ "$RC" = 0 ] && ok || bad "A2: Refs with an item not met must pass (rc=$RC) [$OUT]"
check "Closes #1"$'\n\n'"$MET"$'\n\n'"$REASON"
[ "$RC" = 0 ] && ok || bad "A3: Closes with every item met must pass (rc=$RC) [$OUT]"

check "Closes #1"$'\n\n'$'## Acceptance self-check\n- [x] a body that says Closes while an item is not met is refused: met'$'\n\n'"$REASON"
[ "$RC" = 0 ] && ok || bad "A4: a checked item whose text says 'not met' must pass (rc=$RC) [$OUT]"

# ── B: evidence bound to the head
check "Refs #1"$'\n\n'"## Tests (head ${P1:0:12})"$'\n'"- 9 passed"$'\n\n'"$REASON"
[ "$RC" = 1 ] && has "REFUSE evidence-head" && has "bin/a.sh" && ok || bad "B1: evidence on ${P1:0:8}, with bin/a.sh changed after it, must be refused (rc=$RC) [$OUT]"
check "Refs #1"$'\n\n'"## Tests (head $P2)"$'\n'"- 9 passed"$'\n\n'"$REASON"
[ "$RC" = 0 ] && ok || bad "B2: evidence on ${P2:0:8}, with only docs/notes changed after it, must pass (rc=$RC) [$OUT]"
check "Refs #1"$'\n\n'"<!-- evidence-head: $P3 -->"$'\n\n'"$REASON"
[ "$RC" = 0 ] && ok || bad "B3: evidence on the head must pass (rc=$RC) [$OUT]"
check "Refs #1"$'\n\n'"## Tests (head 0123456789abcdef0123456789abcdef01234567)"$'\n\n'"$REASON"
[ "$RC" = 1 ] && has "REFUSE evidence-head" && ok || bad "B4: evidence on a sha the repo does not have must be refused (rc=$RC) [$OUT]"

# ── B5-B9 (lead review lr-5828-0691c979b9ea): fix rounds and conductor rebases
# push new heads and never rewrite the body, so the evidence sha goes stale by
# construction. A rebased head whose PR files read the same as at the evidence
# sha is the same evidence; a builder marker (<!-- evidence-head: -->) a fix
# round moved past is a NOTE, never a 30-minute hold. A human's own
# `head <sha>` claim is still held to the head.
git -C "$R" checkout -q main; echo m1 > "$R/MAIN1"; git -C "$R" add -A; git -C "$R" commit -qm M1
git -C "$R" checkout -qb rebased ticket/bh-1; git -C "$R" rebase -q main >/dev/null 2>&1; RB=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -qb rebased-fix rebased; echo three > "$R/bin/a.sh"; git -C "$R" commit -qam fixround; RBF=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q ticket/bh-1
check "Refs #1"$'\n\n'"<!-- evidence-head: $P3 -->"$'\n\n'"$REASON" "$RB"
! has "evidence-head" && [ "$RC" = 0 ] && ok || bad "B5: a rebased head whose PR files match the evidence sha must pass silently (rc=$RC) [$OUT]"
check "Refs #1"$'\n\n'"## Tests (head ${P3:0:12})"$'\n'"- 9 passed"$'\n\n'"$REASON" "$RB"
! has "REFUSE evidence-head" && [ "$RC" = 0 ] && ok || bad "B6: a human head claim on a rebase that changed no PR file must pass (rc=$RC) [$OUT]"
check "Refs #1"$'\n\n'"<!-- evidence-head: $P1 -->"$'\n\n'"$REASON" "$P3"
[ "$RC" = 0 ] && has "NOTE evidence-head" && has "bin/a.sh" && ! has "REFUSE evidence-head" && ok \
  || bad "B7: a builder marker a fix round moved past must be a NOTE naming the file, not a hold (rc=$RC) [$OUT]"
check "Refs #1"$'\n\n'"<!-- evidence-head: $P3 -->"$'\n\n'"$REASON" "$RBF"
[ "$RC" = 0 ] && has "NOTE evidence-head" && ! has "REFUSE evidence-head" && ok \
  || bad "B8: a builder marker on a rebased, then fixed head must be a NOTE (rc=$RC) [$OUT]"
check "Refs #1"$'\n\n'"## Tests (head ${P3:0:12})"$'\n'"- 9 passed"$'\n\n'"$REASON" "$RBF"
[ "$RC" = 1 ] && has "REFUSE evidence-head" && ok || bad "B9: a human head claim whose PR files changed after it is still refused (rc=$RC) [$OUT]"

# ── B10-B11 (lead review lr-5828-da3826282): the hub clone fetches only the
# base and the head, so a builder marker on a pre-rebase head may not resolve
GONE=0123456789abcdef0123456789abcdef01234567
check "Refs #1"$'\n\n'"<!-- evidence-head: $GONE -->"$'\n\n'"$REASON"
[ "$RC" = 0 ] && has "NOTE evidence-head" && ! has "REFUSE evidence-head" && ok \
  || bad "B10: an unresolvable builder marker must be a NOTE, not a refusal (rc=$RC) [$OUT]"
check "Refs #1"$'\n\n'"## Tests (head $GONE)"$'\n\n'"$REASON"
[ "$RC" = 1 ] && has "REFUSE evidence-head" && ok || bad "B11: an unresolvable human head claim is still refused (rc=$RC) [$OUT]"

# ── N1-N2 (the same review's NOTEs): the builder's ## Evidence table names
# claims, so a CONFIRMED row whose claim text says "not met" is not an unmet
# item; and the match is case-blind on every awk, not only gawk.
check "Closes #1"$'\n\n'$'## Evidence\n| claim | verdict |\n|---|---|\n| a body with an item not met is refused | CONFIRMED |'$'\n\n'"$REASON"
! has "REFUSE closes-not-met" && ok || bad "N1: an Evidence table row naming 'not met' is not an unmet item [$OUT]"
check "Closes #1"$'\n\n'$'## ACCEPTANCE self-check\n- the seed: NOT MET'$'\n\n'"$REASON"
has "REFUSE closes-not-met" && ok || bad "N2: 'NOT MET' under an upper-case heading must still be refused [$OUT]"

# ── C: files outside the plan
check "Refs #1"
[ "$RC" = 1 ] && has "REFUSE plan-files" && has "bin/extra.sh" && ok || bad "C1: bin/extra.sh is not in the plan and has no reason (rc=$RC) [$OUT]"
has "docs/notes/n.md" && bad "C3: docs/notes/ is an allowed glob and must not be named [$OUT]" || ok
check "Refs #1"$'\n\n'"$REASON"
[ "$RC" = 0 ] && ok || bad "C2: a file with a reason must pass (rc=$RC) [$OUT]"

# ── M1: the catalog decides: plan-files off
awk -F'\t' 'BEGIN{OFS="\t"} $1 == "plan-files" {$2 = "off"} {print}' "$T/catalog.tsv" > "$T/c2" && mv "$T/c2" "$T/catalog.tsv"
check "Refs #1"
[ "$RC" = 0 ] && ok || bad "M1: with plan-files off in the catalog, C1 must pass (rc=$RC) [$OUT]"

echo "pr-self-check.bh-5798: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
