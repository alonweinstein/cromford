#!/bin/bash
# bin/lib/triage-close.sh — close the D1 `alerts` rows the alert-triage lane
# settled on its own (BH-2544). Sourced by bin/alert-triage.sh.
#
# BH-2568 wrote the contract (these two signatures and the four hook calls);
# BH-2570 implements it. Only a POSITIVE re-verify closes a row: a STEP 0
# NOISE-STALE retirement (every PR it names read terminal) or a settlement whose
# reason is `resolved:`, `superseded:` or `verify:`. The clock rules
# (EXPIRED-AGE, EXPIRED-CONDSTATE) and `stale-akey:` say a line is old, not that
# its condition cleared, so they never yield an id.
#
#   triage_close_ids <reason> <idsfile>
#     <reason> is `step0` (lines bin/triage-spool-retire.sh retired, ids written
#     to TRIAGE_RETIRE_IDS_OUT) or `settle` (lines the lane settled without a
#     session). <idsfile> holds one alert id per line. The ids are deduped, an
#     id the worker's regex would refuse is dropped (one bad id 400s the whole
#     request), and the rest go to alert_resolve (bin/lib/jobs/alerts.sh) in
#     slices of ALERT_IDS_SLICE (90, the worker's ALERT_IDS_SLICE; its cap is
#     99). Each slice logs `CLOSED (no model call) reason=<r> resolved=<n> of
#     <m>`, n being the WORKER's count of rows that moved. A slice that fails
#     logs `close rc=<rc> for <m> id(s)` and is not retried: the row stays
#     quarantined and the 900s claim lease re-offers it next tick. With
#     ALERTS_DB not 1 nothing is sent and one `close skipped` line is logged per
#     process. An empty or missing file is no request and no line. Always rc 0.
#     The caller logs BEFORE it calls this, so a row is never closed without its
#     NOISE-STALE / STEP 0 line.
#
#   triage_settled_ids <settledfile> <idsout>
#     <settledfile> is the lane's $SETTLED: `reason<TAB>line`, one per line.
#     <idsout> is overwritten with the `alertid` of every line whose beat carries
#     `"dbrow":true` AND whose reason starts with `resolved:`, `superseded:` or
#     `verify:`, deduped. A `stale-akey:` reason never yields an id, and neither
#     does a line without `"dbrow":true`.

_TC_OFF_SAID=0

triage_close_ids() { # triage_close_ids <reason> <idsfile>
  local reason="${1:-}" f="${2:-}" log="${LOG:-/dev/stderr}" ids m slice n rc chunk
  [ -s "$f" ] || return 0
  ids=$(grep -E '^[A-Za-z0-9_.-]{1,120}$' "$f" | sort -u)
  [ -n "$ids" ] || return 0
  m=$(grep -c . <<<"$ids")
  if [ "${ALERTS_DB:-0}" != 1 ]; then
    [ "$_TC_OFF_SAID" = 1 ] || echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') close skipped: ALERTS_DB off — $m id(s) not resolved" >> "$log"
    _TC_OFF_SAID=1
    return 0
  fi
  if ! declare -F alert_resolve >/dev/null 2>&1; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') close skipped: alert_resolve not loaded — $m id(s) not resolved" >> "$log"
    return 0
  fi
  slice="${ALERT_IDS_SLICE:-90}"
  case "$slice" in ''|*[!0-9]*) slice=90 ;; esac
  { [ "$slice" -ge 1 ] && [ "$slice" -le 90 ]; } 2>/dev/null || slice=90
  while IFS= read -r chunk; do
    [ -n "$chunk" ] || continue
    # shellcheck disable=SC2086  # the chunk is validated ids, one word each
    set -- $chunk
    n=$(alert_resolve "$@"); rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') CLOSED (no model call) reason=$reason resolved=${n:-0} of $#" >> "$log"
    else
      echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') close rc=$rc for $# id(s) — rows stay quarantined; the lease re-offers them" >> "$log"
    fi
  done < <(printf '%s\n' "$ids" | xargs -n "$slice" echo)
  return 0
}

triage_settled_ids() { # triage_settled_ids <settledfile> <idsout>
  local f="${1:-}" out="${2:-}"
  [ -n "$out" ] || return 0
  if [ ! -s "$f" ]; then : > "$out"; return 0; fi
  awk -F'\t' '$1 ~ /^(resolved|superseded|verify):/ && index($0, "\"dbrow\":true")' "$f" \
    | grep -o '"alertid":"[^"]*"' | cut -d'"' -f4 | grep . | sort -u > "$out"
  return 0
}
