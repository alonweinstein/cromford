#!/bin/bash
# tests/block-gate-lib-test.sh — bin/lib/block-gate.sh, the shared BLOCK gate
# (BH-762), on its own: the marker vocabulary, the two dates, the clear rule,
# the three sources, the failure answers and the posted-comment ledger.
#
# THE NEGATIVES CARRY THE WEIGHT. This classifier gates an IRREVERSIBLE action,
# so both ways of being wrong are expensive: a missed BLOCK merges over a human,
# and a false BLOCK stops every merge on the fleet. The words that must NOT
# block — BLOCKED_HUMAN, PLAN_BLOCKED, `Blocked-by:`, a quoted `> BLOCK`, the
# gate's own refusal comment — are pinned here one by one, and so are the words
# that must NOT clear (APPROVE and LGTM above all: the harness's own reviewers
# post VERDICT: APPROVE under a PAT whose login can be the blocker's own).
#
# Every fixture time is a literal. Nothing here reads the wall clock.
# Run from anywhere: tests/block-gate-lib-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$T/h/state" "$T/h/logs" "$T/fakebin"
SLUG=o/r; PR=41; ISSUE=20
PRURL="https://github.com/$SLUG/pull/$PR"
HEAD=aaaaaaaa1111
T_HEAD_OLD=2026-09-17T18:40:00Z
T_HEAD_NEW=2026-09-17T18:50:00Z
T_EARLY=2026-09-17T18:45:00Z
T_BLOCK=2026-09-17T18:47:00Z
T_CLEAR=2026-09-17T18:52:00Z

# The stub answers each source out of a file holding exactly what `gh api … -q`
# prints: one TSV line per comment. $T/fail-<what> makes that read exit nonzero.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr comment"*) [ -f "$T/comment-fails" ] && exit 1
                  printf '%s\n' "\$*" >> "$T/gh-comments.txt"; exit 0 ;;
  # bg_refuse's "has another box already said this?" read asks for bodies, not
  # for the TSV the scan asks for, so it gets its own file.
  *".[].body"*)                               [ -f "$T/fail-bodies" ] && exit 1
                                              cat "$T/prbodies" 2>/dev/null; exit 0 ;;
  *"api repos/$SLUG/issues/$PR/comments"*)    [ -f "$T/fail-comments" ] && exit 1
                                              cat "$T/prcomments" 2>/dev/null; exit 0 ;;
  *"api repos/$SLUG/pulls/$PR/reviews"*)      [ -f "$T/fail-reviews" ] && exit 1
                                              cat "$T/reviews" 2>/dev/null; exit 0 ;;
  *"api repos/$SLUG/issues/$ISSUE/comments"*) [ -f "$T/fail-issue404" ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
                                              [ -f "$T/fail-issue" ] && { echo "gh: HTTP 502" >&2; exit 1; }
                                              cat "$T/issuecomments" 2>/dev/null; exit 0 ;;
  *"api repos/$SLUG/pulls/$PR/commits"*) cat "$T/headtime" 2>/dev/null; exit 0 ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$DIR/bin/lib/block-gate.sh" || { echo "cannot source bin/lib/block-gate.sh"; exit 1; }

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
cmt() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(b64 "$5")"; }
fresh() { # fresh <head-time>
  : > "$T/prcomments"; : > "$T/reviews"; : > "$T/issuecomments"; : > "$T/prbodies"
  : > "$T/gh-calls.txt"; : > "$T/gh-comments.txt"
  rm -f "$T/fail-comments" "$T/fail-reviews" "$T/comment-fails" \
        "$T/fail-issue404" "$T/fail-issue" "$T/fail-bodies"
  rm -rf "$T/h/state/block-gate"
  printf '%s\n' "$1" > "$T/headtime"
}
scan() { BGOUT=$(bg_scan "$SLUG" "$PR" "$PRURL" "$HEAD" "${1:-}"); BGRC=$?; }

# ══ 1. bg_marker_block accepts the shapes a real verdict is written in ═══════
for B in "BLOCK" \
         "BLOCK, one blocking finding" \
         "**BLOCK**" \
         "VERDICT: BLOCK" \
         "## BLOCK" \
         "  BLOCK: the channel adoption is wrong" \
         "\`\`\`
BLOCK
\`\`\`" \
         "$(printf 'findings\r\nBLOCK\r\n')" ; do
  bg_marker_block "$B" && ok || bad "bg_marker_block must accept: $(head -1 <<<"$B")"
done

# ══ 2. …and rejects every near miss, including its own refusal comment ═══════
MARK="<!-- block-gate refused aaaaaaaa 9001 -->"
REFUSAL="Not merging aaaaaaaa: https://github.com/o/r/issues/20#issuecomment-1 (@someone, $T_BLOCK) is a BLOCK on this head with no later clearing comment from that author. It merges when a newer commit is pushed, or when the same author posts UNBLOCK or CLEARED — and, for a block posted by one of the harness's own review lanes, when that same machine login posts a later terminal verdict line naming this head. Refused by the merge-conductor merge gate.

$MARK"
for B in "BLOCKED_HUMAN" "REVIEW_BLOCKED" "PLAN_BLOCKED" "Blocked-by: #12" "blocker" \
         "non-blocking finding" "> BLOCK" "the BLOCK gate is on" "unblock" "block" \
         "BLOCK_GATE_ENFORCE=0" "BLOCKED" "BLOCKER" "non-BLOCK" "$MARK" "$REFUSAL"; do
  bg_marker_block "$B" && bad "bg_marker_block must REJECT: $B" || ok
done
bg_marker_clear "$REFUSAL" && bad "the gate's own refusal comment must not read as a CLEAR either" || ok
# …nor as a terminal VERDICT (BH-1131). The refusal now NAMES the verdict rule
# for the human reading it, and the gate's own comment is posted under the
# lane's App login on a bot-authored PR — a refusal that read as its own clear
# would merge the head it just refused.
bg_marker_approve "$REFUSAL" && bad "the gate's own refusal comment must not read as an APPROVE" || ok
bg_marker_clear "$MARK" && bad "the dedupe marker must not read as a CLEAR either" || ok

# ══ 3. bg_marker_clear: what clears, and what does not ══════════════════════
for C in "UNBLOCK" "UNBLOCKED" "CLEARED" "BLOCK CLEARED" "BLOCK: CLEARED" "**UNBLOCK** — false positive"; do
  bg_marker_clear "$C" && ok || bad "bg_marker_clear must accept: $C"
done
# APPROVE in every shape a reviewer writes it, bare included: the harness's own
# reviewers post approvals under a PAT whose login can be the human blocker's
# own, so an approval must never clear a person's BLOCK.
for C in "VERDICT: APPROVE" "APPROVE" "APPROVED" "VERDICT: APPROVE, ship it" \
         "LGTM" "cleared the cache" "UNBLOCKING soon" "I have not cleared it"; do
  bg_marker_clear "$C" && bad "bg_marker_clear must REJECT: $C" || ok
done

# ══ 4. a BLOCK newer than the head → rc 1, naming the comment ═══════════════
fresh "$T_HEAD_OLD"
cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK, one blocking finding" > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && ok || bad "a BLOCK 7 minutes newer than the head must answer rc 1 (got rc=$BGRC out=$BGOUT)"
[ "$BGOUT" = "$(printf 'https://x/c9001\treviewer-h\t%s\t9001' "$T_BLOCK")" ] \
  && ok || bad "rc 1 must print url, login, time, id: got [$BGOUT]"

# ══ 5. the same BLOCK, OLDER than the head → rc 0 (an r2 clears its own) ════
fresh "$T_HEAD_NEW"
cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK, one blocking finding" > "$T/prcomments"
scan
[ "$BGRC" = 0 ] && ok || bad "a BLOCK older than the head must answer rc 0 (got rc=$BGRC out=$BGOUT)"
# …and a block at EXACTLY the head's time is not newer than it.
fresh "$T_BLOCK"
cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK" > "$T/prcomments"
scan
[ "$BGRC" = 0 ] && ok || bad "a BLOCK at exactly the head's time is not NEWER than it (got rc=$BGRC)"

# ══ 6. BLOCK then UNBLOCK by the same login → rc 0 ══════════════════════════
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK, one blocking finding"
  cmt 9002 "$T_CLEAR" reviewer-h "https://x/c9002" "UNBLOCK — false positive"; } > "$T/prcomments"
scan
[ "$BGRC" = 0 ] && ok || bad "a BLOCK cleared by its own author must answer rc 0 (got rc=$BGRC out=$BGOUT)"
# …but the SAME author approving is not the same author clearing. This is the
# whole reason APPROVE is out of the CLEAR vocabulary, so it is pinned end to
# end and not only on bg_marker_clear.
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK, one blocking finding"
  cmt 9002 "$T_CLEAR" reviewer-h "https://x/c9002" "APPROVE"; } > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && ok || bad "an APPROVE by the blocker must NOT clear the BLOCK (got rc=$BGRC out=$BGOUT)"
[ "$BGRC" = 1 ] && grep -q 9001 <<<"$BGOUT" && ok || bad "the still-standing block 9001 must be the one named (rc=$BGRC out=$BGOUT)"

# ══ 7. a clear from a DIFFERENT login does not clear it ═════════════════════
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK, one blocking finding"
  cmt 9002 "$T_CLEAR" someone-else "https://x/c9002" "CLEARED"; } > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && grep -q reviewer-h <<<"$BGOUT" && ok || bad "another login cannot clear reviewer-h's BLOCK (rc=$BGRC out=$BGOUT)"

# ══ 8. ORDER MATTERS: a clear BEFORE the block clears nothing ══════════════
fresh "$T_HEAD_OLD"
{ cmt 9000 "$T_EARLY" reviewer-h "https://x/c9000" "UNBLOCK"
  cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK, one blocking finding"; } > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && ok || bad "an UNBLOCK posted BEFORE the BLOCK must not clear it (rc=$BGRC out=$BGOUT)"

# ══ 9. A blocks, A clears, B blocks → still refused, naming B ══════════════
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK, one blocking finding"
  cmt 9002 2026-09-17T18:49:00Z reviewer-h "https://x/c9002" "UNBLOCK"
  cmt 9003 "$T_CLEAR" reviewer-b "https://x/c9003" "BLOCK — the RLS migration is missing"; } > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && grep -q "reviewer-b" <<<"$BGOUT" && grep -q c9003 <<<"$BGOUT" \
  && ok || bad "the newest unresolved block (reviewer-b's) must be the one named (rc=$BGRC out=$BGOUT)"

# ══ 10. a BLOCK as a REVIEW body counts, with the review's own url ═════════
fresh "$T_HEAD_OLD"
cmt 4100 "$T_BLOCK" reviewer-h "https://x/pullrequestreview-4100" "VERDICT: BLOCK

One blocking finding." > "$T/reviews"
scan
[ "$BGRC" = 1 ] && grep -q pullrequestreview-4100 <<<"$BGOUT" \
  && ok || bad "a BLOCK in a REVIEW body must gate and name the review (rc=$BGRC out=$BGOUT)"

# ══ 11. the TICKET thread, and only when an issue number is handed over ════
fresh "$T_HEAD_OLD"
cmt 7001 "$T_BLOCK" reviewer-h "https://x/i7001" "BLOCK, one blocking finding" > "$T/issuecomments"
scan "$ISSUE"
[ "$BGRC" = 1 ] && grep -q i7001 <<<"$BGOUT" || bad "a BLOCK on the ticket thread must gate when the issue number is passed (rc=$BGRC out=$BGOUT)"
[ "$BGRC" = 1 ] && ok
fresh "$T_HEAD_OLD"
cmt 7001 "$T_BLOCK" reviewer-h "https://x/i7001" "BLOCK, one blocking finding" > "$T/issuecomments"
scan
[ "$BGRC" = 0 ] && ok || bad "with no issue number the ticket thread must not be read (rc=$BGRC out=$BGOUT)"
grep -q "issues/$ISSUE/comments" "$T/gh-calls.txt" && bad "the ticket thread must not be READ when no issue number was passed" || ok

# ══ 12. the happy path buys nothing extra ═════════════════════════════════
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "VERDICT: APPROVE"
  cmt 9002 "$T_CLEAR" someone-else "https://x/c9002" "BLOCKED_HUMAN is a state word"; } > "$T/prcomments"
scan
[ "$BGRC" = 0 ] && ok || bad "a thread with no BLOCK must answer rc 0 (got rc=$BGRC out=$BGOUT)"
grep -q -- "pulls/$PR/commits" "$T/gh-calls.txt" && bad "the head's commit dates must not be bought with no BLOCK in the thread" || ok

# ══ 13. what cannot be judged answers rc 2, and NEVER rc 0 ════════════════
fresh "$T_HEAD_OLD"; touch "$T/fail-comments"
scan
[ "$BGRC" = 2 ] && [ "$BGOUT" = comments ] && ok || bad "a failed comments read must answer rc 2 'comments' (rc=$BGRC out=$BGOUT)"
fresh "$T_HEAD_OLD"; touch "$T/fail-reviews"
scan
[ "$BGRC" = 2 ] && [ "$BGOUT" = reviews ] && ok || bad "a failed reviews read must answer rc 2 'reviews' (rc=$BGRC out=$BGOUT)"
fresh "$T_HEAD_OLD"; : > "$T/headtime"
cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK" > "$T/prcomments"
scan
[ "$BGRC" = 2 ] && [ "$BGOUT" = head-time ] && ok || bad "an unreadable head time must answer rc 2 'head-time' (rc=$BGRC out=$BGOUT)"
# A source that answers something that is not the agreed shape is a FAILED read,
# not an empty thread — otherwise a changed API quietly reads as "no block".
fresh "$T_HEAD_OLD"
printf 'not a tsv line\n' > "$T/prcomments"
scan
[ "$BGRC" = 2 ] && ok || bad "an unparseable comments answer must be rc 2, never rc 0 (rc=$BGRC out=$BGOUT)"

# ══ 14. bg_refuse: one comment per (PR, head, blocking comment) ═══════════
fresh "$T_HEAD_OLD"
LINE=$(printf 'https://x/c9001\treviewer-h\t%s\t9001' "$T_BLOCK")
bg_refuse "$SLUG" "$PR" "$PRURL" "$HEAD" "$LINE" merge-conductor && ok || bad "the first refusal must post"
bg_refuse "$SLUG" "$PR" "$PRURL" "$HEAD" "$LINE" merge-conductor && ok || bad "a repeat refusal must answer rc 0 (already said)"
[ "$(grep -c 'pr comment' "$T/gh-comments.txt")" = 1 ] && ok || bad "exactly one comment per (PR, head, block): $(cat "$T/gh-comments.txt")"
[ "$(grep -c . "$T/h/state/block-gate/posted.txt")" = 1 ] && ok || bad "one ledger line: $(cat "$T/h/state/block-gate/posted.txt")"
grep -q "https://x/c9001" "$T/gh-comments.txt" && ok || bad "the comment must link the blocking comment: $(cat "$T/gh-comments.txt")"
# THE REFUSAL'S OWN TEXT, as the gate really posts it (BH-1131). It is the one
# surface a person reads, so it must name EVERY way the hold ends — a newer
# commit, UNBLOCK/CLEARED, and a harness review lane's later terminal verdict on
# this head — and it must still read as none of the three markers itself: the
# gate posts it under the lane's App login on a bot-authored PR, so a refusal
# that read as its own clear would merge the head it had just refused.
POSTED_BODY=$(grep 'pr comment' "$T/gh-comments.txt" | head -1)
grep -q "UNBLOCK or CLEARED" <<<"$POSTED_BODY" && ok \
  || bad "the refusal must still name UNBLOCK/CLEARED: $POSTED_BODY"
grep -q "terminal verdict line naming this head" <<<"$POSTED_BODY" && ok \
  || bad "the refusal must name the terminal-verdict clear too: $POSTED_BODY"
bg_marker_block   "$POSTED_BODY" && bad "the posted refusal must not read as a BLOCK: $POSTED_BODY"   || ok
bg_marker_clear   "$POSTED_BODY" && bad "the posted refusal must not read as a CLEAR: $POSTED_BODY"   || ok
bg_marker_approve "$POSTED_BODY" && bad "the posted refusal must not read as an APPROVE: $POSTED_BODY" || ok
# a SECOND blocker on the same head gets its own comment
LINE2=$(printf 'https://x/c9003\treviewer-b\t%s\t9003' "$T_CLEAR")
bg_refuse "$SLUG" "$PR" "$PRURL" "$HEAD" "$LINE2" merge-conductor >/dev/null
[ "$(grep -c 'pr comment' "$T/gh-comments.txt")" = 2 ] && ok || bad "a different blocking comment must get its own refusal: $(cat "$T/gh-comments.txt")"
# a failed post writes NO ledger line, so the next pass retries it
touch "$T/comment-fails"
LINE3=$(printf 'https://x/c9005\treviewer-c\t%s\t9005' "$T_CLEAR")
bg_refuse "$SLUG" "$PR" "$PRURL" "$HEAD" "$LINE3" merge-conductor && bad "a failed pr comment must answer rc 1" || ok
grep -q 9005 "$T/h/state/block-gate/posted.txt" && bad "a failed post must leave NO ledger line — the next pass has to retry it" || ok

# ══ 15. ONE comment per (PR, head, block) across BOXES, not just per box ═══
# Six lanes on three machines can refuse the same head, each with its own empty
# ledger — a tier-1 build stands down and the hub conductor picks the PR up
# minutes later. The marker on the PR is how the second one knows not to repeat
# the first, so this is the SAME (pr, head, id) with the ledger wiped.
fresh "$T_HEAD_OLD"
bg_refuse "$SLUG" "$PR" "$PRURL" "$HEAD" "$LINE" merge-conductor >/dev/null
grep -q 'block-gate refused aaaaaaaa 9001' "$T/gh-comments.txt" \
  && ok || bad "the refusal must carry the marker the other boxes recognise: $(cat "$T/gh-comments.txt")"
cp "$T/gh-comments.txt" "$T/prbodies"          # the comment is now ON the PR
rm -rf "$T/h/state/block-gate"                 # …and this is a DIFFERENT box
: > "$T/gh-comments.txt"
bg_refuse "$SLUG" "$PR" "$PRURL" "$HEAD" "$LINE" merge-sweep && ok || bad "a second lane must answer rc 0 when the PR already says it"
[ -s "$T/gh-comments.txt" ] && bad "a second box must NOT repeat the same refusal: $(cat "$T/gh-comments.txt")" || ok
grep -q 9001 "$T/h/state/block-gate/posted.txt" && ok || bad "the second box must record what it found, so it stops asking GitHub"
# a DIFFERENT blocking comment is a different thing to say, marker or no marker
: > "$T/gh-comments.txt"; rm -rf "$T/h/state/block-gate"
bg_refuse "$SLUG" "$PR" "$PRURL" "$HEAD" "$LINE2" merge-sweep >/dev/null
[ "$(grep -c 'pr comment' "$T/gh-comments.txt")" = 1 ] && ok || bad "a second blocker still gets its own comment: $(cat "$T/gh-comments.txt")"
# an unreadable marker read posts anyway: a duplicate is noise, a silence is a hold
: > "$T/gh-comments.txt"; rm -rf "$T/h/state/block-gate"; touch "$T/fail-bodies"
bg_refuse "$SLUG" "$PR" "$PRURL" "$HEAD" "$LINE" merge-sweep >/dev/null
[ -s "$T/gh-comments.txt" ] && ok || bad "when the marker read fails the refusal must still be SAID"

# ══ 16. no such ticket thread is an empty thread, not "cannot judge" ═══════
# mc_issue_of falls back to the first number in the branch name, so a harness PR
# on branch hotfix/rotate-2026-keys asks for issue 2026 and gets a 404. That is
# "there is no such thread", and fail-closed on it would refuse the merge on
# every tick for ever. Any OTHER failure of that read stays fail-closed.
fresh "$T_HEAD_OLD"; touch "$T/fail-issue404"
scan "$ISSUE"
[ "$BGRC" = 0 ] && ok || bad "a 404 on the ticket thread must read as an empty thread (rc=$BGRC out=$BGOUT)"
fresh "$T_HEAD_OLD"; touch "$T/fail-issue404"
cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK, one blocking finding" > "$T/prcomments"
scan "$ISSUE"
[ "$BGRC" = 1 ] && ok || bad "a 404 on the ticket thread must not hide a BLOCK on the PR (rc=$BGRC out=$BGOUT)"
fresh "$T_HEAD_OLD"; touch "$T/fail-issue"
scan "$ISSUE"
[ "$BGRC" = 2 ] && [ "$BGOUT" = issue-comments ] && ok \
  || bad "any other ticket-thread failure stays rc 2 'issue-comments' (rc=$BGRC out=$BGOUT)"

# ══ 17. an empty html_url must not shift the body out of the row ══════════
# The rows are tab-split and tab is IFS whitespace, so two separators in a row
# would collapse and read the base64 body as the url — and the BLOCK with it.
fresh "$T_HEAD_OLD"
printf '%s\t%s\t%s\t\t%s\n' 9001 "$T_BLOCK" reviewer-h "$(b64 "BLOCK, one blocking finding")" > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && ok || bad "a comment with no html_url must still gate (rc=$BGRC out=$BGOUT)"
[ "$(cut -f1 <<<"$BGOUT")" = "$PRURL" ] && ok || bad "with no comment url the PR's own url is the honest link: [$BGOUT]"

echo "block-gate-lib: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
