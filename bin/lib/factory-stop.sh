#!/bin/bash
# bin/lib/factory-stop.sh — BH-3687 (slice BH-3708): the factory-stop switch.
# Sourced, never executed. No side effect at source time beyond defining
# functions (and sourcing lane-switch.sh when this shell does not have it yet).
#
# ONE SWITCH, ONE ROW. `factory-stop` is the settings row `switch.factory-stop`
# (catalog/switches.d/factory-stop.json), read only through lane_switch in
# `file` mode: the box row, then the fleet row, then flags/factory-stop, with no
# /api/flags read. A lane whose registry manifest carries a `factory_stop` tag
# (launch|merge|deploy) is stopped by lane_gate_or_exit while it is ON.
#
# FAIL-SAFE IS NOT STOPPED. No readable row and no file means the factory runs,
# with one throttled logs/lane-gate.log line saying so: pausing must be
# explicit. A row recorded before a worker outage keeps answering from the
# settings cache at any age, so a stop holds through the outage.
#
#   factory_stopped      rc 0 = stopped, rc 1 = not. Exports FACTORY_STOP_SRC
#                        (lane_switch's LANE_SWITCH_SRC for this read).
#   factory_stop_status  one GET /api/settings/switch.factory-stop, printed as
#                        `state<TAB>since_iso<TAB>actor<TAB>note`, state
#                        on|off|none|unknown. rc 2 and nothing printed when the
#                        worker did not answer (the cache drops updated_at,
#                        which is why this is a direct GET).
#   factory_stop_dur <s> `3h12m` / `2h05m`, `<m>m` under an hour; rc 1 and
#                        nothing printed for anything but a whole number.

if ! command -v lane_switch >/dev/null 2>&1; then
  # shellcheck source=lane-switch.sh
  . "$(dirname "${BASH_SOURCE[0]}")/lane-switch.sh" || return 1
fi

factory_stopped() {
  local rc
  # ls_isolated: a half-synced jobs client exits the shell it is sourced into,
  # and this runs inside every tagged lane's gate.
  ls_isolated lane_switch factory-stop file; rc=$?
  FACTORY_STOP_SRC=$LANE_SWITCH_SRC; export FACTORY_STOP_SRC
  case "$FACTORY_STOP_SRC" in
    box-row|fleet-row) ;;
    *) [ "$rc" -eq 0 ] || _lg_log_throttled factory-stop-norow "factory-stop: no readable switch.factory-stop row (src=$FACTORY_STOP_SRC) — read as NOT stopped (pausing must be explicit)" ;;
  esac
  return "$rc"
}

factory_stop_status() {
  local resp
  # In a subshell, for the same reason as ls_isolated above.
  resp=$(_lg_ensure_client || exit 2
         command -v _jobs_req >/dev/null 2>&1 || exit 2
         [ -n "${JOBS_URL:-}" ] || exit 2
         _jobs_req GET /api/settings/switch.factory-stop 2>/dev/null) || return 2
  printf '%s' "$resp" | jq -er '
    def flat: tostring | gsub("[\t\n\r]"; " ");
    if type != "object" or (has("setting") | not) then error("no setting field")
    elif .setting == null then "none\t\t\t"
    else (.setting.value | tostring | ascii_downcase) as $v
      | (if $v == "1" or $v == "on" or $v == "true" then "on"
         elif $v == "0" or $v == "off" or $v == "false" then "off"
         else "unknown" end)
        + "\t" + (.setting.updated_at // "" | flat)
        + "\t" + (.setting.actor // "" | flat)
        + "\t" + (.setting.note // "" | flat)
    end' 2>/dev/null || return 2
}

factory_stop_dur() {
  local s="${1:-}"
  case "$s" in ''|*[!0-9]*) return 1 ;; esac
  s=$((10#$s))
  if [ "$s" -lt 3600 ]; then printf '%dm' $((s / 60))
  else printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60)); fi
}
