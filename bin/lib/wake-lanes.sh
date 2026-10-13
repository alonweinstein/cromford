#!/bin/bash
# bin/lib/wake-lanes.sh — the BH-1034 wake-class contract, keyed on LANES.
#
# A BACKSTOP, NOT A GATE. Every lane keeps its cron line exactly where it is.
# All this library does is let a lane whose wake-driven run JUST happened skip
# the cron tick that would repeat it. Every unclear answer — no class for this
# lane, no flag, no flag_active, no stamp, the kill switch — means RUN, which is
# today's behaviour byte for byte.
#
# THE TWO LINES EACH LANE SCRIPT PASTES, right after its own flock:
#   [ -r "$H/bin/lib/wake-lanes.sh" ] && . "$H/bin/lib/wake-lanes.sh"
#   command -v wake_backstop_skip >/dev/null 2>&1 && wake_backstop_skip <lane> [project] [window] && exit 0
#
# NO SIDE EFFECTS WHEN SOURCED. bin/jobs-client.sh is sourced lazily, inside
# wake_backstop_skip, the only function that needs flag_active — sourcing it up
# here would hand every lane script that pastes those two lines jobs-client's
# `set -uo pipefail`, its env/global.env read and its box-name resolve, none of
# which a lane asked for.
# shellcheck shell=bash

# wake_class_of <lane> — print the class that drives this LANE. The argument is
# a lane (the script name without .sh), never an event: the event suffixes the
# receiver stores (pull_request.closed, check_suite.completed) are what a CLASS
# discriminates on internally, while the flag an operator flips, and the flag
# this library reads, is per class. A lane no class drives prints nothing, rc 1.
wake_class_of() {
  case "${1:-}" in
    reconcile-prs|check-migration-prs|alerts-groom)    echo 'pr-closed' ;;
    review-prs|review-autopilot|tickets-snapshot-push) echo 'pr-ci' ;;
    rebase-train|fleet-propagate|prompt-eval)          echo 'push' ;;
    deploy-train|migration-autopilot|apply-migrations) echo 'deploy' ;;
    flaky-detect)                                      echo 'flaky' ;;
    *) return 1 ;;
  esac
}

# wake_stamp <lane> [project] — record that this lane ran NOW. The project is
# optional because a hub-level lane (alerts-groom, prompt-eval) has none.
# NEVER FAILS THE CALLER: a lane that cannot write its stamp still runs, it just
# does not get to skip its next cron tick.
wake_stamp() {
  local lane="${1:-}" project="${2:-}" dir name
  [ -n "$lane" ] || return 0
  name="$lane"
  [ -n "$project" ] && name="$lane-$project"
  dir="${HARNESS:-/root/harness}/state/wake-ran"
  mkdir -p "$dir" 2>/dev/null && date +%s > "$dir/$name" 2>/dev/null
  return 0
}

# wake_backstop_skip <lane> [project] [window] — rc 0 means "this cron tick is
# redundant, exit 0". rc 1 means run, and rc 1 is what EVERY unclear path gives.
wake_backstop_skip() {
  local lane="${1:-}" project="${2:-}" window="${3:-}" H class stampf now last age
  command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lane-switch.sh" 2>/dev/null \
    || lane_switch() { [ -f "${HARNESS:-/root/harness}/flags/$1" ]; }
  [ -n "$lane" ] || return 1
  H="${HARNESS:-/root/harness}"

  # A wake-driven run is never skipped, and it is the ONLY run that stamps: the
  # stamp asserts "the work this lane owes has just been done", so only the run
  # that actually did it may write one.
  if [ "${WAKE_LAUNCH:-}" = "1" ]; then
    wake_stamp "$lane" "$project"
    return 1
  fi

  # The kill switch outranks every per-class flag. It is read by lane_switch
  # (BH-2439): a settings row switch.wake-lanes-off[.<box>] answers first, and
  # flags/wake-lanes-off only when there is no row. bin/wake-loop.sh still reads
  # only the file until #2407 moves it, so a row alone stops this backstop but
  # not the wake loop.
  HARNESS="$H" lane_switch wake-lanes-off file && return 1

  class=$(wake_class_of "$lane") || return 1

  if ! command -v flag_active >/dev/null 2>&1; then
    # shellcheck source=bin/jobs-client.sh
    [ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
  fi
  command -v flag_active >/dev/null 2>&1 || return 1
  flag_active "wake-lanes-$class" >/dev/null 2>&1 || return 1

  # The window is how long a wake-driven run covers for. It is deliberately
  # longer than any lane's cron period: the point is to skip the ticks that
  # would repeat work already done, not to shave one tick.
  #
  # NO LITERAL HERE (BH-1511.1). WAKE_BACKSTOP_S is a registry knob in the
  # `libs` scope (catalog/lanes.d/_lib.json, required): lib_env_apply sets it
  # from a lib.wake-lanes.wake_backstop_s row, the box cache, the env or the
  # registry default, in that order, before this reads it. lane-gate.sh is
  # sourced lazily for the same reason jobs-client.sh is above. A window that is
  # still not a number — no gate library on this box, a garbage env value — is
  # an unclear answer, and every unclear answer here means RUN.
  if [ -z "$window" ] || [ -n "${window//[0-9]/}" ]; then
    if ! command -v lib_env_apply >/dev/null 2>&1; then
      # shellcheck source=bin/lib/lane-gate.sh
      [ -r "$H/bin/lib/lane-gate.sh" ] && . "$H/bin/lib/lane-gate.sh"
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply wake-lanes
    window="${WAKE_BACKSTOP_S:-}"
  fi
  case "$window" in ''|*[!0-9]*)
    # SAID, ONCE AN HOUR (BH-1511.1 review, M1): a registry that will not
    # render turns off every wake-class backstop at once, and a run that is
    # merely not skipped leaves no other trace.
    stampf="$H/state/wake-ran/.no-window-$lane"
    # braces own the redirect, or the missing-stamp error leaks (#1565 N2)
    now=$(date +%s); last=$( { tr -dc '0-9' < "$stampf"; } 2>/dev/null )
    if [ -z "$last" ] || [ "$(( now - last ))" -ge 3600 ] || [ "$(( now - last ))" -lt 0 ]; then
      mkdir -p "$H/logs" "$H/state/wake-ran" 2>/dev/null
      printf '%s\n' "$now" > "$stampf" 2>/dev/null
      printf '%s\n' "${lane}[${project}]: no backstop window (WAKE_BACKSTOP_S='${WAKE_BACKSTOP_S:-}', lib_env_apply $(command -v lib_env_apply >/dev/null 2>&1 && echo ran || echo unavailable)) — running every tick" \
        >> "$H/logs/wake-backstop.log" 2>/dev/null
    fi
    return 1 ;;
  esac

  stampf="$H/state/wake-ran/$lane"
  [ -n "$project" ] && stampf="$stampf-$project"
  [ -r "$stampf" ] || return 1
  last=$(tr -dc '0-9' < "$stampf" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  age=$(( now - last ))
  [ "$age" -ge 0 ] && [ "$age" -lt "$window" ] || return 1

  # ONE line, in a file of its own. A skip is the single fact an operator wants
  # when a lane "did not run": stdout would land in cron mail or in whatever log
  # the lane itself writes, where nobody looks for it.
  mkdir -p "$H/logs" 2>/dev/null || true
  printf '%s\n' "${lane}[${project}]: cron tick skipped — wake-driven run ${age}s ago (backstop ${window}s)" \
    >> "$H/logs/wake-backstop.log" 2>/dev/null
  return 0
}
