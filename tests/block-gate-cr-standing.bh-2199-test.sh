#!/bin/bash
# tests/block-gate-cr-standing.bh-2199-test.sh — a standing non-bot
# CHANGES_REQUESTED review blocks every merge lane (BH-2199, lib half).
#
# THE INCIDENTS. #2158 merged over the lead's CHANGES_REQUESTED because the
# block gate only read review TEXT for a `BLOCK` marker (the review said
# `## BLOCKING`) and treated any head authored after the review as a fix, and
# the only commits after it were `Merge origin/main`. #2196 merged at the very
# head the review named. Nothing on the merge path read the review STATE.
#
# WHAT IS DRIVEN. bin/lib/block-gate.sh, sourced, with a gh stub that runs the
# lib's OWN jq programs (the -q argument) over JSON fixtures shaped like
# GitHub's REST answers, so the reads are exercised as well as the logic.
#   S1  CR at the live head: stands, and bg_scan_read refuses (rc 1)
#   S2  CR at head A, live head B only merged main (own diff identical): stands
#   S3  B changed the PR's own diff: does not stand
#   S4  a later APPROVED / DISMISSED by that reviewer: does not stand
#   S5  a Bot, an App login, the harness review lane's footer, a CONTRIBUTOR:
#       none of them stands
#   S6  a later RESUME / MERGE comment by the same login clears; another
#       login's RESUME does not
#   S7  unreadable reviews: rc 2 `review-states` from bg_scan_read (fail closed)
#   S8  an unreadable or truncated compare: the block stands (fail closed)
#   S9  bg_why names the lead BLOCK and the head it was left on
# Run from anywhere: tests/block-gate-cr-standing.bh-2199-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

FX="$T/fx"; mkdir -p "$FX" "$T/fakebin" "$T/h/logs"
export HARNESS="$T/h" FX GHLOG="$T/gh-calls.txt"
SLUG=o/r; NUM=41; URL="https://github.com/o/r/pull/41"
HA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa   # the head the lead blocked
HB=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb   # a later head

# The stub: every read answers from a fixture file, through the -q program the
# caller passed, exactly as `gh api … -q` would. A `fail-<name>` file makes that
# read exit 1 (a failed gh call).
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GHLOG"
q=""; path=""; prev=""
for a in "$@"; do
  [ "$prev" = -q ] && q="$a"
  case "$a" in repos/*) [ -n "$path" ] || path="$a" ;; esac
  prev="$a"
done
path="${path%%\?*}"
case "$path" in
  repos/o/r/pulls/41/reviews) f=reviews ;;
  repos/o/r/issues/41/comments) f=comments ;;
  repos/o/r/pulls/41) f=pull ;;
  repos/o/r/compare/*) f="compare-${path##*...}" ;;
  repos/o/r/collaborators/*/permission) f="perm-$(basename "$(dirname "$path")")" ;;
  *) exit 0 ;;
esac
# The block gate's older text read of the SAME reviews endpoint has no -X GET;
# it gets an empty thread so only the state read is under test here.
case "$*" in "api repos/o/r/pulls/41/reviews"*) exit 0 ;; esac
[ -f "$FX/fail-$f" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
[ -f "$FX/$f.json" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
if [ -n "$q" ]; then jq -r "$q" "$FX/$f.json"; else cat "$FX/$f.json"; fi
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

# shellcheck source=bin/lib/block-gate.sh
. "$DIR/bin/lib/block-gate.sh" || { echo "cannot source block-gate.sh"; exit 1; }
command -v bg_cr_standing >/dev/null 2>&1 && ok || bad "bg_cr_standing is not defined by bin/lib/block-gate.sh"

# review <id> <login> <type> <assoc> <state> <commit> <time> [body]
review() {
  jq -nc --arg id "$1" --arg l "$2" --arg ty "$3" --arg as "$4" --arg st "$5" --arg c "$6" --arg at "$7" --arg b "${8:-findings}" \
    '{id:($id|tonumber), user:{login:$l, type:$ty}, author_association:$as, state:$st, commit_id:$c,
      submitted_at:$at, html_url:("https://github.com/o/r/pull/41#pullrequestreview-"+$id), body:$b}'
}
reviews() { jq -s . > "$FX/reviews.json"; }
comment() { # comment <id> <login> <time> <body>
  jq -nc --arg id "$1" --arg l "$2" --arg at "$3" --arg b "$4" \
    '{id:($id|tonumber), user:{login:$l}, created_at:$at, html_url:("https://github.com/o/r/pull/41#issuecomment-"+$id), body:$b}'
}
comments() { jq -s . > "$FX/comments.json"; }
# compare <sha> <patch-for-src/a.sh> [extra-file-json] — the PR's OWN diff at
# that head: a three-dot compare against main. Context lines and hunk offsets
# differ between heads on purpose (a main merge shifts them); the +/- lines are
# what the PR itself changed.
compare() {
  local sha="$1" patch="$2" extra="${3:-}"
  jq -nc --arg p "$patch" --argjson x "${extra:-null}" \
    '{files: ([{filename:"src/a.sh", status:"modified", changes:2, sha:"1111", patch:$p}] + (if $x then [$x] else [] end))}' \
    > "$FX/compare-$sha.json"
}
echo '{"number":41,"base":{"ref":"main"}}' > "$FX/pull.json"
PA=$'@@ -10,3 +10,3 @@ ctx one\n ctx\n-old line\n+new line'
PA_SHIFTED=$'@@ -42,3 +42,3 @@ ctx moved by main\n other ctx\n-old line\n+new line'
PB_CHANGED=$'@@ -10,3 +10,4 @@ ctx one\n ctx\n-old line\n+new line\n+the fix the lead asked for'

reset() { rm -f "$FX"/*.json "$FX"/fail-*; : > "$GHLOG"; echo '[]' > "$FX/comments.json"
          echo '{"number":41,"base":{"ref":"main"}}' > "$FX/pull.json"; }
std() { bg_cr_standing "$SLUG" "$NUM" "$URL" "$1" "$(bg_read "repos/$SLUG/issues/$NUM/comments" created_at)"; }

# ── S1: CR at the live head ──────────────────────────────────────────────────
reset
review 501 operator User OWNER CHANGES_REQUESTED "$HA" 2026-09-24T21:09:38Z '## BLOCKING
the proxy sets no actor' | reviews
OUT=$(std "$HA"); RC=$?
[ "$RC" = 0 ] && ok || bad "S1: a lead CHANGES_REQUESTED on the live head must stand (rc=$RC out=$OUT)"
grep -q 'pullrequestreview-501' <<<"$OUT" && ok || bad "S1: the answer must carry the review url (got: $OUT)"
grep -q "operator" <<<"$OUT" && ok || bad "S1: the answer must name the reviewer (got: $OUT)"
grep -q "cr-501@${HA:0:12}" <<<"$OUT" && ok || bad "S1: the id must be cr-<review>@<head12> (got: $OUT)"
SOUT=$(bg_scan_read "$SLUG" "$NUM" "$URL" "$HA"); SRC=$?
[ "$SRC" = 1 ] && ok || bad "S1: bg_scan_read must refuse the merge (rc 1) on a standing CR even with no BLOCK marker (rc=$SRC out=$SOUT)"

# ── S2: CR at A, B only merged main ─────────────────────────────────────────
reset
review 502 operator User COLLABORATOR CHANGES_REQUESTED "$HA" 2026-09-24T19:03:16Z '## BLOCKING' | reviews
compare "$HA" "$PA"; compare "$HB" "$PA_SHIFTED"
OUT=$(std "$HB"); RC=$?
[ "$RC" = 0 ] && ok || bad "S2: a CR on A must still stand on B when B only merged main (rc=$RC out=$OUT)"
grep -q "cr-502@${HA:0:12}" <<<"$OUT" && ok || bad "S2: the id must name the head the lead blocked (got: $OUT)"
grep -q 'compare/main\.\.\.' "$GHLOG" && ok || bad "S2: the own diff must be a three-dot compare against the PR's base (calls: $(cat "$GHLOG"))"
SOUT=$(bg_scan_read "$SLUG" "$NUM" "$URL" "$HB"); SRC=$?
[ "$SRC" = 1 ] && ok || bad "S2: bg_scan_read must refuse B (rc=$SRC out=$SOUT)"

# ── S3: B changed the PR's own diff ─────────────────────────────────────────
reset
review 503 operator User OWNER CHANGES_REQUESTED "$HA" 2026-09-24T19:03:16Z 'fix it' | reviews
compare "$HA" "$PA"; compare "$HB" "$PB_CHANGED"
OUT=$(std "$HB"); RC=$?
[ "$RC" = 1 ] && ok || bad "S3: a head that changed the PR's own diff lifts the CR (rc=$RC out=$OUT)"
compare "$HB" "$PA" '{"filename":"src/new.sh","status":"added","changes":1,"sha":"2222","patch":"@@ -0,0 +1 @@\n+echo hi"}'
OUT=$(std "$HB"); RC=$?
[ "$RC" = 1 ] && ok || bad "S3: a new file in the PR's own diff is a change too (rc=$RC out=$OUT)"

# ── S4: GitHub's own clears ──────────────────────────────────────────────────
reset
{ review 504 operator User OWNER CHANGES_REQUESTED "$HA" 2026-09-24T19:00:00Z
  review 505 operator User OWNER APPROVED "$HA" 2026-09-24T19:30:00Z; } | reviews
OUT=$(std "$HA"); RC=$?
[ "$RC" = 1 ] && ok || bad "S4: a later APPROVED by the same reviewer clears (rc=$RC out=$OUT)"
{ review 506 operator User OWNER DISMISSED "$HA" 2026-09-24T19:00:00Z; } | reviews
OUT=$(std "$HA"); RC=$?
[ "$RC" = 1 ] && ok || bad "S4: a DISMISSED review does not stand (rc=$RC out=$OUT)"
# A COMMENTED review after the CR is not a clear: GitHub keeps the CR standing.
{ review 507 operator User OWNER CHANGES_REQUESTED "$HA" 2026-09-24T19:00:00Z
  review 508 operator User OWNER COMMENTED "$HA" 2026-09-24T19:30:00Z 'one more thought'; } | reviews
OUT=$(std "$HA"); RC=$?
[ "$RC" = 0 ] && ok || bad "S4: a later COMMENTED review does not clear a CR (rc=$RC out=$OUT)"
# Order is by submitted_at, not by the order GitHub listed them.
{ review 510 operator User OWNER APPROVED "$HA" 2026-09-24T19:30:00Z
  review 509 operator User OWNER CHANGES_REQUESTED "$HA" 2026-09-24T19:45:00Z; } | reviews
OUT=$(std "$HA"); RC=$?
[ "$RC" = 0 ] && ok || bad "S4: a CR newer than the reviewer's APPROVE stands (rc=$RC out=$OUT)"

# ── S5: whose CR counts ──────────────────────────────────────────────────────
reset
review 511 some-ci Bot NONE CHANGES_REQUESTED "$HA" 2026-09-24T19:00:00Z | reviews
std "$HA" >/dev/null; [ $? = 1 ] && ok || bad "S5: a Bot's CR must not stand"
review 512 'cromford-reviewer[bot]' User NONE CHANGES_REQUESTED "$HA" 2026-09-24T19:00:00Z | reviews
std "$HA" >/dev/null; [ $? = 1 ] && ok || bad "S5: an App login's CR must not stand"
review 513 operator User OWNER CHANGES_REQUESTED "$HA" 2026-09-24T19:00:00Z "VERDICT: BLOCK

---
_Automated harness review (Fable) of $HA. Static review — no build run._" | reviews
std "$HA" >/dev/null; [ $? = 1 ] && ok || bad "S5: the harness review lane's own CR (its footer) is consumed by that lane, not a lead BLOCK"
review 514 drive-by User CONTRIBUTOR CHANGES_REQUESTED "$HA" 2026-09-24T19:00:00Z | reviews
echo '{"permission":"read"}' > "$FX/perm-drive-by.json"
std "$HA" >/dev/null; [ $? = 1 ] && ok || bad "S5: a reviewer without write access (CONTRIBUTOR, permission read) must not stand"
# A PRIVATE org member is reported as CONTRIBUTOR to a token that cannot see the
# membership; the permission read is what says it is the lead.
review 518 private-lead User CONTRIBUTOR CHANGES_REQUESTED "$HA" 2026-09-24T19:00:00Z | reviews
echo '{"permission":"admin"}' > "$FX/perm-private-lead.json"
std "$HA" >/dev/null; [ $? = 0 ] && ok || bad "S5: a CONTRIBUTOR-reported reviewer WITH write permission (a private org member) stands"
rm -f "$FX/perm-private-lead.json"; touch "$FX/fail-perm-private-lead"
std "$HA" >/dev/null; [ $? = 0 ] && ok || bad "S5: an unreadable permission leaves the CR standing (fail closed)"
review 515 teammate User MEMBER CHANGES_REQUESTED "$HA" 2026-09-24T19:00:00Z | reviews
std "$HA" >/dev/null; [ $? = 0 ] && ok || bad "S5: an org MEMBER's CR stands"

# ── S6: the explicit word ────────────────────────────────────────────────────
reset
review 516 operator User OWNER CHANGES_REQUESTED "$HA" 2026-09-24T19:00:00Z | reviews
comment 901 other-human 2026-09-24T19:10:00Z 'RESUME' | comments
std "$HA" >/dev/null; [ $? = 0 ] && ok || bad "S6: ANOTHER login's RESUME must not clear the reviewer's CR"
{ comment 901 other-human 2026-09-24T19:10:00Z 'RESUME'
  comment 902 operator 2026-09-24T19:20:00Z 'RESUME — lead fix reviewed'; } | comments
std "$HA" >/dev/null; [ $? = 1 ] && ok || bad "S6: the reviewer's own later RESUME clears the CR"
comment 903 operator 2026-09-24T19:20:00Z '**MERGE**' | comments
std "$HA" >/dev/null; [ $? = 1 ] && ok || bad "S6: the reviewer's own later MERGE clears the CR"
comment 904 operator 2026-09-24T18:50:00Z 'RESUME' | comments
std "$HA" >/dev/null; [ $? = 0 ] && ok || bad "S6: a RESUME OLDER than the CR clears nothing"
comment 905 operator 2026-09-24T19:20:00Z 'MERGED by hand? not yet — MERGE_REFUSED stays' | comments
std "$HA" >/dev/null; [ $? = 0 ] && ok || bad "S6: MERGED / MERGE_REFUSED are not the clear word"

# ── S7: unreadable reviews fail closed ───────────────────────────────────────
reset
touch "$FX/fail-reviews"
OUT=$(std "$HA"); RC=$?
[ "$RC" = 2 ] && ok || bad "S7: a failed reviews read must answer rc 2 (rc=$RC out=$OUT)"
SOUT=$(bg_scan_read "$SLUG" "$NUM" "$URL" "$HA"); SRC=$?
[ "$SRC" = 2 ] && [ "$SOUT" = review-states ] && ok || bad "S7: bg_scan_read must answer rc 2 'review-states' (rc=$SRC out=$SOUT)"
# A read that answers something that is not the row shape is not an empty list.
rm -f "$FX/fail-reviews"; echo '"not an array"' > "$FX/reviews.json"
std "$HA" >/dev/null; [ $? = 2 ] && ok || bad "S7: a malformed reviews answer must be rc 2, never 'no reviews'"

# ── S8: the compare fails closed ────────────────────────────────────────────
reset
review 517 operator User OWNER CHANGES_REQUESTED "$HA" 2026-09-24T19:00:00Z | reviews
compare "$HA" "$PA"                       # no compare fixture for B: a 404
std "$HB" >/dev/null; [ $? = 0 ] && ok || bad "S8: an unreadable compare must leave the CR standing"
compare "$HB" "$PB_CHANGED"; touch "$FX/fail-pull"
std "$HB" >/dev/null; [ $? = 0 ] && ok || bad "S8: an unreadable PR base must leave the CR standing"
rm -f "$FX/fail-pull"
jq -nc '{files: [range(0;300) | {filename:("f"+(.|tostring)), status:"modified", changes:1, sha:"x", patch:"+x"}]}' > "$FX/compare-$HB.json"
std "$HB" >/dev/null; [ $? = 0 ] && ok || bad "S8: a truncated compare (300 files) must leave the CR standing"
jq -nc '{files: [{filename:"big.sql", status:"modified", changes:9000, sha:"x"}]}' > "$FX/compare-$HB.json"
std "$HB" >/dev/null; [ $? = 0 ] && ok || bad "S8: a file whose patch GitHub omitted must leave the CR standing"

# ── S9: the refusal names the lead BLOCK ─────────────────────────────────────
W=$(bg_why "https://github.com/o/r/pull/41#pullrequestreview-502	operator	2026-09-24T19:03:16Z	cr-502@${HA:0:12}" "$HB")
grep -q 'standing CHANGES_REQUESTED (lead/human BLOCK)' <<<"$W" && ok || bad "S9: bg_why must name the lead BLOCK (got: $W)"
grep -q "${HA:0:8}" <<<"$W" && grep -q "${HB:0:8}" <<<"$W" && ok || bad "S9: bg_why must name the blocked head and the live head (got: $W)"
grep -q 'only merged main' <<<"$W" && ok || bad "S9: bg_why must say the heads since only merged main (got: $W)"

echo "block-gate-cr-standing.bh-2199-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
