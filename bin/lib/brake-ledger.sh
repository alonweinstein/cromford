#!/bin/bash
# bin/lib/brake-ledger.sh — BH-2343 (BH-2316.0). The durable copy of the three
# paid alert lanes' "we already paid for this" brakes. Sourced, never executed,
# and only after bin/jobs-client.sh is loaded (job_ledger_put, ledger_page).
#
# WHY IT EXISTS. alert-triage, alerts-medic and watchdog-responder keep their
# brakes only in hub-local files. A rebuilt hub starts empty and buys the same
# triage and responder sessions again. Each brake now writes through to the
# generic `ledgers(kind,key)` table and reads back as a union every tick.
#
# THE LOCAL FILE STAYS PRIMARY. Callers write the file first and the row
# second. Every verb returns the _jobs_req rc verbatim, and the whole thing is
# gated on alerts_db_on, so a worker outage is today's behaviour exactly.
#
# A READ OUTAGE IS NEVER AN EMPTY BRAKE SET. brake_read prints nothing and
# returns rc 1 on a transport failure or a 200 that is not a ledger list, even
# when earlier pages were fine. rc 0 with no rows is a real "no brakes".
#
# Kinds (one per brake): brake:triage-family, brake:triage-deferred,
# brake:triage-cliff, brake:medic-family, brake:medic-parked, brake:medic-seen,
# brake:responder-handled.

# The worker's list is capped at 1000 rows a page; five pages bound one read.
_BRAKE_PAGE=1000
_BRAKE_PAGES=5

# _brake_kind <name> — echoes brake:<name>. rc 1 when the name is not
# [a-z0-9-]+ or the kind is over 32 chars: the worker slices kind to 32 on
# PUT, so a longer one would be written and read under two different kinds.
_brake_kind() {
  local name="${1:-}"
  case "$name" in ''|*[!a-z0-9-]*) return 1 ;; esac
  [ "${#name}" -le 26 ] || return 1
  printf 'brake:%s' "$name"
}

# brake_db_on — the one opt-in: alerts_db_on (flags/alerts-db). rc 1 when the
# alert-state gate is not loaded.
brake_db_on() {
  declare -F alerts_db_on >/dev/null 2>&1 || return 1
  alerts_db_on
}

# brake_mark <name> <key> <epoch> [detail_json] — status set, detail is
# detail_json + {"at":epoch} (at always wins). Bad input: rc 1, no request.
brake_mark() {
  local kind key="${2:-}" epoch="${3:-}" detail="${4:-}" json
  kind=$(_brake_kind "${1:-}") || return 1
  [ -n "$key" ] || return 1
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  [ -z "$detail" ] && detail='{}'
  printf '%s' "$detail" | jq -e 'type=="object"' >/dev/null 2>&1 || return 1
  json=$(jq -nc --argjson d "$detail" --argjson at "$epoch" '$d + {at:$at}') || return 1
  job_ledger_put "$kind" "$key" set "$json"
}

# brake_clear <name> <key> — status cleared; brake_read skips it.
brake_clear() {
  local kind key="${2:-}"
  kind=$(_brake_kind "${1:-}") || return 1
  [ -n "$key" ] || return 1
  job_ledger_put "$kind" "$key" cleared
}

# brake_read <name> <max_age_s> — TSV `key<TAB>epoch<TAB>detail_json` for the
# set rows whose at >= now-max_age_s (at is detail.at, else updated_at). Walks
# `before=<last updated_at>&before_key=<last key>` (BH-2450: a compound cursor,
# so rows sharing the last row's second are not skipped) until a page is short
# or its oldest row is out of the window; a walk that hits the page cap ends
# with a `#truncated` line.
brake_read() {
  local kind max="${2:-}" now cutoff before="" before_key="" rows="" resp rc parsed head n last_epoch p
  kind=$(_brake_kind "${1:-}") || return 1
  case "$max" in ''|*[!0-9]*) return 1 ;; esac
  now=${BRAKE_NOW:-$(date +%s)}
  cutoff=$((now - max))
  for ((p = 1; p <= _BRAKE_PAGES; p++)); do
    resp=$(ledger_page "$kind" "$_BRAKE_PAGE" "$before" "$before_key"); rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    # Line 1: raw page length, last updated_at, its epoch. Then the rows.
    parsed=$(printf '%s' "$resp" | jq -r --argjson c "$cutoff" '
      if (.ledgers|type) != "array" then error("not a ledger list") else . end
      | .ledgers as $l
      | ($l[-1].updated_at // "") as $last
      | ([($l|length), $last, (if $last == "" then "" else ($last|fromdateiso8601) end)] | @tsv),
        ($l[] | select(.status == "set")
         | (((.detail|fromjson?)|.at?|numbers) // (.updated_at|fromdateiso8601)) as $at
         | select($at >= $c)
         | [.key, $at, (((.detail|fromjson?) // {})|tojson)] | @tsv)' 2>/dev/null) || return 1
    head=${parsed%%$'\n'*}
    [ "$parsed" = "$head" ] || rows="$rows${parsed#*$'\n'}"$'\n'
    IFS=$'\t' read -r n before last_epoch <<< "$head"
    [ "$n" -lt "$_BRAKE_PAGE" ] && break
    [ "$last_epoch" -lt "$cutoff" ] && break
    # The key is read raw, not from the @tsv line: @tsv escapes tabs and
    # backslashes, which would page on a key no row has. A full page with no
    # last key is not a ledger list, so it is an outage like any other.
    before_key=$(printf '%s' "$resp" | jq -r '.ledgers[-1].key // empty' 2>/dev/null)
    [ -n "$before_key" ] || return 1
    [ "$p" -eq "$_BRAKE_PAGES" ] && rows="$rows#truncated"$'\n'
  done
  printf '%s' "$rows"
  return 0
}
