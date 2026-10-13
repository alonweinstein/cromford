#!/bin/bash
# tests/tracker-linear.bh-4077-test.sh — BH-4077: the Linear adapter of the
# tracker contract (bin/lib/tracker/linear.sh). It runs the SAME shared cases
# tests/lib/tracker-contract.sh runs for GitHub and the board (C1-C11), then the
# Linear-only facts:
#
#   L0  every call hit the stub, at the configured API, and nothing else
#   L1  every request is a POST of {query: string, variables: object}
#   L2  RATELIMITED on a 400 and HTTP 429 are 75; HTTP 401 is 1
#   L3  the list filter carries the team key and the label; pages are followed;
#       a list still paging after 10 pages is rc 1 (incomplete), never partial
#   L4  a comment thread longer than one page is rc 1, "not read to the end"
#   L5  TRK_LINEAR_STATES maps a contract status to a state by name
#   L6  no mapping: the state of the right TYPE with the lowest position
#   L7  a mapped name that matches no state is rc 1 and sends nothing
#   L8  a label that exists only on another team is rc 1 and sends nothing
#   L9  link_pr is a real attachment: url and a `PR #9 o/r` title
#   L10 the log names the key's variable, the API saw the bare key (no Bearer)
#   L11 a UUID is accepted wherever an identifier is
#   L12 waiting_on never calls Linear (Linear Asks / triage inbox are out of scope)
#   L13 sourcing the adapter twice under set -u is silent and inert
#   L-P1 a settings row `linear` resolves through the real tracker_adapter
#   L-P2 a `linear` row reaching the real file_children files nothing anywhere
#
# No network. A `curl` stub plays api.linear.app/graphql from the hand-written
# answers in tests/fixtures/tracker-linear/ (and the jobs worker for L-P1/L-P2),
# routing on the GraphQL operation name. It keeps its own write log and the
# request bodies, and never writes its argv, which is where the key rides.
#   HARNESS_TEST_SANDBOX=1 bash tests/tracker-linear.bh-4077-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/tracker-contract.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

KEY=tok-FIXTURE-SENTINEL-4077
API=https://api.linear.app/graphql
FIX="$DIR/tests/fixtures/tracker-linear"
mkdir -p "$T/h/bin" "$T/h/env" "$T/h/state" "$T/h/logs" "$T/stub" "$T/run" "$T/ls"
echo 0 > "$T/ls/seq"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
linproj   o/l  https://lin.example  -  9
scoutish  o/s  https://s.example    -  8
CONF
export HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" GH_ETAG=0 PATH="$T/stub:$PATH"
export TL_STATE="$T/ls" TL_FIX="$FIX" TL_KEY_EXPECT="$KEY" TL_API="$API"

# ---- the Linear stub --------------------------------------------------------
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
S="$TL_STATE"; F="$TL_FIX"; m=GET; url=""; data=""; out=""; fmt=""; auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift ;;
    --data-binary|-d) data="${2#@}"; shift ;;
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -m|--max-time|--connect-timeout) shift ;;
    -H) case "$2" in Authorization:*) auth="${2#Authorization: }" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
reply() { # reply <code> <body>
  if [ -n "$out" ]; then printf '%s' "$2" > "$out"; printf '%s' "$fmt" | sed "s/%{http_code}/$1/g"
  else printf '%s' "$2"; printf '%s' "$fmt" | sed "s/%{http_code}/$1/g"; fi
  exit 0
}
case "$url" in
  https://jobs.example/*)
    printf '%s %s\n' "$m" "$url" >> "$S/jobs.log"
    f="$S/setting-${url##*/}"
    [ -r "$f" ] && reply "$(head -1 "$f")" "$(sed -n '2,$p' "$f")"
    reply 404 '{"error":"no route"}' ;;
esac
seq=$(( $(cat "$S/seq" 2>/dev/null || echo 0) + 1 )); echo "$seq" > "$S/seq"
printf '%s %s %s\n' "$seq" "$m" "$url" >> "$S/reqs"
[ -n "$data" ] && [ -r "$data" ] && cp "$data" "$S/req-$seq.json"
[ "$auth" = "$TL_KEY_EXPECT" ] || echo "badauth $seq" >> "$S/authbad"
op=$(jq -r '.query // ""' "$data" 2>/dev/null | sed -nE '1s/^(query|mutation) ([A-Za-z]+).*/\2/p')
v() { jq -r --arg k "$1" '.variables[$k] // empty' "$data"; }
arm=$(cat "$S/arm" 2>/dev/null)
case "$arm" in
  ratelimit) reply 400 "$(cat "$F/ratelimited.json")" ;;
  http429)   reply 429 '{"error":"too many requests"}' ;;
  http401)   reply 401 "$(cat "$F/unauthenticated.json")" ;;
  # a partial answer: data AND errors, which is still a failure
  http200err) reply 200 "$(jq -c '. + {errors: [{message: "internal", path: ["issue", "comments"], extensions: {code: "INTERNAL_SERVER_ERROR"}}]}' "$F/issue-CRO-1.json")" ;;
esac
ident_of() { # a UUID or an identifier -> the identifier, or empty
  local f; for f in "$F"/issue-*.json; do
    jq -e --arg i "$1" '.data.issue | .id == $i or .identifier == $i' "$f" >/dev/null && { jq -r .data.issue.identifier "$f"; return; }
  done
}
issue() { # issue <identifier> — the fixture plus the labels the stub added
  local dyn="$S/labels-$1.json"; [ -s "$dyn" ] || echo '[]' > "$dyn"
  jq -c --slurpfile d "$dyn" '.data.issue.labels.nodes += $d[0]' "$F/issue-$1.json"
}
label_name() { jq -r --arg i "$1" '.data.issueLabels.nodes[] | select(.id == $i) | .name' "$F/labels.json"; }
wn() { echo "$1" >> "$S/writes"; grep -cE '^(comment|attachment) ' "$S/writes"; }
case "$op" in
  TrkIssues)
    [ "$arm" = list_endless ] && reply 200 "$(cat "$F/issues-page1.json")"
    case "$(v after)" in "") reply 200 "$(cat "$F/issues-page1.json")" ;; cursor-p1) reply 200 "$(cat "$F/issues-page2.json")" ;; esac
    reply 200 '{"data":{"issues":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}' ;;
  TrkIssue|TrkIssueMeta)
    i=$(ident_of "$(v id)"); [ -n "$i" ] && reply 200 "$(issue "$i")"
    reply 200 "$(cat "$F/not-found.json")" ;;
  TrkLabels)
    reply 200 "$(jq -c --arg n "$(v name)" '.data.issueLabels.nodes |= map(select((.name | ascii_downcase) == ($n | ascii_downcase)))' "$F/labels.json")" ;;
  TrkComment)
    i=$(ident_of "$(v id)"); [ -n "$i" ] || reply 200 "$(cat "$F/not-found.json")"
    k=$(wn "comment $i"); jq -j '.variables.body' "$data" > "$S/body-$k"
    [ "$arm" = comment_fail ] && reply 200 '{"data":{"commentCreate":{"success":false,"comment":null}}}'
    reply 200 '{"data":{"commentCreate":{"success":true,"comment":{"id":"00000000-0000-0000-0000-c00000000001"}}}}' ;;
  TrkUpdate)
    i=$(ident_of "$(v id)"); [ -n "$i" ] || reply 200 "$(cat "$F/not-found.json")"
    sid=$(v stateId); name=$(jq -r --arg s "$sid" '.data.issue.team.states.nodes[] | select(.id == $s) | .name' "$F/issue-$i.json")
    case "$name" in Todo) w=todo ;; "In Progress") w=in_progress ;; "In Review") w=review ;; Done) w=done ;; Canceled) w=closed ;; *) w="$name" ;; esac
    wn "status $i $w" >/dev/null
    [ "$arm" = transition_fail ] && sid=$(jq -r .data.issue.state.id "$F/issue-$i.json")
    reply 200 "$(jq -nc --arg s "$sid" '{data:{issueUpdate:{success:true, issue:{state:{id:$s}}}}}')" ;;
  TrkAddLabel|TrkRemoveLabel)
    i=$(ident_of "$(v id)"); l=$(label_name "$(v labelId)"); dyn="$S/labels-$i.json"
    [ -s "$dyn" ] || echo '[]' > "$dyn"
    if [ "$op" = TrkAddLabel ]; then
      wn "label_add $i $l" >/dev/null
      jq -c --arg i "$(v labelId)" --arg n "$l" '. + [{id:$i, name:$n}]' "$dyn" > "$dyn.new"
    else
      wn "label_remove $i $l" >/dev/null
      jq -c --arg i "$(v labelId)" 'map(select(.id != $i))' "$dyn" > "$dyn.new"
    fi
    mv "$dyn.new" "$dyn"
    reply 200 "{\"data\":{\"$( [ "$op" = TrkAddLabel ] && echo issueAddLabel || echo issueRemoveLabel )\":{\"success\":true}}}" ;;
  TrkAttach)
    i=$(ident_of "$(v id)"); [ -n "$i" ] || reply 200 "$(cat "$F/not-found.json")"
    k=$(wn "attachment $i"); printf '%s %s' "$(v url)" "$(v title)" > "$S/body-$k"
    reply 200 '{"data":{"attachmentLinkURL":{"success":true,"attachment":{"id":"00000000-0000-0000-0000-a00000000001"}}}}' ;;
esac
reply 400 '{"errors":[{"message":"unknown operation","extensions":{"code":"GRAPHQL_VALIDATION_FAILED"}}]}'
SH
# ---- gh: L-P2 must never reach it ----------------------------------------------
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
echo "gh $*" >> "$TL_STATE/gh.log"
exit 1
SH
chmod +x "$T/stub/curl" "$T/stub/gh"

# ---- setup and stub hooks -----------------------------------------------------
. "$DIR/bin/lib/tracker.sh" || exit 1
tc_reset()  { rm -f "$T/ls/writes" "$T/ls/arm" "$T/ls"/body-* "$T/ls"/labels-*.json; }
tc_arm()    { printf '%s' "$1" > "$T/ls/arm"; }
tc_writes() { cat "$T/ls/writes" 2>/dev/null; }
tc_body()   { cat "$T/ls/body-$1" 2>/dev/null; }
tc_setup_linear() {
  tracker_load linear || return 1
  TRK_LINEAR_TOKEN="$KEY"; TRK_LINEAR_TOKEN_VAR=LINEAR_API_KEY; TRK_LINEAR_TEAM=CRO
  TRK_LINEAR_API="$API"; TRK_LINEAR_STATES=""; TRK_LOG="$T/run/linear.log"; TRK_ERR="$T/run/curl.err"
  TRK_DRY=0; TRK_REQ_FILE=""
  TC_PROJECT=linproj; TC_T=CRO-1; TC_Q=CRO-2; TC_M=CRO-999; TC_TERMINAL="done"; TC_Q_WAIT=OK; TC_LABELS=1
  TC_LINK_WRITE=attachment
  TC_SECRET="$KEY"; TC_SCAN_ROOT="$T/run $T/ls $FIX $T/h/state $T/h/logs"
}

tracker_contract_run linear

# ---- Linear-only facts ---------------------------------------------------------
ok() { _tc_ok; }; bad() { TC_A=linear _tc_bad "$1"; }
req_of() { # req_of <op> — the newest request body for that operation
  local n; for n in $(ls "$T/ls"/req-*.json 2>/dev/null | sed 's/.*req-\([0-9]*\)\.json/\1/' | sort -rn); do
    jq -e --arg o "$1" '.query | test("^(query|mutation) " + $o + "\\b")' "$T/ls/req-$n.json" >/dev/null 2>&1 && { cat "$T/ls/req-$n.json"; return 0; }
  done; return 1
}

# L0
[ -s "$T/ls/reqs" ] && ok || bad "L0 the stub never answered"
[ "$(awk '{print $3}' "$T/ls/reqs" | sort -u)" = "$API" ] && ok || bad "L0 a call went somewhere other than $API: $(awk '{print $3}' "$T/ls/reqs" | sort -u)"
# L1
[ "$(awk '$2 != "POST"' "$T/ls/reqs" | grep -c .)" = 0 ] && ok || bad "L1 a request was not a POST: $(awk '$2 != "POST"' "$T/ls/reqs")"
nbad=0; nreq=0
for r in "$T/ls"/req-*.json; do
  nreq=$((nreq+1))
  jq -e '(.query | type == "string" and test("^(query|mutation) Trk")) and (.variables | type == "object")' "$r" >/dev/null 2>&1 || nbad=$((nbad+1))
done
[ "$nbad" = 0 ] && [ "$nreq" = "$(grep -c . "$T/ls/reqs")" ] && ok || bad "L1 $nbad request bodies are not {query, variables}"

# L2
tc_reset; tc_arm ratelimit; tracker_read CRO-1 >/dev/null 2>&1; rc=$?
[ "$rc" = 75 ] && ok || bad "L2 RATELIMITED on a 400 must be 75 (rc=$rc)"
tc_reset; tc_arm http429; tracker_read CRO-1 >/dev/null 2>&1; rc=$?
[ "$rc" = 75 ] && ok || bad "L2 HTTP 429 must be 75 (rc=$rc)"
tc_reset; tc_arm http401; tracker_read CRO-1 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok || bad "L2 HTTP 401 must be 1 (rc=$rc)"
tc_reset; tc_arm http200err; out=$(tracker_read CRO-1 2>/dev/null); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "L2 a 200 carrying errors must be 1 with no output (rc=$rc out=$out)"
tc_reset

# L3
out=$(tracker_list); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -c '[.[].id]')" = '["CRO-1","CRO-2"]' ] && ok || bad "L3 page 2 must be followed and merged (rc=$rc): $out"
[ "$(printf '%s' "$out" | jq -c '.[0] | [.key, .status, .labels, .url, .waitingOn]')" = '["CRO-1","Todo",["ai-build","feature"],"https://linear.app/crosstest/issue/CRO-1/ledger-export",null]' ] \
  && ok || bad "L3 the list row shape: $out"
req_of TrkIssues | jq -e '.variables.team == "CRO" and .variables.label == "ai-build" and .variables.after == "cursor-p1"' >/dev/null \
  && ok || bad "L3 the list request carries team CRO, label ai-build, the page cursor: $(req_of TrkIssues | jq -c .variables)"
req_of TrkIssues | jq -e '.query | test("team: \\{ key: \\{ eq: \\$team") and test("nin: \\[\"completed\", \"canceled\"\\]")' >/dev/null \
  && ok || bad "L3 the list filter: $(req_of TrkIssues | jq -r .query)"
TRK_LINEAR_LABEL=Ready tracker_list >/dev/null; req_of TrkIssues | jq -e '.variables.label == "Ready"' >/dev/null && ok || bad "L3 TRK_LINEAR_LABEL is the list label"
tc_arm list_endless; s0=$(cat "$T/ls/seq")
out=$(tracker_list 2>"$T/run/list.err"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "L3 a list still paging after the cap must be rc 1 with no output (rc=$rc)"
[ "$(( $(cat "$T/ls/seq") - s0 ))" = 10 ] && ok || bad "L3 the list must read exactly 10 pages: $(( $(cat "$T/ls/seq") - s0 ))"
grep -q 'incomplete' "$T/run/list.err" && ok || bad "L3 the capped list says so: $(cat "$T/run/list.err")"
tc_reset
out=$(TRK_LINEAR_TEAM="" tracker_list 2>/dev/null); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "L3 an empty team must be rc 1 (rc=$rc)"
out=$(TRK_LINEAR_TEAM="" tracker_read CRO-1 | jq -r .id); [ "$out" = CRO-1 ] && ok || bad "L3 read by identifier needs no team: $out"

# L4
out=$(tracker_read CRO-3 2>"$T/run/partial.err"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "L4 a thread past one page must be rc 1 with no output (rc=$rc)"
grep -q 'not read to the end' "$T/run/partial.err" && ok || bad "L4 the partial read says so: $(cat "$T/run/partial.err")"
# the normalized read, beyond C2's key list
[ "$(tracker_read CRO-1 | jq -c '[.key, .body, .status, .url, [.comments[].author]]')" = '["CRO-1","Ship the export.","Todo","https://linear.app/crosstest/issue/CRO-1/ledger-export",["client","Harness","client"]]' ] \
  && ok || bad "L4 key, description, state name, url, authors (bot actor too): $(tracker_read CRO-1 | jq -c .)"

sid() { jq -r --arg n "$1" '.data.issue.team.states.nodes[] | select(.name == $n) | .id' "$FIX/issue-CRO-1.json"; }
# L5
tc_reset
TRK_LINEAR_STATES='{"review":"code review"}' tracker_transition CRO-1 review >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(req_of TrkUpdate | jq -r .variables.stateId)" = "$(sid 'Code Review')" ] && ok || bad "L5 a mapped name (case-insensitive) wins: rc=$rc $(req_of TrkUpdate | jq -c .variables)"
tc_reset; tracker_transition CRO-1 review >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(req_of TrkUpdate | jq -r .variables.stateId)" = "$(sid 'In Review')" ] && ok || bad "L5 unmapped review is the state named In Review: rc=$rc"
tc_reset; tracker_transition CRO-1 closed >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(tc_writes)" = "status CRO-1 closed" ] && ok || bad "L5 closed is the canceled state: rc=$rc $(tc_writes)"
# L6
tc_reset; tracker_transition CRO-1 in_progress >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(req_of TrkUpdate | jq -r .variables.stateId)" = "$(sid 'In Progress')" ] && ok || bad "L6 two started states: the lowest position (In Progress, not Doing) rc=$rc: $(tc_writes)"
# L7
tc_reset
out=$(TRK_LINEAR_STATES='{"done":"Shipped"}' tracker_transition CRO-1 "done" 2>"$T/run/l7.err"); rc=$?
[ "$rc" = 1 ] && [ "$(tc_writes | grep -c .)" = 0 ] && ok || bad "L7 a mapped name with no state must be rc 1 and send nothing (rc=$rc): $(tc_writes)"
grep -q "Shipped" "$T/run/l7.err" && ok || bad "L7 one stderr line names the missing state: $(cat "$T/run/l7.err")"
TRK_LINEAR_STATES='not json' tracker_transition CRO-1 "done" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(tc_writes | grep -c .)" = 0 ] && ok || bad "L7 an unparseable state map must be rc 1, never the type default (rc=$rc)"

# L8
tc_reset
tracker_label_add CRO-1 ops-only >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(tc_writes | grep -c .)" = 0 ] && ok || bad "L8 another team's label must be rc 1 with no write (rc=$rc): $(tc_writes)"
tracker_label_add CRO-1 no-such-label >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(tc_writes | grep -c .)" = 0 ] && ok || bad "L8 an absent label is rc 1, never created (rc=$rc)"
tracker_label_add CRO-1 FEATURE >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(tc_writes)" = "label_add CRO-1 feature" ] && ok || bad "L8 label names match case-insensitively (rc=$rc): $(tc_writes)"
tc_reset; tracker_label_remove CRO-1 AI-Build >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(tc_writes)" = "label_remove CRO-1 ai-build" ] && ok || bad "L8 remove matches case-insensitively too (rc=$rc): $(tc_writes)"

# L9
tc_reset
tracker_link_pr CRO-1 https://github.com/o/r/pull/9 >/dev/null; rc=$?
req_of TrkAttach | jq -e --arg u "$(jq -r .data.issue.id "$FIX/issue-CRO-1.json")" \
  '.variables.url == "https://github.com/o/r/pull/9" and .variables.title == "PR #9 o/r" and .variables.id == $u' >/dev/null \
  && [ "$rc" = 0 ] && ok || bad "L9 the attachment's url, title and issue UUID: $(req_of TrkAttach | jq -c .variables)"
tracker_link_pr CRO-1 https://github.com/o/r/issues/9 >/dev/null; rc=$?
[ "$rc" = 1 ] && [ "$(tc_writes | grep -c .)" = 1 ] && ok || bad "L9 an issue URL is not a PR (rc=$rc): $(tc_writes)"

# L10
grep -q 'auth=\$LINEAR_API_KEY' "$T/run/linear.log" && ok || bad "L10 the log names the key's variable: $(head -2 "$T/run/linear.log")"
grep -qF "$KEY" "$T/run/linear.log" && bad "L10 the key reached the log" || ok
[ ! -e "$T/ls/authbad" ] && ok || bad "L10 a call carried something other than the bare key: $(cat "$T/ls/authbad")"
grep -q 'commentCreate issue=CRO-1 body=@' "$T/run/linear.log" && ok || bad "L10 a write is logged by mutation and issue: $(cat "$T/run/linear.log")"

# L11
U1=$(jq -r .data.issue.id "$FIX/issue-CRO-1.json")
[ "$(tracker_read "$U1" | jq -r .id)" = CRO-1 ] && ok || bad "L11 read by UUID"
tc_reset; tracker_comment "$U1" "$FIX/labels.json" >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(tc_writes)" = "comment CRO-1" ] && ok || bad "L11 comment by UUID (rc=$rc): $(tc_writes)"
tc_reset; tracker_comment 'CRO-1 x' "$FIX/labels.json" >/dev/null; rc=$?
[ "$rc" = 1 ] && ok || bad "L11 a malformed id is rc 1 (rc=$rc)"

# L12
s0=$(cat "$T/ls/seq")
[ "$(tracker_waiting_on linproj CRO-2)" = OK ] && [ "$(cat "$T/ls/seq")" = "$s0" ] && ok || bad "L12 waiting_on called Linear"

# L13 sourcing the adapter twice under set -u: silent, inert, nothing written
mkdir -p "$T/l13"
out=$(cd "$T/l13" && env -u HARNESS -u H bash -c 'set -u; . "$1"; . "$1"; declare -F trk_linear_read >/dev/null && echo READY' _ "$DIR/bin/lib/tracker/linear.sh" 2>&1)
[ "$out" = READY ] && [ -z "$(ls -A "$T/l13")" ] && ok || bad "L13 sourcing twice must print nothing, write nothing and define trk_linear_read: [$out]"

# L-P1 / L-P2: the real resolver and the real child filer --------------------------
run_env() { env -u HARNESS_SECRET HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/stub:$PATH" TL_STATE="$T/ls" \
  HARNESS_SECRET=x JOBS_URL=https://jobs.example JOBS_RETRIES=0 "$@"; }
printf '200\n{"setting":{"key":"tracker_adapter.scoutish","value":"linear"}}\n' > "$T/ls/setting-tracker_adapter.scoutish"
out=$(run_env bash -c 'set -u; . "$1" || exit 9; a=$(tracker_adapter scoutish); r=$?; tracker_load "$a" || exit 8; printf "%s rc=%s %s|%s" "$a" "$r" "$TRK_ADAPTER" "$TRACKER_ADAPTERS"' _ "$DIR/bin/lib/tracker.sh" 2>&1)
# TEST-CHANGE (merge of main, BH-4076 Jira landed first): the default adapter list now also names jira.
[ "$out" = "linear rc=0 linear|github-issues board jira linear" ] && ok || bad "L-P1 row linear: [$out]"
grep -q 'settings/tracker_adapter.scoutish' "$T/ls/jobs.log" 2>/dev/null && ok || bad "L-P1 the row was never asked for"
B="$T/lp2"; mkdir -p "$B"; echo '[{"title":"a","after":[],"body":"b"}]' > "$B/children.json"
rm -f "$T/ls/gh.log" "$T/ls/jobs.log"; s0=$(cat "$T/ls/seq")
run_env bash -c '. "$1" || exit 9; file_children scoutish 552 TK-552 "$2" "$2/children.json"' _ "$DIR/bin/lib/file-children.sh" "$B" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok || bad "L-P2 file_children on a linear row rc=$rc, want 1"
grep -q 'FILE_CHILDREN no child-filing lane for linear (scoutish)' "$B/pipeline.log" 2>/dev/null && ok || bad "L-P2 pipeline.log: $(cat "$B/pipeline.log" 2>/dev/null)"
grep -q 'unresolved' "$B/pipeline.log" 2>/dev/null && bad "L-P2 a valid row logged as unresolved" || ok
[ ! -s "$T/ls/gh.log" ] && [ "$(cat "$T/ls/seq")" = "$s0" ] && [ "$(grep -vc 'jobs.example/api/settings/' "$T/ls/jobs.log" 2>/dev/null)" = 0 ] \
  && ok || bad "L-P2 a tracker was called: $(cat "$T/ls/gh.log" 2>/dev/null) seq $s0 -> $(cat "$T/ls/seq")"
[ ! -e "$B/children.txt" ] && ok || bad "L-P2 children.txt written"

# C11 again, after the Linear-only cases wrote more files
LEAK=$(grep -rlF -- "$KEY" "$T/run" "$T/ls" "$FIX" "$T/lp2" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "the key reached: $LEAK"

echo "tracker-linear.bh-4077: PASS $TC_PASS FAIL $TC_FAIL"
[ "$TC_FAIL" -eq 0 ]
