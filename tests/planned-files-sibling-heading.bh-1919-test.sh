#!/bin/bash
# tests/planned-files-sibling-heading.bh-1919-test.sh — a heading that is not a
# sub-heading of the skipped "## Sibling claims (not touched)" section ends it.
#
# WHY (BH-1919, 2026-09-24). BH-623 made bin/planned-files.sh skip that section
# up to the next level-1/2 heading. A plan that wrote `### Task 1` straight after
# the section, with no `## Tasks` heading in between, lost every path its tasks
# named: the claim under-listed and conflict-check could not see a real overlap.
#
# The rule now: a level-3+ heading ends the section unless its title starts with
# a ticket key (`### BH-455`, `#### TK-12`), which is the per-sibling sub-heading
# shape BH-623's A1 pins. Level-1/2 headings behave as before.
#
# PF_OVERRIDE runs the cases against another extractor (main's copy) to prove
# this suite goes red without the fix.
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PF="${PF_OVERRIDE:-$REPO/bin/planned-files.sh}"
CC="$REPO/bin/conflict-check.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

mkdir -p "$T/h/builds"
# A build dir named like a real one; no RESULT file = running (4h mtime window).
mkbuild() { mkdir -p "$T/h/builds/$1"; printf '%s' "$T/h/builds/$1"; }
has()  { grep -qxF "$2" "$1/planned-files.txt"; }
list() { tr '\n' ' ' < "$1/planned-files.txt"; }

SIB_NOTE='Active sibling claim BH-455 edits `docs/sib-only.md`. No overlap.'

# --- B1: `### Task 1` straight after the section is scanned ------------------
C1=$(mkbuild proj-BH-11-a)
cat > "$C1/plan.md" <<EOF
# BH-11 plan

## Sibling claims (not touched)
$SIB_NOTE

### Task 1
Edit \`scripts/x.sh\`.
VALIDATE: bash scripts/x.sh
EOF
"$PF" "$C1"; rc=$?
[ "$rc" = 0 ] && ok || bad "B1: planned-files.sh rc=$rc"
has "$C1" scripts/x.sh && ok || bad "B1: ### Task 1 after the section must be claimed: [$(list "$C1")]"
has "$C1" docs/sib-only.md && bad "B1: docs/sib-only.md is only in the sibling section: [$(list "$C1")]" || ok
scratch_rm "$C1"

# --- B2: later tasks and bare dirs are scanned too ----------------------------
C2=$(mkbuild proj-BH-12-a)
cat > "$C2/plan.md" <<EOF
## Sibling claims (not touched)
$SIB_NOTE

### Task 1
Edit \`scripts/x.sh\`.

### Task 2
Edit \`tests/y.sh\` and everything under src/feat/dir/.
EOF
"$PF" "$C2"
for p in scripts/x.sh tests/y.sh src/feat/dir; do
  has "$C2" "$p" && ok || bad "B2: $p must be listed: [$(list "$C2")]"
done
has "$C2" docs/sib-only.md && bad "B2: sibling path leaked: [$(list "$C2")]" || ok
scratch_rm "$C2"

# --- B3: any non-ticket-key heading ends it, at level 3 or 4 -----------------
C3=$(mkbuild proj-BH-13-a)
cat > "$C3/plan.md" <<EOF
## Sibling claims (not touched)
$SIB_NOTE

### Files to touch
- \`lib/a.sh\`
EOF
"$PF" "$C3"
has "$C3" lib/a.sh && ok || bad "B3: ### Files to touch must end the section: [$(list "$C3")]"
scratch_rm "$C3"
C3=$(mkbuild proj-BH-13-b)
cat > "$C3/plan.md" <<EOF
## Sibling claims (not touched)
$SIB_NOTE

#### Step 1
Write \`docs/b.md\`.
EOF
"$PF" "$C3"
has "$C3" docs/b.md && ok || bad "B3: #### Step 1 must end the section: [$(list "$C3")]"
has "$C3" docs/sib-only.md && bad "B3: sibling path leaked: [$(list "$C3")]" || ok
scratch_rm "$C3"

# --- B4: per-sibling sub-headings stay inside the section --------------------
C4=$(mkbuild proj-BH-14-a)
cat > "$C4/plan.md" <<EOF
## Sibling claims (not touched)
$SIB_NOTE

### BH-455
Also quoted: \`docs/sib-deep.md\`.

#### TK-12 notes
And \`docs/sib-deeper.md\`.

### Task 1
Edit \`scripts/x.sh\`.
EOF
"$PF" "$C4"
has "$C4" scripts/x.sh && ok || bad "B4: task path must be listed: [$(list "$C4")]"
has "$C4" docs/sib-deep.md && bad "B4: ### BH-455 stays inside the section: [$(list "$C4")]" || ok
has "$C4" docs/sib-deeper.md && bad "B4: #### TK-12 stays inside the section: [$(list "$C4")]" || ok
scratch_rm "$C4"

# --- B5: conflict-check sees the overlap the task names ----------------------
S=$(mkbuild proj-BH-2-s)
printf 'scripts/x.sh\n' > "$S/planned-files.txt"
C5=$(mkbuild proj-BH-15-a)
cat > "$C5/plan.md" <<EOF
# BH-15 plan

## Sibling claims (not touched)
Active sibling claim BH-2 edits \`docs/other.md\`. No overlap.

### Task 1
Edit \`scripts/x.sh\`.
EOF
"$PF" "$C5"
OUT=$(HARNESS="$T/h" "$CC" proj "$C5" 2>&1); crc=$?
[ "$crc" = 1 ] && ok || bad "B5: a real overlap must defer (rc=$crc: $OUT)"
[ "$OUT" = "CONFLICT with proj-BH-2-s: scripts/x.sh ~ scripts/x.sh" ] \
  && ok || bad "B5: conflict reason: $OUT"
scratch_rm "$C5"; scratch_rm "$S"

# --- B6: no sibling heading = nothing dropped, ticket-key headings included --
C6=$(mkbuild proj-BH-16-a)
cat > "$C6/plan.md" <<EOF
## Tasks
### Task 1
Edit \`scripts/x.sh\`.

### BH-9
Touches \`docs/z.md\`.
EOF
"$PF" "$C6"
[ "$(cat "$C6/planned-files.txt")" = "$(printf 'docs/z.md\nscripts/x.sh')" ] && ok \
  || bad "B6: want exactly docs/z.md + scripts/x.sh: [$(list "$C6")]"
scratch_rm "$C6"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
