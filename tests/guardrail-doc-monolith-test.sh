#!/bin/bash
# tests/guardrail-doc-monolith-test.sh — the doc-monolith-edit pack must FIRE.
#
# What this check is worth is entirely in its negatives. A guardrail that lets
# an appended decision paragraph through looks exactly like a repo where nobody
# appended one, so the cases that matter are the near-misses: a title that
# merely CONTAINS "docs:", a diff that edits the Changes region and the body in
# the same breath, a PR that deletes a marker so the region it must stay inside
# no longer exists.
#
# Every case drives the real check.sh from inside a scratch checkout (markers at
# fixed lines, so the shipped fixtures' hunk headers line up) and asserts on its
# exit code and printed output. Nothing here greps the script's source.
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
  echo "guardrail-doc-monolith-test: 0 pass, 1 fail"
  exit 1
fi

# A monolith as the fixtures assume it:
#   1 # <NAME>            5 <!-- changes:end -->
#   2                     6
#   3 <!-- changes:begin -->   7 Stable contract text.
#   4 > pointer line           8 More stable text.
# The marker-less variant is the same 8 lines with ordinary prose on 3-5, so one
# set of fixtures exercises both checkouts. `noend` is the tree a PR that DELETES
# the end marker leaves behind, which is the tree CI reads its markers from.
mk_repo() { # mk_repo <dir> <markers: yes|no|noend>
  local d="$1" m="$2" f
  mkdir -p "$d/docs"
  for f in MERGE-CONDUCTOR BUILD-CONCURRENCY RUN-BUILD-GRAPH OPERATOR-SETUP EVENTS; do
    {
      echo "# $f"
      echo
      if [ "$m" = yes ]; then
        echo '<!-- changes:begin -->'
        echo "> pointer line"
        echo '<!-- changes:end -->'
      elif [ "$m" = noend ]; then
        echo '<!-- changes:begin -->'
        echo "> pointer line"
      else
        echo "This doc never adopted the region markers."
        echo "Second line of prose."
        echo "Third line of prose."
      fi
      echo
      echo "Stable contract text."
      echo "More stable text."
    } > "$d/docs/$f.md"
  done
}
mk_repo "$T/marked" yes
mk_repo "$T/marked-noend" noend
mk_repo "$T/unmarked" no
mkdir -p "$T/plain/docs"
echo "# Some other doc" > "$T/plain/docs/README.md"

OUT=""; RC=0
run() { # run <repo> <title> <diff-file>
  OUT=$( cd "$1" && PR_TITLE="$2" DOC_MONOLITH_DIFF="$3" "$C" 2>&1 ); RC=$?
}

# ── the core verdict: a body append fails, the same diff under docs: passes ──
run "$T/marked" 'feat: x' "$FX/diff-body.txt"
[ "$RC" = 1 ] && ok || bad "body append under 'feat: x' exited $RC, expected 1"
grep -qF 'docs/notes/' <<<"$OUT" && ok \
  || bad "the failure message does not point at docs/notes/"
run "$T/marked" 'docs: x' "$FX/diff-body.txt"
[ "$RC" = 0 ] && ok || bad "'docs: x' did not exempt the diff (rc=$RC)"

# ── the near-miss titles, which are the whole point of a PREFIX test ─────────
run "$T/marked" 'Docs: x' "$FX/diff-body.txt"
[ "$RC" = 0 ] && ok || bad "'Docs: x' (capitalised) was not accepted (rc=$RC)"
run "$T/marked" '   docs: x' "$FX/diff-body.txt"
[ "$RC" = 0 ] && ok || bad "a leading-whitespace 'docs:' title was not accepted (rc=$RC)"
run "$T/marked" 'feat: docs for x' "$FX/diff-body.txt"
[ "$RC" = 1 ] && ok || bad "'feat: docs for x' was treated as a docs PR (rc=$RC)"
run "$T/marked" 'fix(docs): x' "$FX/diff-body.txt"
[ "$RC" = 1 ] && ok || bad "'fix(docs): x' was treated as a docs PR (rc=$RC)"
run "$T/marked" 'docs x' "$FX/diff-body.txt"
[ "$RC" = 1 ] && ok || bad "'docs x' (no colon) was treated as a docs PR (rc=$RC)"
# the one a substring match gets wrong: a real 'docs:' that is not the prefix
run "$T/marked" 'refactor: docs: rewrite the lane' "$FX/diff-body.txt"
[ "$RC" = 1 ] && ok || bad "'refactor: docs: …' was treated as a docs PR (rc=$RC)"

# ── the diff-shape verdicts ─────────────────────────────────────────────────
run "$T/marked" 'feat: x' "$FX/diff-notes-only.txt"
[ "$RC" = 0 ] && ok || bad "a diff that only adds a note failed (rc=$RC)"
run "$T/marked" 'feat: x' "$FX/diff-changes-region.txt"
[ "$RC" = 0 ] && ok || bad "an in-region edit failed (rc=$RC)"
run "$T/marked" 'feat: x' "$FX/diff-region-plus-body.txt"
[ "$RC" = 1 ] && ok || bad "a body hunk rode in on an in-region hunk (rc=$RC)"
# judged against the tree the deletion LEAVES BEHIND, which is what CI reads:
# the end marker is gone, so the region is empty and every touched line is
# outside it. Against the pre-diff tree this passed for the wrong reason.
run "$T/marked-noend" 'feat: x' "$FX/diff-delete-marker.txt"
[ "$RC" = 1 ] && ok || bad "deleting a region marker was allowed (rc=$RC)"

# The shape that reads like a file header and is not: a removed line whose own
# text starts with '-- ' arrives as '--- worker/jobs/schema.sql', an added one
# starting with '++' as '+++ …'. docs/BUILD-CONCURRENCY.md:24 is the first shape
# today, inside a guarded doc's body.
run "$T/marked" 'feat: x' "$FX/diff-body-dashes.txt"
[ "$RC" = 1 ] && ok || bad "a body edit of '-- '/'++' lines passed as file headers (rc=$RC)"
grep -qE 'changed outside it:.*\b8\b' <<<"$OUT" && ok \
  || bad "the removed '-- ' line was not judged at line 8: $OUT"
grep -qE 'changed outside it:.*\b9\b' <<<"$OUT" && ok \
  || bad "the added '++' line was not judged at line 9: $OUT"

# a rename carries no hunk, so nothing but the header says the doc moved
run "$T/marked" 'feat: x' "$FX/diff-rename.txt"
[ "$RC" = 1 ] && ok || bad "renaming a guarded doc away passed (rc=$RC)"
grep -qF 'renamed-away' <<<"$OUT" && ok || bad "the rename failure does not name the rename: $OUT"

# a monolith with no region at all has an EMPTY region — nothing can be inside it
run "$T/unmarked" 'feat: x' "$FX/diff-changes-region.txt"
[ "$RC" = 1 ] && ok || bad "an edit to a marker-less monolith passed (rc=$RC)"

# deleting a monolith outright is an edit to all of it
cat > "$T/delete-file.txt" <<'EOF'
diff --git a/docs/EVENTS.md b/docs/EVENTS.md
deleted file mode 100644
index 1111111..0000000
--- a/docs/EVENTS.md
+++ /dev/null
@@ -1,8 +0,0 @@
-# EVENTS
-
-<!-- changes:begin -->
-> pointer line
-<!-- changes:end -->
-
-Stable contract text.
-More stable text.
EOF
run "$T/marked" 'feat: x' "$T/delete-file.txt"
[ "$RC" = 1 ] && ok || bad "deleting a monolith outright passed (rc=$RC)"

# an emptied monolith deleted carries no hunk at all — only the mode header says so
cat > "$T/delete-empty.txt" <<'EOF'
diff --git a/docs/EVENTS.md b/docs/EVENTS.md
deleted file mode 100644
index e69de29..0000000
EOF
run "$T/marked" 'feat: x' "$T/delete-empty.txt"
[ "$RC" = 1 ] && ok || bad "deleting a hunk-less monolith passed (rc=$RC)"

# and renaming some other file ONTO a guarded path replaces the contract doc
# with text nobody reviewed as that doc
cat > "$T/rename-onto.txt" <<'EOF'
diff --git a/docs/SCRATCH.md b/docs/EVENTS.md
similarity index 100%
rename from docs/SCRATCH.md
rename to docs/EVENTS.md
EOF
run "$T/marked" 'feat: x' "$T/rename-onto.txt"
[ "$RC" = 1 ] && ok || bad "renaming another file onto a guarded doc passed (rc=$RC)"
grep -qF 'renamed-onto' <<<"$OUT" && ok || bad "the rename-onto failure does not name it: $OUT"

# ── the honest no-ops, each printed rather than silent ──────────────────────
run "$T/plain" 'feat: x' "$FX/diff-body.txt"
[ "$RC" = 0 ] && grep -qF 'not adopted' <<<"$OUT" && ok \
  || bad "a repo with none of the five docs must pass and say 'not adopted' (rc=$RC)"
run "$T/marked" 'feat: x' "$T/no-such-diff.txt"
[ "$RC" = 0 ] && grep -qF 'not checked' <<<"$OUT" && ok \
  || bad "an unreadable diff seam must pass and say 'not checked' (rc=$RC)"

# ── the escape hatch: both halves, or nothing ──────────────────────────────
OUT=$( cd "$T/marked" && PR_LABELS="skip-guardrail" PR_TITLE='feat: x' \
  DOC_MONOLITH_DIFF="$FX/diff-body.txt" "$C" 2>&1 ); RC=$?
[ "$RC" = 1 ] && ok || bad "the skip-guardrail label alone skipped the check (rc=$RC)"
OUT=$( cd "$T/marked" && PR_LABELS="bug,skip-guardrail" PR_TITLE='feat: x' \
  GUARDRAIL_JUSTIFICATION="Guardrail-Justification: reverting a bad note by restoring the paragraph verbatim" \
  DOC_MONOLITH_DIFF="$FX/diff-body.txt" "$C" 2>&1 ); RC=$?
[ "$RC" = 0 ] && ok || bad "label + justification did not skip the check (rc=$RC)"

echo "guardrail-doc-monolith-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
