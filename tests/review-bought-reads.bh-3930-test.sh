#!/bin/bash
# tests/review-bought-reads.bh-3930-test.sh — BH-3938 (BH-3930 child 2): the
# real body of review_bought, the three D1 reads that answer "has a verdict
# already been paid for on exactly this head?".
#
# Driven through the REAL bin/jobs-client.sh (_jobs_req, pr_attempt_list) over a
# fake curl that serves one fixture per worker route and records every request,
# so "stop at the first hit" and "zero requests with dedupe off" are assertions
# about traffic. The fixtures are the shapes the routes emit:
#   /api/pr-attempts       {attempts:[{sha:"<sha> <WORD> <epoch>"}],count}
#   /api/verdicts          {rows:[{head_sha,verdict,source,created_at}]} newest first
#   /api/verdict/history   {rounds:[{verdict,reviewed_sha,source,detail,created_at}]} oldest first
# A missing fixture answers what the route answers with nothing to say (the
# attempts list: a 200 with no rows; verdicts and history: 404, a real miss), a
# <fixture>.code file forces a status (503 = an outage).
#
#   A1  rrverdict at the head -> mc-rereview, one request
#   A2  /api/verdicts at the head -> lead | box | human, history never asked
#   A3  history review-prs round -> covers, with and without --except-builder
#   A4  source-less / run-build history round -> covers unless --except-builder
#   A5  adversarial negatives: another sha, a 12-hex prefix, uppercase, a
#       settled:false round, a backfill source, the sha in rrverdict field 2
#   A6  an outage with no hit is rc 1, never a miss; a hit beats an outage
#   A7  REVIEW_DEDUPE=0 -> rc 2 with ZERO requests
#   A8  REVIEW_DEDUPE_REBUY_AFTER: newer rows only; an unparseable date is old
#   A9  --class lead: /api/verdicts only, lead/human only
#   A10n word normalisation; a non-verdict word is skipped
#   N1  no jobs client loaded -> rc 1, nothing written
#
# Run from anywhere: bash tests/review-bought-reads.bh-3930-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# No clock read: every fixture date and re-buy epoch below is a fixed literal.
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to drive the reads"; exit 1; }
unset REVIEW_DEDUPE REVIEW_DEDUPE_REBUY_AFTER HARNESS_ENV_DIR RB_SOURCE RB_WORD RB_CLASS

LIB="$DIR/bin/lib/review-bought.sh"
S=0123456789abcdef0123456789abcdef01234567
P=fedcba9876543210fedcba9876543210fedcba98
SU=$(printf '%s' "$S" | tr a-f A-F)
S12=${S:0:12}
OLD="2025-10-01T10:00:00.000Z"     # every fixture row is this old
OLD_E=1759312800                   # = $OLD as an epoch
BEFORE=1759000000                  # a rebuy epoch older than every row
AFTER=1760000000                   # newer than every row (rrverdict lines use 1759500000)

mkdir -p "$T/fakebin" "$T/h/bin/lib/jobs" "$T/fix"
FIX="$T/fix"; REQ="$T/req.log"; : > "$REQ"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do case "$1" in -X) METHOD="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s\t%s\n' "$METHOD" "$URL" >> "$REQ_SINK"
case "$URL" in
  *"/api/pr-attempts?"*)       F="$FIX/attempts" ;;
  *"/api/verdict/history?"*)   F="$FIX/history" ;;
  *"/api/verdicts?"*)          F="$FIX/verdicts" ;;
  *)                           F="" ;;
esac
if [ -n "$F" ] && [ -f "$F" ]; then
  CODE=200; [ -f "$F.code" ] && CODE=$(cat "$F.code")
  printf '%s\n%s\n' "$(cat "$F")" "$CODE"; exit 0
fi
if [ -n "$F" ] && [ -f "$F.code" ]; then printf '{"error":"down"}\n%s\n' "$(cat "$F.code")"; exit 0; fi
# the attempts LIST route never 404s (worker/jobs/src/routes/pr-state.js): no rows is a 200
[ "$F" = "$FIX/attempts" ] && { printf '{"attempts":[],"count":0}\n200\n'; exit 0; }
printf '{"error":"not found"}\n404\n'
STUB
chmod +x "$T/fakebin/curl"

reset() { rm -f "$FIX"/*; : > "$REQ"; }
# fixtures — each takes JSON objects already shaped like a row
att()  { printf '%s' "$1" | jq -c '{attempts: [.[] | {sha: .}], count: length}' > "$FIX/attempts"; }
ver()  { printf '%s' "$1" > "$FIX/verdicts.rows"; jq -c '{rows: .}' "$FIX/verdicts.rows" > "$FIX/verdicts"; rm -f "$FIX/verdicts.rows"; }
his()  { printf '%s' "$1" > "$FIX/history.rows"; jq -c '{rounds: .}' "$FIX/history.rows" > "$FIX/history"; rm -f "$FIX/history.rows"; }
down() { echo 503 > "$FIX/$1.code"; }
vrow() { jq -nc --arg h "$1" --arg w "$2" --arg s "$3" --arg c "${4:-$OLD}" '{id:1,repo:"o/r",pr:7,head_sha:$h,verdict:$w,source:$s,created_at:$c}'; }
# hrow <sha> <word> <source-json> [detail] — detail defaults to {"reviewed_sha":<sha>}
hrow() { local d="${4:-}"; [ -n "$d" ] || d=$(jq -nc --arg h "$1" '{reviewed_sha:$h}')
  jq -nc --arg h "$1" --arg w "$2" --argjson s "$3" --arg d "$d" --arg c "$OLD" \
    '{verdict:$w,reviewed_sha:$h,source:$s,detail:$d,created_at:$c,job_id:"j1"}'; }

# rb <args...> — one review_bought call with the REAL client loaded; prints
# rc|stdout|RB_SOURCE|RB_WORD|RB_CLASS (the TAB in stdout shown as '>')
rb() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box FIX="$FIX" JOBS_RETRIES=0 REQ_SINK="$REQ"
    [ -n "${DEDUPE_V-}" ] && export REVIEW_DEDUPE="$DEDUPE_V"
    [ -n "${REBUY_V-}" ] && export REVIEW_DEDUPE_REBUY_AFTER="$REBUY_V"
    # shellcheck source=/dev/null
    . "$T/h/bin/jobs-client.sh" || exit 9
    # shellcheck source=/dev/null
    . "$LIB" || exit 9
    RB_SOURCE=x; RB_WORD=x; RB_CLASS=x
    review_bought o/r 7 "$@" > "$T/rb.out"; rc=$?
    out=$(cat "$T/rb.out")
    printf '%s|%s|%s|%s|%s' "$rc" "${out//$'\t'/>}" "$RB_SOURCE" "$RB_WORD" "$RB_CLASS" )
}
nreq() { local n; n=$(grep -c "$1" "$REQ" 2>/dev/null); printf '%s' "${n:-0}"; }
# rb1 — rb, then the number of requests that one call made
rb1() { local o; : > "$REQ"; o=$(rb "$@"); printf '%s|%s' "$o" "$(wc -l < "$REQ" | tr -d ' ')"; }
want() { # want <label> <got> <expected>
  [ "$2" = "$3" ] && ok || bad "$1: got '$2', want '$3'"
}

# --- A1. rrverdict at the head -----------------------------------------------
reset; att "[\"$S APPROVE 1759500000\"]"; ver "[$(vrow "$S" MERGE lead)]"; his "[$(hrow "$S" APPROVE '"review-prs"')]"
want A1 "$(rb1 "$S")" "0|mc-rereview>APPROVE|mc-rereview|APPROVE|approve|1"
[ "$(nreq /api/verdicts)" = 0 ] && [ "$(nreq /api/verdict/history)" = 0 ] && ok || bad "A1 a later read ran after the first hit: $(cut -f2 "$REQ" | tr '\n' ' ')"
# several rrverdict lines: the newest epoch wins
reset; att "[\"$S APPROVE 1759500000\", \"$S BLOCK 1759600000\", \"$S MERGE 1759400000\"]"
want "A1 newest rrverdict" "$(rb "$S")" "0|mc-rereview>BLOCK|mc-rereview|BLOCK|block"

# --- A2. /api/verdicts at the head --------------------------------------------
for src in lead box; do
  reset; ver "[$(vrow "$S" MERGE "$src")]"; his "[$(hrow "$S" APPROVE '"review-prs"')]"
  want "A2 $src" "$(rb1 "$S")" "0|$src>MERGE|$src|MERGE|approve|2"
  want "A2 $src history asked" "$(nreq /api/verdict/history)" 0
done
reset; ver "[$(vrow "$S" BLOCK human)]"
want "A2 human BLOCK" "$(rb "$S")" "0|human>BLOCK|human|BLOCK|block"
want "A2 human history asked" "$(nreq /api/verdict/history)" 0
# newest first: the first matching row wins
reset; ver "[$(vrow "$S" BLOCK lead),$(vrow "$S" MERGE lead)]"
want "A2 newest verdicts row" "$(rb "$S")" "0|lead>BLOCK|lead|BLOCK|block"
# the query names the repo and the pr, URI-encoded, and no head=
reset; ver "[$(vrow "$S" MERGE lead)]"; rb "$S" >/dev/null
grep -q $'GET\thttps://jobs.invalid/api/verdicts?repo=o%2Fr&pr=7$' "$REQ" && ok || bad "A2 verdicts query: $(grep verdicts "$REQ" | head -1)"

# --- A3. history review-prs round ----------------------------------------------
for x in "" --except-builder; do
  reset; his "[$(hrow "$S" APPROVE '"review-prs"')]"
  want "A3 review-prs $x" "$(rb "$S" $x)" "0|review-prs>APPROVE|review-prs|APPROVE|approve"
done
reset; his "[$(hrow "$S" APPROVE '"review-prs"')]"; rb "$S" >/dev/null
grep -q $'GET\thttps://jobs.invalid/api/verdict/history?pr=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F7$' "$REQ" \
  && ok || bad "A3 history query: $(grep history "$REQ" | head -1)"
# oldest first: the LAST matching round wins
reset; his "[$(hrow "$S" APPROVE '"review-prs"'),$(hrow "$S" BLOCK '"review-prs"')]"
want "A3 newest round" "$(rb "$S")" "0|review-prs>BLOCK|review-prs|BLOCK|block"
# a detail that is not JSON is {} -> settled, covers (job_verdict_covers' rule)
reset; his "[$(hrow "$S" APPROVE '"review-prs"' 'not json')]"
want "A3 unparseable detail" "$(rb "$S")" "0|review-prs>APPROVE|review-prs|APPROVE|approve"

# --- A4. the builder's own round ------------------------------------------------
for s in null '"run-build"' '"-"' '""'; do
  reset; his "[$(hrow "$S" APPROVE "$s")]"
  want "A4 source $s plain" "$(rb "$S")" "0|run-build>APPROVE|run-build|APPROVE|approve"
  want "A4 source $s --except-builder" "$(rb "$S" --except-builder)" "2||||"
done

# --- A5. adversarial negatives: every one is a miss ------------------------------
neg() { want "A5 $1" "$(rb "$S" ${2:-})" "2||||"; }
reset; att "[\"$P APPROVE 1759500000\"]"; ver "[$(vrow "$P" MERGE lead)]"; his "[$(hrow "$P" APPROVE '"review-prs"')]"; neg "rows only on another sha"
reset; att "[\"$S12 APPROVE 1759500000\"]"; ver "[$(vrow "$S12" MERGE lead)]"; his "[$(hrow "$S12" APPROVE '"review-prs"')]"; neg "rows on the 12-hex prefix"
reset; att "[\"$SU APPROVE 1759500000\"]"; ver "[$(vrow "$SU" MERGE lead)]"; his "[$(hrow "$SU" APPROVE '"review-prs"')]"; neg "rows on the uppercase sha"
reset; his "[$(hrow "$S" APPROVE '"review-prs"' '{"settled":false}')]"; neg "a settled:false round"
reset; his "[$(hrow "$S" APPROVE '"review-rescue-backfill"')]"; neg "a review-rescue-backfill round"
reset; att "[\"$P $S 1\"]"; neg "the sha only in rrverdict field 2"
reset; his "[$(hrow "$S" APPROVE null)]"; neg "a builder round with --except-builder" --except-builder
reset; ver "[$(vrow "$S" MERGE box)]"; neg "a box row under --class lead" "--class lead"
# a settled:false round AFTER a settled one does not hide the settled one
reset; his "[$(hrow "$S" APPROVE '"review-prs"'),$(hrow "$S" BLOCK '"review-prs"' '{"settled":false}')]"
want "A5 provisional newest round" "$(rb "$S")" "0|review-prs>APPROVE|review-prs|APPROVE|approve"

# --- A6. outages ------------------------------------------------------------------
reset; down verdicts
want "A6 verdicts 503, rest 404" "$(rb "$S")" "1||||"
reset; down attempts; ver "[$(vrow "$S" MERGE lead)]"
want "A6 attempts 503, verdicts hit" "$(rb "$S")" "0|lead>MERGE|lead|MERGE|approve"
reset; echo 'not json' > "$FIX/verdicts"
want "A6 verdicts 200 not json" "$(rb "$S")" "1||||"
reset; echo '{"error":"x"}' > "$FIX/history"
want "A6 history 200 without rounds" "$(rb "$S")" "1||||"
reset; down history
want "A6 history 503" "$(rb "$S")" "1||||"
reset; down attempts
want "A6 attempts 503" "$(rb "$S")" "1||||"
reset; echo '{"x":1}' > "$FIX/attempts"
want "A6 attempts 200 bad shape" "$(rb "$S")" "1||||"
# all three answered with nothing: a measured miss
reset; att '[]'; ver '[]'; his '[]'
want "A6 all empty" "$(rb "$S")" "2||||"
reset
want "A6 all 404" "$(rb "$S")" "2||||"
# no JOBS_URL: not configured is a failure, never a miss
reset; att "[\"$S APPROVE 1759500000\"]"
got=$( ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret REQ_SINK="$REQ" FIX="$FIX"
         . "$T/h/bin/jobs-client.sh" || exit 9; unset JOBS_URL; . "$LIB"; review_bought o/r 7 "$S"; echo "|$?" ) 2>/dev/null)
want "A6 JOBS_URL unset" "$got" "|1"

# --- A7. the kill switch -----------------------------------------------------------
reset; att "[\"$S APPROVE 1759500000\"]"; ver "[$(vrow "$S" MERGE lead)]"; his "[$(hrow "$S" APPROVE '"review-prs"')]"
for c in "" "--class lead"; do
  : > "$REQ"
  want "A7 REVIEW_DEDUPE=0 $c" "$(DEDUPE_V=0 rb "$S" $c)" "2||||"
  want "A7 requests with REVIEW_DEDUPE=0 $c" "$(wc -l < "$REQ" | tr -d ' ')" 0
done

# --- A8. the operator's re-buy epoch ---------------------------------------------
reset; att "[\"$S APPROVE $OLD_E\"]"; ver "[$(vrow "$S" MERGE lead)]"; his "[$(hrow "$S" APPROVE '"review-prs"')]"
want "A8 rebuy after every row" "$(REBUY_V=$AFTER rb "$S")" "2||||"
want "A8 rebuy before every row" "$(REBUY_V=$BEFORE rb "$S")" "0|mc-rereview>APPROVE|mc-rereview|APPROVE|approve"
reset; ver "[$(vrow "$S" MERGE lead)]"
want "A8 verdicts rebuy before" "$(REBUY_V=$BEFORE rb "$S")" "0|lead>MERGE|lead|MERGE|approve"
want "A8 verdicts rebuy after" "$(REBUY_V=$AFTER rb "$S")" "2||||"
reset; his "[$(hrow "$S" APPROVE '"review-prs"')]"
want "A8 history rebuy before" "$(REBUY_V=$BEFORE rb "$S")" "0|review-prs>APPROVE|review-prs|APPROVE|approve"
want "A8 history rebuy after" "$(REBUY_V=$AFTER rb "$S")" "2||||"
reset; ver "[$(vrow "$S" MERGE lead garbage)]"
want "A8 garbage created_at under rebuy" "$(REBUY_V=$BEFORE rb "$S")" "2||||"
want "A8 garbage created_at, rebuy off" "$(rb "$S")" "0|lead>MERGE|lead|MERGE|approve"
reset; att "[\"$S APPROVE\"]"
want "A8 rrverdict no epoch under rebuy" "$(REBUY_V=$BEFORE rb "$S")" "2||||"
want "A8 rrverdict no epoch, rebuy off" "$(rb "$S")" "0|mc-rereview>APPROVE|mc-rereview|APPROVE|approve"
reset; att "[\"$S APPROVE soon\"]"
want "A8 rrverdict epoch 'soon' under rebuy" "$(REBUY_V=$BEFORE rb "$S")" "2||||"
want "A8 not a number rebuy is off" "$(REBUY_V=soon rb "$S")" "0|mc-rereview>APPROVE|mc-rereview|APPROVE|approve"

# --- A9. --class lead ----------------------------------------------------------------
reset; att "[\"$S APPROVE 1759500000\"]"; ver "[$(vrow "$S" MERGE box)]"; his "[$(hrow "$S" APPROVE '"review-prs"')]"
want "A9 lead class, box row" "$(rb1 "$S" --class lead)" "2|||||1"
[ "$(nreq /api/verdicts)" = 1 ] && [ "$(nreq /api/pr-attempts)" = 0 ] && [ "$(nreq /api/verdict/history)" = 0 ] \
  && ok || bad "A9 lead class asked more than /api/verdicts: $(cut -f2 "$REQ" | tr '\n' ' ')"
for src in lead human; do
  reset; ver "[$(vrow "$S" MERGE box),$(vrow "$S" MERGE "$src")]"
  want "A9 lead class, $src row" "$(rb "$S" --class lead)" "0|$src>MERGE|$src|MERGE|approve"
done
reset; ver "[$(vrow "$S" MERGE lead)]"
want "A9 --class review explicit" "$(rb "$S" --class review)" "0|lead>MERGE|lead|MERGE|approve"

# --- A10n. word normalisation ------------------------------------------------------
reset; ver "[$(vrow "$S" MERGE-WITH-NOTES lead)]"
want "A10n MERGE-WITH-NOTES" "$(rb "$S")" "0|lead>MERGE-WITH-NOTES|lead|MERGE-WITH-NOTES|approve"
reset; his "[$(hrow "$S" REQUEST_CHANGES '"review-prs"')]"
want "A10n REQUEST_CHANGES" "$(rb "$S")" "0|review-prs>REQUEST_CHANGES|review-prs|REQUEST_CHANGES|block"
for w in PENDING ERROR approve merge; do
  reset; att "[\"$S $w 1759500000\"]"; ver "[$(vrow "$S" "$w" lead)]"; his "[$(hrow "$S" "$w" '"review-prs"')]"
  want "A10n lone $w" "$(rb "$S")" "2||||"
done
# a non-verdict newest row does not hide an older real one
reset; ver "[$(vrow "$S" PENDING lead),$(vrow "$S" BLOCK lead)]"
want "A10n PENDING then BLOCK" "$(rb "$S")" "0|lead>BLOCK|lead|BLOCK|block"

# --- N1. no jobs client loaded -------------------------------------------------------
E="$T/empty"; mkdir -p "$E"; : > "$REQ"
got=$( ( export PATH="$T/fakebin:$PATH" HARNESS="$E" REQ_SINK="$REQ"
         unset -f _jobs_req pr_attempt_list job_verdict_history 2>/dev/null
         . "$LIB"; RB_WORD=x; review_bought o/r 7 "$S"; printf '|%s|%s' "$?" "$RB_WORD" ) 2>&1)
want "N1 no client" "$got" "|1|"
[ -z "$(ls -A "$E")" ] && [ ! -s "$REQ" ] && ok || bad "N1 no client wrote '$(ls -A "$E")' / requested '$(cat "$REQ")'"
grep -nE '^[^#]*(\.|source)[[:space:]].*jobs-client' "$LIB" && bad "N1 the lib sources the jobs client" || ok

echo "review-bought-reads.bh-3930: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
