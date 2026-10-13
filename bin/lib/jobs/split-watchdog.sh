#!/bin/bash
# shellcheck shell=bash
# bin/lib/jobs/split-watchdog.sh — BH-1805 (BH-1793.0) contract, BH-1806 (BH-1793.1) bodies: the split-watchdog action ledger verbs over the split_watchdog_actions table (worker/jobs/src/routes/split-watchdog.js). Sourced by bin/jobs-client.sh (JC_MODULES), never run.

# --- split-watchdog ledger ----------------------------------------------------
# sw_record <project> <family> <child> <step> <reason> <outcome>
#   Records one watchdog action. Prints `first` for a new (project, child, step,
#   reason) row or `repeat <n>` when the row already existed. rc 1 on outage.
# sw_seen <project> <child> <step> <reason>
#   Prints the recorded outcome for that row, or nothing when there is none.
#   rc 1 on outage, and rc 1 is never read as not-seen.
# sw_list <project> [family]
#   Prints the ledger rows as TSV.
# sw_actions_today <project> [family]
#   Prints the count of `acted` rows since UTC midnight.
#
# Every failure is rc 1 with nothing on stdout: a 4xx, a 5xx, a transport error,
# an unconfigured client, and a 2xx that lacks the field the verb reads. The
# reason fingerprint (reason_fp) is computed by the WORKER from the reason text;
# no verb here hashes anything, so shell and worker cannot disagree on it.
# sw_list's columns: project family child step reason_fp outcome repeats
# first_at last_at actor reason. sw_list and sw_actions_today read at most 500
# rows (the route's page cap).

_sw_uri() { jq -rn --arg v "$1" '$v|@uri'; }

sw_record() {
  [ $# -eq 6 ] || return 1
  local body out
  body=$(jq -nc --arg p "$1" --arg f "$2" --arg c "$3" --arg s "$4" --arg r "$5" --arg o "$6" \
    --arg a "${JOBS_BOX:-}" '{project:$p, family:$f, child:$c, step:$s, reason:$r, outcome:$o, actor:$a}') || return 1
  out=$(_jobs_req POST /api/split-watchdog "$body") || return 1
  out=$(printf '%s' "$out" | jq -r 'if .recorded != true or (.repeats|type) != "number" then empty
    elif .first == true then "first" elif .first == false then "repeat \(.repeats)" else empty end' 2>/dev/null)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

sw_seen() {
  [ $# -eq 4 ] || return 1
  local out
  out=$(_jobs_req GET "/api/split-watchdog?project=$(_sw_uri "$1")&child=$(_sw_uri "$2")&step=$(_sw_uri "$3")&reason=$(_sw_uri "$4")") || return 1
  printf '%s' "$out" | jq -e 'type == "object" and has("split_watchdog_action")' >/dev/null 2>&1 || return 1
  out=$(printf '%s' "$out" | jq -r '.split_watchdog_action | if . == null then empty else (.outcome // "") end') || return 1
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# _sw_rows <project> <family> [extra-query] — the list route's answer, only when it carries rows[].
_sw_rows() {
  local q out
  q="project=$(_sw_uri "$1")&limit=500"
  [ -n "$2" ] && q="$q&family=$(_sw_uri "$2")"
  [ -n "${3:-}" ] && q="$q&$3"
  out=$(_jobs_req GET "/api/split-watchdog?$q") || return 1
  printf '%s' "$out" | jq -e '(.rows|type) == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

sw_list() {
  [ -n "${1:-}" ] || return 1
  local out
  out=$(_sw_rows "$1" "${2:-}") || return 1
  printf '%s' "$out" | jq -r '.rows[] | [.project, .family, .child, .step, .reason_fp, .outcome,
    .repeats, .first_at, .last_at, .actor, .reason] | map(. // "") | @tsv' || return 1
}

sw_actions_today() {
  [ -n "${1:-}" ] || return 1
  local out
  # A bare date sorts below every ISO stamp of the same day, so it is UTC midnight.
  out=$(_sw_rows "$1" "${2:-}" "outcome=acted&since=$(date -u +%F)") || return 1
  printf '%s' "$out" | jq -r '.rows | length' || return 1
}
