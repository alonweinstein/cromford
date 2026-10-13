#!/bin/bash
# shellcheck shell=bash

# Thin wrappers over /api/conductor/held; every verb returns _jobs_req's rc verbatim.

# conductor_mode_publish <mode> <held-summary> — two settings rows, so readers use the 60s settings cache.
conductor_mode_publish() {
  local mode="${1:-}" summary="${2:-}" rc
  [ -n "$mode" ] || return 1
  setting_set merge-conductor.mode "$mode" "BH-1201: written by the conductor every tick"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  # Nothing held publishes "0" (setting_set refuses empty).
  summary="${summary:-0}"
  # Truncate to the 256-char column so the busiest tick is not refused.
  summary="${summary:0:256}"
  setting_set merge-conductor.held_pages "$summary"
}

# held_page_put <repo> <num> <state> <head> <kind> <text> <mark> <mode>
held_page_put() {
  local repo="${1:-}" num="${2:-}" state="${3:-}" head="${4:-}" kind="${5:-}" \
        text="${6:-}" mark="${7:-}" mode="${8:-}" body
  [ -n "$repo" ] && [ -n "$num" ] && [ -n "$state" ] && [ -n "$head" ] \
    && [ -n "$kind" ] && [ -n "$text" ] && [ -n "$mode" ] || return 1
  body=$(jq -nc --arg repo "$repo" --arg num "$num" --arg state "$state" \
    --arg head "$head" --arg kind "$kind" --arg text "$text" --arg mark "$mark" \
    --arg mode "$mode" \
    '{repo:$repo}
     + (if ($num|test("^[0-9]+$")) then {number:($num|tonumber)} else {number:$num} end)
     + {state:$state, head:$head, kind:$kind, text:$text, mode:$mode}
     + (if $mark == "" then {} else {mark:$mark} end)' 2>/dev/null) || return 1
  _jobs_req PUT /api/conductor/held "$body" >/dev/null
}

# held_pages_list [limit] — TSV, oldest first:
held_pages_list() {
  local limit="${1:-100}" resp rc rows
  resp=$(_jobs_req GET "/api/conductor/held?limit=$limit"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  # A non-JSON 200 is an outage, not an empty table.
  rows=$(printf '%s' "$resp" | jq -r '.rows[]? | [
    .repo, .number, .state, .head, .kind,
    (.text // ""),
    (.mark // ""), .mode, .first_held_at, .last_seen_at ] | @tsv' 2>/dev/null) || return 1
  [ -n "$rows" ] && printf '%s\n' "$rows"
  return 0
}

# held_pages_whole [limit] — held_pages_list's TSV, but only for a WHOLE list
# (BH-2361): rc 0 when the rows returned equal n_total (no output = nothing held),
# rc 3 truncated, rc 1 unparseable or no n_total, _jobs_req's rc otherwise.
held_pages_whole() {
  local limit="${1:-500}" resp rc rows
  resp=$(_jobs_req GET "/api/conductor/held?limit=$limit"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$resp" | jq -e '(.n_total|type) == "number" and (.rows|type) == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$resp" | jq -e '(.rows|length) == .n_total' >/dev/null 2>&1 || return 3
  rows=$(printf '%s' "$resp" | jq -r '.rows[] | [
    .repo, .number, .state, .head, .kind,
    (.text // ""),
    (.mark // ""), .mode, .first_held_at, .last_seen_at ] | @tsv' 2>/dev/null) || return 1
  [ -n "$rows" ] && printf '%s\n' "$rows"
  return 0
}

# held_page_release <repo> <num> <state> <head> <kind> <why>
held_page_release() {
  local repo="${1:-}" num="${2:-}" state="${3:-}" head="${4:-}" kind="${5:-}" \
        why="${6:-}" body resp rc out
  # why is required; refuse here since fail-open hides a 400.
  [ -n "$repo" ] && [ -n "$num" ] && [ -n "$state" ] && [ -n "$head" ] \
    && [ -n "$kind" ] && [ -n "$why" ] || return 1
  body=$(jq -nc --arg repo "$repo" --arg num "$num" --arg state "$state" \
    --arg head "$head" --arg kind "$kind" --arg why "$why" \
    '{repo:$repo}
     + (if ($num|test("^[0-9]+$")) then {number:($num|tonumber)} else {number:$num} end)
     + {state:$state, head:$head, kind:$kind, why:$why}' 2>/dev/null) || return 1
  resp=$(_jobs_req POST /api/conductor/held/release "$body"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  out=$(printf '%s' "$resp" | jq -r '.released // 0' 2>/dev/null) || return 1
  printf '%s\n' "$out"
}
