#!/bin/bash
# tests/tracker-jira.bh-4076-test.sh — BH-4076: the Jira Cloud adapter
# "$DIR/bin/lib/tracker/jira.sh" facts the shared contract cases and the guard
# suite do not cover. Gateway stub: tests/lib/tracker-jira-stub.sh. No network.
#
#   J1  registry: a `jira` row resolves; no row on a `-` project is still github-issues
#   J2  credentials: gateway base only, the project's own env file only
#   J3  list JQL: bounded project clause, label row, mapped custom fields
#   J4  search paging: two pages merged; a 4th page with a token is rc 1
#   J4b comment paging: 150 comments read whole; 200 is a partial read, rc 1
#   J5  ADF to text (rich document, plain v2 string, null description)
#   J6  text to ADF (paragraphs, hardBreak, link mark)
#   J7  transitions: status_map alias, ambiguity, close_out by category, no
#       done transition, a 401 comment stops close_out
#   J8  neither the token nor its Basic form reaches a file
#   J9  file_children on a jira project says there is no lane, calls nothing
#   J10-J12 bin/triage-gate.sh --buildable[-strict] on Jira tickets
#
#   HARNESS_TEST_SANDBOX=1 bash tests/tracker-jira.bh-4076-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/tracker-jira-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

jira_stub_setup "$T" || { echo "stub setup failed"; exit 1; }
mkdir -p "$T/run"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
ghp      o/r  https://gh.example  -  9
jnobase  o/j  https://j.example   -  9
CONF
export FLEET_CONF="$T/h/fleet.conf"
JIRA_LIB="$DIR/bin/lib/tracker/jira.sh"
[ -r "$JIRA_LIB" ] || { echo "FAIL: $JIRA_LIB missing"; echo "tracker-jira.bh-4076: 0 passed, 1 failed"; exit 1; }
. "$DIR/bin/lib/tracker.sh" || exit 1
TRK_LOG="$T/run/jira.log"; TRK_ERR="$T/run/curl.err"; TRK_DRY=0; TRK_REQ_FILE=""
S="$JIRA_STUB_STATE"
GATE="$DIR/bin/triage-gate.sh"
fresh() { rm -f "$S/requests" "$S/writes" "$S/arm" "$S"/body-* "$S"/search-req-*.json "$S/settings.log"; }
arm() { printf '%s' "$1" > "$S/arm"; }
nw() { cat "$S/writes" 2>/dev/null | grep -c .; }
BODY="$T/run/body.txt"; printf 'Shipped it.\n' > "$BODY"

# --- J1 -------------------------------------------------------------------
[ "$(tracker_adapter jproj)" = jira ] && ok || bad "J1 a jira row: tracker_adapter answered '$(tracker_adapter jproj 2>&1)'"
( tracker_load jira && [ "$TRK_ADAPTER" = jira ] && declare -F trk_jira_read >/dev/null ) && ok || bad "J1 tracker_load jira"
[ "$(tracker_adapter ghp)" = github-issues ] && ok || bad "J1 no row on a '-' project must stay github-issues: $(tracker_adapter ghp 2>&1)"
tracker_load jira || { echo "FAIL: tracker_load jira"; exit 1; }

# --- J2 -------------------------------------------------------------------
cp "$T/h/env/jproj.env" "$T/run/jproj.env.good"
fresh; sed -i 's#^JIRA_BASE=.*#JIRA_BASE=https://sandbox-example.atlassian.net#' "$T/h/env/jproj.env"
trk_jira_context jproj 2>"$T/run/j2.err"; rc=$?
[ "$rc" = 1 ] && [ -z "${TRK_JIRA_BASE:-}" ] && ok || bad "J2 a site URL base must fail the context (rc=$rc base=${TRK_JIRA_BASE:-})"
grep -q 'api.atlassian.com/ex/jira' "$T/run/j2.err" && ok || bad "J2 stderr says the gateway is required: $(cat "$T/run/j2.err")"
tracker_read CROM-1 >/dev/null 2>&1; [ "$(jira_req_count .)" = 0 ] && ok || bad "J2 a request went out on a refused base: $(jira_requests)"
# No token in jproj.env: one in global.env and one inherited must not stand in.
grep -v '^JIRA_API_TOKEN=' "$T/run/jproj.env.good" > "$T/h/env/jproj.env"
printf 'JIRA_API_TOKEN=%s\n' "$JIRA_TOKEN_FX" > "$T/h/env/global.env"
JIRA_API_TOKEN="$JIRA_TOKEN_FX" trk_jira_context jproj 2>"$T/run/j2.err"; rc=$?
[ "$rc" = 1 ] && ok || bad "J2 no JIRA_API_TOKEN in the project's env file must fail the context (rc=$rc)"
grep -q 'JIRA_API_TOKEN' "$T/run/j2.err" && ok || bad "J2 stderr names the missing variable: $(cat "$T/run/j2.err")"
rm -f "$T/h/env/global.env"; cp "$T/run/jproj.env.good" "$T/h/env/jproj.env"
fresh; trk_jira_context jproj && ok || bad "J2 the good env file loads"
[ "$TRK_JIRA_TOKEN_VAR" = JIRA_API_TOKEN ] && [ "$TRK_JIRA_BASE" = "$JIRA_GW" ] && ok || bad "J2 context: $TRK_JIRA_BASE $TRK_JIRA_TOKEN_VAR"

# --- J3 -------------------------------------------------------------------
fresh; jira_set tracker_jira.jproj.label ai-ready; trk_jira_context jproj
tracker_list > "$T/run/j3.out"; rc=$?
[ "$rc" = 0 ] && ok || bad "J3 list rc=$rc"
[ "$(jira_requests | head -1)" = "POST /rest/api/3/search/jql" ] && ok || bad "J3 the search route: $(jira_requests)"
jql=$(jq -r .jql "$S/search-req-1.json")
case "$jql" in 'project in ("CROM","CMNT") AND '*) ok ;; *) bad "J3 the bounded project clause: $jql" ;; esac
case "$jql" in *'labels = "ai-ready"'*'statusCategory != Done'*) ok ;; *) bad "J3 the label row and the open filter: $jql" ;; esac
[ "$(jq -c '[.maxResults, (.fields | index("customfield_10050") != null), (.fields | index("customfield_10051") != null)]' "$S/search-req-1.json")" = '[50,true,true]' ] \
  && ok || bad "J3 maxResults and the mapped fields: $(cat "$S/search-req-1.json")"
[ "$(jq -c '.[0] | [.id, .key, .title, .status, .waitingOn, .triageVerdict, .url]' "$T/run/j3.out")" = '["CROM-1","CROM-1","Ledger export","To Do","Team","ready","https://sandbox-example.atlassian.net/browse/CROM-1"]' ] \
  && ok || bad "J3 the row: $(jq -c '.[0]' "$T/run/j3.out")"
jira_unset tracker_jira.jproj.label

# --- J4 -------------------------------------------------------------------
fresh; trk_jira_context jproj
[ "$(tracker_list | jq -c '[.[].key]')" = '["CROM-1","CROM-2"]' ] && ok || bad "J4 two pages merged"
[ "$(jq -r '.nextPageToken // "none"' "$S/search-req-2.json" 2>/dev/null)" = CAEaAggD ] && ok || bad "J4 page 2 carries page 1's nextPageToken"
fresh; arm search_endless
out=$(tracker_list 2>"$T/run/j4.err"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "J4 a 4th page that still has a token must be rc 1 with nothing printed (rc=$rc)"
grep -q 'list incomplete' "$T/run/j4.err" && ok || bad "J4 stderr: $(cat "$T/run/j4.err")"
[ "$(jira_req_count search)" = 4 ] && ok || bad "J4 at most 4 search pages: $(jira_req_count search)"

# --- J4b ------------------------------------------------------------------
fresh
jq -c '.comments[0] as $c | {startAt:0, maxResults:100, total:150, comments:[range(150) | . as $i | $c | .id = ("3" + ($i|tostring)) | .body = {type:"doc",version:1,content:[{type:"paragraph",content:[{type:"text",text:("c\($i)")}]}]}]}' \
  "$JIRA_STUB_FIX/comments-CROM-1.json" > "$S/comments-CROM-1.json"
out=$(tracker_read CROM-1); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq '.comments | length')" = 150 ] && ok || bad "J4b 150 comments read whole (rc=$rc)"
[ "$(printf '%s' "$out" | jq -r '.comments[149].body')" = c149 ] && ok || bad "J4b the last comment is there"
[ "$(jira_req_count '/comment\?')" = 2 ] && ok || bad "J4b two comment pages: $(jira_requests)"
jq -c '.comments[0] as $c | .total = 200 | .comments = [range(200) | $c]' "$JIRA_STUB_FIX/comments-CROM-1.json" > "$S/comments-CROM-1.json"
out=$(tracker_read CROM-1 2>"$T/run/j4b.err"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "J4b 200 comments is a partial read, rc 1 (rc=$rc)"
grep -q 'not read to the end' "$T/run/j4b.err" && ok || bad "J4b stderr: $(cat "$T/run/j4b.err")"
rm -f "$S/comments-CROM-1.json"

# --- J5 -------------------------------------------------------------------
fresh
jq --slurpfile d "$JIRA_STUB_FIX/adf-rich.json" '.key = "CROM-5" | .fields.description = $d[0]' "$JIRA_STUB_FIX/issue-CROM-1.json" > "$S/issue-CROM-5.json"
jq '.comments = [.comments[0] | .body = "plain v2 body"] | .total = 1' "$JIRA_STUB_FIX/comments-CROM-1.json" > "$S/comments-CROM-5.json"
cat > "$T/run/j5.want" <<'TXT'
Hi @Harness Bot, see the spec (https://example.com/spec) and https://example.com/card.

Line one
Line two

- Outer A
  - Inner A1
- Outer B

1. First step
2. Second step

```bash
npm run build
npm test
```
TXT
out=$(tracker_read CROM-5); rc=$?
[ "$rc" = 0 ] && ok || bad "J5 read CROM-5 rc=$rc"
printf '%s\n' "$(printf '%s' "$out" | jq -r .body)" > "$T/run/j5.got"
cmp -s "$T/run/j5.got" "$T/run/j5.want" && ok || bad "J5 ADF to text: $(diff "$T/run/j5.want" "$T/run/j5.got")"
[ "$(printf '%s' "$out" | jq -r '.comments[0].body')" = "plain v2 body" ] && ok || bad "J5 a plain string body passes through"
[ "$(tracker_read CMNT-3 | jq -c '[.body, .waitingOn, .triageVerdict]')" = '["",null,null]' ] && ok || bad "J5 a null description is \"\", null fields are null: $(tracker_read CMNT-3)"

# --- J6 -------------------------------------------------------------------
fresh
printf 'First line\nsecond line\n\nThe PR: https://github.com/o/r/pull/9\n' > "$T/run/j6.txt"
tracker_comment CROM-1 "$T/run/j6.txt" >/dev/null; rc=$?
[ "$rc" = 0 ] && ok || bad "J6 comment rc=$rc"
[ "$(jq -c '[.body.type, (.body.content | length), [.body.content[].type]]' "$S/body-1.json")" = '["doc",2,["paragraph","paragraph"]]' ] \
  && ok || bad "J6 two paragraphs: $(cat "$S/body-1.json")"
[ "$(jq -c '[.body.content[0].content[].type]' "$S/body-1.json")" = '["text","hardBreak","text"]' ] && ok || bad "J6 the single newline is a hardBreak"
[ "$(jq -c '.body.content[1].content[] | select(.marks) | [.text, .marks]' "$S/body-1.json")" = '["https://github.com/o/r/pull/9",[{"type":"link","attrs":{"href":"https://github.com/o/r/pull/9"}}]]' ] \
  && ok || bad "J6 the URL carries a link mark: $(jq -c '.body.content[1]' "$S/body-1.json")"

# --- J7 -------------------------------------------------------------------
fresh; jira_set tracker_jira.jproj.status_map 'done=Done;review=In Review'; trk_jira_context jproj
tracker_transition CROM-1 review >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$S/writes")" = "status CROM-1 In Review" ] && ok || bad "J7 the alias review=In Review (rc=$rc): $(cat "$S/writes" 2>/dev/null)"
grep -q 'POST /rest/api/3/issue/CROM-1/transitions' "$S/requests" && ok || bad "J7 the discovered transition was posted"
# A transient error on the verify GET after a 204 is 75 (retry), not 1 ("did not move").
fresh; arm verify_503
tracker_transition CROM-1 review >/dev/null 2>"$T/run/j7v.err"; rc=$?
[ "$rc" = 75 ] && ok || bad "J7 a 503 on the verify GET is 75 (rc=$rc): $(cat "$T/run/j7v.err")"
fresh; arm transitions_dup
tracker_transition CROM-1 Done >/dev/null 2>"$T/run/j7.err"; rc=$?
[ "$rc" = 1 ] && [ "$(nw)" = 0 ] && ok || bad "J7 two transitions into Done: rc 1, no write (rc=$rc): $(cat "$S/writes" 2>/dev/null)"
jira_unset tracker_jira.jproj.status_map; trk_jira_context jproj
fresh
tracker_close_out CROM-1 "$BODY" >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(tr '\n' '|' < "$S/writes")" = "comment CROM-1|status CROM-1 Done|" ] && ok || bad "J7 close_out picks the done-category transition (rc=$rc): $(cat "$S/writes" 2>/dev/null)"
fresh; arm transitions_nodone
tracker_close_out CROM-1 "$BODY" >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ "$(nw)" = 0 ] && ok || bad "J7 no done transition: rc 3 and NO write, not even the comment (rc=$rc): $(cat "$S/writes" 2>/dev/null)"
fresh; arm transitions_dup
tracker_close_out CROM-1 "$BODY" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(nw)" = 0 ] && ok || bad "J7 two done transitions: rc 1 and no write (rc=$rc)"
fresh; arm comment_401
tracker_close_out CROM-1 "$BODY" >/dev/null 2>"$T/run/j7.err"; rc=$?
[ "$rc" = 1 ] && ok || bad "J7 a 401 on the comment fails close_out (rc=$rc)"
grep -q '^status ' "$S/writes" && bad "J7 moved after the comment was refused: $(cat "$S/writes")" || ok
grep -q '401' "$T/run/j7.err" && ok || bad "J7 the 401 is named on stderr: $(cat "$T/run/j7.err")"

# --- J8 -------------------------------------------------------------------
B64=$(printf '%s:%s' "$JIRA_EMAIL_FX" "$JIRA_TOKEN_FX" | base64 | tr -d '\n')
LEAK=$(grep -rlF -e "$JIRA_TOKEN_FX" -e "$B64" "$T" 2>/dev/null | grep -v "^$T/h/env/" | grep -v "^$T/run/jproj.env.good$")
[ -z "$LEAK" ] && ok || bad "J8 the token or its Basic form reached: $LEAK"
grep -qF 'auth=Basic($JIRA_EMAIL:$JIRA_API_TOKEN)' "$TRK_LOG" && ok || bad "J8 the log names the variables: $(head -2 "$TRK_LOG")"

# --- J9 -------------------------------------------------------------------
B="$T/j9"; mkdir -p "$B"
printf '%s\n' '[{"title":"metrics table","after":[],"body":"Create the table.\n\nFiles: src/db/m.ts\n\n## Observable outcome\nIt works."}]' > "$B/children.json"
fresh; rm -f "$S/gh.log"
bash -c '. "$1" || exit 9; file_children jproj 552 CROM-552 "$2" "$2/children.json"' _ "$DIR/bin/lib/file-children.sh" "$B" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok || bad "J9 file_children on a jira project rc=$rc, want 1"
grep -q 'FILE_CHILDREN no child-filing lane for jira (jproj)' "$B/pipeline.log" 2>/dev/null && ok || bad "J9 pipeline.log: $(cat "$B/pipeline.log" 2>/dev/null)"
[ ! -s "$S/gh.log" ] && [ "$(jira_req_count .)" = 0 ] && ok || bad "J9 a tracker was called: $(cat "$S/gh.log" 2>/dev/null) $(jira_requests)"
[ ! -e "$B/children.txt" ] && ok || bad "J9 children.txt written"

# --- J10 ------------------------------------------------------------------
jira_unset tracker_jira.jproj.waiting_on_field; jira_unset tracker_jira.jproj.triage_verdict_field
fresh; trk_jira_context jproj
[ "$(tracker_read CROM-1 | jq -c '[.waitingOn, .triageVerdict]')" = '[null,null]' ] && ok || bad "J10 unmapped fields are null"
[ "$("$GATE" jproj --buildable CROM-1)" = OK ] && ok || bad "J10 gate on CROM-1 with no field rows: $("$GATE" jproj --buildable CROM-1)"
grep -q 'GET /rest/api/3/myself' "$S/requests" && ok || bad "J10 the gate asked who the token is: $(jira_requests)"

# --- J11 ------------------------------------------------------------------
jira_set tracker_jira.jproj.triage_verdict_field customfield_10051
[ "$("$GATE" jproj --buildable CROM-2)" = "BLOCKED triageVerdict=needs_clarification" ] && ok || bad "J11 CROM-2: $("$GATE" jproj --buildable CROM-2)"
[ "$("$GATE" jproj --buildable CROM-1)" = OK ] && ok || bad "J11 CROM-1 (verdict ready): $("$GATE" jproj --buildable CROM-1)"

# --- J12 ------------------------------------------------------------------
jira_set tracker_jira.jproj.waiting_on_field customfield_10050
[ "$("$GATE" jproj --buildable CROM-3)" = "BLOCKED newest-comment-system" ] && ok || bad "J12 newest comment by the token's account: $("$GATE" jproj --buildable CROM-3)"
fresh; arm myself_500
[ "$("$GATE" jproj --buildable CROM-1)" = OK ] && ok || bad "J12 /myself 500 under --buildable is fail-open OK: $("$GATE" jproj --buildable CROM-1)"
[ "$("$GATE" jproj --buildable-strict CROM-1)" = "BLOCKED unreadable" ] && ok || bad "J12 /myself 500 under --buildable-strict: $("$GATE" jproj --buildable-strict CROM-1)"
# A failed /myself must not discard a waitingOn=client already read (review BH-4076 #1).
[ "$("$GATE" jproj --buildable CROM-2)" = "BLOCKED waitingOn=client" ] && ok || bad "J12 /myself 500 still blocks a waiting ticket: $("$GATE" jproj --buildable CROM-2)"
[ "$("$GATE" jproj --buildable-strict CROM-2)" = "BLOCKED waitingOn=client" ] && ok || bad "J12 /myself 500 still blocks a waiting ticket under strict: $("$GATE" jproj --buildable-strict CROM-2)"
fresh
[ "$("$GATE" jproj --buildable CROM-404)" = OK ] && ok || bad "J12 a missing issue is unreadable, fail-open OK"
[ "$("$GATE" jproj --buildable-strict CROM-404)" = "BLOCKED unreadable" ] && ok || bad "J12 a missing issue under strict"
[ "$("$GATE" jproj --buildable-strict CLNT-5)" = "BLOCKED unreadable" ] && [ "$(jira_req_count CLNT)" = 0 ] && ok || bad "J12 an unlisted key is unreadable and never fetched"
# A project with a jira row but no JIRA_BASE never reaches the Jira arm and
# costs triage-gate no settings call.
jira_set tracker_adapter.jnobase jira
fresh
[ "$("$GATE" jnobase --buildable 7)" = OK ] && ok || bad "J12 jnobase: $("$GATE" jnobase --buildable 7)"
[ ! -s "$S/settings.log" ] && [ "$(jira_req_count .)" = 0 ] && ok || bad "J12 no JIRA_BASE, yet: $(cat "$S/settings.log" 2>/dev/null) $(jira_requests)"
# The arm also needs the row: JIRA_BASE with a board row is today's path.
jira_set tracker_adapter.jproj board
fresh
out=$("$GATE" jproj --buildable CROM-2)
[ "$(jira_req_count .)" = 0 ] && ok || bad "J12 a non-jira row took the Jira arm ($out): $(jira_requests)"
jira_set tracker_adapter.jproj jira

echo "tracker-jira.bh-4076: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
