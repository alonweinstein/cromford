#!/bin/bash
# tests/tracker-contract-test.sh — the tracker contract (bin/lib/tracker.sh,
# BH-4075) run against EVERY adapter: the same eleven cases from
# tests/lib/tracker-contract.sh, once for bin/lib/tracker/github-issues.sh, once
# for bin/lib/tracker/board.sh and once for bin/lib/tracker/jira.sh (BH-4076,
# its gateway stub and setup in tests/lib/tracker-jira-stub.sh). A new tracker
# adds a tc_setup_<adapter> and must pass the same cases unchanged.
#
# No network. A `gh` stub answers `gh api -i` the way GitHub does (status line,
# blank line, body); a `curl` stub plays the board (and the board-fetch.sh read
# bin/triage-gate.sh makes for C9). Both keep their own write log, and neither
# ever writes its argv, which is where the board token rides.
#   HARNESS_TEST_SANDBOX=1 bash tests/tracker-contract-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/tracker-contract.sh" || exit 1
. "$(dirname "$0")/lib/tracker-jira-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

TOKEN=tok-FIXTURE-SENTINEL-4075
GHTOK=gh-FIXTURE-SENTINEL-4075
mkdir -p "$T/h/bin" "$T/h/env" "$T/h/state" "$T/h/logs" "$T/stub" "$T/run" "$T/gs" "$T/bs"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/board-fetch.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
ghproj  o/r  https://gh.example     -           9
xos     o/x  https://board.example  /api/board  3
CONF
cat > "$T/h/env/xos.env" <<CONF
XOS_API_BASE=https://board.example
XOS_INTERNAL_API_TOKEN=$TOKEN
CONF
export HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" GH_ETAG=0 PATH="$T/stub:$PATH"
export TC_GSTATE="$T/gs" TC_BSTATE="$T/bs" TC_BOARD_TOKEN_EXPECT="$TOKEN"

# ---- the GitHub stub -------------------------------------------------------
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
S="$TC_GSTATE"
send() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "${2:-}"; exit 0; }
[ "$1 $2 $3" = "api -i -X" ] || exit 1
m="$4"; p="${5%%\?*}"; shift 5
page=1; state=""; label=""; bodyf=""
while [ $# -gt 0 ]; do
  case "$1" in
    -F|-f) case "$2" in page=*) page="${2#page=}" ;; state=*) state="${2#state=}" ;; 'labels[]='*) label="${2#labels[]=}" ;; body=@*) bodyf="${2#body=@}" ;; esac; shift ;;
  esac
  shift
done
arm=$(cat "$S/arm" 2>/dev/null)
case "$m $p" in
  "GET repos/o/r/issues")
    [ "$arm" = ratelimit ] && send 403 '{"message":"API rate limit exceeded for installation"}'
    [ "$page" = 1 ] && send 200 "$(cat "$S/list.json")"; send 200 '[]' ;;
  "GET repos/o/r/issues/"*/comments)
    [ "$arm" = ratelimit ] && send 403 '{"message":"API rate limit exceeded for installation"}'
    n="${p#repos/o/r/issues/}"; n="${n%/comments}"
    [ "$page" = 1 ] && [ -f "$S/comments-$n.json" ] && send 200 "$(cat "$S/comments-$n.json")"; send 200 '[]' ;;
  "GET repos/o/r/issues/"*)
    [ "$arm" = ratelimit ] && send 403 '{"message":"API rate limit exceeded for installation"}'
    n="${p##*/}"; [ -f "$S/issue-$n.json" ] && send 200 "$(cat "$S/issue-$n.json")"; send 404 '{"message":"Not Found"}' ;;
  "POST repos/o/r/issues/"*/comments)
    n="${p#repos/o/r/issues/}"; n="${n%/comments}"
    echo "comment $n" >> "$S/writes"; cp "$bodyf" "$S/body-$(grep -c '^comment' "$S/writes")"
    [ "$arm" = comment_fail ] && send 422 '{"message":"Validation Failed"}'
    send 201 '{"id":1}' ;;
  "PATCH repos/o/r/issues/"*)
    n="${p##*/}"; echo "status $n $state" >> "$S/writes"
    [ "$arm" = transition_fail ] && send 422 '{"message":"Validation Failed"}'
    [ "$arm" = transition_noop ] && send 200 "{\"number\":$n,\"state\":\"open\"}"
    send 200 "{\"number\":$n,\"state\":\"$state\"}" ;;
  "POST repos/o/r/issues/"*/labels)
    n="${p#repos/o/r/issues/}"; n="${n%/labels}"
    echo "label_add $n $label" >> "$S/writes"; echo "$label" >> "$S/labels-$n"; send 200 '[]' ;;
  "DELETE repos/o/r/issues/"*/labels/*)
    l="${p##*/}"; n="${p#repos/o/r/issues/}"; n="${n%%/*}"
    echo "label_remove $n $l" >> "$S/writes"
    if grep -qx "$l" "$S/labels-$n" 2>/dev/null; then
      grep -vx "$l" "$S/labels-$n" > "$S/labels-$n.new"; mv "$S/labels-$n.new" "$S/labels-$n"; send 200 '[]'
    fi
    send 404 '{"message":"Label does not exist"}' ;;
esac
send 404 '{"message":"Not Found"}'
SH

# ---- the board stub (adapter calls, board-fetch.sh, jobs-client) ------------
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
S="$TC_BSTATE"; m=GET; url=""; data=""; out=""; fmt=""; fail=0; auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift ;;
    --data-binary) data="${2#@}"; shift ;;
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -m|--max-time|--connect-timeout) shift ;;
    -H) case "$2" in "Authorization: Bearer "*) auth="${2#Authorization: Bearer }" ;; esac; shift ;;
    -f) fail=1 ;;
    http*) url="$1" ;;
  esac
  shift
done
[ "$auth" = "$TC_BOARD_TOKEN_EXPECT" ] || echo "badauth $m $url" >> "$S/authbad"
arm=$(cat "$S/arm" 2>/dev/null)
code=200; body=""
path="${url#https://board.example/api/board}"
case "$m $path" in
  "GET /boards") body='[{"id":"b1","capabilities":["dependencies"]}]' ;;
  "GET /boards/b1/tickets") body=$(cat "$S/list.json") ;;
  "GET /tickets/"*)
    id="${path#/tickets/}"
    if [ "$arm" = ratelimit ]; then code=429; body='{"error":"slow down"}'
    elif [ -f "$S/t-$id.json" ]; then body=$(cat "$S/t-$id.json")
    else code=404; body='{"error":"not found"}'; fi ;;
  "POST /tickets/"*/comments)
    id="${path#/tickets/}"; id="${id%/comments}"
    echo "comment $id" >> "$S/writes"; jq -j .body "$data" > "$S/body-$(grep -c '^comment' "$S/writes")"
    if [ "$arm" = comment_fail ]; then code=500; body='{"error":"boom"}'; else body='{"comment":{"id":"c9"}}'; fi ;;
  "POST /tickets/"*/move)
    id="${path#/tickets/}"; id="${id%/move}"; st=$(jq -r .toStatus "$data")
    echo "status $id $st" >> "$S/writes"
    if [ "$arm" = transition_fail ]; then body='{"ticket":{"status":"todo"}}'; else body="{\"ticket\":{\"status\":\"$st\"}}"; fi ;;
  *) code=404; body='{"error":"no route"}' ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" > "$out"; printf '%s' "$fmt" | sed "s/%{http_code}/$code/g"; exit 0; fi
if [ "$fail" = 1 ] && [ "$code" -ge 400 ]; then echo "curl: (22) The requested URL returned error: $code" >&2; exit 22; fi
printf '%s\n' "$body"
SH
chmod +x "$T/stub/gh" "$T/stub/curl"

# ---- fixtures ---------------------------------------------------------------
# GitHub: #101 a feature with 3 comments, #102 a question nobody answered, a PR
# in the list (the issues route returns PRs too; the list must drop it).
jq -n '{number:101, title:"Ledger export", body:"Ship the export.", state:"open",
  labels:[{name:"ai-build"}], html_url:"https://github.com/o/r/issues/101"}' > "$T/gs/issue-101.json"
jq -n '{number:102, title:"Fee toggle", body:"Remove the discount toggle.", state:"open",
  labels:[{name:"ai-build"}], html_url:"https://github.com/o/r/issues/102"}' > "$T/gs/issue-102.json"
jq -n '[{user:{login:"client"}, body:"first", created_at:"2026-10-01T01:00:00Z"},
  {user:{login:"operator"}, body:"second", created_at:"2026-10-01T02:00:00Z"},
  {user:{login:"client"}, body:"third", created_at:"2026-10-01T03:00:00Z"}]' > "$T/gs/comments-101.json"
jq -n '[{user:{login:"operator"}, body:"How does the rep set the fee?", created_at:"2026-10-01T01:00:00Z"}]' > "$T/gs/comments-102.json"
# #104: a thread at the 200-comment read cap, which is a partial read.
jq -n '{number:104, title:"Long thread", body:"", state:"open", labels:[]}' > "$T/gs/issue-104.json"
jq -n '[range(200) | {user:{login:"client"}, body:"c\(.)", created_at:"2026-10-01T01:00:00Z"}]' > "$T/gs/comments-104.json"
jq -s '. + [{number:103, title:"a PR", state:"open", pull_request:{url:"x"}}]' "$T/gs/issue-101.json" "$T/gs/issue-102.json" > "$T/gs/list.json"

# Board: cmT1 ready, newest comment from the client; cmQ1 waiting on the client.
jq -n '{ticket:{id:"cmT1", key:"XO-1", title:"Ledger export", description:"<p>Ship the export.</p>",
  status:"todo", waitingOn:"team", triageVerdict:"ready", url:"https://board.example/t/XO-1"},
  comments:[{author:{name:"Client User", userId:"client-1"}, body:"first", createdAt:"2026-10-01T01:00:00Z", isInternal:false},
    {author:{name:"Dev", userId:"dev-1"}, body:"second", createdAt:"2026-10-01T02:00:00Z", isInternal:false},
    {author:{name:"Client User", userId:"client-1"}, body:"third", createdAt:"2026-10-01T03:00:00Z", isInternal:false}]}' > "$T/bs/t-cmT1.json"
jq -n '{ticket:{id:"cmQ1", key:"XO-2", title:"Fee toggle", description:"<p>Remove it.</p>", status:"todo",
  waitingOn:"client", triageVerdict:"needs_clarification"},
  comments:[{author:{name:"System Harness", userId:"Harness"}, body:"How does the rep set the fee?", createdAt:"2026-10-01T01:00:00Z", isInternal:true}]}' > "$T/bs/t-cmQ1.json"
jq -s '{tickets: [.[] | .ticket]}' "$T/bs/t-cmT1.json" "$T/bs/t-cmQ1.json" > "$T/bs/list.json"

# ---- per-adapter setup and stub hooks ---------------------------------------
. "$DIR/bin/lib/tracker.sh" || exit 1
TC_S=""
tc_reset()  { rm -f "$TC_S/writes" "$TC_S/arm" "$TC_S"/body-*; }
tc_arm()    { printf '%s' "$1" > "$TC_S/arm"; }
tc_writes() { cat "$TC_S/writes" 2>/dev/null; }
tc_body()   { cat "$TC_S/body-$1" 2>/dev/null; }

tc_setup_github_issues() {
  tracker_load github-issues || return 1
  TC_S="$T/gs"; TRK_SLUG=o/r; TRK_LOG="$T/run/gh.log"; TRK_DRY=0; TRK_REQ_FILE=""
  export GH_TOKEN="$GHTOK"
  TC_PROJECT=ghproj; TC_T=101; TC_Q=102; TC_M=999; TC_TERMINAL=closed; TC_Q_WAIT=OK; TC_LABELS=1
  TC_SECRET="$GHTOK"; TC_SCAN_ROOT="$T/run"
}
tc_setup_board() {
  tracker_load board || return 1
  unset GH_TOKEN
  TC_S="$T/bs"; TRK_BOARD_BASE="https://board.example/api/board"; TRK_BOARD_TOKEN="$TOKEN"
  TRK_BOARD_TOKEN_VAR=XOS_INTERNAL_API_TOKEN; TRK_LOG="$T/run/board.log"; TRK_ERR="$T/run/curl.err"
  TRK_DRY=0; TRK_REQ_FILE=""
  TC_PROJECT=xos; TC_T=cmT1; TC_Q=cmQ1; TC_M=cmMissing; TC_TERMINAL=review; TC_Q_WAIT="BLOCKED waitingOn=client"; TC_LABELS=0
  # The env file holds the token by design (bin/triage-gate.sh reads it there).
  TC_SECRET="$TOKEN"; TC_SCAN_ROOT="$T/run $T/bs $T/h/state $T/h/logs"
}

tracker_contract_run github-issues
# Adapter-specific facts the shared cases do not cover.
[ "$(tracker_list | jq -c '[.[].id]')" = '["101","102"]' ] && _tc_ok || _tc_bad "[github-issues] the list must drop the PR the issues route returns"
grep -q '^gh api -X PATCH repos/o/r/issues/101 -f state=closed$' "$T/run/gh.log" && _tc_ok || _tc_bad "[github-issues] TRK_LOG records the close: $(cat "$T/run/gh.log")"
out=$(TRK_SLUG=o/r tracker_read 104 2>"$T/run/partial.err"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && _tc_ok || _tc_bad "[github-issues] a thread at the 200-comment cap is a partial read, rc 1 (rc=$rc)"
grep -q 'not read to the end' "$T/run/partial.err" && _tc_ok || _tc_bad "[github-issues] the partial read says so: $(cat "$T/run/partial.err")"
TC_S="$T/gs"; tc_reset; tc_arm transition_noop
tracker_transition 101 closed >/dev/null; rc=$?
[ "$rc" = 1 ] && _tc_ok || _tc_bad "[github-issues] a 200 whose issue is still open is not a close (rc=$rc)"
tc_reset

tracker_contract_run board
[ ! -e "$T/bs/authbad" ] && _tc_ok || _tc_bad "[board] a call went out without the token: $(cat "$T/bs/authbad")"
grep -q "Authorization: Bearer \$XOS_INTERNAL_API_TOKEN" "$T/run/board.log" && _tc_ok || _tc_bad "[board] the log names the token variable: $(head -2 "$T/run/board.log")"
[ "$(tracker_read cmT1 | jq -r '.key + "|" + .body + "|" + (.comments[0].author)')" = 'XO-1|<p>Ship the export.</p>|Client User' ] \
  && _tc_ok || _tc_bad "[board] key, description and author mapping: $(tracker_read cmT1)"
[ "$(tracker_read cmQ1 | jq -c '[.waitingOn, .triageVerdict, .comments[0].internal]')" = '["client","needs_clarification",true]' ] \
  && _tc_ok || _tc_bad "[board] the turn, the verdict and isInternal: $(tracker_read cmQ1)"

# Jira runs LAST: tc_setup_jira puts its own curl stub ahead of the board's.
tracker_contract_run jira
[ "$(tracker_list | jq -c '[.[].id]')" = '["CROM-1","CROM-2"]' ] && _tc_ok || _tc_bad "[jira] the two search pages, merged: $(tracker_list)"
grep -qF 'curl -X POST /rest/api/3/issue/CROM-1/transitions auth=Basic($JIRA_EMAIL:$JIRA_API_TOKEN)' "$T/run/jira.log" \
  && _tc_ok || _tc_bad "[jira] TRK_LOG names the transition and the credential variables: $(head -3 "$T/run/jira.log")"
grep -qF "$JIRA_TOKEN_FX" "$T/run/jira.log" && _tc_bad "[jira] the token reached TRK_LOG" || _tc_ok
[ "$(tracker_read CROM-2 | jq -c '[.waitingOn, .triageVerdict, .comments[0].internal]')" = '["Client","needs_clarification",true]' ] \
  && _tc_ok || _tc_bad "[jira] the mapped fields and jsdPublic:false: $(tracker_read CROM-2)"
[ ! -e "$JIRA_STUB_STATE/authbad" ] && _tc_ok || _tc_bad "[jira] a call went out with the wrong credential: $(cat "$JIRA_STUB_STATE/authbad")"

echo "tracker-contract: PASS $TC_PASS FAIL $TC_FAIL"
[ "$TC_FAIL" -eq 0 ]
