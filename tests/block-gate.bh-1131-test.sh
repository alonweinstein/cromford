#!/bin/bash
# tests/block-gate.bh-1131-test.sh — BH-1131, the three defects that between
# them held PR #728 for 7 hours 40 minutes with CI green, mergeState CLEAN and
# a head-bound APPROVE sitting on the PR:
#
#   A. a later terminal verdict by the SAME author, on the SAME head, never
#      cleared that author's own earlier BLOCK. The review autopilot writes
#      `VERDICT: APPROVE`, never `UNBLOCK`, so once it blocked a head only a
#      new commit could free it — and a new commit buys another review. A
#      deadlock the pipeline enters on its own.
#   B. bg_head_time read the CLI's GraphQL `--json commits`. The App token's
#      GraphQL budget is capped and invisible in `rate_limit`, so an exhausted
#      budget made the gate answer rc 2 `head-time` — 81 identical refusal
#      lines in one day's logs/merge-conductor.log.
#   C. those 81 lines raised no alert. A gate that has refused the same
#      (PR, head, reason) K times in a row has to say so once, out loud.
#
# THE NEGATIVES ARE THE POINT, AGAIN. This gate stands in front of an
# irreversible action: widening what CLEARS a block is the dangerous direction,
# so every case that must STILL block is pinned beside the one that now clears —
# a bare APPROVE, an approve from a different login, a re-review that still
# names a finding, and a later BLOCK after an approve.
#
# Section E is WHO may clear and on WHICH head (the r1 review's BLOCK finding).
# `bin/review-prs.sh` posts its `VERDICT: APPROVE` review through the fleet PAT,
# whose login is `operator` — the same login a human blocker types from — on every
# OS repo today (project-3 #355, project-1 #691, project-2 #525/#526). A verdict-line
# clear scoped by login ALONE therefore lets the machine reviewer clear a
# PERSON's block minutes after it is posted, which is the one thing the rule it
# replaced existed to prevent. So the clear needs two more bindings: the
# approving login must be a MACHINE account (`[bot]`/`app/` — GitHub refuses
# `[` and `]` in a person's user name, so the suffix cannot be worn by a human),
# and the approving body must NAME THIS HEAD, which every harness review lane
# writes into its own footer. Section E pins both, in both sources.
#
# Section D replays the REAL #728 thread out of
# tests/fixtures/bh-1131-pr728-thread.tsv (the five comments from 04:11Z to
# 07:55Z, verbatim and base64'd exactly as `gh api … -q @tsv` prints them) at
# the head time both GraphQL and REST reported for that PR. That is the
# acceptance case the ticket names, and nothing in it is invented.
#
# Every fixture time is a literal. Nothing here reads the wall clock.
# Run from anywhere: tests/block-gate.bh-1131-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T/h"
mkdir -p "$T/h/state" "$T/h/logs" "$T/h/bin" "$T/fakebin"
SLUG=o/r; PR=41
PRURL="https://github.com/$SLUG/pull/$PR"
HEAD=aaaaaaaa1111
HEAD2=bbbbbbbb2222
T_HEAD_OLD=2026-09-17T18:40:00Z
T_BLOCK=2026-09-17T18:47:00Z
T_MID=2026-09-17T18:49:00Z
T_LATE=2026-09-17T18:52:00Z
T_LATEST=2026-09-17T18:55:00Z

# The stub answers each source out of a file holding exactly what `gh api … -q`
# prints. GRAPHQL IS A HARD FAILURE HERE: any `gh pr`/`gh issue`/`--json` read
# is recorded and exits 1, so a gate that still reaches for one cannot pass this
# file by accident.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"--json"*|"pr view"*|*" pr view "*|*" issue view "*)
      printf '%s\n' "\$*" >> "$T/graphql-calls.txt"; exit 1 ;;
  *"pr comment"*) printf '%s\n' "\$*" >> "$T/gh-comments.txt"; exit 0 ;;
  *".[].body"*) exit 0 ;;
  *"api repos/$SLUG/issues/$PR/comments"*) cat "$T/prcomments" 2>/dev/null; exit 0 ;;
  *"api repos/$SLUG/pulls/$PR/reviews"*)   cat "$T/reviews" 2>/dev/null; exit 0 ;;
  *"api repos/$SLUG/pulls/$PR/commits"*)
      [ -f "$T/fail-commits" ] && { echo "gh: HTTP 403 rate limit" >&2; exit 1; }
      cat "$T/commits" 2>/dev/null; exit 0 ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$DIR/bin/lib/block-gate.sh" || { echo "cannot source bin/lib/block-gate.sh"; exit 1; }

# A lane-alert.sh that RECORDS what it was told and is deliberately NOISY on
# stdout: bg_scan runs inside `out=$(bg_scan …)` in every lane, so one stray
# line from here would be read as a blocking comment's url.
cat > "$T/h/bin/lane-alert.sh" <<'ALERT'
#!/bin/bash
echo "lane-alert stdout noise"
printf '%s\n' "$*" >> "${LANE_ALERT_LOG:-/dev/null}"
exit 0
ALERT
chmod +x "$T/h/bin/lane-alert.sh"
export LANE_ALERT_LOG="$T/alerts.txt"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
cmt() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(b64 "$5")"; }
fresh() { # fresh <head-time>
  : > "$T/prcomments"; : > "$T/reviews"; : > "$T/gh-calls.txt"
  : > "$T/graphql-calls.txt"; : > "$T/gh-comments.txt"; : > "$T/alerts.txt"
  rm -f "$T/fail-commits"
  rm -rf "$T/h/state/block-gate"
  printf '%s\n' "$1" > "$T/commits"
}
scan() { BGOUT=$(bg_scan "$SLUG" "$PR" "$PRURL" "${1:-$HEAD}"); BGRC=$?; }
# The two footers the live review lanes write, in shape: the autopilot's HTML
# marker (bin/review-autopilot.sh, `<!-- harness-review-autopilot <head12> -->`)
# and the conductor's head-bound re-review footer (bin/merge-conductor.sh:805,
# `… (Fable) of <head>: APPROVE …`). BOTH NAME THE HEAD — that is what binds a
# terminal verdict to the head it adjudicated, and section E pins that a body
# which names no head clears nothing.
ap_body() { printf '<!-- harness-review-autopilot %s -->\n%s' "${2:-$HEAD}" "$1"; }
rr_body() { printf '%s\n\n---\n_Head-bound harness re-review (Fable) of %s: APPROVE — approval rebound to this head. Static review, no build run._' "$1" "${2:-$HEAD}"; }

# ══ A. a same-author TERMINAL VERDICT clears that author's own BLOCK ═════════

# A1 — the #728 shape: BLOCK, then APPROVE, same machine login, same head.
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" 'review[bot]' "https://x/c9001" "VERDICT: BLOCK — one blocking finding"
  cmt 9002 "$T_LATE"  'review[bot]' "https://x/c9002" "$(rr_body "Re-reviewed on this head. Downgraded to PLAUSIBLE.

VERDICT: APPROVE")"; } > "$T/prcomments"
scan
[ "$BGRC" = 0 ] && ok || bad "A1: a later VERDICT: APPROVE by the blocker must clear its own BLOCK (rc=$BGRC out=$BGOUT)"

# A2 — MERGE-WITH-NOTES is the autopilot's other landing verdict and clears too.
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" 'review[bot]' "https://x/c9001" "BLOCK — one blocking finding"
  cmt 9002 "$T_LATE"  'review[bot]' "https://x/c9002" "$(ap_body "VERDICT: MERGE-WITH-NOTES — the notes are follow-ups")"; } > "$T/prcomments"
scan
[ "$BGRC" = 0 ] && ok || bad "A2: VERDICT: MERGE-WITH-NOTES by the blocker must clear its own BLOCK (rc=$BGRC out=$BGOUT)"

# A3 — a terminal verdict from a DIFFERENT login clears nothing.
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" reviewer-h    "https://x/c9001" "BLOCK — one blocking finding"
  cmt 9002 "$T_LATE"  'review[bot]' "https://x/c9002" "$(ap_body "VERDICT: APPROVE")"; } > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && grep -q reviewer-h <<<"$BGOUT" && ok \
  || bad "A3: another login's APPROVE must not clear reviewer-h's BLOCK (rc=$BGRC out=$BGOUT)"

# A4 — BLOCK then BLOCK stays blocked, and the NEWEST one is named.
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" 'review[bot]' "https://x/c9001" "VERDICT: BLOCK — finding one"
  cmt 9002 "$T_LATE"  'review[bot]' "https://x/c9002" "VERDICT: BLOCK — finding two"; } > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && grep -q c9002 <<<"$BGOUT" && ok \
  || bad "A4: BLOCK then BLOCK must stay blocked, naming the newest (rc=$BGRC out=$BGOUT)"

# A5 — BLOCK, APPROVE, BLOCK: the newest verdict wins, so it is blocked again.
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK"  'review[bot]' "https://x/c9001" "VERDICT: BLOCK — finding one"
  cmt 9002 "$T_MID"    'review[bot]' "https://x/c9002" "$(ap_body "VERDICT: APPROVE")"
  cmt 9003 "$T_LATEST" 'review[bot]' "https://x/c9003" "VERDICT: BLOCK — it came back"; } > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && grep -q c9003 <<<"$BGOUT" && ok \
  || bad "A5: a BLOCK after an APPROVE must block again (rc=$BGRC out=$BGOUT)"

# A6 — a re-review that STILL names a blocking finding blocks, whatever its
# last line says. An ambiguous comment is read the fail-closed way.
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" 'review[bot]' "https://x/c9001" "VERDICT: BLOCK — finding one"
  cmt 9002 "$T_LATE"  'review[bot]' "https://x/c9002" "$(ap_body "BLOCK — the RLS migration is still missing

VERDICT: APPROVE")"; } > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && ok || bad "A6: a comment carrying BOTH markers must stay blocked (rc=$BGRC out=$BGOUT)"

# A7 — an APPROVE posted BEFORE the block clears nothing (order matters).
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_MID"    'review[bot]' "https://x/c9001" "$(ap_body "VERDICT: APPROVE")"
  cmt 9002 "$T_LATEST" 'review[bot]' "https://x/c9002" "VERDICT: BLOCK — finding one"; } > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && ok || bad "A7: an APPROVE posted BEFORE the BLOCK must not clear it (rc=$BGRC out=$BGOUT)"

# A8 — THE VOCABULARY DID NOT WIDEN BEYOND THE VERDICT LINE. A bare approval is
# still not a clear, in bg_marker_clear and end to end, which is what keeps a
# chatty "approve" away from a real person's BLOCK.
# The verdict WORD is case-sensitive, exactly as BLOCK is (`block` does not
# block), so a lowercase `approve` is prose and not a verdict. The `verdict:`
# label itself is not, which is the same latitude BG_BLOCK_RE gives it.
for C in "APPROVE" "APPROVED" "LGTM" "approve" "I approve of this" \
         "VERDICT: approve" "verdict: approve"; do
  bg_marker_clear "$C"   && bad "A8: bg_marker_clear must still REJECT: $C"   || ok
  bg_marker_approve "$C" && bad "A8: bg_marker_approve must REJECT: $C" || ok
done
for C in "VERDICT: APPROVE" "verdict: APPROVE" "**VERDICT: APPROVE**" \
         "VERDICT: MERGE-WITH-NOTES" "VERDICT: MERGE" "VERDICT: APPROVE, ship it"; do
  bg_marker_approve "$C" && ok || bad "A8: bg_marker_approve must accept: $C"
  bg_marker_clear   "$C" && bad "A8: bg_marker_clear must stay unchanged and REJECT: $C" || ok
done
bg_marker_approve "VERDICT: BLOCK" && bad "A8: VERDICT: BLOCK is not an approve" || ok
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" 'review[bot]' "https://x/c9001" "BLOCK — one blocking finding"
  cmt 9002 "$T_LATE"  'review[bot]' "https://x/c9002" "$(ap_body "APPROVE")"; } > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && ok || bad "A8: a BARE APPROVE by the blocker must still NOT clear (rc=$BGRC out=$BGOUT)"

# ══ E. WHO may clear, and on WHICH head ═════════════════════════════════════
# THE LIVE HAZARD (r1 review of this PR). `bin/review-prs.sh` ends its review
# body with `VERDICT: APPROVE` and posts it with `gh pr review --approve` on
# whatever token the lane armed; `gh_default_auth_for_project … || true` falls
# back to the fleet PAT, whose login is `operator` — the same login the operator's own
# comments carry. Live on every OS repo today: project-3 #355, project-1 #691,
# project-2 #525/#526 all carry `operator`-authored machine APPROVEs. So a
# verdict-line clear scoped by LOGIN ALONE hands the machine reviewer the power
# to clear a PERSON's block, minutes after that person posts it — which is
# exactly what the rule this ticket replaced existed to prevent.
#
# TWO BINDINGS CLOSE IT, and section A above pins that neither breaks the
# deadlock fix:
#   1. the approving login must be a MACHINE account — `[bot]` suffix or REST's
#      `app/` spelling. GitHub refuses `[` and `]` in a user name, so a person's
#      account cannot wear that suffix, and a human's BLOCK therefore has no
#      machine twin whose verdict could drop it (the drop is per login).
#   2. the approving body must NAME THIS HEAD. Every harness review lane writes
#      the head into its own footer, so a verdict is bound to the head it
#      adjudicated and a stale or chatty one clears nothing.

E_HUMAN=operator
# The live review-prs footer, in shape (bin/review-prs.sh RP_MARKER + POSTED).
rp_body() { printf '%s\n\n---\n_Automated harness review (Fable) of %s. Static review — no build run._' "$1" "${2:-$HEAD}"; }

# E1 — the hazard end to end, through the REVIEWS source the machine reviewer
# really posts to: a person blocks this head in a PR comment, and five minutes
# later the review lane approves the SAME head under the SAME login. The
# person's block must still hold.
fresh "$T_HEAD_OLD"
cmt 9001 "$T_BLOCK" "$E_HUMAN" "https://x/c9001" "BLOCK — do not merge, waiting on the RLS migration" > "$T/prcomments"
cmt 7001 "$T_LATE" "$E_HUMAN" "https://x/r7001" "$(rp_body "No blocking findings in the diff.

TIER: 1
VERDICT: APPROVE")" > "$T/reviews"
scan
[ "$BGRC" = 1 ] && grep -q "$E_HUMAN" <<<"$BGOUT" && grep -q 9001 <<<"$BGOUT" && ok \
  || bad "E1: a machine APPROVE under the human blocker's own login must NOT clear that block (rc=$BGRC out=$BGOUT)"

# E2 — …and the same body posted as a PR COMMENT rather than a review is the
# same answer. The source a verdict arrives on is not a credential.
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" "$E_HUMAN" "https://x/c9001" "BLOCK — hold this, the migration is not applied"
  cmt 9002 "$T_LATE"  "$E_HUMAN" "https://x/c9002" "$(rp_body "VERDICT: APPROVE")"; } > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && grep -q 9001 <<<"$BGOUT" && ok \
  || bad "E2: a human-login terminal verdict must clear nothing, on either source (rc=$BGRC out=$BGOUT)"

# E3 — a mixed thread: the machine's head-bound verdict clears ITS OWN block and
# leaves the person's standing. This is the whole rule in one case.
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" "$E_HUMAN"    "https://x/c9001" "BLOCK — waiting on the RLS migration"
  cmt 9002 "$T_BLOCK" 'review[bot]' "https://x/c9002" "VERDICT: BLOCK — a finding of its own"
  cmt 9003 "$T_LATE"  'review[bot]' "https://x/c9003" "$(ap_body "VERDICT: APPROVE")"; } > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && grep -q "$E_HUMAN" <<<"$BGOUT" && grep -q 9001 <<<"$BGOUT" && ok \
  || bad "E3: the bot's verdict may clear its own block only — the person's must stand (rc=$BGRC out=$BGOUT)"

# E4 — a machine verdict that NAMES NO HEAD clears nothing. A bot comment that
# merely ends in the verdict vocabulary is not an adjudication of this head.
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" 'review[bot]' "https://x/c9001" "VERDICT: BLOCK — one blocking finding"
  cmt 9002 "$T_LATE"  'review[bot]' "https://x/c9002" "VERDICT: APPROVE"; } > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && grep -q 9001 <<<"$BGOUT" && ok \
  || bad "E4: a terminal verdict naming no head must not clear (rc=$BGRC out=$BGOUT)"

# E5 — …and one naming ANOTHER head clears nothing either: a verdict is a fact
# about one sha, which is the rule the conductor's own head-bound review obeys.
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" 'review[bot]' "https://x/c9001" "VERDICT: BLOCK — one blocking finding"
  cmt 9002 "$T_LATE"  'review[bot]' "https://x/c9002" "$(ap_body "VERDICT: APPROVE" "$HEAD2")"; } > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && grep -q 9001 <<<"$BGOUT" && ok \
  || bad "E5: a verdict bound to ANOTHER head must not clear this one (rc=$BGRC out=$BGOUT)"

# E6 — an unreadable head (empty, or too short to identify a commit) FAILS
# CLOSED: nothing clears, the block stands. The dangerous direction is the one
# that merges.
# bg_scan is called DIRECTLY here: the scan() helper above defaults an empty
# head back to $HEAD, and the empty one is precisely the case under test.
fresh "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" 'review[bot]' "https://x/c9001" "VERDICT: BLOCK — one blocking finding"
  cmt 9002 "$T_LATE"  'review[bot]' "https://x/c9002" "$(ap_body "VERDICT: APPROVE")"; } > "$T/prcomments"
for H in "" abc zzzzzzzzzzzz; do
  BGOUT=$(bg_scan "$SLUG" "$PR" "$PRURL" "$H"); BGRC=$?
  [ "$BGRC" = 1 ] && grep -q 9001 <<<"$BGOUT" && ok \
    || bad "E6: an unreadable head [$H] must fail closed, not clear (rc=$BGRC out=$BGOUT)"
done

# E7 — bg_bot_login: the machine accounts, and every human spelling near them.
for L in 'cromford[bot]' 'review[bot]' 'app/cromford' 'coderabbitai[bot]'; do
  bg_bot_login "$L" && ok || bad "E7: bg_bot_login must accept: $L"
done
for L in operator operator-bot bot robot 'bot]' '[bot' 'operator[bot ' - "" 'app' 'myapp/x'; do
  bg_bot_login "$L" && bad "E7: bg_bot_login must REJECT: [$L]" || ok
done

# E8 — bg_verdict_clears is the whole predicate: vocabulary, machine login and
# this head, in one seam the six lanes cannot forget to call.
FULL=aaaaaaaa1111cccccccc2222dddddddd3333eeee
bg_verdict_clears "$(ap_body "VERDICT: APPROVE")" 'review[bot]' "$HEAD" && ok \
  || bad "E8: a head-bound machine verdict must clear"
bg_verdict_clears "$(rr_body "VERDICT: APPROVE" "$FULL")" 'review[bot]' "$FULL" && ok \
  || bad "E8: the full-sha footer spelling must clear"
bg_verdict_clears "$(rr_body "VERDICT: APPROVE" "$FULL")" 'review[bot]' "${FULL:0:8}" && ok \
  || bad "E8: a caller that hands over a short head prefix must still clear"
bg_verdict_clears "$(ap_body "VERDICT: APPROVE" "$(tr 'a-f' 'A-F' <<<"$HEAD")")" 'review[bot]' "$HEAD" && ok \
  || bad "E8: the head match must not turn on the sha's case"
bg_verdict_clears "$(ap_body "VERDICT: APPROVE")" "$E_HUMAN" "$HEAD" \
  && bad "E8: a human login must clear nothing" || ok
bg_verdict_clears "$(ap_body "APPROVE")" 'review[bot]' "$HEAD" \
  && bad "E8: a BARE approve must clear nothing" || ok
bg_verdict_clears "$(ap_body "BLOCK — still missing

VERDICT: APPROVE")" 'review[bot]' "$HEAD" \
  && bad "E8: a body that still names a block must clear nothing" || ok
bg_verdict_clears "VERDICT: APPROVE" 'review[bot]' "$HEAD" \
  && bad "E8: a verdict naming no head must clear nothing" || ok
bg_verdict_clears "$(ap_body "VERDICT: APPROVE" "$HEAD2")" 'review[bot]' "$HEAD" \
  && bad "E8: a verdict bound to another head must clear nothing" || ok
bg_verdict_clears "$(ap_body "VERDICT: APPROVE")" 'review[bot]' "" \
  && bad "E8: an empty head must clear nothing" || ok
bg_verdict_clears "$(ap_body "VERDICT: APPROVE")" 'review[bot]' "zzzzzzzzzzzz" \
  && bad "E8: a head that is not a sha must clear nothing" || ok

# ══ B. bg_head_time reads REST, and never GraphQL ═══════════════════════════

# B1 — the whole gate runs with every GraphQL call wired to fail, and still
# answers. The stub records any it sees; there must be none.
fresh "$T_HEAD_OLD"
cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK, one blocking finding" > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && ok || bad "B1: the gate must still answer with GraphQL unavailable (rc=$BGRC out=$BGOUT)"
[ -s "$T/graphql-calls.txt" ] && bad "B1: the gate made a GraphQL call: $(cat "$T/graphql-calls.txt")" || ok
grep -q "api repos/$SLUG/pulls/$PR/commits" "$T/gh-calls.txt" && ok \
  || bad "B1: the head time must be read from the REST commits endpoint: $(cat "$T/gh-calls.txt")"
grep -q -- "--paginate" "$T/gh-calls.txt" && ok || bad "B1: the commits read must paginate"

# B2 — the source file says so too, which is the ticket's own acceptance line.
grep -q 'gh pr view' "$DIR/bin/lib/block-gate.sh" \
  && bad "B2: bin/lib/block-gate.sh still contains a 'gh pr view' read" || ok

# B3 — THE MAX ACROSS AN UNORDERED, MULTI-PAGE COMMITS ANSWER. `gh api
# --paginate -q` runs the jq program once per PAGE, so a jq-side `| max` answers
# one line per page and the "newest" becomes whichever page came last. The
# answer below is what the REST read really prints for a 4-commit PR whose
# commits are not in date order; the newest is 18:48, in the middle.
fresh "$T_HEAD_OLD"
printf '%s\n' 2026-09-17T18:41:00Z 2026-09-17T18:39:00Z \
              2026-09-17T18:48:00Z 2026-09-17T18:44:00Z > "$T/commits"
HT=$(bg_head_time "$SLUG" "$PR"); HTRC=$?
[ "$HTRC" = 0 ] && [ "$HT" = 2026-09-17T18:48:00Z ] && ok \
  || bad "B3: the newest date across an unordered commits answer must be 18:48 (rc=$HTRC got [$HT])"
# …and the gate that USES it: a BLOCK at 18:47 is OLDER than that head, so it
# does not gate. A per-page max would have answered 18:44 and refused the merge.
cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK, one blocking finding" > "$T/prcomments"
scan
[ "$BGRC" = 0 ] && ok || bad "B3: a BLOCK older than the true newest commit must not gate (rc=$BGRC out=$BGOUT)"

# B4 — a FAILED commits read is still rc 2 'head-time'. Never rc 0.
fresh "$T_HEAD_OLD"; touch "$T/fail-commits"
cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK" > "$T/prcomments"
scan
[ "$BGRC" = 2 ] && [ "$BGOUT" = head-time ] && ok \
  || bad "B4: a failed commits read must answer rc 2 'head-time' (rc=$BGRC out=$BGOUT)"

# B5 — an answer that is NOT a date is a failed read, not a time. A rate-limited
# gh has answered an empty string and a line of prose before (#768).
for A in "" "null" "rate limit exceeded" "-"; do
  fresh "$T_HEAD_OLD"
  printf '%s\n' "$A" > "$T/commits"
  bg_head_time "$SLUG" "$PR" >/dev/null 2>&1 \
    && bad "B5: bg_head_time must refuse a non-date answer: [$A]" || ok
  cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK" > "$T/prcomments"
  scan
  [ "$BGRC" = 2 ] && ok || bad "B5: a non-date head time must be rc 2, never rc 0 (answer [$A], rc=$BGRC)"
done

# ══ C. a gate that refuses the same thing K times says so ONCE, out loud ═════

# awk, not `grep -c`: grep exits 1 on an empty file, and `|| echo 0` after a
# `grep -c` that already printed 0 prints it twice.
alerts() { awk 'END{print NR}' "$T/alerts.txt" 2>/dev/null; }

# C1 — five refusals are silent; the sixth alerts exactly once; the next two
# are silent again. (K=6 at the conductor's 5-minute tick is ~30 minutes.)
fresh "$T_HEAD_OLD"; touch "$T/fail-commits"
cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK" > "$T/prcomments"
for i in 1 2 3 4 5; do
  scan
  [ "$BGRC" = 2 ] || bad "C1: tick $i must still refuse (rc=$BGRC)"
done
[ "$(alerts)" = 0 ] && ok || bad "C1: five consecutive refusals must be silent, got: $(cat "$T/alerts.txt")"
scan
[ "$(alerts)" = 1 ] && ok || bad "C1: the sixth refusal must raise exactly one alert, got: $(cat "$T/alerts.txt")"
grep -q "head-time" "$T/alerts.txt" && ok || bad "C1: the alert must name the refusal reason: $(cat "$T/alerts.txt")"
grep -q "$SLUG#$PR" "$T/alerts.txt" && ok || bad "C1: the alert must name the PR: $(cat "$T/alerts.txt")"
grep -q "${HEAD:0:8}" "$T/alerts.txt" && ok || bad "C1: the alert must name the head: $(cat "$T/alerts.txt")"
grep -q " 6 consecutive " "$T/alerts.txt" && ok || bad "C1: the alert must name the count: $(cat "$T/alerts.txt")"
scan; scan
[ "$(alerts)" = 1 ] && ok || bad "C1: it must not repeat while the reason and head hold, got: $(cat "$T/alerts.txt")"

# C2 — a NEW head is a new condition: the count restarts and it alerts again.
: > "$T/alerts.txt"
for i in 1 2 3 4 5; do scan "$HEAD2"; done
[ "$(alerts)" = 0 ] && ok || bad "C2: a new head must restart the count, got: $(cat "$T/alerts.txt")"
scan "$HEAD2"
[ "$(alerts)" = 1 ] && grep -q "${HEAD2:0:8}" "$T/alerts.txt" && ok \
  || bad "C2: the new head must alert on its own sixth refusal: $(cat "$T/alerts.txt")"

# C3 — a clean scan resets everything: the gate stopped refusing.
: > "$T/alerts.txt"; rm -f "$T/fail-commits"
: > "$T/prcomments"
scan
[ "$BGRC" = 0 ] && ok || bad "C3: the clean scan must answer rc 0 (rc=$BGRC out=$BGOUT)"
[ "$(alerts)" = 0 ] && ok || bad "C3: a clean scan must not alert: $(cat "$T/alerts.txt")"
touch "$T/fail-commits"
cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK" > "$T/prcomments"
for i in 1 2 3 4 5; do scan; done
[ "$(alerts)" = 0 ] && ok || bad "C3: the streak must have restarted after the clean scan: $(cat "$T/alerts.txt")"

# C4 — a DIFFERENT blocking comment is a different condition, not a longer
# streak of the first one. Five blocks by c9001 then five by c9003 is silent.
fresh "$T_HEAD_OLD"
cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK" > "$T/prcomments"
for i in 1 2 3 4 5; do scan; [ "$BGRC" = 1 ] || bad "C4: tick $i must refuse (rc=$BGRC)"; done
cmt 9003 "$T_LATE" reviewer-b "https://x/c9003" "BLOCK — a second finding" >> "$T/prcomments"
for i in 1 2 3 4 5; do scan; done
[ "$(alerts)" = 0 ] && ok || bad "C4: a different blocking comment must restart the count: $(cat "$T/alerts.txt")"
scan
[ "$(alerts)" = 1 ] && grep -q "blocks head" "$T/alerts.txt" && ok \
  || bad "C4: the sixth refusal of the NEW blocker must alert, naming it: $(cat "$T/alerts.txt")"

# C5 — THE ALERT MUST NOT LEAK INTO THE GATE'S ANSWER. Every lane reads this as
# `out=$(bg_scan …)` and splits the answer on tabs; the stub alerter above
# prints a line on stdout on purpose.
fresh "$T_HEAD_OLD"
cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK" > "$T/prcomments"
for i in 1 2 3 4 5 6; do scan; done
[ "$(alerts)" -ge 1 ] && ok || bad "C5: the alert must have fired for this case"
[ "$BGOUT" = "$(printf 'https://x/c9001\treviewer-h\t%s\t9001' "$T_BLOCK")" ] && ok \
  || bad "C5: the alerter's stdout leaked into the gate's answer: [$BGOUT]"

# C6 — K is a knob, and a box with no lane-alert.sh installed must not fail.
fresh "$T_HEAD_OLD"
cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK" > "$T/prcomments"
BLOCK_GATE_STREAK_K=2 scan
[ "$(alerts)" = 0 ] && ok || bad "C6: one refusal must not alert at K=2: $(cat "$T/alerts.txt")"
BLOCK_GATE_STREAK_K=2 scan
[ "$(alerts)" = 1 ] && ok || bad "C6: the second refusal must alert at K=2: $(cat "$T/alerts.txt")"
fresh "$T_HEAD_OLD"
cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK" > "$T/prcomments"
chmod -x "$T/h/bin/lane-alert.sh"
for i in 1 2 3 4 5 6 7; do scan; done
[ "$BGRC" = 1 ] && ok || bad "C6: a box with no lane-alert.sh must still gate normally (rc=$BGRC)"
chmod +x "$T/h/bin/lane-alert.sh"

# ══ D. the real PR #728 thread, replayed ════════════════════════════════════
# 04:33:22Z BLOCK and 07:51:11Z VERDICT: APPROVE, both from cromford[bot],
# both newer than the head's newest commit author date — the exact 7h40m hold.
# AT #728's REAL HEAD, because the clear is head-bound: the 07:51Z re-review's
# own footer names 94e6bf9147b01324eb199090da846eaca46293f9, and that is the
# binding under test. The 04:11:35Z comment in the fixture is @operator's and
# carries no BLOCK marker, so the only blocker in the thread is the bot's.
PR728_HEAD=94e6bf9147b01324eb199090da846eaca46293f9
fresh 2026-09-20T04:11:16Z
cp "$DIR/tests/fixtures/bh-1131-pr728-thread.tsv" "$T/prcomments"
scan "$PR728_HEAD"
[ "$BGRC" = 0 ] && ok \
  || bad "D: replaying PR #728's real thread must answer rc 0 (rc=$BGRC out=$BGOUT)"
# …and with the 07:51Z re-review removed, the 04:33Z BLOCK still holds it: the
# fixture is not passing because the gate has stopped reading it.
grep -v '^5748502185' "$DIR/tests/fixtures/bh-1131-pr728-thread.tsv" > "$T/prcomments"
scan "$PR728_HEAD"
[ "$BGRC" = 1 ] && grep -q 5747640960 <<<"$BGOUT" && ok \
  || bad "D: without the APPROVE the real BLOCK must still gate (rc=$BGRC out=$BGOUT)"
# …and the SAME thread judged against any OTHER head does not clear: the
# fixture's verdict is bound to 94e6bf91 and to nothing else.
cp "$DIR/tests/fixtures/bh-1131-pr728-thread.tsv" "$T/prcomments"
scan "$HEAD"
[ "$BGRC" = 1 ] && grep -q 5747640960 <<<"$BGOUT" && ok \
  || bad "D: #728's verdict must not clear a different head (rc=$BGRC out=$BGOUT)"

echo "block-gate.bh-1131: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
