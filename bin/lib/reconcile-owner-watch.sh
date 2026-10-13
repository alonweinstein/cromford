#!/bin/bash
# shellcheck shell=bash
# bin/lib/reconcile-owner-watch.sh — rcw_check: page ONCE when the reconcile-prs
# owner stops beating (BH-1608, slice BH-1595.1). Sourced by bin/jobs-watchdog.sh.
#
# reconcile-prs runs on ONE box (BH-1583). If that box dies, or the owner row
# names a box that does not exist, nothing reconciles and nothing else pages.
# The owner beats into reconcile_owner_beat every tick (bin/lib/reconcile-owner-
# beat.sh); this reads the row back from GET /api/reconcile-prs/owner.
#
#   - Only the hub checks: jobs-watchdog runs on every box, and ten watchers of
#     one row would race the latch into duplicate pages.
#   - Staleness is age_s > RECONCILE_PRS_OWNER_STALE_TICKS x tick_s, with age_s
#     from the SERVER clock. The knob is registered (catalog/lanes.d/jobs-
#     watchdog.json, required) and has no literal here; a non-integer = no check.
#   - Unreadable owner row = no alert (unreachable is not stale), one log line.
#   - Paused lane (lane-off-reconcile-prs / all-off) = silent, latch cleared.
#   - The ALERTS line is written BEFORE the latch PATCH: a failed PATCH repeats
#     the page next run rather than silently missing it.
# Expects $LOG, $ALERTS and STAMP from the caller.
rcw_check() {
  local n resp owner src age tick alerted beat_at box thr
  command -v is_hub_box >/dev/null 2>&1 || . "${H:-${HARNESS:-/root/harness}}/bin/lib/hub-box.sh" 2>/dev/null
  command -v is_hub_box >/dev/null 2>&1 && is_hub_box "${JOBS_BOX:-$(hostname)}" || return 0
  n="${RECONCILE_PRS_OWNER_STALE_TICKS:-}"
  case "$n" in
    ''|*[!0-9]*) echo "$(STAMP) reconcile-owner: RECONCILE_PRS_OWNER_STALE_TICKS='$n' is not an integer — no owner check" >> "$LOG"; return 0 ;;
  esac
  if resp=$(_jobs_req GET /api/reconcile-prs/owner 2>/dev/null) \
     && owner=$(jq -er '.owner // "?"' <<<"$resp" 2>/dev/null) \
     && tick=$(jq -er '.tick_s | numbers' <<<"$resp" 2>/dev/null); then :; else
    echo "$(STAMP) reconcile-owner: owner row unreadable (http=${JOBS_HTTP:-none}) — no check, unreachable is not stale" >> "$LOG"
    return 0
  fi
  src=$(jq -r '.owner_source // "?"' <<<"$resp")
  alerted=$(jq -r '.beat.alerted // false' <<<"$resp")
  if { command -v flag_active >/dev/null 2>&1 && { flag_active all-off || flag_active lane-off-reconcile-prs; }; }; then
    if [ "$alerted" = true ]; then
      _jobs_req PATCH /api/reconcile-prs/owner/alert '{"alerted":false}' >/dev/null 2>&1
      echo "$(STAMP) reconcile-owner: lane paused, not dead — latch cleared" >> "$LOG"
    fi
    return 0
  fi
  jq -e '.beat | objects' <<<"$resp" >/dev/null 2>&1 || return 0
  age=$(jq -r '.beat.age_s // 0 | floor' <<<"$resp")
  beat_at=$(jq -r '.beat.beat_at // "never"' <<<"$resp")
  box=$(jq -r '.beat.box // "-"' <<<"$resp")
  thr=$(( n * tick ))
  if [ "$age" -gt "$thr" ]; then
    [ "$alerted" = true ] && return 0
    echo "$(STAMP) [jobs-watchdog] RECONCILE OWNER SILENT: configured owner $owner ($src) — no reconcile-prs heartbeat for $((age / 60))m ($n ticks of $((tick / 60))m); last beat $beat_at from $box" >> "$ALERTS"
    echo "$(STAMP) reconcile-owner-silent owner=$owner age=${age}s threshold=${thr}s" >> "$LOG"
    _jobs_req PATCH /api/reconcile-prs/owner/alert '{"alerted":true}' >/dev/null 2>&1
  elif [ "$alerted" = true ]; then
    echo "$(STAMP) [jobs-watchdog] RECONCILE OWNER RESUMED: configured owner $owner ($src) — reconcile-prs heartbeat is back ($((age / 60))m ago from $box)" >> "$ALERTS"
    echo "$(STAMP) reconcile-owner-resumed owner=$owner age=${age}s" >> "$LOG"
    _jobs_req PATCH /api/reconcile-prs/owner/alert '{"alerted":false}' >/dev/null 2>&1
  fi
  return 0
}
