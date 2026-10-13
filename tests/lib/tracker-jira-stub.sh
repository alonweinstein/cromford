#!/bin/bash
# tests/lib/tracker-jira-stub.sh — the Jira Cloud gateway, played from the
# fixtures in tests/fixtures/tracker-jira/ (BH-4076), plus the jobs-worker
# settings route the adapter reads its allowlists from. Shared by
# tests/tracker-contract-test.sh, tests/jira-sandbox-guard-test.sh and
# tests/tracker-jira.bh-4076-test.sh. No network.
#
#   jira_stub_setup <scratch root>   writes the stubs, the jproj env file and the
#                                    default settings rows; exports what the
#                                    stubs and the adapter read; PATH gains the
#                                    stub dir
#   jira_set <key> <value>           one settings row (200)
#   jira_unset <key>                 drop a row (the worker then answers 404)
#   jira_requests                    every gateway request since the last reset of
#                                    `requests`, `<METHOD> <path?query>`;
#                                    `requests.all` keeps every one, never reset
#   jira_req_count [<pattern>]       how many of them match (grep -E)
#   tc_setup_jira                    the tracker contract setup (tests/lib/tracker-contract.sh)
#
# THE STUB STATE ($JIRA_STUB_STATE) uses the contract's file names: `writes`
# (`comment <KEY>`, `status <KEY> <Jira status>`, `label_add <KEY> <l>`,
# `label_remove <KEY> <l>`), `arm`, `body-<n>` (the comment's text) and
# `body-<n>.json` (the ADF it arrived as). An issue's status and labels are its
# fixture plus the writes since the last reset, so a reset restores both.
# Arms: ratelimit (429), comment_fail (400), comment_401, transition_fail (204,
# status unchanged), transitions_dup (two transitions into Done),
# transitions_nodone (no done-category transition), search_endless (every
# search page carries a nextPageToken), myself_500, verify_503 (the
# post-transition status GET answers 503).
# CROM-9 is always answered with the moved issue CLNT-88.
#
# The stub never records a header: the token rides there. It checks the Basic
# credential against JIRA_STUB_AUTH and answers 401 (and notes `authbad`) when
# it is wrong.

JIRA_CLOUD=33333333-3333-3333-3333-333333333333
JIRA_GW="https://api.atlassian.com/ex/jira/$JIRA_CLOUD"
JIRA_TOKEN_FX=tok-FIXTURE-SENTINEL-4075
JIRA_EMAIL_FX=harness@example.com

jira_stub_setup() {
  local root="$1" here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  mkdir -p "$root/jstub" "$root/js" "$root/h/env" "$root/h/state" "$root/h/logs" "$root/h/bin" || return 1
  export JIRA_STUB_STATE="$root/js" JIRA_STUB_FIX="$here/../fixtures/tracker-jira" JIRA_STUB_GW="$JIRA_GW"
  JIRA_STUB_AUTH="Basic $(printf '%s:%s' "$JIRA_EMAIL_FX" "$JIRA_TOKEN_FX" | base64 | tr -d '\n')"
  export JIRA_STUB_AUTH
  export HARNESS="$root/h" HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.example JOBS_RETRIES=0 JOBS_TIMEOUT=5
  case ":$PATH:" in *":$root/jstub:"*) ;; *) export PATH="$root/jstub:$PATH" ;; esac
  cat > "$root/h/env/jproj.env" <<CONF
JIRA_BASE=$JIRA_GW
JIRA_EMAIL=$JIRA_EMAIL_FX
JIRA_API_TOKEN=$JIRA_TOKEN_FX
JIRA_SITE=https://sandbox-example.atlassian.net
CONF
  _jira_write_curl "$root/jstub/curl"
  cat > "$root/jstub/gh" <<'SH'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$JIRA_STUB_STATE/gh.log"
exit 1
SH
  chmod +x "$root/jstub/curl" "$root/jstub/gh"
  rm -f "$JIRA_STUB_STATE"/setting-*
  jira_set tracker_adapter.jproj jira
  jira_set tracker_jira.jproj.write_projects CROM
  jira_set tracker_jira.jproj.comment_projects CMNT
  jira_set tracker_jira.jproj.read_projects "CROM CMNT"
  jira_set tracker_jira.jproj.waiting_on_field customfield_10050
  jira_set tracker_jira.jproj.triage_verdict_field customfield_10051
}

jira_set() {
  jq -n --arg k "$1" --arg v "$2" '{setting:{key:$k,value:$v}}' | { echo 200; cat; } > "$JIRA_STUB_STATE/setting-$1"
}
jira_unset() { rm -f "$JIRA_STUB_STATE/setting-$1"; }
jira_requests() { cat "$JIRA_STUB_STATE/requests" 2>/dev/null; }
jira_req_count() { jira_requests | grep -cE -- "${1:-.}"; }

_jira_write_curl() {
  cat > "$1" <<'SH'
#!/bin/bash
S="$JIRA_STUB_STATE"; F="$JIRA_STUB_FIX"; m=GET; url=""; data=""; out=""; fmt=""; auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift ;;
    --data-binary|-d) data="${2#@}"; shift ;;
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -m|--max-time|--connect-timeout|-u) shift ;;
    -H) case "$2" in "Authorization: Basic "*) auth="${2#Authorization: }" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
emit() { # emit <code> <body>
  if [ -n "$out" ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi
  [ -n "$fmt" ] && printf '%s' "$fmt" | sed "s/%{http_code}/$1/g"
  exit 0
}
fx() { # fx <name> — the state copy wins over the fixture
  if [ -r "$S/$1" ]; then cat "$S/$1"; elif [ -r "$F/$1" ]; then cat "$F/$1"; else return 1; fi
}
case "$url" in
  https://jobs.example/api/settings/*)
    key="${url##*/}"; echo "$key" >> "$S/settings.log"
    [ -e "$S/settings-down" ] && emit 503 '{"error":"down"}'
    f="$S/setting-$key"
    [ -r "$f" ] && emit "$(head -1 "$f")" "$(sed -n '2,$p' "$f")"
    emit 404 '{"error":"no such setting"}' ;;
  https://jobs.example/*) emit 404 '{}' ;;
  "$JIRA_STUB_GW"/*) ;;
  *) echo "OFFBASE $m $url" | tee -a "$S/requests.all" >> "$S/requests"; [ -n "$fmt" ] && printf '000'; exit 7 ;;
esac
pq="${url#"$JIRA_STUB_GW"}"; path="${pq%%\?*}"; query=""; case "$pq" in *\?*) query="${pq#*\?}" ;; esac
printf '%s %s\n' "$m" "$pq" | tee -a "$S/requests.all" >> "$S/requests"
[ "$auth" = "$JIRA_STUB_AUTH" ] || { echo "badauth $m $path" >> "$S/authbad"; emit 401 '{"errorMessages":["Unauthorized"]}'; }
arm=$(cat "$S/arm" 2>/dev/null)
[ "$arm" = ratelimit ] && emit 429 '{"errorMessages":["Rate limit exceeded."]}'
qv() { printf '%s' "$query" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
issue_file() { [ "$1" = CROM-9 ] && { fx issue-CROM-9-moved.json; return; }; fx "issue-$1.json"; }
transitions() {
  local t; t=$(fx transitions-CROM-1.json) || return 1
  case "$arm" in
    transitions_dup) printf '%s' "$t" | jq -c '.transitions += [(.transitions[] | select(.to.name == "Done") | .id = "41" | .name = "Close")]' ;;
    transitions_nodone) printf '%s' "$t" | jq -c '.transitions |= map(select(.to.statusCategory.key != "done"))' ;;
    *) printf '%s' "$t" ;;
  esac
}
# The issue as it stands now: the fixture, its status moved by every status
# write since the reset (unless the transition_fail arm is up), its labels
# changed by every label write.
current() {
  local k="$1" j st labels verb wk l
  j=$(issue_file "$k") || return 1
  labels=$(printf '%s' "$j" | jq -c '.fields.labels // []')
  st=""
  while read -r verb wk l; do
    [ "$wk" = "$k" ] || continue
    case "$verb" in
      label_add) labels=$(printf '%s' "$labels" | jq -c --arg l "$l" '. + [$l] | unique') ;;
      label_remove) labels=$(printf '%s' "$labels" | jq -c --arg l "$l" 'map(select(. != $l))') ;;
      status) [ "$arm" = transition_fail ] || st="$l" ;;
    esac
  done < <(cat "$S/writes" 2>/dev/null)
  printf '%s' "$j" | jq -c --argjson l "$labels" --arg st "$st" \
    '.fields.labels = $l | if $st == "" then . else .fields.status.name = $st | .fields.status.statusCategory.key = (if $st == "Done" then "done" else "indeterminate" end) end'
}
k=""
case "$path" in /rest/api/3/issue/*) k="${path#/rest/api/3/issue/}"; k="${k%%/*}" ;; esac
case "$m $path" in
  "GET /rest/api/3/myself")
    [ "$arm" = myself_500 ] && emit 500 '{"errorMessages":["Internal server error"]}'
    emit 200 "$(fx myself.json)" ;;
  "POST /rest/api/3/search/jql")
    n=$(ls "$S"/search-req-*.json 2>/dev/null | wc -l); cp "$data" "$S/search-req-$((n+1)).json"
    tok=$(jq -r '.nextPageToken // empty' "$data")
    [ "$arm" = search_endless ] && emit 200 "$(fx search-page1.json)"
    [ -z "$tok" ] && emit 200 "$(fx search-page1.json)"
    [ "$tok" = "$(fx search-page1.json | jq -r .nextPageToken)" ] && emit 200 "$(fx search-page2.json)"
    emit 400 '{"errorMessages":["Invalid nextPageToken"]}' ;;
  "GET /rest/api/3/issue/"*/comment)
    issue_file "$k" >/dev/null || emit 404 '{"errorMessages":["Issue does not exist or you do not have permission to see it."]}'
    c=$(fx "comments-$k.json") || c='{"startAt":0,"maxResults":100,"total":0,"comments":[]}'
    sa=$(qv startAt); mr=$(qv maxResults)
    emit 200 "$(printf '%s' "$c" | jq -c --argjson s "${sa:-0}" --argjson n "${mr:-50}" '.comments as $all | {startAt:$s, maxResults:$n, total:($all|length), comments:$all[$s:($s+$n)]}')" ;;
  "GET /rest/api/3/issue/"*/transitions)
    issue_file "$k" >/dev/null || emit 404 '{"errorMessages":["Issue does not exist"]}'
    emit 200 "$(transitions)" ;;
  "POST /rest/api/3/issue/"*/transitions)
    id=$(jq -r '.transition.id' "$data")
    to=$(transitions | jq -r --arg id "$id" '.transitions[] | select(.id == $id) | .to.name')
    [ -n "$to" ] || emit 400 '{"errorMessages":["Transition id is not valid for this issue."]}'
    echo "status $k $to" >> "$S/writes"
    emit 204 '' ;;
  "POST /rest/api/3/issue/"*/comment)
    echo "comment $k" >> "$S/writes"; n=$(grep -c '^comment' "$S/writes")
    cp "$data" "$S/body-$n.json"
    jq -j 'def t: if .type == "text" then .text elif .type == "hardBreak" then "\n" else ([.content[]? | t] | join("")) end;
           [.body.content[] | t] | join("\n\n")' "$data" > "$S/body-$n"
    [ "$arm" = comment_fail ] && emit 400 '{"errorMessages":["Comment body is not valid!"]}'
    [ "$arm" = comment_401 ] && emit 401 '{"errorMessages":["Unauthorized"]}'
    emit 201 '{"id":"20999","created":"2026-10-04T00:00:00.000+0000"}' ;;
  "PUT /rest/api/3/issue/"*)
    op=$(jq -r '.update.labels[0] | keys[0]' "$data"); l=$(jq -r '.update.labels[0][]' "$data")
    case "$op" in add) echo "label_add $k $l" >> "$S/writes" ;; remove) echo "label_remove $k $l" >> "$S/writes" ;; *) emit 400 '{}' ;; esac
    emit 204 '' ;;
  "GET /rest/api/3/issue/"*)
    [ "$arm" = verify_503 ] && [ "$(qv fields)" = status ] && emit 503 '{"errorMessages":["Service unavailable"]}'
    j=$(current "$k") || emit 404 '{"errorMessages":["Issue does not exist or you do not have permission to see it."],"errors":{}}'
    emit 200 "$j" ;;
esac
emit 404 '{"errorMessages":["no route"]}'
SH
}

# The contract setup: tests/tracker-contract-test.sh runs it LAST, so the stub
# dir it puts on PATH shadows the board stub only for the Jira run.
tc_setup_jira() {
  jira_stub_setup "$T" || return 1
  tracker_load jira || return 1
  TC_S="$JIRA_STUB_STATE"
  TRK_LOG="$T/run/jira.log"; TRK_ERR="$T/run/jira-curl.err"; TRK_DRY=0; TRK_REQ_FILE=""
  trk_jira_context jproj || return 1
  TC_PROJECT=jproj; TC_T=CROM-1; TC_Q=CROM-2; TC_M=CROM-404; TC_TERMINAL=Done
  TC_Q_WAIT="BLOCKED waitingOn=client"; TC_LABELS=1
  # The env file holds the token by design; what is scanned is everything else.
  TC_SECRET="$JIRA_TOKEN_FX"; TC_SCAN_ROOT="$T/run $JIRA_STUB_STATE $T/h/state $T/h/logs"
}
