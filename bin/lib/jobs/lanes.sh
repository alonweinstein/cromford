#!/bin/bash
# shellcheck shell=bash
# bin/lib/jobs/lanes.sh — BH-1194: lane liveness: the per-tick heartbeat of a lane, what the fleet expects to see ticking, and the alert switch for a lane that stopped. Sourced by bin/jobs-client.sh (JC_MODULES), never run.

# --- Lane liveness (2026-08-30) -----------------------------------------------
# A LANE IS NOT A JOB, and lane_tick is NOT a second heartbeat path. job_heartbeat
# above beats a CLAIM — a row that exists, every ~150s for as long as it works.
# lane_tick records that a CRON FIRED for a (project, box) pair, once per tick,
# whether or not it claimed anything.
#
# That distinction is the whole point. On 2026-08-30 project-7's crons vanished
# from box-project-6-1 at 05:17 and the lane was silent for ten hours
# with nothing alerting, because every ledger we had records work that HAPPENED:
# no tick, no row, nothing to age. And most ticks on a quiet board are gate
# SKIPs that claim nothing and spend nothing — so "the lane is alive" is a fact
# the job ledger structurally cannot carry, and this is where it goes instead.
#
# Fail-open like everything else here: no worker, no row, no noise, and
# bin/run-triage.sh behaves exactly as it does today.

# lane_tick <project> [kind]  — kind: start | skip | paused | locked | run | failed
lane_tick() {
  local project="${1:-}" kind="${2:-tick}" body
  [ -n "$project" ] || return 1
  body=$(jq -nc --arg p "$project" --arg b "$JOBS_BOX" --arg k "$kind" \
    '{project:$p,box:$b,kind:$k}' 2>/dev/null) || return 1
  _jobs_req POST /api/lanes/tick "$body" >/dev/null
}

# --- The PROCESS half of one liveness fact (BH-1031, state→DB slice 6) --------
# lane_tick above records that a CRON FIRED. This records that a long-lived
# PROCESS is still breathing, and it lands on the SAME ROW so the fleet has one
# liveness fact instead of the three it had: the box-local heartbeat file (only
# readable on the box that wrote it — blind exactly when the box is gone), the
# ssh probe in bin/fleet-heartbeat.sh (which answered "can the hub reach it",
# not "is the lane alive", and is deleted in this slice), and the lanes row.
#
# KEYED 'hb.<lane>' ON PURPOSE. A box runs several long-lived lanes at once
# (merge-conductor and blocked-resolver overlap as their normal state), so one
# row per (lane, box) is required; the prefix keeps a process row out of the
# hub's fleet.conf namespace, where the expected-set PUT could otherwise declare
# or retire it.
#
# FAIL-OPEN AND SILENT, like everything else here: a lane must never do less
# work — or die — because the ledger is unreachable.
_lane_proc_key() { # _lane_proc_key <lane> — the row's project column
  local l; l=$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-60)
  [ -n "$l" ] || return 1
  printf 'hb.%s' "$l"
}

# lane_proc_beat <lane> <start|beat|done> [pid] [interval_s] [expect_s] [note]
lane_proc_beat() {
  local lane="${1:-}" event="${2:-beat}" pid="${3:-}" iv="${4:-}" ex="${5:-}" note="${6:-}" key body
  key=$(_lane_proc_key "$lane") || return 1
  case "$event" in start|beat|done) ;; *) return 1 ;; esac
  # Tested BARE, never through `${x:-0}`: the default would make an empty value
  # read as "0" here and still travel on as the empty string, which jq then
  # refuses as --argjson — a beat that silently never lands.
  case "$pid" in ''|*[!0-9]*) pid=0 ;; esac
  case "$iv"  in ''|*[!0-9]*) iv=0 ;; esac
  # expect_s 0 is a REAL declaration ("this loop runs for ever on purpose"), so
  # it is sent as 0 rather than dropped — the worker clears the deadline on it.
  case "$ex"  in ''|*[!0-9]*) ex=-1 ;; esac
  body=$(jq -nc --arg p "$key" --arg b "$JOBS_BOX" --arg e "$event" --arg n "$note" \
    --argjson pid "$pid" --argjson iv "$iv" --argjson ex "$ex" \
    '{project:$p,box:$b,event:$e,note:$n}
     + (if $pid > 0 then {pid:$pid} else {} end)
     + (if $iv > 0 then {interval_s:$iv} else {} end)
     + (if $ex >= 0 then {expect_s:$ex} else {} end)' 2>/dev/null) || return 1
  _jobs_req POST /api/lanes/tick "$body" >/dev/null
}

# lane_procs [stale] — every PROCESS row the DB knows, as TSV:
#   lane  box  proc_state  proc_age_s  proc_pid  proc_stale_after_s  alerted(0|1)
#   proc_started_at  proc_note
# `stale` asks the worker for the stale ones only, judged by the row's own
# threshold — one definition of stale, shared by the reaper and the console, so
# the pager and the screen can never disagree about a lane.
lane_procs() {
  local want="${1:-}" q resp
  case "$want" in stale) q='?proc_stale=1' ;; *) q='?proc=1' ;; esac
  resp=$(_jobs_req GET "/api/lanes$q") || return 1
  printf '%s' "$resp" | jq -r '
    .lanes[]? | select((.project // "") | startswith("hb."))
    | [ ((.project // "") | sub("^hb\\.";"")), .box, (.proc_state // "none"),
        (if .proc_age_s == null then -1 else (.proc_age_s | floor) end),
        (.proc_pid // 0), ((.proc_stale_after_s // 900) | floor),
        (if .alerted_at then 1 else 0 end), (.proc_started_at // "-"),
        ((.proc_note // "-") | gsub("[\\t\\n]";" ")) ] | @tsv' 2>/dev/null
}

# lanes_expect <json-array>  — the hub's declaration of what SHOULD be ticking.
#   [{"project":"project-7","box":"box-project-6-1","cadence_min":10,"offset_min":1}]
#   An EMPTY array is refused by the worker on purpose (an unreadable fleet.conf
#   must not be able to un-watch the fleet), so it is refused here too rather
#   than sent and rejected.
lanes_expect() {
  local arr="${1:-}" n body
  [ -n "$arr" ] || return 1
  n=$(printf '%s' "$arr" | jq -r 'if type == "array" then length else -1 end' 2>/dev/null)
  case "$n" in ''|-1|0) return 1 ;; esac
  body=$(jq -nc --argjson l "$arr" --arg a "$JOBS_BOX" '{lanes:$l,actor:$a}' 2>/dev/null) || return 1
  _jobs_req PUT /api/lanes "$body" >/dev/null
}

# lanes_list — every lane the DB knows, as TSV:
#   project  box  state  silence_s  tick_age_s  last_tick_kind  alerted(0|1)
#   stale_after_s  last_tick_at  ticked_since_declared(0|1)
# The STATE is the worker's, not this client's: one definition of stale, shared
# by the pager and the console, so the two can never disagree about a lane.
#
# The tenth column is appended at the END, the same way job_stale appends
# `attempts`, so a box running an older bin/ reads the nine it knows and is
# unaffected. It exists because "has not ticked" has two shapes with two
# different fixes — never at all, or not since the lane was re-declared after a
# retirement — and an alert that names the wrong one sends someone to the wrong
# box.
lanes_list() {
  local resp
  resp=$(_jobs_req GET /api/lanes) || return 1
  printf '%s' "$resp" | jq -r '
    .lanes[]? | [ .project, .box, .state,
                  ((.silence_s // -1) | floor), (if .tick_age_s == null then -1 else (.tick_age_s | floor) end),
                  (.last_tick_kind // "-"), (if .alerted_at then 1 else 0 end),
                  ((.stale_after_s // 1800) | floor), (.last_tick_at // "-"),
                  (if (.ticked_since_declared // false) then 1 else 0 end) ] | @tsv' 2>/dev/null
}

# lane_alert_set <project> <box> on|off — the stale latch. `on` after paging a
# dead lane so it pages once; `off` on recovery, which is what emits the
# "resumed" line. A file on the hub could do the first half and never the second.
lane_alert_set() {
  local project="${1:-}" box="${2:-}" want="${3:-on}" body
  [ -n "$project" ] && [ -n "$box" ] || return 1
  body=$(jq -nc --arg p "$project" --arg b "$box" \
    --argjson a "$([ "$want" = on ] && echo true || echo false)" \
    '{project:$p,box:$b,alerted:$a}' 2>/dev/null) || return 1
  _jobs_req PATCH /api/lanes/alert "$body" >/dev/null
}

