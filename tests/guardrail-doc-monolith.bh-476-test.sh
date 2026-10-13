#!/bin/bash
# tests/guardrail-doc-monolith.bh-476-test.sh — the region math, judged against
# the checkout CI actually has.
#
# the operator's review of #786 found the check reading a region that is not there. The
# markers are read from the WORKING TREE, and in CI that tree is the head the
# diff produced — so a PR that deletes `<!-- changes:begin -->` is judged against
# a file that has only an end marker. The old code defaulted the two bounds
# independently (B=0, E=<end marker line>), which turns "no region" into "lines
# 1..E-1", and the deletion sailed through as Clean. The mirror defect: a removed
# line was judged with the same strict `n < e` as an added one, so deleting the
# last pointer line inside the region — the region SHRINKING, which the README
# promises passes — failed.
#
# So every case here builds the scratch checkout as it looks AFTER the diff, and
# asserts on the real check.sh's exit code and printed output. Nothing greps the
# script's source. Every date here is a literal; nothing reads a clock.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
C="$DIR/guardrails/doc-monolith-edit/check.sh"
FX="$DIR/guardrails/doc-monolith-edit/fixtures"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

if [ ! -x "$C" ]; then
  echo "FAIL: guardrails/doc-monolith-edit/check.sh is missing"
  echo "guardrail-doc-monolith.bh-476-test: 0 pass, 1 fail"
  exit 1
fi

# mk <dir> — the body on stdin becomes <dir>/docs/EVENTS.md. One guarded doc is
# enough: adoption only needs one of the five to exist, and every fixture below
# touches EVENTS.md.
mk() {
  mkdir -p "$1/docs"
  cat > "$1/docs/EVENTS.md"
}

# The pre-diff shape the shipped fixtures' hunk headers are cut against:
#   1 # EVENTS            5 <!-- changes:end -->
#   2                     6
#   3 <!-- changes:begin -->   7 Stable contract text.
#   4 > pointer line           8 More stable text.
mk "$T/marked" <<'EOF'
# EVENTS

<!-- changes:begin -->
> pointer line
<!-- changes:end -->

Stable contract text.
More stable text.
EOF

# …and the post-diff shapes, one per deletion under test.
mk "$T/noend" <<'EOF'
# EVENTS

<!-- changes:begin -->
> pointer line

Stable contract text.
More stable text.
EOF

mk "$T/nobegin" <<'EOF'
# EVENTS

> pointer line
<!-- changes:end -->

Stable contract text.
More stable text.
EOF

mk "$T/nomarkers" <<'EOF'
# EVENTS

> pointer line

Stable contract text.
More stable text.
EOF

mk "$T/shrunk" <<'EOF'
# EVENTS

<!-- changes:begin -->
<!-- changes:end -->

Stable contract text.
More stable text.
EOF

mk "$T/inverted" <<'EOF'
# EVENTS

<!-- changes:end -->
> pointer line
<!-- changes:begin -->

Stable contract text.
More stable text.
EOF

# the blank line right after the end marker is gone: markers still at 3 and 5
mk "$T/no-blank-after" <<'EOF'
# EVENTS

<!-- changes:begin -->
> pointer line
<!-- changes:end -->
Stable contract text.
More stable text.
EOF

# the blank line right before the begin marker is gone: begin moves to 2, end to 4
mk "$T/no-blank-before" <<'EOF'
# EVENTS
<!-- changes:begin -->
> pointer line
<!-- changes:end -->

Stable contract text.
More stable text.
EOF

# ── the diffs that have no shipped fixture ──────────────────────────────────
printf 'diff --git a/docs/EVENTS.md b/docs/EVENTS.md\nindex 1111111..2222222 100644\n--- a/docs/EVENTS.md\n+++ b/docs/EVENTS.md\n@@ -2,5 +2,3 @@\n \n-<!-- changes:begin -->\n > pointer line\n-<!-- changes:end -->\n \n' > "$T/diff-delete-both-markers.txt"
printf 'diff --git a/docs/EVENTS.md b/docs/EVENTS.md\nindex 1111111..2222222 100644\n--- a/docs/EVENTS.md\n+++ b/docs/EVENTS.md\n@@ -4,4 +4,3 @@\n > pointer line\n <!-- changes:end -->\n-\n Stable contract text.\n' > "$T/diff-remove-blank-after-end.txt"
printf 'diff --git a/docs/EVENTS.md b/docs/EVENTS.md\nindex 1111111..2222222 100644\n--- a/docs/EVENTS.md\n+++ b/docs/EVENTS.md\n@@ -1,4 +1,3 @@\n # EVENTS\n-\n <!-- changes:begin -->\n > pointer line\n' > "$T/diff-remove-blank-before-begin.txt"

OUT=""; RC=0
run() { # run <repo> <title> <diff-file>
  OUT=$( cd "$1" && PR_TITLE="$2" DOC_MONOLITH_DIFF="$3" "$C" 2>&1 ); RC=$?
}

# ── finding 1: losing a marker leaves an EMPTY region, never a half one ─────
run "$T/nobegin" 'feat: x' "$FX/diff-delete-begin-marker.txt"
[ "$RC" = 1 ] && ok || bad "deleting only the begin marker passed (rc=$RC): $OUT"
grep -qF 'no Changes region' <<<"$OUT" && ok \
  || bad "the begin-marker deletion was not reported as a missing region: $OUT"

run "$T/noend" 'feat: x' "$FX/diff-delete-marker.txt"
[ "$RC" = 1 ] && ok || bad "deleting only the end marker passed (rc=$RC): $OUT"
grep -qF 'no Changes region' <<<"$OUT" && ok \
  || bad "the end-marker deletion was not reported as a missing region: $OUT"

run "$T/nomarkers" 'feat: x' "$T/diff-delete-both-markers.txt"
[ "$RC" = 1 ] && ok || bad "deleting both markers passed (rc=$RC): $OUT"
grep -qF 'no Changes region' <<<"$OUT" && ok \
  || bad "deleting both markers was not reported as a missing region: $OUT"

# end before begin is not a region either, however many markers are present
run "$T/inverted" 'feat: x' "$FX/diff-changes-region.txt"
[ "$RC" = 1 ] && ok || bad "an inverted marker pair was treated as a region (rc=$RC): $OUT"
grep -qF 'no Changes region' <<<"$OUT" && ok \
  || bad "the inverted marker pair was not reported as a missing region: $OUT"

# ── finding 2: a removed line is INSIDE the region up to and including e ────
run "$T/shrunk" 'feat: x' "$FX/diff-shrink-region.txt"
[ "$RC" = 0 ] && ok || bad "shrinking the region by deleting its last line failed (rc=$RC): $OUT"
grep -qF 'Clean' <<<"$OUT" && ok || bad "the shrink was not reported Clean: $OUT"

run "$T/marked" 'feat: x' "$FX/diff-changes-region.txt"
[ "$RC" = 0 ] && ok || bad "replacing the pointer line inside the region failed (rc=$RC): $OUT"

# ── the near-misses that must stay failures: one line either side of a bound ─
run "$T/no-blank-after" 'feat: x' "$T/diff-remove-blank-after-end.txt"
[ "$RC" = 1 ] && ok || bad "removing the line right AFTER the end marker passed (rc=$RC): $OUT"
grep -qE 'changed outside it:.*\b6\b' <<<"$OUT" && ok \
  || bad "the removed body line was not judged at line 6: $OUT"

run "$T/no-blank-before" 'feat: x' "$T/diff-remove-blank-before-begin.txt"
[ "$RC" = 1 ] && ok || bad "removing the line right BEFORE the begin marker passed (rc=$RC): $OUT"
grep -qE 'changed outside it:.*\b2\b' <<<"$OUT" && ok \
  || bad "the removed line before the region was not judged at line 2: $OUT"

# ── regression pins: the verdicts this change must not move ─────────────────
run "$T/marked" 'feat: x' "$FX/diff-body.txt"
[ "$RC" = 1 ] && ok || bad "a body append under 'feat: x' passed (rc=$RC): $OUT"
run "$T/marked" 'docs: x' "$FX/diff-body.txt"
[ "$RC" = 0 ] && ok || bad "'docs: x' no longer exempts a body append (rc=$RC): $OUT"
run "$T/marked" 'feat: x' "$FX/diff-notes-only.txt"
[ "$RC" = 0 ] && ok || bad "a notes-only diff failed (rc=$RC): $OUT"

echo "guardrail-doc-monolith.bh-476-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
