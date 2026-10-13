#!/bin/bash
# shellcheck shell=bash
# bin/lib/jobs/hub-probe.sh — BH-3447 (BH-3434.0) contract: the hub-probe request ledger verbs over worker/jobs/src/routes/hub-probe.js and hub-probe-count.js. Sourced by bin/jobs-client.sh (JC_MODULES), never run.

# --- hub-probe ledger ---------------------------------------------------------
# hp_request <project> <ticket_key> <probe> <args_json> <requested_by>
#   POST /api/hub-probe. Prints the {created,row} answer as compact JSON.
# hp_claim <claimed_by> <n>
#   POST /api/hub-probe/claim. Prints the claimed rows as a compact JSON array.
# hp_result <id> <pass|fail|rejected> <http_status> <output_file>
#   POST /api/hub-probe/result with the file's text as `output`. rc 0 on {"ok":true}.
# hp_commented <id>
#   POST /api/hub-probe/commented. rc 0 on {"ok":true}.
# hp_list <project> <ticket_key>
#   GET /api/hub-probe?project=&ticket=. Prints the rows as a compact JSON array.
# hp_count_today <probe>
#   GET /api/hub-probe/count-today?probe=. Prints the integer.
# hp_d1_count <table> <template>
#   GET /api/hub-probe/count?table=&template=. Prints the integer.
#
# Every failure is rc 1 with nothing on stdout: a bad argument (checked before
# any call), a 4xx, a 5xx, a transport error, an unconfigured client, and a 2xx
# that lacks the field the verb reads or carries it with the wrong type.

_hp_uri() { jq -rn --arg v "$1" '$v|@uri'; }

hp_request() {
  [ $# -eq 5 ] || return 1
  local body out
  body=$(jq -nc --arg p "$1" --arg k "$2" --arg pr "$3" --argjson a "$4" --arg by "$5" \
    '{project:$p, ticket_key:$k, probe:$pr, args:$a, requested_by:$by}' 2>/dev/null) || return 1
  out=$(_jobs_req POST /api/hub-probe "$body") || return 1
  out=$(printf '%s' "$out" | jq -c 'if (.created|type) == "boolean" and (.row|type) == "object"
    then {created, row} else empty end' 2>/dev/null)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

hp_claim() {
  [ $# -eq 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || return 1
  local body out
  body=$(jq -nc --arg c "$1" --argjson n "$2" '{claimed_by:$c, n:$n}') || return 1
  out=$(_jobs_req POST /api/hub-probe/claim "$body") || return 1
  _hp_rows "$out"
}

hp_result() {
  [ $# -eq 4 ] && [ -f "$4" ] && [ -r "$4" ] || return 1
  case "$2" in pass|fail|rejected) ;; *) return 1 ;; esac
  local body out
  body=$(jq -Rsc --arg i "$1" --arg r "$2" --arg s "$3" \
    '{id:($i|tonumber? // $i), result:$r, http_status:($s|tonumber? // $s), output:.}' < "$4") || return 1
  out=$(_jobs_req POST /api/hub-probe/result "$body") || return 1
  _hp_ok "$out"
}

hp_commented() {
  [ $# -eq 1 ] || return 1
  local body out
  body=$(jq -nc --arg i "$1" '{id:($i|tonumber? // $i)}') || return 1
  out=$(_jobs_req POST /api/hub-probe/commented "$body") || return 1
  _hp_ok "$out"
}

hp_list() {
  [ $# -eq 2 ] || return 1
  local out
  out=$(_jobs_req GET "/api/hub-probe?project=$(_hp_uri "$1")&ticket=$(_hp_uri "$2")") || return 1
  _hp_rows "$out"
}

hp_count_today() {
  [ $# -eq 1 ] || return 1
  local out
  out=$(_jobs_req GET "/api/hub-probe/count-today?probe=$(_hp_uri "$1")") || return 1
  _hp_count "$out"
}

hp_d1_count() {
  [ $# -eq 2 ] || return 1
  local out
  out=$(_jobs_req GET "/api/hub-probe/count?table=$(_hp_uri "$1")&template=$(_hp_uri "$2")") || return 1
  _hp_count "$out"
}

# _hp_rows <answer> — prints .rows compact, only when it is an array.
_hp_rows() {
  local out
  out=$(printf '%s' "$1" | jq -c 'if (.rows|type) == "array" then .rows else empty end' 2>/dev/null)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# _hp_count <answer> — prints .count, only when it is a number.
_hp_count() {
  local out
  out=$(printf '%s' "$1" | jq -r 'if (.count|type) == "number" then .count else empty end' 2>/dev/null)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# _hp_ok <answer> — rc 0 only on {"ok":true}.
_hp_ok() { printf '%s' "$1" | jq -e '.ok == true' >/dev/null 2>&1 || return 1; }
