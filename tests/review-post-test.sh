#!/bin/bash
# tests/review-post-test.sh — the posted review must carry its own findings.
#
# THE INCIDENT (BH-641). A head-bound re-review BLOCKed a PR and the comment it
# posted was the verdict paragraph alone: "finding #1 is a fail-open authz
# check, finding #2 weakens a test, finding #3 is scope creep" — and not one of
# those three findings was in the body. The build record kept nothing either,
# so the only copy of that review was the comment that had already dropped it.
#
# This suite drives bin/lib/review-post.sh, which is the renderer/poster both
# PR-review lanes now go through. What it pins:
#   * a review that carries N findings renders N of them, counted out loud;
#   * a verdict that references `finding #3` while only 2 findings can be
#     parsed FAILS CLOSED — first line PARSE_INCOMPLETE, raw review and raw
#     agent envelope fenced into the body, never a clean-looking comment;
#   * the body stays under GitHub's 65536-char comment limit;
#   * rp_persist writes the review into the build record, or says it could not.
#
# Run from anywhere: tests/review-post-test.sh   (exit 0 = all pass)
set -uo pipefail
# tests/lib/scratch.sh is the fleet contract (check R1, family b3957447980a):
# it sets $T, guards against running as root beside a live harness, and cleans
# up on EXIT. It is in this repo, so there is no fallback to keep.
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/review-post.sh"
[ -r "$LIB" ] || { echo "FAIL: bin/lib/review-post.sh is missing — the renderer this suite is about does not exist"; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

# The index lines of a rendered body: everything between the count line and the
# blank line that closes it. Reading the whole body would sweep up the verbatim
# review's own "1." lines, which is the thing this extraction exists to avoid.
index_lines() { awk '/findings returned,/{f=1;next} f&&/^$/{exit} f' "$1"; }

# ============================================================================
# The fixtures — review texts in the shapes the re-review prompts elicit.
# ============================================================================
cat > "$T/three.md" <<'EOF'
Static review of the current diff. No build was run.

## Findings

1. **[HIGH]** `src/lib/authz.ts:41` — the role check returns true when the caller id is blank
   Scenario: a request with no session posts to /api/settings and is served as an admin.
2. **[MED]** `tests/authz-test.ts:88` — the assertion was softened to `toBeTruthy()`
   Scenario: the fix round answered the first finding by weakening its own test.
3. **[LOW]** `src/ui/table.tsx:12` — a new data table ships with no sortable headers
   Scenario: the client sorts a 900-row list by hand.

Why this blocks: finding #1 is a fail-open authz check, finding #2 weakens a test, finding #3 is scope creep.

TIER: 2
VERDICT: BLOCK
EOF
printf '{"is_error":false,"result":"three findings","duration_ms":41000}\n' > "$T/three.md.json"

# The incident shape: the verdict talks about three findings, the body carries two.
cat > "$T/short.md" <<'EOF'
Static review, no build run.

1. **[HIGH]** `src/lib/authz.ts:41` — the role check returns true when the caller id is blank
2. **[MED]** `tests/authz-test.ts:88` — the assertion was softened to `toBeTruthy()`

Why this blocks: finding #1 is a fail-open authz check, finding #2 weakens a test, finding #3 is scope creep.

VERDICT: BLOCK
EOF
printf '{"is_error":false,"result":"THE RAW ENVELOPE SENTINEL","duration_ms":39000}\n' > "$T/short.md.json"

cat > "$T/headers.md" <<'EOF'
Static review, no build run.

### Finding 1 — the cron sweep has no total deadline
It walks every row with no cap; D21.

### Finding 2 — the backfill is not resumable
A crash at row 40000 restarts from zero.

- **Finding #3** — the vendor mirror hard-deletes owned rows

VERDICT: BLOCK
EOF

cat > "$T/approve.md" <<'EOF'
Static review of the current diff. No build was run.

Nothing to raise. The diff matches the plan, the new suite drives the real
entry point, and no test was weakened.

TIER: 1
VERDICT: APPROVE
EOF
printf '{"is_error":false,"result":"clean"}\n' > "$T/approve.md.json"

# ============================================================================
# 1. A review with three findings renders three findings
# ============================================================================
[ "$(rp_findings "$T/three.md" | wc -l)" = 3 ] \
  && ok || bad "rp_findings must find the three numbered findings (got $(rp_findings "$T/three.md" | wc -l))"
[ "$(rp_findings "$T/three.md" | cut -f1 | tr '\n' ' ')" = "1 2 3 " ] \
  && ok || bad "the numbers come from the text itself (got $(rp_findings "$T/three.md" | cut -f1 | tr '\n' ' '))"
# Captured, never piped into `grep -q`: grep -q closes the pipe on its first
# match, rp_findings dies of SIGPIPE, and `set -o pipefail` reports that as a
# failed assertion about code that was right.
FOUND=$(rp_findings "$T/three.md")
grep -q 'authz.ts:41' <<<"$FOUND" \
  && ok || bad "the headline must carry the finding's own words (file:line, claim), not a placeholder"
[ "$(rp_max_ref "$T/three.md")" = 3 ] \
  && ok || bad "rp_max_ref must read 'finding #3' out of the verdict paragraph (got $(rp_max_ref "$T/three.md"))"

rp_render "$T/three.md" "$T/three.md.json" "$T/rec/rereview-abcd1234" "$T/body1"; RC=$?
[ "$RC" = 0 ] && ok || bad "a review whose findings are all present renders complete (rc $RC)"
grep -qx '3 findings returned, 3 rendered' "$T/body1" \
  && ok || bad "the body must count the findings out loud: '3 findings returned, 3 rendered'"
[ "$(index_lines "$T/body1" | wc -l)" = 3 ] \
  && ok || bad "the body must carry a three-line numbered index (got $(index_lines "$T/body1" | wc -l))"
IDX=$(index_lines "$T/body1")
grep -qE '^1\. .*authz\.ts:41' <<<"$IDX" \
  && ok || bad "index line 1 must be the first finding, verbatim enough to act on"
grep -qE '^3\. .*table\.tsx:12' <<<"$IDX" \
  && ok || bad "index line 3 must be the third finding — the one the incident dropped"
head -1 "$T/body1" | grep -q 'BLOCK' \
  && ok || bad "the body must LEAD with the verdict (got '$(head -1 "$T/body1")')"
grep -q 'Scenario: a request with no session posts' "$T/body1" \
  && ok || bad "the full review text must follow the index verbatim — the index is an index, not a replacement"
grep -q 'PARSE_INCOMPLETE' "$T/body1" \
  && bad "a complete render must never claim PARSE_INCOMPLETE" || ok

# ============================================================================
# 2. The incident: the verdict references finding #3, only two can be rendered
# ============================================================================
[ "$(rp_max_ref "$T/short.md")" = 3 ] \
  && ok || bad "the reference to finding #3 must be read even when no finding #3 was written"
rp_render "$T/short.md" "$T/short.md.json" "$T/rec/rereview-abcd1234" "$T/body2"; RC=$?
[ "$RC" = 3 ] && ok || bad "a short findings count must fail CLOSED (rc 3), not render a clean body (rc $RC)"
# TEST CHANGED BY BH-1625, deliberately, and made STRICTER: every body now leads
# with `**Verdict:** <v>` (the verdict is what the gate acted on, and a
# PARSE_INCOMPLETE that hid it left GitHub no record of it), so the
# PARSE_INCOMPLETE line this pinned as line 1 is pinned, unchanged, as line 2
# and line 1 is pinned too.
[ "$(head -1 "$T/body2")" = '**Verdict:** BLOCK' ] \
  && ok || bad "the first line must carry the verdict even when incomplete (got '$(head -1 "$T/body2")')"
[ "$(sed -n 2p "$T/body2")" = 'PARSE_INCOMPLETE: the verdict references finding #3 but only 2 findings could be rendered' ] \
  && ok || bad "the second line must say exactly what was lost (got '$(sed -n 2p "$T/body2")')"
grep -qx '3 findings returned, 2 rendered' "$T/body2" \
  && ok || bad "the count line must say 3 returned, 2 rendered — silently dropping one is the bug"
grep -qx '```text' "$T/body2" \
  && ok || bad "the raw review must be fenced into the body when the render is incomplete"
grep -qx '```json' "$T/body2" \
  && ok || bad "the raw agent envelope must be fenced into the body when the render is incomplete"
grep -q 'THE RAW ENVELOPE SENTINEL' "$T/body2" \
  && ok || bad "the fenced JSON must be the real envelope, not an empty fence"
grep -q 'Why this blocks: finding #1 is a fail-open authz check' "$T/body2" \
  && ok || bad "the raw review text must be in the body — it is the only copy the reader has"

# ============================================================================
# 3. The other shapes a reviewer writes findings in
# ============================================================================
[ "$(rp_findings "$T/headers.md" | wc -l)" = 3 ] \
  && ok || bad "'### Finding N' headers and a bolded '**Finding #N**' bullet are findings too (got $(rp_findings "$T/headers.md" | wc -l))"
FOUND=$(rp_findings "$T/headers.md")
grep -q 'total deadline' <<<"$FOUND" \
  && ok || bad "a header finding must keep its own headline"
rp_render "$T/headers.md" "" "" "$T/body3"; RC=$?
[ "$RC" = 0 ] && ok || bad "three header-shaped findings and no higher reference renders complete (rc $RC)"

# ============================================================================
# 4. An APPROVE with nothing to list is not a drop
# ============================================================================
rp_render "$T/approve.md" "$T/approve.md.json" "" "$T/body4"; RC=$?
[ "$RC" = 0 ] && ok || bad "an APPROVE with no findings must render complete (rc $RC)"
grep -qx '0 findings returned, 0 rendered' "$T/body4" \
  && ok || bad "zero is stated, not implied"
head -1 "$T/body4" | grep -q 'APPROVE' \
  && ok || bad "the APPROVE body leads with its verdict too"
grep -q 'Nothing to raise' "$T/body4" \
  && ok || bad "the approve text still rides verbatim"
[ "$(rp_max_ref "$T/approve.md")" = 0 ] \
  && ok || bad "a review that references no finding number must answer 0 (got $(rp_max_ref "$T/approve.md"))"

# ============================================================================
# 5. No raw envelope on disk: the fence says so rather than lying
# ============================================================================
cp "$T/short.md" "$T/nojson.md"   # deliberately no .json beside it
rp_render "$T/nojson.md" "$T/nojson.md.json" "" "$T/body5"; RC=$?
[ "$RC" = 3 ] && ok || bad "the incomplete verdict is unchanged by a missing envelope (rc $RC)"
grep -q 'no raw JSON envelope' "$T/body5" \
  && ok || bad "a missing envelope is stated in the fence, never rendered as an empty one"

# ============================================================================
# 6. GitHub's 65536-char comment limit
# ============================================================================
{ printf 'Static review, no build run.\n\n1. **[HIGH]** `src/a.ts:1` — the one finding\n\n'
  head -c 60000 /dev/zero | tr '\0' 'x'
  printf '\n\nVERDICT: BLOCK\n'; } > "$T/huge.md"
printf '{"is_error":false,"result":"huge"}\n' > "$T/huge.md.json"
rp_render "$T/huge.md" "$T/huge.md.json" "$T/rec/rereview-abcd1234" "$T/body6"; RC=$?
[ "$RC" = 0 ] && ok || bad "a huge but complete review is still complete (rc $RC)"
[ "$(wc -c < "$T/body6")" -lt 65536 ] \
  && ok || bad "the body must stay under GitHub's 65536-char comment limit (got $(wc -c < "$T/body6"))"
grep -q '\[truncated' "$T/body6" \
  && ok || bad "a truncated body must SAY it was truncated and name where the full copy is"
grep -q 'rereview-abcd1234' "$T/body6" \
  && ok || bad "the truncation line must point at the persisted copy in the build record"

# ============================================================================
# 7. rp_persist — the build record gets the review, or the caller is told why not
# ============================================================================
rp_persist - abcd1234deadbeef "$T/three.md" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "a PR with no build record ('-') must answer rc 1, not pretend it wrote something (rc $RC)"
rp_persist "" abcd1234deadbeef "$T/three.md" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "an empty record path must answer rc 1 (rc $RC)"
rp_persist "$T/nosuchdir" abcd1234deadbeef "$T/three.md" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "a record directory that is not there must answer rc 1 (rc $RC)"

mkdir -p "$T/rec2"
KEPT=$(rp_persist "$T/rec2" abcd1234deadbeef "$T/three.md"); RC=$?
[ "$RC" = 0 ] && ok || bad "a real record directory must persist (rc $RC)"
[ "$KEPT" = "$T/rec2/rereview-abcd1234" ] \
  && ok || bad "rp_persist must print the prefix it wrote so the caller can name it (got '$KEPT')"
[ -s "$T/rec2/rereview-abcd1234.md" ] \
  && ok || bad "the review itself must be in the build record"
[ -s "$T/rec2/rereview-abcd1234.json" ] \
  && ok || bad "the raw agent envelope must be in the build record beside it"
cmp -s "$T/three.md" "$T/rec2/rereview-abcd1234.md" \
  && ok || bad "the persisted review must be the review, byte for byte"
[ -z "$(ls "$T/rec2"/*.tmp 2>/dev/null)" ] \
  && ok || bad "a half-written copy must never be left behind (cp to .tmp, mv into place)"

rm -f "$T/rec2/rereview-abcd1234.json"
rp_persist "$T/rec2" abcd1234deadbeef "$T/headers.md" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "a review with no envelope beside it still persists (rc $RC)"
[ ! -e "$T/rec2/rereview-abcd1234.json" ] \
  && ok || bad "an envelope that never existed must not be conjured"

# ============================================================================
# 8. An empty or missing review file is never a complete review
# ============================================================================
# The lane names an out file and the file is not there (its build record was
# swept, the agent wrote nothing). 0 findings compares equal to 0 references, so
# before this the renderer answered rc 0 and a body reading "**Verdict:** (the
# review states no verdict) / 0 findings returned, 0 rendered" — a clean-looking
# comment about a review nobody has. It fails closed with the rest.
: > "$T/empty.md"
rp_render "$T/empty.md" "" "" "$T/body7"; RC=$?
[ "$RC" = 3 ] \
  && ok || bad "an EMPTY review file must fail CLOSED (rc 3), never render as a complete review (rc $RC)"
# TEST CHANGED BY BH-1625, deliberately, and made STRICTER: every body now leads
# with `**Verdict:** <v>` (the verdict is what the gate acted on, and a
# PARSE_INCOMPLETE that hid it left GitHub no record of it), so the
# PARSE_INCOMPLETE line this pinned as line 1 is pinned, unchanged, as line 2
# and line 1 is pinned too.
[ "$(head -1 "$T/body7")" = '**Verdict:** (the review states no verdict)' ] \
  && ok || bad "an empty review's first line says it states no verdict (got '$(head -1 "$T/body7")')"
sed -n 2p "$T/body7" | grep -q '^PARSE_INCOMPLETE: the review file is empty or missing' \
  && ok || bad "the second line must say the review file itself was empty (got '$(sed -n 2p "$T/body7")')"
grep -qx '0 findings returned, 0 rendered' "$T/body7" \
  && ok || bad "an empty render still counts out loud"
grep -q 'no raw JSON envelope' "$T/body7" \
  && ok || bad "an empty review with no envelope beside it says so rather than fencing nothing"
# TEST CHANGED BY BH-1625: this grepped for "(the review states no verdict)" as
# the mark of the complete-body shape, but every body now leads with its
# verdict line, so that phrase is in the fail-closed body too (pinned above).
# The complete shape is the verdict line followed by a BLANK line and the count;
# the fail-closed one puts PARSE_INCOMPLETE there. Same claim, exact shape.
[ -n "$(sed -n 2p "$T/body7")" ] \
  && ok || bad "an empty file must never render the complete-body shape (verdict line, blank line, count)"

rp_render "$T/no-such-review.md" "" "" "$T/body8"; RC=$?
[ "$RC" = 3 ] \
  && ok || bad "a MISSING review file must fail closed too (rc $RC)"
[ "$(head -1 "$T/body8")" = '**Verdict:** (the review states no verdict)' ] \
  && ok || bad "a missing review file's first line says it states no verdict (got '$(head -1 "$T/body8")')"
sed -n 2p "$T/body8" | grep -q '^PARSE_INCOMPLETE' \
  && ok || bad "a missing review file puts PARSE_INCOMPLETE right under the verdict (got '$(sed -n 2p "$T/body8")')"

# ... and an empty review never replaces the copy an earlier tick kept.
mkdir -p "$T/rec3"
cp "$T/three.md" "$T/rec3/rereview-abcd1234.md"
rp_persist "$T/rec3" abcd1234deadbeef "$T/empty.md" >/dev/null; RC=$?
[ "$RC" = 1 ] \
  && ok || bad "an empty out file is not a copy worth keeping — rp_persist must answer rc 1 (rc $RC)"
cmp -s "$T/three.md" "$T/rec3/rereview-abcd1234.md" \
  && ok || bad "an empty out file must never overwrite the review already in the build record"

echo "review-post: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
