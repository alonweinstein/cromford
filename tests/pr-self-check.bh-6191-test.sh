#!/bin/bash
# tests/pr-self-check.bh-6191-test.sh — BH-6191: a body section ends only at a
# heading of the same or a higher level, so `###` subsections under
# `## Files to touch` belong to it (plan-files read them as unplanned: #6092).
#
#   S1  plan `## Files to touch` with `### C0` / `### C1`, a file under each: no REFUSE plan-files
#   S2  `## Files to touch` then `## Why` naming a file: the section ends at `## Why` (REFUSE)
#   S3  `### Files to touch` then `## Why`: a deeper section ends at a higher heading (REFUSE)
#   S4  `## Files to touch` then `#### deep` then `# Top`: a file under `# Top` is not planned (REFUSE)
#   S5  `## Acceptance` with `### A1` holding `- [ ]` and Closes: closes-not-met sees it (REFUSE)
#   S6  `## Acceptance` with `- [x]` then `## Notes` holding `- [ ]`: not in the section (pass)
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
export PR_SELF_CHECK_ONLY='^(closes-not-met|plan-files)$'

R="$T/repo"; mkdir -p "$R"
git -C "$R" init -q -b main
echo base > "$R/README"; git -C "$R" add -A; git -C "$R" commit -qm M0
# fixture <branch> <plan text>: a PR changing bin/a.sh, bin/b.sh and the plan
fixture() {
  git -C "$R" checkout -q main; git -C "$R" checkout -qb "$1"
  mkdir -p "$R/bin" "$R/.harness/specs/BH-1"
  printf '%s\n' "$2" > "$R/.harness/specs/BH-1/plan.md"
  echo "$1" > "$R/bin/a.sh"; echo "$1" > "$R/bin/b.sh"
  git -C "$R" add -A; git -C "$R" commit -qm "$1"
}
check() { # check <head> <body-text> — sets RC and OUT
  printf '%s\n' "$2" > "$T/body.md"
  OUT=$(PR_SELF_CHECK_CATALOG="$T/catalog.tsv" bash "$H/bin/pr-self-check.sh" check \
          --repo "$R" --base main --head "$1" --body "$T/body.md" 2>&1); RC=$?
}
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }

fixture s1 $'# plan\n\n## Files to touch\n\n### C0\n- `bin/a.sh`\n\n### C1\n- `bin/b.sh`\n\n## Acceptance tests\n- a test'
check s1 "Refs #1"
[ "$RC" = 0 ] && ! has "REFUSE plan-files" && ok || bad "S1: files under ### C0 / ### C1 are planned (rc=$RC) [$OUT]"

fixture s2 $'# plan\n\n## Files to touch\n- `bin/a.sh`\n\n## Why\n- `bin/b.sh` is only mentioned here'
check s2 "Refs #1"
[ "$RC" = 1 ] && has "REFUSE plan-files" && has "bin/b.sh" && ! has "bin/a.sh" && ok || bad "S2: the section ends at ## Why (rc=$RC) [$OUT]"

fixture s3 $'# plan\n\n### Files to touch\n- `bin/a.sh`\n\n## Why\n- `bin/b.sh` is only mentioned here'
check s3 "Refs #1"
[ "$RC" = 1 ] && has "bin/b.sh" && ! has "bin/a.sh" && ok || bad "S3: a ### section ends at a ## heading (rc=$RC) [$OUT]"

fixture s4 $'## Files to touch\n- `bin/a.sh`\n#### deep\n- note\n# Top\n- `bin/b.sh`'
check s4 "Refs #1"
[ "$RC" = 1 ] && has "bin/b.sh" && ! has "bin/a.sh" && ok || bad "S4: a #### subsection stays in, a # heading ends it (rc=$RC) [$OUT]"

REASON=$'## Files outside the plan\n- `bin/b.sh`: a reason'
check s2 "Closes #1"$'\n\n## Acceptance self-check\n\n### A1\n- [ ] the seed: not met\n\n'"$REASON"
[ "$RC" = 1 ] && has "REFUSE closes-not-met" && ok || bad "S5: an unmet item under ### A1 is in the acceptance section (rc=$RC) [$OUT]"
check s2 "Closes #1"$'\n\n## Acceptance self-check\n- [x] met\n\n## Notes\n- [ ] later idea\n\n'"$REASON"
[ "$RC" = 0 ] && ok || bad "S6: an item under a sibling ## heading is not in the section (rc=$RC) [$OUT]"

echo "pr-self-check.bh-6191: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
