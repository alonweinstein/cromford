#!/bin/bash
# bin/lib/pause.sh — IS THIS LANE PAUSED? One reading of the pauses cache,
# shared by every lane that honours a pause (BH-1672).
#
# WHY IT EXISTS. A pause used to be an env edit on one box: invisible from the
# console, never expiring, and forgotten until someone asked why reviews had
# stopped. BH-1672 makes a pause a row in the jobs worker's `pauses` table
# (worker/jobs/schema.sql) with a reason, an actor and an expiry, and this lib
# is the box-side read of it.
#
# WIRE CONTRACT 1 — the worker API. Implemented by a BH-1672 sibling, NOT here
# and not yet deployed; this is the shape the siblings build against:
#   GET /api/pauses?active=1|0&scope=    → {pauses:[row...], truncated:bool}, capped at 500
#   PUT /api/pauses                      {scope, what, reason, actor, ttl_s? | expires_at?}
#                                        creates the live pause or renews it
#                                        → {pause: row}
#   POST /api/pauses/:id/end             sets ended_at, end_reason=resumed → {pause: row}
#   POST /api/pauses/expire              conditional UPDATE stamps due rows
#                                        ended_at=expires_at, end_reason=expired, and
#                                        returns only the rows it stamped
#                                        → {expired:[row...], as_of}
# The readers also take {pauses:[...]} or a bare array from /expire and a bare
# row from PUT and /end, but the envelopes above are what the worker sends
# (worker/jobs/src/routes/pauses.js, BH-1682).
# A row is {id, scope, what, reason, actor, created_at, expires_at, ended_at,
# end_reason}. scope is 'fleet' or a project; what is reviews|merges|builds|triage.
#
# WIRE CONTRACT 2 — the box cache, ${JOBS_HARNESS:-${HARNESS:-${H:-}}}/state/pauses.json
# (JOBS_HARNESS first, as in bin/jobs-client.sh). It holds the GET body
# verbatim, overwritten wholesale on refresh and never merged. With none of the
# three set there is no cache path (BH-2650): nothing is read, so nothing is
# paused, and pause_refresh still sends both requests but writes no cache and
# no log line, and returns 1 as it does when the state dir cannot be written.
#
# UNREADABLE IS NOT PAUSED. No cache, garbage JSON, or no .pauses array reads as
# "not paused", which is today's behaviour with no pause mechanism at all. A row
# whose expires_at does not parse is not live either.
#
# Sourced, never executed. Entry points:
#   pause_active <project> <what>  rc 0 iff a live row for scope fleet or <project>
#                                  and that what has expires_at > now
#   pause_label <project>          prints "PAUSED(<what>,...) " (sorted, trailing
#                                  space, no newline) for the active whats, or nothing
#   pause_refresh                  one bounded pass: POST /api/pauses/expire, one
#                                  PAUSE_EXPIRED line per returned row in
#                                  logs/pauses.log, then GET /api/pauses?active=1
#                                  replaces the cache on a 200 with a .pauses array.
#                                  rc 1 if either request failed (the cache is kept:
#                                  an outage is not "no pauses"). No client or an
#                                  empty JOBS_URL prints "pause: jobs not configured"
#                                  once to stderr, rc 0, cache untouched.
#   pause_env_shapes               prints one token per env value that looks like a
#                                  pause (env:review-cap=<n>, env:automerge-disabled,
#                                  env:lane-off-<x>). Report only: it writes nothing
#                                  and asks no one, rc always 0.
# "now" is ${PAUSE_NOW:-$(date -u +%s)}, so a test can move the clock.
#
# THE LOG IS ONLY AS EXACT AS THE WORKER'S ANSWER. pauses.log is written from
# the expire response alone, never from a GET diff, so a row is logged once:
# the worker's conditional UPDATE returns each due row to one caller. A POST the
# worker commits but whose answer is lost drops that row's line; the row's
# end_reason='expired' is the durable record.

__pause_cache() {
  local root; root=$(__pause_root)
  [ -n "$root" ] || return 0
  printf '%s\n' "$root/state/pauses.json"
}

# The active whats for $p at $now, as a jq array. Both entry points use this
# one filter, so they cannot disagree about what "active" means.
__PAUSE_JQ_ACTIVE='[ .pauses[]
  | select(.scope == "fleet" or .scope == $p)
  | select(.ended_at == null)
  | select((try (.expires_at | sub("\\.[0-9]+"; "") | fromdateiso8601) catch 0) > $now)
  | .what ] | unique'

pause_active() {
  local p="${1:-}" w="${2:-}" c
  [ -n "$p" ] && [ -n "$w" ] || return 1
  c=$(__pause_cache); [ -n "$c" ] || return 1
  jq -e --arg p "$p" --arg w "$w" --argjson now "${PAUSE_NOW:-$(date -u +%s)}" \
    "$__PAUSE_JQ_ACTIVE | index(\$w) != null" "$c" >/dev/null 2>&1 || return 1
}

pause_label() {
  local p="${1:-}" list c
  [ -n "$p" ] || return 0
  c=$(__pause_cache); [ -n "$c" ] || return 0
  list=$(jq -r --arg p "$p" --argjson now "${PAUSE_NOW:-$(date -u +%s)}" \
    "$__PAUSE_JQ_ACTIVE | join(\",\")" "$c" 2>/dev/null) || return 0
  [ -n "$list" ] && printf 'PAUSED(%s) ' "$list"
  return 0
}

__PAUSE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

__pause_root() { printf '%s\n' "${JOBS_HARNESS:-${HARNESS:-${H:-}}}"; }

pause_refresh() {
  local root c body tmp ts opts failed=0
  root=$(__pause_root)
  if ! declare -F _jobs_req >/dev/null; then
    c="${PAUSE_JOBS_CLIENT:-$__PAUSE_LIB_DIR/../jobs-client.sh}"
    # Probed in a subshell first: the client exits on a half-synced bin/, and
    # an exit here would end the lane that sourced this lib, not just refresh.
    # The client runs `set -uo pipefail`; the caller's options are put back,
    # so loading it leaves only its functions and variables behind.
    opts=$(set +o)
    # shellcheck source=/dev/null
    ( . "$c" ) >/dev/null 2>&1 && . "$c" >/dev/null 2>&1
    eval "$opts"
  fi
  if ! declare -F _jobs_req >/dev/null || [ -z "${JOBS_URL:-}" ]; then
    echo "pause: jobs not configured" >&2
    return 0
  fi
  if body=$(_jobs_req POST /api/pauses/expire); then
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [ -z "$root" ]; then
      failed=1
    else
      mkdir -p "$root/logs"
      printf '%s' "$body" | jq -r --arg ts "$ts" '(if type == "array" then . else (.expired // .pauses) end) | arrays | .[]
        | "\($ts) PAUSE_EXPIRED scope=\(.scope) what=\(.what) reason=\(.reason // "" | tostring | gsub("[\r\n]+"; " ")) actor=\(.actor)"' \
        >> "$root/logs/pauses.log" 2>/dev/null || failed=1
    fi
  else
    failed=1
  fi
  if body=$(_jobs_req GET '/api/pauses?active=1') \
     && printf '%s' "$body" | jq -e '.pauses | type == "array"' >/dev/null 2>&1; then
    if [ -z "$root" ]; then
      failed=1
    else
      mkdir -p "$root/state"
      if ! { tmp=$(mktemp "$root/state/.pauses.XXXXXX") \
             && printf '%s' "$body" > "$tmp" && mv -f "$tmp" "$root/state/pauses.json"; }; then
        rm -f "${tmp:-}"; failed=1
      fi
    fi
  else
    failed=1
  fi
  return "$failed"
}

# __pause_knob <key> <fallback> — a threshold from lane-gate's local settings
# cache (.values), used only when it is a plain non-negative integer. No network.
__pause_knob() {
  local v r; r=$(__pause_root)
  [ -n "$r" ] || { printf '%s\n' "$2"; return 0; }
  v=$(jq -r --arg k "$1" '.values[$k] // empty' "$r/state/settings-cache.json" 2>/dev/null)
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s\n' "$((10#$v))" || printf '%s\n' "$2"
}

pause_env_shapes() {
  local root v below f x age maxage now
  root=$(__pause_root)
  v="${REVIEW_AUTOPILOT_DAILY_CAP:-}"
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    v=$((10#$v)); below=$(__pause_knob pause_env_review_cap_below 5)
    [ "$v" -ge 1 ] && [ "$v" -lt "$below" ] && echo "env:review-cap=$v"
  fi
  [ -n "$root" ] || return 0
  # BH-4153: automerge-disabled is a harness_flags row; a box with a worker
  # configured keeps no flags/ file for it, only the last good answer in
  # state/flags-cache/fleet/. Read that (no network, like the rest of this
  # function), and the legacy file for a box with no worker.
  if [ -e "$root/flags/automerge-disabled" ] \
     || jq -e '.on == true' "$root/state/flags-cache/fleet/automerge-disabled" >/dev/null 2>&1; then
    echo "env:automerge-disabled"
  fi
  now="${PAUSE_NOW:-$(date -u +%s)}"
  maxage=$(__pause_knob pause_env_laneoff_age_s 86400)
  for f in "$root"/flags/lane-off-*; do
    [ -e "$f" ] || continue
    x="${f##*/lane-off-}"; [ -n "$x" ] || continue
    age=$(( now - $(stat -c %Y "$f" 2>/dev/null || echo "$now") ))
    [ "$age" -gt "$maxage" ] && echo "env:lane-off-$x"
  done
  return 0
}
