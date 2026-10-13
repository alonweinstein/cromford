#!/bin/bash
# bin/lib/claim-age.sh — how old is each `claimed` jobs-ledger row, and when did
# it last heartbeat? Sourced, never executed (BH-3951, slice 4 of BH-3943).
# Caller: bin/overlap-schedule.sh source 3, which releases a dead claim from
# another harness for its own schedule only (lib id overlap-claim-ttl, knob
# OVERLAP_CLAIM_TTL_MIN).
#
# claim_ages <project>
#   One `_jobs_req GET /api/queue?project=<p>&status=claimed`. Prints one row per
#   key, the first the ledger lists winning:
#     key<TAB>claimed_by<TAB>claimed_at<TAB>updated_at<TAB>age_min
#   age_min is whole minutes since claimed_at, `-` when it is missing or does
#   not parse. Missing fields print `-`.
#   rc 0  the ledger answered (possibly with no rows)
#   rc 2  no _jobs_req, a failed request, or a body that is not {queue:[...]}.
#         Unreadable is never "no claims".
#
# claim_age_min <iso>
#   Whole minutes since <iso>, clamped at 0 for a future stamp; rc 1 and no
#   output when <iso> does not parse. The clock is `date -u +%s`, or
#   CLAIM_AGE_NOW (epoch seconds) when set, for tests.
#
# bin/lib/jobs/queue.sh:queue_list is deliberately not used: its positional TSV
# has many callers and carries neither stamp.
#
# No `set -e`, no `exit`, no output at source time.
if [ -n "${CLAIM_AGE_LIB:-}" ]; then return 0 2>/dev/null; fi
CLAIM_AGE_LIB=1

_claim_age_now() {
  case "${CLAIM_AGE_NOW:-}" in
    ''|*[!0-9]*) date -u +%s ;;
    *) printf '%s\n' "$CLAIM_AGE_NOW" ;;
  esac
}

claim_age_min() {
  local _cam_now _cam_ts
  [ -n "${1:-}" ] || return 1
  _cam_now=$(_claim_age_now) || return 1
  _cam_ts=$(jq -rn --arg s "$1" '$s | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null) || return 1
  [[ "$_cam_ts" =~ ^[0-9]+$ ]] || return 1
  if [ "$_cam_ts" -ge "$_cam_now" ]; then echo 0; else echo $(( (_cam_now - _cam_ts) / 60 )); fi
}

claim_ages() {
  local _ca_p="${1:-}" _ca_body _ca_now
  [ -n "$_ca_p" ] || return 2
  declare -F _jobs_req >/dev/null || return 2
  command -v jq >/dev/null 2>&1 || return 2
  _ca_body=$(_jobs_req GET "/api/queue?project=$_ca_p&status=claimed" 2>/dev/null) || return 2
  printf '%s' "$_ca_body" | jq -e '(.queue | type) == "array"' >/dev/null 2>&1 || return 2
  _ca_now=$(_claim_age_now) || return 2
  printf '%s' "$_ca_body" | jq -r --argjson now "$_ca_now" '
    def stamp: if type == "string" and . != "" then . else "-" end;
    def age: (try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null) as $t
             | if $t == null then "-" elif $t >= $now then "0"
               else ((($now - $t) / 60) | floor | tostring) end;
    .queue[] | select((.ticket_key // "") != "")
    | [ (.ticket_key | tostring), (.claimed_by | stamp), (.claimed_at | stamp), (.updated_at | stamp),
        (if (.claimed_at | type) == "string" then (.claimed_at | age) else "-" end) ]
    | map(gsub("[\t\n\r]"; " ")) | @tsv' 2>/dev/null | awk -F'\t' '!seen[$1]++'
  return 0
}
