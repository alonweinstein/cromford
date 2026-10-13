#!/bin/bash
# tests/sentry-triage.bh-5620-test.sh — BH-5620 (BH-5611.4): Sentry issues
# become tickets. Drives the REAL bin/sentry-triage.sh in a scratch harness.
#
# The lane's closure is installed with scratch_install_closure. Stubs:
#   - a fake `curl` first on PATH answers the Sentry REST paths from $FXT and
#     logs every call to $FXT/curl.log (JOBS_URL is empty, so the gate reads
#     only flags and never curls);
#   - $H/bin/agent-call.sh records argv and the AGENT_CALL_* env to ac.log,
#     writes $FXT/answer.txt to its out file and exits $FXT/ac.rc;
#   - $H/bin/lane-alert.sh records to alerts.log;
#   - SENTRY_TRIAGE_FIXTURE (sandbox-only seam) defines job_ledger_row/put on
#     $FXT/ledger/<kind>.<key> ($FXT/ledger.rc forces rc 1; put cuts detail at
#     4000 chars, as worker/jobs/src/routes/ledger.js does), lane_role_model /
#     lane_model_ladder (records the role), and gh_rest / gh_rest_comment /
#     gh_rest_issue_list recording to gh.log and answering 201 #9001.
#
#   T1  a new issue with 5 events: one create, ai-build, ledger ticketed/filed,
#       marker and permalink in the body, no em dash
#   T2  the same issue on the next tick: 0 calls, still 1 create (red first)
#   T3  2 events, below the minimum: no call, no ledger row
#   T4  a regressed issue whose row is ticketed: exactly one new pass; an issue
#       first seen regressed gets one pass in total, over two ticks
#   T5  a noise reply: a noise row, never retried; T5b empty reply: failed;
#       T5c rc 1 three ticks: retry 1, 2, then failed; rc 75 keeps attempts
#   T6  the daily cap: 1 create, 1 call, a log line names the cap
#   T7  the kill switch: no API call at all
#   T8  no hard-coded claude-* model id; the route role is stage.sentry-triage
#   T9  ledger outage: 0 calls, 0 creates, one alert
#   T10 hotfix only above the 24h knob; writeback 403 is skipped-403
#   T11 an open issue already carries the marker: healed, 0 calls
#   T12 the lane log lines near the event, only from this box, never a path
#   T13 a failed create leaves `diagnosed`; the next tick files with no call,
#       with THIS issue's tags and log lines even after another issue's call
#   T15 a long answer: the stored detail stays under the worker's 4000-char cut
#       and still files; an unreadable stored diagnosis is failed diagnosis-lost
#   T16 the day call cap SENTRY_TRIAGE_MAX_CALLS_DAY counts noise calls too
#   T5d a comment carries the marker; a marker already on the ticket: no repost
#   T14 the prompt bounds: a long event is cut and keeps its tags; 5 candidates of 600 bytes
#   R   the registry carries the ticket knobs at 3/5/24 and the call cap at 10
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/sentry-triage.bh-5620-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "sentry-triage: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

# The product paths this slice ships (D41).
for f in "$DIR/bin/sentry-triage.sh" "$DIR/bin/lib/sentry-triage.sh" \
         "$DIR/catalog/prompts/sentry-triage.md" "$DIR/catalog/lanes.d/sentry-triage.json" \
         "$DIR/cron/lanes/466-sentry-triage.cron"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

H="$T/h"
export FXT="$T/fx"
mkdir -p "$H/env" "$H/catalog/prompts" "$T/fakebin"
scratch_install_closure bin/sentry-triage.sh "$H" >/dev/null || bad "closure install failed"
cp "$DIR/catalog/prompts/sentry-triage.md" "$H/catalog/prompts/" 2>/dev/null
: > "$H/env/global.env"
rm -f "$H/bin/agent-call.sh" "$H/bin/lane-alert.sh"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
{ printf 'call'; printf ' [%s]' "$@"; env | grep -E '^AGENT_CALL_' | sort | tr '\n' ' '; printf '\n'; } >> "$FXT/ac.log"
case "$6" in @*) cp "${6#@}" "$FXT/prompt.last" 2>/dev/null ;; esac
cat "$FXT/answer.txt" > "$5" 2>/dev/null
exit "$(cat "$FXT/ac.rc" 2>/dev/null || echo 0)"
SH
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
exit 0
SH
chmod +x "$H/bin/agent-call.sh" "$H/bin/lane-alert.sh"

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
out=""; prev=""; m=GET
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; -X) m="$a" ;; esac
  prev="$a"
done
url="${!#}"
printf '%s %s\n' "$m" "$url" >> "$FXT/curl.log"
code=200; body='{}'
case "$url" in
  */projects/*/issues/*) body=$(cat "$FXT/issues.json"); code=$(cat "$FXT/list.code" 2>/dev/null || echo 200) ;;
  */events/latest/*) id=$(printf '%s' "$url" | sed -n 's#.*/issues/\([^/]*\)/events/latest/.*#\1#p')
                     body=$(cat "$FXT/event-$id.json" 2>/dev/null || echo '{}') ;;
  */comments/*) code=$(cat "$FXT/wb.code" 2>/dev/null || echo 201); body='{"detail":"fixture"}' ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
printf '%s' "$code"
exit 0
SH
chmod +x "$T/fakebin/curl"

cat > "$T/fixture.sh" <<'SH'
job_ledger_row() {
  [ "$(cat "$FXT/ledger.rc" 2>/dev/null)" = 1 ] && return 1
  [ -f "$FXT/ledger/$1.$2" ] || return 2
  cat "$FXT/ledger/$1.$2"
}
job_ledger_put() {
  [ "$(cat "$FXT/ledger.rc" 2>/dev/null)" = 1 ] && return 1
  jq -nc --arg s "$3" --arg d "${4:-}" '{status:$s, detail:$d[0:4000]}' > "$FXT/ledger/$1.$2"
}
lane_role_model() { echo "$1" >> "$FXT/roles.log"; echo stub-model; }
lane_model_ladder() { printf '0\tstub-model\tclaude\n'; }
gh_rest() {
  local m=$1 p=$2 f=""; shift 2
  [ "${1:-}" = --input ] && f=$2
  if [ -n "$f" ]; then printf '%s %s %s\n' "$m" "$p" "$(jq -c . "$f")" >> "$FXT/gh.log"
  else printf '%s %s\n' "$m" "$p" >> "$FXT/gh.log"; fi
  case "$m $p" in
    "GET "*/comments) GH_REST_STATUS=200; cat "$FXT/comments.json" 2>/dev/null || echo '[]'; return 0 ;;
  esac
  if [ -f "$FXT/create.code" ]; then GH_REST_STATUS=$(cat "$FXT/create.code"); printf '{"message":"fixture failure"}'; return 75; fi
  GH_REST_STATUS=201
  printf '{"number":9001,"html_url":"https://github.com/example-org/example-repo/issues/9001"}'
}
gh_rest_comment() { printf 'COMMENT %s %s %s\n' "$1" "$2" "$(jq -Rsc . "$3")" >> "$FXT/gh.log"; GH_REST_STATUS=201; }
gh_rest_issue_list() { printf 'LIST %s %s %s %s\n' "$1" "$2" "${3:-}" "${4:-}" >> "$FXT/gh.log"; GH_REST_STATUS=200; cat "$FXT/open.json"; }
SH

NOW=1791676800
DAY=$(date -u -d "@$NOW" +%F)
LOG="$H/logs/sentry-triage.log"

# mkissue <id> <count> [regressed 0|1] [24h events]
mkissue() {
  jq -nc --arg id "$1" --arg c "$2" --argjson r "${3:-0}" --argjson s "${4:-4}" '{
    id: $id, shortId: ("CROMFORD-HARNESS-" + $id), title: ("Example error " + $id),
    permalink: ("https://sentry.example.com/issues/" + $id + "/"), count: $c,
    status: "unresolved", substatus: (if $r == 1 then "regressed" else "ongoing" end),
    stats: {"24h": [[1791673200, ($s / 2 | floor)], [1791676800, ($s - ($s / 2 | floor))]]}}'
}
# mkevent <id> [lane box reason]
mkevent() {
  jq -nc --arg l "${2:-example-lane}" --arg b "${3:-box-fixture}" --arg r "${4:-example-reason-fixture}" '{message: "fixture message", title: "Example error",
    dateCreated: "2026-10-11T00:00:00Z",
    tags: [{key: "lane", value: $l}, {key: "box", value: $b},
           {key: "reason", value: $r}, {key: "harness_sha", value: "abc1234"},
           {key: "project", value: "example-project"}],
    entries: [{type: "exception", data: {values: [{type: "Error", value: "boom",
      stacktrace: {frames: [{filename: "bin/example.sh", function: "main", lineNo: 12}]}}]}}]}' > "$FXT/event-$1.json"
}
answer_ticket() {
  printf '%s\n' '{"verdict":"ticket","title":"Lane example-lane fails — on a missing file","cause":"The lane reads a missing file – then it stops.","proposed_fix":"Create the file first.","acceptance_tests":["T1: the lane runs with the file absent."],"comment":"","reason":""}' > "$FXT/answer.txt"
}
reset() {
  scratch_rm "$FXT"; mkdir -p "$FXT/ledger"
  rm -f "$LOG" "$H/flags/lane-off-sentry-triage" "$H/flags/all-off"
  echo '[]' > "$FXT/open.json"; echo 0 > "$FXT/ac.rc"
  answer_ticket
}
run() {
  env HARNESS="$H" PATH="$T/fakebin:$PATH" HARNESS_TEST_SANDBOX=1 SENTRY_TRIAGE_NOW="$NOW" \
    SENTRY_TRIAGE_FIXTURE="$T/fixture.sh" SENTRY_API_TOKEN=tok-fixture-1 JOBS_URL= JOBS_BOX=box-fixture \
    "$@" bash "$H/bin/sentry-triage.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
calls()   { if [ -f "$FXT/ac.log" ]; then wc -l < "$FXT/ac.log"; else echo 0; fi; }
creates() { if [ -f "$FXT/gh.log" ]; then grep -c '^POST repos/.*/issues ' "$FXT/gh.log"; else echo 0; fi; }
lrow()    { cat "$FXT/ledger/sentry-triage.$1" 2>/dev/null; }
lstat()   { jq -r .status "$FXT/ledger/sentry-triage.$1" 2>/dev/null; }
ldet()    { jq -r ".detail | fromjson | $2" "$FXT/ledger/sentry-triage.$1" 2>/dev/null; }
summary() { grep ' sentry-triage issues=' "$LOG" 2>/dev/null | tail -1; }
# lastbody: the body of the last create, read into a variable before any grep -q.
lastbody() { grep '^POST repos/.*/issues ' "$FXT/gh.log" 2>/dev/null | tail -n 1 | cut -d' ' -f3- | jq -r .body 2>/dev/null; }

# ── T1: a new issue with 5 events → one ticket and a ticketed row ────────────
reset; mkissue 101 5 | jq -s . > "$FXT/issues.json"; mkevent 101
run
check "T1 rc 0 (got $(cat "$T/rc"); $(head -c 300 "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
check "T1 one model call ($(calls))" '[ "$(calls)" = 1 ]'
check "T1 one create ($(creates))" '[ "$(creates)" = 1 ]'
PAY=$(grep '^POST repos/.*/issues ' "$FXT/gh.log" 2>/dev/null | head -1 | cut -d' ' -f3-)
check "T1 label ai-build" 'jq -e ".labels | index(\"ai-build\")" <<<"$PAY" >/dev/null 2>&1'
check "T1 no hotfix at 4 events in 24h" '! jq -e ".labels | index(\"hotfix\")" <<<"$PAY" >/dev/null 2>&1'
BODY=$(jq -r .body <<<"$PAY" 2>/dev/null)
check "T1 body has the marker" 'grep -qF "<!-- sentry-issue: 101 -->" <<<"$BODY"'
check "T1 body has the permalink" 'grep -qF "https://sentry.example.com/issues/101/" <<<"$BODY"'
check "T1 body sections" 'grep -qx "#### Cause" <<<"$BODY" && grep -qx "#### Acceptance tests" <<<"$BODY"'
check "T1 title prefix" 'jq -r .title <<<"$PAY" 2>/dev/null | grep -q "^Sentry CROMFORD-HARNESS-101: Lane example-lane fails"'
check "T1 no em or en dash in title or body" '[ -n "$PAY" ] && ! jq -r ".title, .body" <<<"$PAY" | grep -q "[—–]"'
check "T1 ledger ticketed ($(lstat 101))" '[ "$(lstat 101)" = ticketed ]'
check "T1 detail action filed" '[ "$(ldet 101 .action)" = filed ]'
check "T1 detail issue 9001" '[ "$(ldet 101 .issue)" = 9001 ]'
check "T1 day row lists 101" '[ "$(jq -r ".detail | fromjson | .filed | index(\"101\")" "$FXT/ledger/sentry-triage-day.$DAY" 2>/dev/null)" = 0 ]'
check "T1 summary filed=1 called=1 [$(summary)]" '[[ "$(summary)" == *" called=1 "*"filed=1 "* ]]'
check "T1 prompt carries the wrapped event" 'grep -q "=== UNTRUSTED INPUT" "$FXT/prompt.last" && grep -q "example-reason-fixture" "$FXT/prompt.last"'
check "T1 agent-call argv" 'grep -q "^call \[sentry-triage\] \[fleet\] \[stub-model\] \[300\]" "$FXT/ac.log"'
check "T1 agent-call env" 'grep -q "AGENT_CALL_LANE=sentry-triage" "$FXT/ac.log" && grep -q "AGENT_CALL_NO_TOOLS=1" "$FXT/ac.log" && grep -q "AGENT_CALL_RUNNERS=claude" "$FXT/ac.log" && grep -q "AGENT_CALL_BUDGET_USD_SENTRY_TRIAGE=0.50" "$FXT/ac.log"'
check "T1 writeback posted once" '[ "$(grep -c "^POST .*/issues/101/comments/" "$FXT/curl.log")" = 1 ] && [ "$(ldet 101 .writeback)" = ok ]'
check "T1 no token in the log" '! grep -q tok-fixture-1 "$LOG"'

# ── T2: the same issue on the next tick → no call, no ticket (red first) ─────
run
check "T2 still exactly 1 call after the second tick ($(calls))" '[ "$(calls)" = 1 ]'
check "T2 still exactly 1 create ($(creates))" '[ "$(creates)" = 1 ]'
check "T2 summary terminal=1 called=0 [$(summary)]" '[[ "$(summary)" == *" terminal=1 called=0 "* ]]'

# ── T3: 2 events, below the minimum → no call, no row ────────────────────────
reset; mkissue 103 2 | jq -s . > "$FXT/issues.json"; mkevent 103
run
check "T3 no call" '[ "$(calls)" = 0 ]'
check "T3 no ledger row" '[ ! -e "$FXT/ledger/sentry-triage.103" ]'
check "T3 summary below_min=1 [$(summary)]" '[[ "$(summary)" == *" below_min=1 "* ]]'
# The edge: exactly the minimum acts.
reset; mkissue 113 3 | jq -s . > "$FXT/issues.json"; mkevent 113
run
check "T3 count 3 equals the minimum: one call" '[ "$(calls)" = 1 ]'

# ── T4: a regressed issue already ticketed → exactly one new pass ────────────
reset; mkissue 104 9 | jq -s . > "$FXT/issues.json"; mkevent 104
run
check "T4 first pass ticketed" '[ "$(lstat 104)" = ticketed ] && [ "$(calls)" = 1 ]'
mkissue 104 12 1 | jq -s . > "$FXT/issues.json"
run
check "T4 the regression made one new call ($(calls))" '[ "$(calls)" = 2 ]'
check "T4 the :regressed row is ticketed ($(lstat 104:regressed))" '[ "$(lstat 104:regressed)" = ticketed ]'
LASTBODY=$(lastbody)
check "T4 the regression body carries its own marker" 'grep -qF "<!-- sentry-issue: 104:regressed -->" <<<"$LASTBODY"'
run
check "T4 a third tick makes no call ($(calls))" '[ "$(calls)" = 2 ]'
# Regressed with no row at all is a first pass on <id>.
reset; mkissue 114 9 1 | jq -s . > "$FXT/issues.json"; mkevent 114
run
check "T4 regressed with no row is a first pass on <id>" '[ "$(lstat 114)" = ticketed ] && [ ! -e "$FXT/ledger/sentry-triage.114:regressed" ]'
check "T4 the <id> row records regressed=true" '[ "$(ldet 114 .regressed)" = true ]'
run
check "T4 still regressed on the next tick: no second call ($(calls))" '[ "$(calls)" = 1 ] && [ "$(creates)" = 1 ]'
check "T4 still regressed on the next tick: no :regressed row" '[ ! -e "$FXT/ledger/sentry-triage.114:regressed" ]'

# ── T5: noise → a noise row, never retried ───────────────────────────────────
reset; mkissue 105 5 | jq -s . > "$FXT/issues.json"; mkevent 105
printf '%s\n' '{"verdict":"noise","reason":"A test box sent this event once."}' > "$FXT/answer.txt"
run
check "T5 one call" '[ "$(calls)" = 1 ]'
check "T5 row noise ($(lstat 105))" '[ "$(lstat 105)" = noise ]'
check "T5 reason recorded" '[ "$(ldet 105 .reason)" = "A test box sent this event once." ]'
check "T5 no create" '[ "$(creates)" = 0 ]'
run
check "T5 next tick: no call" '[ "$(calls)" = 1 ]'

# ── T5b: an empty reply → failed, terminal ───────────────────────────────────
reset; mkissue 115 5 | jq -s . > "$FXT/issues.json"; mkevent 115
: > "$FXT/answer.txt"
run
check "T5b row failed ($(lstat 115))" '[ "$(lstat 115)" = failed ] && [ "$(ldet 115 .why)" = empty-reply ]'
run
check "T5b next tick: no call" '[ "$(calls)" = 1 ]'
# A comment naming a ticket outside the candidates is a bad reply.
reset; mkissue 125 5 | jq -s . > "$FXT/issues.json"; mkevent 125
printf '%s\n' '{"verdict":"comment","issue":4242,"comment":"Same cause."}' > "$FXT/answer.txt"
run
check "T5b comment outside the candidates is bad-reply" '[ "$(lstat 125)" = failed ] && [ "$(ldet 125 .why)" = bad-reply ]'
check "T5b no comment posted" '! grep -q "^COMMENT" "$FXT/gh.log" 2>/dev/null'

# ── T5c: rc 1 three ticks → retry 1, 2, failed; rc 75 keeps attempts ──────────
reset; mkissue 135 5 | jq -s . > "$FXT/issues.json"; mkevent 135
echo 1 > "$FXT/ac.rc"
run; A1="$(lstat 135)/$(ldet 135 .attempts)"
run; A2="$(lstat 135)/$(ldet 135 .attempts)"
run; A3="$(lstat 135)/$(ldet 135 .attempts)"
check "T5c retry/1 retry/2 failed/3 (got $A1 $A2 $A3)" '[ "$A1 $A2 $A3" = "retry/1 retry/2 failed/3" ]'
run
check "T5c a fourth tick makes no call ($(calls))" '[ "$(calls)" = 3 ]'
reset; mkissue 145 5 | jq -s . > "$FXT/issues.json"; mkevent 145
echo 1 > "$FXT/ac.rc"; run
echo 75 > "$FXT/ac.rc"; run
check "T5c rc 75 keeps attempts at 1 ($(lstat 145)/$(ldet 145 .attempts))" '[ "$(lstat 145)" = retry ] && [ "$(ldet 145 .attempts)" = 1 ]'
check "T5c rc 75 records last_rc" '[ "$(ldet 145 .last_rc)" = 75 ]'

# ── T5d: a comment verdict on a real candidate ──────────────────────────────
reset; mkissue 155 5 | jq -s . > "$FXT/issues.json"; mkevent 155
jq -nc '[{number: 77, title: "example-reason-fixture breaks the lane", body: "seen on box-fixture", html_url: "https://github.com/example-org/example-repo/issues/77", labels: [{name: "ai-build"}]}]' > "$FXT/open.json"
printf '%s\n' '{"verdict":"comment","issue":77,"comment":"The same cause shows in Sentry."}' > "$FXT/answer.txt"
run
check "T5d one comment on #77" '[ "$(grep -c "^COMMENT [^ ]* 77 " "$FXT/gh.log")" = 1 ]'
CMT=$(grep "^COMMENT" "$FXT/gh.log" 2>/dev/null)
check "T5d comment carries the permalink" 'grep -qF "https://sentry.example.com/issues/155/" <<<"$CMT"'
check "T5d row ticketed commented" '[ "$(lstat 155)" = ticketed ] && [ "$(ldet 155 .action)" = commented ] && [ "$(ldet 155 .issue)" = 77 ]'
check "T5d no create" '[ "$(creates)" = 0 ]'
check "T5d the row url is the candidate html_url" '[ "$(ldet 155 .url)" = "https://github.com/example-org/example-repo/issues/77" ]'
check "T5d writeback posted once" '[ "$(grep -c "^POST .*/issues/155/comments/" "$FXT/curl.log")" = 1 ] && [ "$(ldet 155 .writeback)" = ok ]'
check "T5d the candidate reached the prompt" 'grep -q "#77 example-reason-fixture breaks the lane" "$FXT/prompt.last"'
check "T5d the comment carries the marker" 'grep -qF "<!-- sentry-issue: 155 -->" <<<"$CMT"'
# The comment was posted but the ticketed put was lost: the next tick finds the
# marker on #77 and posts nothing.
reset; mkissue 165 5 | jq -s . > "$FXT/issues.json"; mkevent 165
jq -nc '[{number: 77, title: "example-reason-fixture breaks the lane", body: "seen on box-fixture", html_url: "https://github.com/example-org/example-repo/issues/77", labels: [{name: "ai-build"}]}]' > "$FXT/open.json"
jq -nc '{status: "diagnosed", detail: ({sentry_id: "165", short_id: "CROMFORD-HARNESS-165", permalink: "https://sentry.example.com/issues/165/", regressed: false, attempts: 1,
  diagnosis: {verdict: "comment", issue: 77, comment: "The same cause shows in Sentry."}} | tojson)}' > "$FXT/ledger/sentry-triage.165"
jq -nc '[{id: 1, body: "The same cause shows in Sentry.\n<!-- sentry-issue: 165 -->\n"}]' > "$FXT/comments.json"
run
check "T5d marker already on #77: no repost, no call" '! grep -q "^COMMENT" "$FXT/gh.log" 2>/dev/null && [ "$(calls)" = 0 ]'
check "T5d marker already on #77: row ticketed commented" '[ "$(lstat 165)" = ticketed ] && [ "$(ldet 165 .action)" = commented ]'

# ── T6: the daily cap ────────────────────────────────────────────────────────
reset; { mkissue 106 9; mkissue 116 7; } | jq -s . > "$FXT/issues.json"; mkevent 106; mkevent 116
run SENTRY_TRIAGE_MAX_TICKETS_DAY=1
check "T6 one create ($(creates))" '[ "$(creates)" = 1 ]'
check "T6 one call ($(calls))" '[ "$(calls)" = 1 ]'
check "T6 a log line names the cap" 'grep -q "SENTRY_TRIAGE_MAX_TICKETS_DAY=1" "$LOG"'
check "T6 the capped issue has no row" '[ ! -e "$FXT/ledger/sentry-triage.116" ]'
check "T6 summary capped=1" '[[ "$(summary)" == *" capped=1"* ]]'

# ── T7: the kill switch → no API call ────────────────────────────────────────
for fl in lane-off-sentry-triage all-off; do
  reset; mkissue 107 9 | jq -s . > "$FXT/issues.json"; mkevent 107
  mkdir -p "$H/flags"; touch "$H/flags/$fl"
  run
  check "T7 $fl: rc 0" '[ "$(cat "$T/rc")" = 0 ]'
  check "T7 $fl: no curl" '[ ! -s "$FXT/curl.log" ]'
  check "T7 $fl: no model call" '[ ! -s "$FXT/ac.log" ]'
  check "T7 $fl: no gh call" '[ ! -s "$FXT/gh.log" ]'
  rm -f "$H/flags/$fl"
done

# ── T8: no hard-coded model id; the route role ───────────────────────────────
HITS=$(grep -nE 'claude-[a-z0-9]' "$DIR/bin/sentry-triage.sh" "$DIR/bin/lib/sentry-triage.sh" \
  "$DIR/catalog/prompts/sentry-triage.md" "$DIR/catalog/lanes.d/sentry-triage.json" 2>/dev/null || true)
check "T8 no claude-* literal [$HITS]" '[ -z "$HITS" ]'
reset; mkissue 108 9 | jq -s . > "$FXT/issues.json"; mkevent 108
run
check "T8 the route role is stage.sentry-triage" '[ "$(sort -u "$FXT/roles.log" 2>/dev/null)" = stage.sentry-triage ]'
# MAX_USD=0 is off: no call and no row.
reset; mkissue 118 9 | jq -s . > "$FXT/issues.json"; mkevent 118
run SENTRY_TRIAGE_MAX_USD=0
check "T8 MAX_USD=0: no call, no row" '[ "$(calls)" = 0 ] && [ ! -e "$FXT/ledger/sentry-triage.118" ]'

# ── T9: ledger outage → no call, no create, one alert ────────────────────────
reset; { mkissue 109 9; mkissue 119 8; } | jq -s . > "$FXT/issues.json"; mkevent 109; mkevent 119
echo 1 > "$FXT/ledger.rc"
run
check "T9 no call" '[ "$(calls)" = 0 ]'
check "T9 no create" '[ "$(creates)" = 0 ]'
check "T9 exactly one alert ($(wc -l < "$FXT/alerts.log" 2>/dev/null))" '[ "$(wc -l < "$FXT/alerts.log" 2>/dev/null)" = 1 ] && grep -q "sentry-triage-ledger" "$FXT/alerts.log"'
# A Sentry list failure is one warn with the HTTP code and the body.
reset; echo '{"detail":"fixture denied"}' > "$FXT/issues.json"; echo 401 > "$FXT/list.code"
run
check "T9 list 401: one alert naming the code and the body" '[ "$(wc -l < "$FXT/alerts.log" 2>/dev/null)" = 1 ] && grep -q "sentry-triage-list" "$FXT/alerts.log" && grep -q "401" "$FXT/alerts.log" && grep -q "fixture denied" "$FXT/alerts.log"'
check "T9 list 401: no call" '[ "$(calls)" = 0 ]'

# ── T10: hotfix label above the knob; writeback 403 ──────────────────────────
reset; mkissue 110 80 0 60 | jq -s . > "$FXT/issues.json"; mkevent 110
echo 403 > "$FXT/wb.code"
run
PAY=$(grep '^POST repos/.*/issues ' "$FXT/gh.log" 2>/dev/null | head -1 | cut -d' ' -f3-)
check "T10 60 events in 24h > 50: hotfix" 'jq -e ".labels | index(\"hotfix\")" <<<"$PAY" >/dev/null 2>&1'
check "T10 writeback 403 logged" 'grep -q "lacks issue:write" "$LOG"'
check "T10 row stays ticketed" '[ "$(lstat 110)" = ticketed ]'
check "T10 writeback skipped-403" '[ "$(ldet 110 .writeback)" = skipped-403 ]'
reset; mkissue 120 80 0 50 | jq -s . > "$FXT/issues.json"; mkevent 120
run
PAY=$(grep '^POST repos/.*/issues ' "$FXT/gh.log" 2>/dev/null | head -1 | cut -d' ' -f3-)
check "T10 50 events in 24h, not over 50: no hotfix" '[ -n "$PAY" ] && ! jq -e ".labels | index(\"hotfix\")" <<<"$PAY" >/dev/null 2>&1'

# ── T11: an open issue already carries the marker → healed ───────────────────
reset; mkissue 111 9 | jq -s . > "$FXT/issues.json"; mkevent 111
jq -nc '[{number: 555, title: "Sentry CROMFORD-HARNESS-111: earlier", body: "x\n<!-- sentry-issue: 111 -->\n"}]' > "$FXT/open.json"
run
check "T11 no call" '[ "$(calls)" = 0 ]'
check "T11 row ticketed healed #555" '[ "$(lstat 111)" = ticketed ] && [ "$(ldet 111 .action)" = healed ] && [ "$(ldet 111 .issue)" = 555 ]'
check "T11 summary healed=1" '[[ "$(summary)" == *" healed=1"* ]]'

# ── T12: the lane log lines near the event, only from this box ─────────────
reset; mkissue 112 9 | jq -s . > "$FXT/issues.json"; mkevent 112
mkdir -p "$H/logs"
printf '%s\n' "2026-10-10 23:00:00 far-before-fixture" "2026-10-10T23:55:00Z near-before-fixture" \
  "2026-10-11 00:04:00 near-after-fixture" "2026-10-11 01:00:00 far-after-fixture" > "$H/logs/example-lane.log"
run
check "T12 the in-window lines reach the prompt" 'grep -q near-before-fixture "$FXT/prompt.last" && grep -q near-after-fixture "$FXT/prompt.last"'
check "T12 the out-of-window lines do not" '! grep -q far-before-fixture "$FXT/prompt.last" && ! grep -q far-after-fixture "$FXT/prompt.last"'
LASTBODY=$(lastbody)
check "T12 the ticket body carries the log lines" 'grep -q near-after-fixture <<<"$LASTBODY"'
reset; mkissue 122 9 | jq -s . > "$FXT/issues.json"; mkevent 122
run JOBS_BOX=box-other-fixture
check "T12 an event from another box reads no log" 'grep -q "is on box box-fixture; not read from the hub" "$FXT/prompt.last" && ! grep -q near-after-fixture "$FXT/prompt.last"'
reset; mkissue 132 9 | jq -s . > "$FXT/issues.json"
mkevent 132; jq '.tags[0].value = "../example-lane"' "$FXT/event-132.json" > "$FXT/e.tmp" && mv "$FXT/e.tmp" "$FXT/event-132.json"
run
check "T12 a lane tag with a path reads no log" 'grep -q "no usable lane tag" "$FXT/prompt.last" && ! grep -q near-after-fixture "$FXT/prompt.last"'
# No dateCreated: the lines that name the reason tag are the fallback.
reset; mkissue 142 9 | jq -s . > "$FXT/issues.json"; mkevent 142
jq 'del(.dateCreated)' "$FXT/event-142.json" > "$FXT/e.tmp" && mv "$FXT/e.tmp" "$FXT/event-142.json"
printf '%s\n' "2020-01-01 00:00:00 example-reason-fixture reason-line-fixture" "2020-01-01 00:00:01 other-line-fixture" > "$H/logs/example-lane.log"
run
check "T12 no event time: the reason lines are read" 'grep -q reason-line-fixture "$FXT/prompt.last" && ! grep -q other-line-fixture "$FXT/prompt.last"'
rm -f "$H/logs/example-lane.log"

# ── T13: a failed create leaves diagnosed; the next tick files with no call ───
reset; mkissue 117 9 | jq -s . > "$FXT/issues.json"; mkevent 117
echo 502 > "$FXT/create.code"
run
check "T13 failed create: row diagnosed ($(lstat 117)), 1 call" '[ "$(lstat 117)" = diagnosed ] && [ "$(calls)" = 1 ]'
check "T13 the diagnosis is stored" '[ "$(ldet 117 .diagnosis.verdict)" = ticket ]'
rm -f "$FXT/create.code"
run
check "T13 next tick: filed with no new call ($(calls))" '[ "$(lstat 117)" = ticketed ] && [ "$(ldet 117 .action)" = filed ] && [ "$(calls)" = 1 ]'
LASTBODY=$(lastbody)
check "T13 the resumed body carries the tags of 117" 'grep -qF "reason=example-reason-fixture" <<<"$LASTBODY"'
# The resume after another issue's call in the same tick: 118 has more events,
# so it is called first; 117 is then filed from its stored diagnosis.
reset; mkissue 117 9 | jq -s . > "$FXT/issues.json"; mkevent 117
echo 502 > "$FXT/create.code"
run
rm -f "$FXT/create.code"
{ mkissue 118 50; mkissue 117 9; } | jq -s . > "$FXT/issues.json"; mkevent 118 other-lane box-x ISSUE-118-REASON
run
B117=$(grep '^POST repos/.*/issues ' "$FXT/gh.log" | cut -d' ' -f3- | jq -r 'select(.title | startswith("Sentry CROMFORD-HARNESS-117")) | .body' 2>/dev/null)
check "T13 117 filed after 118's call ($(calls) calls)" '[ "$(lstat 117)" = ticketed ] && [ "$(lstat 118)" = ticketed ] && [ "$(calls)" = 2 ] && [ -n "$B117" ]'
check "T13 117's body names its own reason tag" 'grep -qF "reason=example-reason-fixture" <<<"$B117"'
check "T13 117's body carries nothing of 118" '! grep -q "ISSUE-118-REASON\|other-lane\|box-x" <<<"$B117"'

# ── T15: a long answer stays readable after the worker's 4000-char cut ────────
reset; mkissue 127 9 | jq -s . > "$FXT/issues.json"; mkevent 127
jq -nc --arg c "$(head -c 3500 /dev/zero | tr '\0' 'c')" --arg f "$(head -c 1200 /dev/zero | tr '\0' 'f')" \
  '{verdict: "ticket", title: "Long cause fixture", cause: ("cause-head-fixture " + $c), proposed_fix: $f, acceptance_tests: ["T1: long."]}' > "$FXT/answer.txt"
echo 502 > "$FXT/create.code"
run
check "T15 long answer: row diagnosed, 1 call" '[ "$(lstat 127)" = diagnosed ] && [ "$(calls)" = 1 ]'
check "T15 the stored detail is under 4000 chars and parses" '[ "$(ldet 127 .diagnosis.verdict)" = ticket ] && [ "$(jq -r ".detail | length" "$FXT/ledger/sentry-triage.127")" -lt 4000 ]'
check "T15 the cut is recorded and logged" '[ "$(ldet 127 .cut)" -gt 0 ] && grep -q "127 detail over 3900 bytes" "$LOG"'
rm -f "$FXT/create.code"
run
LASTBODY=$(lastbody)
check "T15 next tick: filed with no new call ($(calls))" '[ "$(lstat 127)" = ticketed ] && [ "$(calls)" = 1 ] && grep -q "^cause-head-fixture" <<<"$LASTBODY"'
# A diagnosed row whose detail does not parse: failed, logged, never silent.
reset; mkissue 137 9 | jq -s . > "$FXT/issues.json"; mkevent 137
jq -nc '{status: "diagnosed", detail: "{\"sentry_id\":\"137\",\"diagnosis\":{\"verdict\":\"tic"}' > "$FXT/ledger/sentry-triage.137"
run
check "T15 lost diagnosis: failed diagnosis-lost, no call ($(lstat 137))" '[ "$(lstat 137)" = failed ] && [ "$(ldet 137 .why)" = diagnosis-lost ] && [ "$(calls)" = 0 ]'
check "T15 lost diagnosis: a log line and summary failed=1" 'grep -q "137 stored diagnosis unreadable" "$LOG" && [[ "$(summary)" == *" failed=1 "* ]]'

# ── T16: the day call cap counts every call, noise included ──────────────────
reset; { mkissue 126 9; mkissue 136 7; } | jq -s . > "$FXT/issues.json"; mkevent 126; mkevent 136
printf '%s\n' '{"verdict":"noise","reason":"A test box sent this event once."}' > "$FXT/answer.txt"
run SENTRY_TRIAGE_MAX_CALLS_DAY=1
check "T16 one call under MAX_CALLS_DAY=1 ($(calls))" '[ "$(calls)" = 1 ]'
check "T16 a log line names the call cap" 'grep -q "SENTRY_TRIAGE_MAX_CALLS_DAY=1" "$LOG"'
check "T16 the day row counts 1 call" '[ "$(jq -r ".detail | fromjson | .calls" "$FXT/ledger/sentry-triage-day.$DAY" 2>/dev/null)" = 1 ]'
check "T16 the capped issue has no row" '[ ! -e "$FXT/ledger/sentry-triage.136" ]'
run SENTRY_TRIAGE_MAX_CALLS_DAY=1
check "T16 the next tick makes no call ($(calls))" '[ "$(calls)" = 1 ]'
# A filed ticket keeps the call count in the day row.
reset; mkissue 146 9 | jq -s . > "$FXT/issues.json"; mkevent 146
run
check "T16 filed: day row has filed [146] and calls 1" '[ "$(jq -c ".detail | fromjson" "$FXT/ledger/sentry-triage-day.$DAY" 2>/dev/null)" = "{\"filed\":[\"146\"],\"calls\":1}" ]'

# ── T14: the prompt bounds: event cut at 12000 bytes, at most 5 candidates ───
reset; mkissue 124 9 | jq -s . > "$FXT/issues.json"; mkevent 124
jq --arg m "$(head -c 30000 /dev/zero | tr '\0' 'x')" '.message = $m' "$FXT/event-124.json" > "$FXT/e.tmp" && mv "$FXT/e.tmp" "$FXT/event-124.json"
jq -nc '[range(1; 8) | {number: (100 + .), title: "example-reason-fixture case \(.)", body: (("y" * 2000) + "tail-fixture")}]' > "$FXT/open.json"
run
XS=$(tr -cd x < "$FXT/prompt.last" | wc -c)
# The prompt's own words hold a few dozen x; the message adds 4000.
check "T14 the event message is cut to 4000 chars ($XS x)" '[ "$XS" -ge 4000 ] && [ "$XS" -lt 4200 ]'
check "T14 the tags survive a long event" 'grep -q "reason=example-reason-fixture" <<<"$(grep "^POST repos/.*/issues " "$FXT/gh.log" | cut -d" " -f3- | jq -r .body)"'
check "T14 at most 5 candidates ($(grep -c "^#10[0-9] example-reason-fixture" "$FXT/prompt.last"))" '[ "$(grep -c "^#10[0-9] example-reason-fixture" "$FXT/prompt.last")" = 5 ]'
check "T14 each candidate body is cut to 600 bytes" '! grep -q tail-fixture "$FXT/prompt.last"'

# 30 frames of 1000-char file names: the prompt cuts the event at 12000 bytes.
reset; mkissue 134 9 | jq -s . > "$FXT/issues.json"; mkevent 134
jq --arg f "$(head -c 1000 /dev/zero | tr '\0' 'z')" '.entries[0].data.values[0].stacktrace.frames = [range(0; 40) | {filename: $f, function: "main", lineNo: .}]' \
  "$FXT/event-134.json" > "$FXT/e.tmp" && mv "$FXT/e.tmp" "$FXT/event-134.json"
run
ZS=$(tr -cd z < "$FXT/prompt.last" | wc -c)
check "T14 the prompt cuts the event at 12000 bytes ($ZS z)" '[ "$ZS" -gt 10000 ] && [ "$ZS" -lt 12000 ]'

# ── Registry: the three ticket knobs at their defaults ───────────────────────
REG=$(jq -c '.lanes[] | select(.lane == "sentry-triage" or .id == "sentry-triage") | [.knobs[] | {(.env): .default}] | add' "$DIR/catalog/lanes.json" 2>/dev/null)
check "R MIN_EVENTS=3 MAX_TICKETS_DAY=5 LOOKBACK_H=24 [$REG]" \
  '[ "$(jq -c "[.SENTRY_TRIAGE_MIN_EVENTS, .SENTRY_TRIAGE_MAX_TICKETS_DAY, .SENTRY_TRIAGE_LOOKBACK_H]" <<<"$REG" 2>/dev/null)" = "[3,5,24]" ]'
check "R MAX_CALLS_DAY=10" '[ "$(jq -c ".SENTRY_TRIAGE_MAX_CALLS_DAY" <<<"$REG" 2>/dev/null)" = 10 ]'

echo "sentry-triage: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
