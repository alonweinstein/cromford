#!/bin/bash
# bin/lib/wake-class-flaky.sh — BH-1061 flaky wake class.
# Sourced by bin/wake-loop.sh; defines wc_flaky_row and wc_flaky_dispatch.
# Fires only when flags/wake-lanes-flaky is on (enforced by class_on in the loop).
# Drives flaky-detect only on check_suite.completed; per-job check_run.completed
# is deliberately ignored.
# shellcheck shell=bash

WC_FLAKEY_PROJECTS=""

# wc_flaky_row <project> <kind> <key> <event> <repo> <id>
wc_flaky_row() {
  local project="${1:-}" kind="${2:-}" event="${4:-}"
  [ "$kind" = "checks" ] && [ "$event" = "check_suite.completed" ] || return 0
  case " $WC_FLAKEY_PROJECTS " in
    *" $project "*) ;;
    *) WC_FLAKEY_PROJECTS="${WC_FLAKEY_PROJECTS:+$WC_FLAKEY_PROJECTS }$project" ;;
  esac
  return 0
}

# wc_flaky_dispatch — run once per non-empty drain after legacy lanes.
wc_flaky_dispatch() {
  local p
  local projects="$WC_FLAKEY_PROJECTS"

  for p in $projects; do
    if cooled flaky-detect "$p" "${WAKE_FLAKY_COOLDOWN_S:-21600}"; then
      launch "checks[$p] flaky-detect" "$SELF/flaky-detect.sh" "$p" --days 1
    fi
  done
  WC_FLAKEY_PROJECTS=""
  return 0
}
