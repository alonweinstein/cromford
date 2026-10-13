#!/bin/bash
# tests/verdict-parse.bh-1625-test.sh — a BLOCK review that quotes an earlier
# "VERDICT: APPROVE" must never read as APPROVE (BH-1625).
#
# FOUND BY THE #1577 MERGE PROBE (2026-09-23). The head-bound merge gate read a
# re-review's verdict as the LAST `VERDICT` token anywhere in its text
# (bin/lib/mc/rebase.sh mc_rereview). A BLOCK review that ends by quoting the
# approval it overturns reads as APPROVE under that rule, and twenty-odd other
# verdict readers in bin/ each carried their own variant of it. The same probe
# found the comment renderer posting PARSE_INCOMPLETE on every re-review that
# talks about the PREVIOUS review's findings ("- Finding 1 (...)", "Finding 5
# has moved on"), with the **Verdict:** line dropped, and a review footer that
# said "(Fable)" about a read claude-opus-5-5 had made.
#
# What this suite pins:
#   1. bin/lib/verdict-parse.sh — the ONE parser: anchored to a line that
#      starts with the label, inside the final block (a registered knob), a
#      conflict inside that block is unknown, unknown is never APPROVE.
#   2. the merge gate's own readers, driven for real: mc_rereview (the
#      head-bound re-review) and mc_verdict (the build record) on a BLOCK review
#      quoting APPROVE; rp_render's **Verdict:** line; blocked-resolver's
#      br_review_verdict on a posted review body with its footer.
#   3. a ratchet: no reader in bin/ still carries one of the unanchored shapes.
#   4. the renderer: plain `- Finding N` bullets count, references at or below
#      the prior review's finding count are satisfied by it, and every body —
#      PARSE_INCOMPLETE included — leads with `**Verdict:** <v>`.
#   5. the conductor's re-review footer names the model from <out>.model.
#
# Run from anywhere: tests/verdict-parse.bh-1625-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/verdict-parse.sh"
[ -r "$LIB" ] && ok || bad "bin/lib/verdict-parse.sh is missing — there is no shared verdict parser"
# shellcheck source=/dev/null
[ -r "$LIB" ] && . "$LIB"
unset VERDICT_WINDOW_LINES

# The parse, as a caller sees it: the word, or "unknown" when the lib says rc 1
# (or is missing altogether, which is the same fail-closed answer).
vp() { local o; o=$(verdict_parse "$@" 2>/dev/null) || { printf 'unknown'; return 0; }; printf '%s' "$o"; }

# ============================================================================
# The fixtures.
# ============================================================================
# F1 — the issue's shape: the review states its BLOCK, then ends by quoting the
# approval it overturns. The last VERDICT token in the text is APPROVE.
cat > "$T/f1.md" <<'EOF'
Static review of the moved head. No build was run.

1. **[HIGH]** `bin/x.sh:12` — the new branch fails open when the ledger read errors.

TIER: 2
VERDICT: BLOCK

For the record, the build review of the old head ended with "VERDICT: APPROVE"; that approval is about a head that no longer exists.
EOF
# F2 — the quote is a blockquote line of its own, at the very end.
cat > "$T/f2.md" <<'EOF'
1. **[HIGH]** `bin/x.sh:12` — the fix answered finding 1 by deleting its assertion.

TIER: 2
VERDICT: BLOCK

The prior review said:
> VERDICT: APPROVE
EOF
# F3 — a bare line-start quote INSIDE the final block, after the review's own
# BLOCK. Two anchored verdicts that disagree: no verdict at all.
cat > "$T/f3.md" <<'EOF'
1. **[HIGH]** the migration is not idempotent.
VERDICT: BLOCK
The previous round's last line was:
VERDICT: APPROVE
EOF
# F4 — APPROVE only inside a quote mid-text; the review never states its own.
cat > "$T/f4.md" <<'EOF'
Static review. The build review said "VERDICT: APPROVE" and I have not finished checking whether that still holds.
Findings are still being written up.
EOF
cat > "$T/approve.md" <<'EOF'
Static review of the current diff. No build was run.

Nothing to raise.

TIER: 1
VERDICT: APPROVE
EOF
printf 'Nothing to raise.\n\n**VERDICT:** APPROVE\n' > "$T/bold1.md"
printf 'Findings above.\n\nVERDICT: **BLOCK**\n' > "$T/bold2.md"
printf '## Verdict: BLOCK\n' > "$T/heading.md"
# F6 — a real anchored APPROVE, but far above the final block.
printf 'VERDICT: APPROVE\nline one\nline two\nline three\nline four\nline five\n' > "$T/far.md"
# F7 — the only anchored verdict is inside a code fence.
printf 'Here is what the old review printed:\n```text\nVERDICT: APPROVE\n```\n' > "$T/fence.md"
printf 'VERDICT: APPROVED by the prior reviewer\n' > "$T/prefix.md"
printf -- '- VERDICT: APPROVE\n' > "$T/bullet.md"

# ============================================================================
# 1. the parser
# ============================================================================
[ "$(vp "$T/f1.md")" = BLOCK ] && ok || bad "1a F1: a BLOCK review that ends by quoting an earlier APPROVE mid-sentence must parse as BLOCK (got '$(vp "$T/f1.md")')"
[ "$(vp "$T/f2.md")" = BLOCK ] && ok || bad "1b F2: a '> VERDICT: APPROVE' blockquote after the review's BLOCK is not a verdict — BLOCK (got '$(vp "$T/f2.md")')"
[ "$(vp "$T/f3.md")" = unknown ] && ok || bad "1c F3: BLOCK and APPROVE anchored in one final block disagree — unknown (got '$(vp "$T/f3.md")')"
[ "$(vp "$T/f4.md")" = unknown ] && ok || bad "1d F4: APPROVE only in a quote mid-text is no verdict — unknown (got '$(vp "$T/f4.md")')"
[ "$(vp "$T/approve.md")" = APPROVE ] && ok || bad "1e a plain TIER + VERDICT: APPROVE ending is APPROVE (got '$(vp "$T/approve.md")')"
[ "$(vp "$T/bold1.md")" = APPROVE ] && ok || bad "1f '**VERDICT:** APPROVE' is a verdict line (got '$(vp "$T/bold1.md")')"
[ "$(vp "$T/bold2.md")" = BLOCK ] && ok || bad "1g 'VERDICT: **BLOCK**' is a verdict line (got '$(vp "$T/bold2.md")')"
[ "$(vp "$T/heading.md")" = BLOCK ] && ok || bad "1h '## Verdict: BLOCK' is a verdict line (got '$(vp "$T/heading.md")')"
[ "$(vp "$T/far.md")" = unknown ] && ok || bad "1i an anchored verdict outside the final block is not read — unknown (got '$(vp "$T/far.md")')"
[ "$(vp "$T/fence.md")" = unknown ] && ok || bad "1j a verdict line inside a code fence is not the review's — unknown (got '$(vp "$T/fence.md")')"
[ "$(vp "$T/prefix.md")" = unknown ] && ok || bad "1k 'APPROVED' is not the word APPROVE — unknown (got '$(vp "$T/prefix.md")')"
[ "$(vp "$T/bullet.md")" = unknown ] && ok || bad "1l a list item quoting a verdict is not a verdict — unknown (got '$(vp "$T/bullet.md")')"
[ "$(vp "$T/no-such-file.md")" = unknown ] && ok || bad "1m a missing file is unknown"
[ "$(vp - < /dev/null)" = unknown ] && ok || bad "1n an empty stdin is unknown"
[ "$(vp - < "$T/approve.md")" = APPROVE ] && ok || bad "1o stdin is read when no file is named"
# rc and verdict_is: unknown is never the word asked for.
verdict_parse "$T/f4.md" >/dev/null 2>&1 && bad "1p unknown must return rc 1" || ok
verdict_is APPROVE "$T/f3.md" && bad "1q verdict_is APPROVE on a conflicted block must be false" || ok
verdict_is APPROVE "$T/f1.md" && bad "1r verdict_is APPROVE on F1 must be false" || ok
verdict_is BLOCK "$T/f1.md" && ok || bad "1s verdict_is BLOCK on F1 must be true"
verdict_is APPROVE "$T/approve.md" && ok || bad "1t verdict_is APPROVE on a plain approval must be true"
# CRLF bodies (a GitHub comment read back over REST).
printf 'Nothing.\r\nVERDICT: APPROVE\r\n' > "$T/crlf.md"
[ "$(vp "$T/crlf.md")" = APPROVE ] && ok || bad "1u a CRLF body parses (got '$(vp "$T/crlf.md")')"
# Vocabulary: the >12h autopilot's words, longest first is not required.
printf 'notes\nVERDICT: MERGE-WITH-NOTES\n' > "$T/mwn.md"
printf 'notes\nVERDICT: MERGE\n' > "$T/merge.md"
[ "$(vp -w 'MERGE|BLOCK|MERGE-WITH-NOTES' "$T/mwn.md")" = MERGE-WITH-NOTES ] && ok || bad "1v MERGE-WITH-NOTES is not MERGE (got '$(vp -w 'MERGE|BLOCK|MERGE-WITH-NOTES' "$T/mwn.md")')"
[ "$(vp -w 'MERGE-WITH-NOTES|BLOCK|MERGE' "$T/merge.md")" = MERGE ] && ok || bad "1w MERGE parses (got '$(vp -w 'MERGE-WITH-NOTES|BLOCK|MERGE' "$T/merge.md")')"
[ "$(vp -w 'APPROVE|REQUEST_CHANGES' "$T/f1.md")" = unknown ] && ok || bad "1x a word outside the vocabulary is no verdict"
# A comment body: the harness footer after the last '---' is not the review.
printf 'Findings.\n\nTIER: 2\nVERDICT: REQUEST_CHANGES\n\n---\n_Automated harness review of abc. Static review._\n\nGenerated with a tool\n' > "$T/comment.md"
[ "$(vp -c -w 'APPROVE|REQUEST_CHANGES' "$T/comment.md")" = REQUEST_CHANGES ] && ok || bad "1y -c drops the footer before the final block is measured (got '$(vp -c -w 'APPROVE|REQUEST_CHANGES' "$T/comment.md")')"
[ "$(vp -w 'APPROVE|REQUEST_CHANGES' "$T/comment.md")" = unknown ] && ok || bad "1z without -c the footer IS the final block — unknown"
# Bad caller input never reaches the regex.
[ "$(vp -w 'APPROVE|.*' "$T/approve.md")" = unknown ] && ok || bad "1aa a vocabulary with regex characters is refused"
[ "$(vp -l 'VERD.CT' "$T/approve.md")" = unknown ] && ok || bad "1ab a label with regex characters is refused"

# The lens artifacts bin/lib/rb/review.sh APPENDS a merged re-review block to:
# the original verdict stays above it, and the appended one is the answer.
cat > "$T/lens.md" <<'EOF'
1. **[HIGH]** the webhook can double-fire.
VERDICT: BLOCK

=== MERGED RE-REVIEW after the single fix round (head abc1234) ===
The lenses ran in parallel and ONE fix round answered them together; the full re-review is in merged-review2.md and its VERDICT-SECURITY line is the verdict below.
VERDICT: APPROVE
EOF
[ "$(vp "$T/lens.md")" = APPROVE ] && ok || bad "1ac an appended merged re-review block is the lens's answer (got '$(vp "$T/lens.md")')"
# -L: an APPENDED artifact (run-build's sequential re-review round: "Re-review
# after fixes; append to review.md"). A short re-review puts its APPROVE right
# under the BLOCK it answers; the latest anchored line is the verdict there.
printf 'finding\nTIER: 2\nVERDICT: BLOCK\nAll three findings are fixed.\nVERDICT: APPROVE\n' > "$T/appended.md"
[ "$(vp -L "$T/appended.md")" = APPROVE ] && ok || bad "1ag2 -L: a re-review appended under a BLOCK is its APPROVE (got '$(vp -L "$T/appended.md")')"
[ "$(vp "$T/appended.md")" = unknown ] && ok || bad "1ag3 without -L the same text is a disagreement — unknown"
# ... and -L is still ANCHORED: the quote shapes never count.
[ "$(vp -L "$T/f1.md")" = BLOCK ] && ok || bad "1ag4 -L: a mid-sentence APPROVE after the BLOCK is not a verdict (got '$(vp -L "$T/f1.md")')"
[ "$(vp -L "$T/f2.md")" = BLOCK ] && ok || bad "1ag5 -L: a blockquoted APPROVE after the BLOCK is not a verdict (got '$(vp -L "$T/f2.md")')"
[ "$(vp -L "$T/f4.md")" = unknown ] && ok || bad "1ag6 -L: a quote-only review is still unknown"
# The merged re-review's per-lens tags: one line per lens after TIER; -x adds them.
printf 'body\nTIER: 2\nVERDICT-REVIEW: APPROVE\nVERDICT-SECURITY: BLOCK\nVERDICT-REFUTE: APPROVE\n' > "$T/tags.md"
[ "$(vp -l VERDICT-REVIEW -x 3 "$T/tags.md")" = APPROVE ] && ok || bad "1ad a lens tag is read with -l (got '$(vp -l VERDICT-REVIEW -x 3 "$T/tags.md")')"
[ "$(vp -l VERDICT-SECURITY -x 3 "$T/tags.md")" = BLOCK ] && ok || bad "1ae VERDICT-SECURITY is BLOCK"
[ "$(vp "$T/tags.md")" = unknown ] && ok || bad "1af VERDICT-REVIEW: is not a VERDICT: line"
# THE COLONLESS TAG, a deliberate loosening (#1639 review). The merged re-review
# model sometimes writes `VERDICT-REVIEW APPROVE` with no colon. The old reader
# required `$LENS_TAG:`, so that line read as SILENCE, and silence on the
# general lens is BLOCK: ~11 REVIEW_BLOCKED builds a week whose reviewer had
# written APPROVE. The shared reader's colon is optional (as it always was for
# VERDICT itself), so they now read as what the reviewer wrote. Pinned both
# ways: colonless APPROVE is APPROVE, colonless BLOCK is still BLOCK, and a
# colonless tag QUOTED mid-sentence is still nothing.
printf 'body\nTIER: 2\nVERDICT-REVIEW APPROVE\nVERDICT-SECURITY BLOCK\n' > "$T/tags-nocolon.md"
[ "$(vp -l VERDICT-REVIEW -x 2 "$T/tags-nocolon.md")" = APPROVE ] && ok || bad "1af2 a colonless 'VERDICT-REVIEW APPROVE' tag reads APPROVE (got '$(vp -l VERDICT-REVIEW -x 2 "$T/tags-nocolon.md")')"
[ "$(vp -l VERDICT-SECURITY -x 2 "$T/tags-nocolon.md")" = BLOCK ] && ok || bad "1af3 a colonless 'VERDICT-SECURITY BLOCK' tag reads BLOCK"
printf 'body\nThe lens line should say VERDICT-REVIEW APPROVE once fixed.\nTIER: 2\n' > "$T/tags-quoted.md"
[ "$(vp -l VERDICT-REVIEW -x 2 "$T/tags-quoted.md")" = unknown ] && ok || bad "1af4 a colonless tag quoted mid-sentence is not a tag"

# The knob. The window is a registered knob with no literal in the lib.
REGDEF=$(jq -r '.libs[]|select(.id=="verdict-parse")|.knobs[]|select(.env=="VERDICT_WINDOW_LINES")|.default' "$DIR/catalog/lanes.d/_lib.json" 2>/dev/null)
[ -n "$REGDEF" ] && [ "$REGDEF" != null ] && ok || bad "1ag catalog/lanes.d/_lib.json must register VERDICT_WINDOW_LINES under the verdict-parse lib"
[ "$(verdict_window 2>/dev/null)" = "$REGDEF" ] && ok || bad "1ah with nothing set, the window is the registry default '$REGDEF' (got '$(verdict_window 2>/dev/null)')"
[ "$(VERDICT_WINDOW_LINES=1 vp "$T/approve.md")" = APPROVE ] && ok || bad "1ai window 1 still reads a last-line verdict"
printf 'VERDICT: APPROVE\nTIER: 1\n' > "$T/two.md"
[ "$(VERDICT_WINDOW_LINES=1 vp "$T/two.md")" = unknown ] && ok || bad "1aj window 1 excludes the second-to-last line"
[ "$(VERDICT_WINDOW_LINES=2 vp "$T/two.md")" = APPROVE ] && ok || bad "1ak window 2 includes it"
[ "$(VERDICT_WINDOW_LINES=40 vp "$T/far.md")" = APPROVE ] && ok || bad "1al a wide window reaches the far verdict"
[ "$(VERDICT_WINDOW_LINES=abc verdict_window 2>/dev/null)" = "$REGDEF" ] && ok || bad "1am a garbage env value falls through to the registry default"
if grep -qE 'VERDICT_WINDOW_LINES:?[-=][0-9]' <(grep -v '^[[:space:]]*#' "$LIB"); then
  bad "1an the lib carries a literal window fallback"
else ok; fi

# ============================================================================
# 2. the gate's readers, driven for real
# ============================================================================
H="$T/h"; export HARNESS="$H"
mkdir -p "$H/bin/lib/mc" "$H/logs" "$H/state" "$H/env" "$H/catalog/lanes.d" "$T/fakebin"
cp "$DIR/bin/lib/review-model.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/review-provenance.sh" "$DIR/bin/lib/gh-pr-list.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
[ -r "$LIB" ] && cp "$LIB" "$H/bin/lib/"
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/" 2>/dev/null
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" demo-os
# The review lane: a claude read whose text is whatever $RR_TEXT names.
cat > "$H/bin/agent-call.sh" <<'EOF'
#!/bin/bash
OUT="$5"
cat "$RR_TEXT" > "$OUT"
printf 'claude\n' > "$OUT.runner"
printf '%s\n' "$3" > "$OUT.model"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"v3.diff"*) restpr --diff '--- a/x.sh
+++ b/x.sh
+echo hi
' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/1"*)
    restpr OPEN deadbeef ticket/x main "" MERGEABLE CLEAN operator "" 'a PR body' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
URL=https://github.com/example-org/demo-os/pull/1
rr() { # rr <review-text-file> -> "<verdict> rc=<rc>"
  local v rc
  v=$(RR_TEXT="$1" PATH="$T/fakebin:$PATH" bash -c '
    set -uo pipefail
    # shellcheck source=/dev/null
    . "$HARNESS/bin/lib/merge-conductor-lib.sh"
    mc_rereview example-org/demo-os 1 demo-os '"$URL"' oldsha newsha "" "$0.out"' "$T/rr-$(basename "$1")")
  rc=$?
  printf '%s rc=%s' "$v" "$rc"
}
R=$(rr "$T/f1.md")
case "$R" in "APPROVE "*) bad "2a mc_rereview (the head-bound merge gate) read F1 — a BLOCK quoting APPROVE — as APPROVE ($R)" ;; *) ok ;; esac
[ "$R" = "BLOCK rc=0" ] && ok || bad "2b mc_rereview must answer BLOCK for F1 (got '$R')"
R=$(rr "$T/f2.md"); [ "$R" = "BLOCK rc=0" ] && ok || bad "2c mc_rereview must answer BLOCK for F2 (got '$R')"
R=$(rr "$T/f3.md"); [ "$R" = " rc=1" ] && ok || bad "2d mc_rereview: a conflicted final block is NO verdict (rc 1, nothing printed), never APPROVE (got '$R')"
R=$(rr "$T/f4.md"); [ "$R" = " rc=1" ] && ok || bad "2e mc_rereview: APPROVE only in a mid-text quote is NO verdict (got '$R')"
R=$(rr "$T/approve.md"); [ "$R" = "APPROVE rc=0" ] && ok || bad "2f mc_rereview: a plain approval is still APPROVE (got '$R')"

# mc_verdict reads the build record's review.md.
mkdir -p "$T/rec"
mv_rec() { # mv_rec <fixture> -> the verdict field mc_verdict prints
  cp "$1" "$T/rec/review.md"
  bash -c '. "$HARNESS/bin/lib/merge-conductor-lib.sh"; mc_verdict "'"$URL"'" "'"$T/rec"'"' 2>/dev/null | cut -f1
}
[ "$(mv_rec "$T/f2.md")" = BLOCK ] && ok || bad "2g mc_verdict: F2's quoted APPROVE must not make the record APPROVE (got '$(mv_rec "$T/f2.md")')"
[ "$(mv_rec "$T/f1.md")" = BLOCK ] && ok || bad "2h mc_verdict: F1's mid-sentence APPROVE must not make the record APPROVE (got '$(mv_rec "$T/f1.md")')"
[ "$(mv_rec "$T/appended.md")" = APPROVE ] && ok || bad "2h2 mc_verdict: a record whose re-review round APPENDED a short APPROVE under the BLOCK it answers is APPROVE (got '$(mv_rec "$T/appended.md")')"
[ "$(mv_rec "$T/f4.md")" = "-" ] && ok || bad "2h3 mc_verdict: a record with only a quoted verdict is '-' (got '$(mv_rec "$T/f4.md")')"
[ "$(mv_rec "$T/approve.md")" = APPROVE ] && ok || bad "2i mc_verdict: a plain approval is APPROVE"

# rp_render's **Verdict:** line is the same parse.
( . "$DIR/bin/lib/review-post.sh"; rp_render "$T/f1.md" "" "" "$T/render-f1.body" ) >/dev/null 2>&1
head -1 "$T/render-f1.body" | grep -qx '\*\*Verdict:\*\* BLOCK' && ok \
  || bad "2j rp_render must lead a BLOCK-quoting-APPROVE review with '**Verdict:** BLOCK' (got '$(head -1 "$T/render-f1.body")')"

# blocked-resolver's reader of a POSTED review body (footer included).
awk '/^br_review_verdict\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DIR/bin/blocked-resolver.sh" > "$T/brv.sh"
cat > "$T/posted.md" <<'EOF'
1. **[HIGH]** the ledger write is not idempotent.

TIER: 2
VERDICT: REQUEST_CHANGES

The earlier pass on this head said "VERDICT: APPROVE"; it missed the retry path.

---
_Automated harness review (Fable) of deadbeef. Static review — no build run._
EOF
BRV=$( . "$LIB"; . "$T/brv.sh"; br_review_verdict "$(cat "$T/posted.md")" )
[ "$BRV" = REQUEST_CHANGES ] && ok || bad "2k br_review_verdict: a REQUEST_CHANGES body quoting APPROVE is REQUEST_CHANGES (got '$BRV')"

# ============================================================================
# 3. the ratchet: the unanchored shapes are gone from bin/
# ============================================================================
# Each is a way the old readers found a verdict ANYWHERE: the last token in the
# text, the last anchored line in the text, or a tail -N | grep for a word.
LEFT=$(grep -rnE \
  -e 'grep -oE ["'"'"']VERDICT:\? \*' \
  -e "grep -oE ['\"]\\^?VERDICT: \\((APPROVE|BLOCK)" \
  -e 'tail -[0-9]+ [^|]*\| *grep -[qoE]+[^|]*(APPROVE|BLOCK)' \
  -e 'grep -oE "MERGE-WITH-NOTES\|BLOCK\|MERGE" <<<' \
  -e 'grep -l "VERDICT: BLOCK"' \
  -e 'grep -q "VERDICT: "' \
  -e 'grep -oE ["'"'"'].*LENS_TAG:' \
  "$DIR/bin" 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#')
[ -z "$LEFT" ] && ok || bad "3a unanchored verdict readers remain in bin/ (move them to bin/lib/verdict-parse.sh):
$LEFT"

# ============================================================================
# 4. the renderer (bin/lib/review-post.sh)
# ============================================================================
# The build's own review of the approved head: five numbered findings.
mkdir -p "$T/rec4"
cat > "$T/rec4/review.md" <<'EOF'
## Findings (non-blocking)
1. The knob-off semantics are narrower.
2. An empty app file is no longer accepted.
3. One routing request per project per tick.
4. The live probe is still owed.
5. shellcheck was not run in the sandbox.

TIER: 2
VERDICT: APPROVE
EOF
# The #1577 re-review, in its own shape: it talks about those five findings with
# plain bullets and prose, and raises none of its own.
cat > "$T/rr1577.md" <<'EOF'
I reviewed this statically and did not build or run any tests.

**The one unreviewed commit** (two test files only):
- the fixture now writes an app name instead of an empty file.
  - This addresses the prior review's finding 2 by making the test match production.

**Earlier findings:** they were all non-blocking and none needed a fix commit.
- Finding 1 (pool check now also needs builder-fly) and finding 3 (one routing request per tick) still stand as notes.
- Finding 4 still applies: the live probe must come before the flip.
- Finding 5 has moved on: CI is now green on this head.

VERDICT: APPROVE
EOF
printf '{"is_error":false,"result":"x"}\n' > "$T/rr1577.md.json"
POSTED_BODY="$T/posted-1577.body"
(
  . "$DIR/bin/lib/review-post.sh"
  rp_comment() { cp "$2" "$POSTED_BODY"; return 0; }
  rp_post "$T/rec4" abcd1234deadbeef "$T/rr1577.md" "$URL" "_footer_" >/dev/null
)
[ -s "$POSTED_BODY" ] && ok || bad "4a rp_post posted nothing"
grep -q 'PARSE_INCOMPLETE' "$POSTED_BODY" \
  && bad "4b a re-review that references the PRIOR review's findings 1-5 must not post PARSE_INCOMPLETE" || ok
head -1 "$POSTED_BODY" | grep -qx '\*\*Verdict:\*\* APPROVE' && ok \
  || bad "4c the #1577 re-review body must lead with '**Verdict:** APPROVE' (got '$(head -1 "$POSTED_BODY")')"
# Plain bullets are findings.
printf -- '- Finding 1: the lock leaks.\n- Finding #2 — the retry double-bills.\n\nVERDICT: BLOCK\n' > "$T/plain.md"
IDX=$( . "$DIR/bin/lib/review-post.sh"; rp_findings "$T/plain.md" | cut -f1 | tr '\n' ' ')
[ "$IDX" = "1 2 " ] && ok || bad "4d plain '- Finding N' bullets must be counted as findings (got '$IDX')"
# A reference ABOVE the prior count is still this review's own and still fails
# closed when it cannot be rendered.
printf 'Why this blocks: finding #7 is new and unanswered.\n\nVERDICT: BLOCK\n' > "$T/over.md"
( . "$DIR/bin/lib/review-post.sh"; rp_render "$T/over.md" "" "" "$T/over.body" 5 ); RC=$?
[ "$RC" = 3 ] && ok || bad "4e a reference to finding #7 against a prior count of 5 must still fail closed (rc $RC)"
head -1 "$T/over.body" | grep -qx '\*\*Verdict:\*\* BLOCK' && ok \
  || bad "4f a PARSE_INCOMPLETE body still leads with '**Verdict:** BLOCK' (got '$(head -1 "$T/over.body")')"
sed -n 2p "$T/over.body" | grep -q '^PARSE_INCOMPLETE: the verdict references finding #7' && ok \
  || bad "4g PARSE_INCOMPLETE is the second line, right under the verdict (got '$(sed -n 2p "$T/over.body")')"
# Without a prior count the same #1577 text is still incomplete: the prior
# review is what satisfies those references, nothing else.
( . "$DIR/bin/lib/review-post.sh"; rp_render "$T/rr1577.md" "" "" "$T/noprior.body" ); RC=$?
[ "$RC" = 3 ] && ok || bad "4h with no prior review, references to findings the body cannot show still fail closed (rc $RC)"

# ============================================================================
# 5. the conductor's re-review footer names the model that ran
# ============================================================================
awk '/^ *# >>> rereview helpers/{f=1;next} /^ *# <<< rereview helpers/{exit} f' \
  "$DIR/bin/lib/mc/classify.sh" > "$T/mc-helpers.sh"
awk '/^ *# >>> rereview post \(/{f=1;next} /^ *# <<< rereview post/{exit} f' \
  "$DIR/bin/lib/mc/classify.sh" > "$T/mc-post.sh"
[ -s "$T/mc-post.sh" ] && ok || bad "5a no '# >>> rereview post' block in bin/lib/mc/classify.sh"
mc_drive() { # mc_drive <tag> <verdict> <out-file>
  local tag="$1"
  mkdir -p "$T/rec5-$tag"
  ( . "$DIR/bin/lib/review-post.sh"
    rp_comment()           { cp "$2" "$T/body5-$tag"; return 0; }
    mc_log()               { :; }
    mc_transition()        { :; }
    mc_hb_refuse()         { :; }
    mc_prov_clear()        { :; }
    mc_patch_id_remember() { return 0; }
    mc_rr_noci_why()       { printf ''; }
    # shellcheck source=/dev/null
    . "$T/mc-helpers.sh"
    v="$2"; outf="$3"; rec="$T/rec5-$tag"; head=abcd1234deadbeefcafe; url="$URL"
    key="example-org/demo-os#1"; slug="example-org/demo-os"; num=1; proj=demo-os
    rrwhat="Head-bound harness re-review"; mode=moved
    reviewed=0000111122223333; mstate=UNKNOWN
    # shellcheck source=/dev/null
    . "$T/mc-post.sh"
  ) >/dev/null 2>&1
}
cp "$T/approve.md" "$T/ap5.md"; printf 'claude-opus-5-5\n' > "$T/ap5.md.model"
mc_drive approve APPROVE "$T/ap5.md"
grep -q '(claude-opus-5-5)' "$T/body5-approve" 2>/dev/null && ok \
  || bad "5b the APPROVE footer must name the model from <out>.model (got: $(tail -1 "$T/body5-approve" 2>/dev/null))"
grep -q '(Fable)' "$T/body5-approve" 2>/dev/null && bad "5c the APPROVE footer must not claim Fable for an opus read" || ok
cp "$T/f1.md" "$T/bl5.md"; printf 'claude-opus-5-5\n' > "$T/bl5.md.model"
mc_drive block BLOCK "$T/bl5.md"
grep -q '(claude-opus-5-5)' "$T/body5-block" 2>/dev/null && ok \
  || bad "5d the BLOCK footer must name the model from <out>.model (got: $(tail -1 "$T/body5-block" 2>/dev/null))"
cp "$T/approve.md" "$T/nomodel.md"
mc_drive nomodel APPROVE "$T/nomodel.md"
grep -q '(Fable)' "$T/body5-nomodel" 2>/dev/null && bad "5e with no <out>.model the footer must not guess a model name" || ok
grep -q 'model unrecorded' "$T/body5-nomodel" 2>/dev/null && ok \
  || bad "5f with no <out>.model the footer says the model is unrecorded (got: $(tail -1 "$T/body5-nomodel" 2>/dev/null))"
grep -q '(Fable)' "$T/mc-post.sh" && bad "5g the rereview post block still hardcodes '(Fable)'" || ok

# ============================================================================
# 6. the window knob is resolved ONCE per process (#1639 review: ~277 ms each)
# ============================================================================
# A counting lib_env_apply stands in for the settings contract. Sourcing the lib
# primed once (verdict_prime, BH-1644); every later parse — in the same shell AND inside $(...) —
# reuses $_VP_WINDOW and never calls it again. An env value still wins per call.
CNT="$T/resolves.txt"; : > "$CNT"
(
  unset VERDICT_WINDOW_LINES _VP_WINDOW
  lib_env_apply() { printf 'resolve %s\n' "$1" >> "$CNT"; export VERDICT_WINDOW_LINES=3; }
  # shellcheck source=/dev/null
  . "$LIB"
  unset VERDICT_WINDOW_LINES
  verdict_prime   # BH-1644: sourcing no longer resolves; a lane primes once
  unset VERDICT_WINDOW_LINES
  A1=$(verdict_parse "$T/approve.md"); A2=$(verdict_parse "$T/f1.md")
  verdict_is APPROVE "$T/approve.md" || echo "SECOND-CALL-WRONG" >> "$CNT"
  [ "$A1/$A2" = "APPROVE/BLOCK" ] || echo "PARSE-WRONG $A1/$A2" >> "$CNT"
  # shellcheck source=/dev/null
  . "$LIB"   # a re-source keeps the cache
  verdict_parse "$T/approve.md" >/dev/null
  [ "$(VERDICT_WINDOW_LINES=1 verdict_parse "$T/two.md")" = unknown ] || echo "ENV-DID-NOT-WIN" >> "$CNT"
)
[ "$(grep -c '^resolve verdict-parse$' "$CNT")" = 1 ] && ok \
  || bad "6a the window must be resolved exactly once per process across source, parses, \$(...) parses and a re-source (got $(grep -c '^resolve' "$CNT") resolves)"
grep -q 'WRONG' "$CNT" && bad "6b cached-window parses answered wrong: $(grep WRONG "$CNT")" || ok
grep -q 'ENV-DID-NOT-WIN' "$CNT" && bad "6c an env window must still win over the per-process cache" || ok

# ============================================================================
# 7. review-autopilot's footer names the model that ran, not "(Fable)"
# ============================================================================
AP="$DIR/bin/review-autopilot.sh"
grep -q 'Automatic adversarial review (Fable)' "$AP" && bad "7a review-autopilot.sh still hardcodes '(Fable)' in its posted footer" || ok
grep -q 'Automatic adversarial review (\$RA_SERVED)' "$AP" && ok || bad "7b the autopilot footer must carry the served model (\$RA_SERVED)"
grep -q 'RA_SERVED=\$(head -1 "\$OUT_FILE.model"' "$AP" && ok || bad "7c RA_SERVED must come from <out>.model, the file agent-call.sh writes"

echo "verdict-parse.bh-1625: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
