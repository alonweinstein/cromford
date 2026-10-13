#!/bin/bash
# bin/lib/mc-ci-timeout.sh — A JOB THAT DIES AT ITS timeout-minutes IS A REPO
# PROBLEM, NOT A FLAKE (BH-3775; this file is the BH-3784 contract). Sourced by
# bin/merge-conductor.sh, never executed.
#
# THE CASE. 15 project-4 PRs sat in WAIT_CI for up to 9 days: a required check
# (`timeout-minutes: 10`) died at its limit on 29 of 40 runs. GitHub reports a
# job timeout as `cancelled`, so the BH-636 flake ladder re-ran each PR once and
# then paged one CI_FLAKE_TWICE per PR, and nobody saw the repo-level cause.
#
# THE CONTRACT. The ladder calls cit_assess once per PR with the flake list
# mc_ci_flake_runs gave it, and then runs its rung `case` on CIT_RUNS_LEFT
# (skipped when CIT_SKIP_RUNG=1 or CIT_RUNS_LEFT is empty). The three steps
# below are fail-open stubs; the optional part files mc-ci-timeout-scan.sh,
# -rekick.sh and -budget.sh replace them. With the stubs alone CIT_RUNS_LEFT is
# the input list and the ladder is byte for byte BH-636's.

# Knobs (catalog/lanes.d/_lib.mc-ci-timeout.json): row > cached row > env >
# registry default, in a SUBSHELL like bin/lib/mc/queue.sh's _MCQ_KV. The code
# literal after it is the documented fallback when there is no registry, and it
# also replaces a non-integer value.
_CIT_KV=$(
  exec 3>&1
  _CIT_R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd) || exit 0
  command -v lib_env_apply >/dev/null 2>&1 || . "$_CIT_R/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
  if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_CIT_R/bin/lib/lanes-registry.sh" >/dev/null 2>&1; then
    LANE_REGISTRY=$(lanes_json_path "$_CIT_R" 2>/dev/null) && export LANE_REGISTRY
  fi
  trap 'for _CIT_K in MC_CI_TIMEOUT MC_CI_TIMEOUT_SLACK_S MC_CI_TIMEOUT_DEFAULT_MIN MC_CI_TIMEOUT_MIN_PRS MC_CI_TIMEOUT_RATIO_PCT MC_CI_TIMEOUT_HISTORY_N MC_CI_TIMEOUT_HISTORY_MIN MC_CI_TIMEOUT_WINDOW_S; do printf "%s\t%s\n" "$_CIT_K" "${!_CIT_K:-}" >&3; done' EXIT
  lib_env_apply mc-ci-timeout >/dev/null 2>&1)
while IFS=$'\t' read -r _CIT_K _CIT_V; do
  if [ -n "$_CIT_V" ]; then printf -v "$_CIT_K" '%s' "$_CIT_V"; fi
done <<<"$_CIT_KV"
unset _CIT_KV _CIT_K _CIT_V
case "${MC_CI_TIMEOUT:-}" in ''|*[!0-9]*) MC_CI_TIMEOUT=1 ;; esac
case "${MC_CI_TIMEOUT_SLACK_S:-}" in ''|*[!0-9]*) MC_CI_TIMEOUT_SLACK_S=60 ;; esac
case "${MC_CI_TIMEOUT_DEFAULT_MIN:-}" in ''|*[!0-9]*) MC_CI_TIMEOUT_DEFAULT_MIN=360 ;; esac
case "${MC_CI_TIMEOUT_MIN_PRS:-}" in ''|*[!0-9]*) MC_CI_TIMEOUT_MIN_PRS=3 ;; esac
case "${MC_CI_TIMEOUT_RATIO_PCT:-}" in ''|*[!0-9]*) MC_CI_TIMEOUT_RATIO_PCT=50 ;; esac
case "${MC_CI_TIMEOUT_HISTORY_N:-}" in ''|*[!0-9]*) MC_CI_TIMEOUT_HISTORY_N=20 ;; esac
case "${MC_CI_TIMEOUT_HISTORY_MIN:-}" in ''|*[!0-9]*) MC_CI_TIMEOUT_HISTORY_MIN=10 ;; esac
case "${MC_CI_TIMEOUT_WINDOW_S:-}" in ''|*[!0-9]*) MC_CI_TIMEOUT_WINDOW_S=259200 ;; esac

# State, next to the conductor's other files. No root at all (no MC_STATE_DIR,
# HARNESS or H) leaves both paths empty, and cit_ledger_put refuses.
_CIT_STATE=${MC_STATE_DIR:-}
if [ -z "$_CIT_STATE" ] && [ -n "${HARNESS:-${H:-}}" ]; then _CIT_STATE="${HARNESS:-${H:-}}/state/merge-conductor"; fi
# One line per classified dead job, tab-separated:
#   epoch slug check key head run_id duration_s timeout_min class wfpath run_started_at
CIT_LEDGER=${_CIT_STATE:+$_CIT_STATE/ci-timeout.tsv}
# One line per budget firing, tab-separated:
#   epoch day slug check wfpath T X Y p50 p90 prs
# Nothing writes it yet (BH-3775 budget slice).
CIT_FIRING_TSV=${_CIT_STATE:+$_CIT_STATE/ci-timeout-firing.tsv}
unset _CIT_STATE

# cit_ledger_put <epoch> <slug> <check> <key> <head> <run_id> <duration_s>
#   <timeout_min> <class> <wfpath> <run_started_at> — append one ledger line
#   under flock. Tabs and newlines in the check name become spaces, so a line
#   always has 11 fields. Non-zero when the line was not written.
cit_ledger_put() {
  [ -n "${CIT_LEDGER:-}" ] && [ "$#" = 11 ] || return 1
  local check=${3//$'\t'/ } d
  check=${check//$'\n'/ }
  d=$(dirname "$CIT_LEDGER")
  mkdir -p "$d" 2>/dev/null || return 1
  ( flock 9 || exit 1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$1" "$2" "$check" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" >> "$CIT_LEDGER"
  ) 9>>"$CIT_LEDGER.lock" 2>/dev/null
}

_cit_reset() {
  CIT_RUNS_LEFT=$1; CIT_TIMEOUTS=""; CIT_FIRING=0; CIT_CHECK=""; CIT_WF=""; CIT_T=""
  CIT_REKICK=0; CIT_SKIP_RUNG=0; CIT_HIT=""; CIT_OF=""; CIT_PRS=""; CIT_P50=""; CIT_P90=""
}

# cit_assess <slug> <key> <head> <base> <num> <flake-runs> — call it as a plain
#   command, never in $( ): its answer is the CIT_* globals. Always rc 0. A
#   step that returns non-zero puts every global back to the reset values, so a
#   failure can only ever leave the ladder on the full flake list.
cit_assess() {
  _cit_reset "${6:-}"
  [ "$MC_CI_TIMEOUT" = 1 ] || return 0
  cit_scan "$@" || { _cit_reset "${6:-}"; return 0; }
  [ -n "$CIT_TIMEOUTS" ] || return 0
  cit_rekick_step "$@" || { _cit_reset "${6:-}"; return 0; }
  cit_budget_step "$@" || { _cit_reset "${6:-}"; return 0; }
  return 0
}

# The fail-open stubs. cit_scan fills CIT_TIMEOUTS, one line per TIMEOUT dead
# job: run_id<TAB>check<TAB>wfpath<TAB>T<TAB>run_started_at. cit_rekick_step may
# set CIT_REKICK=1 / CIT_SKIP_RUNG=1. cit_budget_step may set CIT_FIRING=1 and
# remove withheld lines from CIT_RUNS_LEFT.
cit_scan() { return 0; }
cit_rekick_step() { return 0; }
cit_budget_step() { return 0; }

_CIT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
# shellcheck source=/dev/null
[ -r "$_CIT_DIR/mc-ci-timeout-scan.sh" ] && . "$_CIT_DIR/mc-ci-timeout-scan.sh"
# shellcheck source=/dev/null
[ -r "$_CIT_DIR/mc-ci-timeout-rekick.sh" ] && . "$_CIT_DIR/mc-ci-timeout-rekick.sh"
# shellcheck source=/dev/null
[ -r "$_CIT_DIR/mc-ci-timeout-budget.sh" ] && . "$_CIT_DIR/mc-ci-timeout-budget.sh"
unset _CIT_DIR
