#!/bin/bash
# shellcheck shell=bash
# bin/lib/jobs/dequeue-watch.sh — BH-3726 (BH-3719.0) contract: the dequeue-watch ledger verbs the BH-3719 siblings build against. Sourced by bin/jobs-client.sh (JC_MODULES), never run.
#
# The bodies are real since BH-3727 (BH-3719.1): each verb is one _jobs_req call
# against the worker's /api/dequeue-watch/* routes, and prints only an answer
# whose shape it checked. Arguments are checked first, so a typo costs no request.

# --- dequeue-watch ledger -----------------------------------------------------
# dqw_event_record <repo> <pr> <head> <run_id> <project> <json-extra>
#   Records one dequeue event. Prints {recorded, first, row}.
# dqw_event_state <repo> <pr> <head> <run_id> <json-fields>
#   PUT of the event's attribution, attribution_how, class, class_how, rule_id,
#   suites, fail_lines, llm_fp, llm_attempted_at, llm_class.
# dqw_events_list <repo> [pr] [since] [llm_fp]
#   Prints {rows, truncated}. The llm_fp filter is what the LLM fallback's reuse reads.
# dqw_action_claim <repo> <pr> <head> <class> <action> <project>
#   Claims one action per (pr, head, class). Prints {claimed, row}.
# dqw_action_set <repo> <pr> <head> <class> <status> [ref] [note] [action]
#   The optional action lets `observe` rows be re-claimed by update when
#   DEQUEUE_WATCH_ACT flips to 1.
# dqw_actions_list <repo> [pr] [head] [class] [action] [status]
#   Prints {rows, truncated}.
# dqw_rounds_count <repo> <pr> <class>
#   Prints the count of action=fix-round rows across heads. rc 1 = unreadable,
#   never a printed `0` (D11).
# dqw_summary [since]
#   Prints {by_class, requeues, mean_requeue_s, fix_rounds:{claimed,done,failed},
#   holds, unowned_now:null}.
#
# Every failure is rc 1 with nothing on stdout.
#
# --- names fixed here (siblings use them verbatim) -----------------------------
# class:  rule-break | scanner-fp | semantic-test | textual-conflict | bystander
#         | stale-status | flake | main-red | unclassified
# action: requeue | lead-request | fix-round | main-red-wait | hold | observe
# status: claimed | done | failed | waiting
# Fix-round reason `queue-dequeued`; cap_key `dqw-<num>-<head12>-<class>`;
# rkey `dqw-<num>-<head12>`.
# record_in.dequeue = {pr, head, class, rule_id, suite, fail_lines, hint, brief,
#   run_id, run_url, draft}
# Conductor mark `dqwculprit <slug>#<num> <head>`, written via mc_attempt_put and
# read via mc_attempt_has.

# The class/action/status words above, as the client checks them before a request.
_DQW_CLASSES=" rule-break scanner-fp semantic-test textual-conflict bystander stale-status flake main-red unclassified "
_DQW_ACTIONS=" requeue lead-request fix-round main-red-wait hold observe "
_DQW_STATUSES=" claimed done failed waiting "

dqw_event_record() {
  [ $# -eq 6 ] && [[ "$2" =~ ^[0-9]+$ ]] && [[ "$3" =~ ^[0-9a-fA-F]{40}$ ]] || return 1
  printf '%s' "$6" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  local body out
  body=$(jq -nc --arg r "$1" --argjson pr "$2" --arg h "$3" --arg id "$4" --arg p "$5" --argjson x "$6" \
    '{repo:($r|ascii_downcase), pr:$pr, head:($h|ascii_downcase), run_id:$id, project:$p, extra:$x}' 2>/dev/null) || return 1
  out=$(_jobs_req POST /api/dequeue-watch/events "$body") || return 1
  _dqw_shape "$out" '.recorded == true and (.first|type) == "boolean" and (.row|type) == "object"' '{recorded, first, row}'
}

dqw_event_state() {
  [ $# -eq 5 ] && [[ "$2" =~ ^[0-9]+$ ]] && [[ "$3" =~ ^[0-9a-fA-F]{40}$ ]] || return 1
  printf '%s' "$5" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  local body out
  body=$(jq -nc --arg r "$1" --argjson pr "$2" --arg h "$3" --arg id "$4" --argjson f "$5" \
    '$f + {repo:($r|ascii_downcase), pr:$pr, head:($h|ascii_downcase), run_id:$id}' 2>/dev/null) || return 1
  out=$(_jobs_req PUT /api/dequeue-watch/events/state "$body") || return 1
  _dqw_shape "$out" '(.row|type) == "object"' '{row, fail_lines_truncated}'
}

dqw_events_list() {
  [ $# -ge 1 ] && [ $# -le 4 ] || return 1
  [ -z "${2:-}" ] || [[ "$2" =~ ^[0-9]+$ ]] || return 1
  local out
  out=$(_jobs_req GET "/api/dequeue-watch/events$(_dqw_query repo "$1" pr "${2:-}" since "${3:-}" llm_fp "${4:-}")") || return 1
  _dqw_shape "$out" '(.rows|type) == "array" and (.truncated|type) == "boolean"' '{rows, truncated}'
}

dqw_action_claim() {
  [ $# -eq 6 ] && [[ "$2" =~ ^[0-9]+$ ]] && [[ "$3" =~ ^[0-9a-fA-F]{40}$ ]] || return 1
  _dqw_in "$4" "$_DQW_CLASSES" && _dqw_in "$5" "$_DQW_ACTIONS" || return 1
  local body out
  body=$(jq -nc --arg r "$1" --argjson pr "$2" --arg h "$3" --arg c "$4" --arg a "$5" --arg p "$6" \
    '{repo:($r|ascii_downcase), pr:$pr, head:($h|ascii_downcase), class:$c, action:$a, project:$p}' 2>/dev/null) || return 1
  out=$(_jobs_req POST /api/dequeue-watch/actions/claim "$body") || return 1
  _dqw_shape "$out" '(.claimed|type) == "boolean" and (.row|type) == "object"' '{claimed, row}'
}

dqw_action_set() {
  [ $# -ge 5 ] && [ $# -le 8 ] && [[ "$2" =~ ^[0-9]+$ ]] && [[ "$3" =~ ^[0-9a-fA-F]{40}$ ]] || return 1
  _dqw_in "$4" "$_DQW_CLASSES" && _dqw_in "$5" "$_DQW_STATUSES" || return 1
  [ -z "${8:-}" ] || _dqw_in "$8" "$_DQW_ACTIONS" || return 1
  local body out
  body=$(jq -nc --arg r "$1" --argjson pr "$2" --arg h "$3" --arg c "$4" --arg s "$5" \
    --arg ref "${6:-}" --arg note "${7:-}" --arg a "${8:-}" \
    '{repo:($r|ascii_downcase), pr:$pr, head:($h|ascii_downcase), class:$c, status:$s}
     + (if $ref == "" then {} else {ref:$ref} end)
     + (if $note == "" then {} else {note:$note} end)
     + (if $a == "" then {} else {action:$a} end)' 2>/dev/null) || return 1
  out=$(_jobs_req PUT /api/dequeue-watch/actions/state "$body") || return 1
  _dqw_shape "$out" '(.row|type) == "object"' '.row'
}

dqw_actions_list() {
  [ $# -ge 1 ] && [ $# -le 6 ] || return 1
  [ -z "${2:-}" ] || [[ "$2" =~ ^[0-9]+$ ]] || return 1
  [ -z "${3:-}" ] || [[ "$3" =~ ^[0-9a-fA-F]{40}$ ]] || return 1
  [ -z "${4:-}" ] || _dqw_in "$4" "$_DQW_CLASSES" || return 1
  [ -z "${5:-}" ] || _dqw_in "$5" "$_DQW_ACTIONS" || return 1
  [ -z "${6:-}" ] || _dqw_in "$6" "$_DQW_STATUSES" || return 1
  local out
  out=$(_jobs_req GET "/api/dequeue-watch/actions$(_dqw_query repo "$1" pr "${2:-}" head "${3:-}" class "${4:-}" action "${5:-}" status "${6:-}")") || return 1
  _dqw_shape "$out" '(.rows|type) == "array" and (.truncated|type) == "boolean"' '{rows, truncated}'
}

# A truncated list is not a count: rc 1, never the length of the first page.
dqw_rounds_count() {
  [ $# -eq 3 ] && [[ "$2" =~ ^[0-9]+$ ]] && _dqw_in "$3" "$_DQW_CLASSES" || return 1
  local out
  out=$(_jobs_req GET "/api/dequeue-watch/actions$(_dqw_query repo "$1" pr "$2" class "$3" action fix-round limit 500)") || return 1
  _dqw_shape "$out" '(.rows|type) == "array" and .truncated == false' '.rows | length'
}

dqw_summary() {
  [ $# -le 1 ] || return 1
  local out
  out=$(_jobs_req GET "/api/dequeue-watch/summary$(_dqw_query since "${1:-}")") || return 1
  _dqw_shape "$out" '(.by_class|type) == "object" and (.requeues|type) == "number"' '.'
}

# _dqw_in <word> <" list ">: the word is one of the list's words.
_dqw_in() { [ -n "$1" ] && [[ "$2" == *" $1 "* ]]; }

# _dqw_query <name> <value>...: "?a=1&b=2" from the non-empty values, each
# @uri-encoded, the repo lowercased; "" when every value is empty.
_dqw_query() {
  local q="" v
  while [ $# -ge 2 ]; do
    if [ -n "$2" ]; then
      v=$2; [ "$1" = repo ] && v=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
      q="$q&$1=$(jq -rn --arg v "$v" '$v|@uri')"
    fi
    shift 2
  done
  [ -z "$q" ] || printf '?%s' "${q#&}"
}

# _dqw_shape <answer> <jq test> <jq projection>: prints the projection, compact,
# only when the answer is JSON that passes the test; otherwise rc 1, nothing printed.
_dqw_shape() {
  local out
  out=$(printf '%s' "$1" | jq -c "if ($2) then ($3) else empty end" 2>/dev/null)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
