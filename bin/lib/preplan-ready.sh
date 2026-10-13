#!/bin/bash
# bin/lib/preplan-ready.sh — the deterministic readiness filter asked before a
# pre-plan session is bought (BH-2543). Sourced only; safe under `set -u`. No
# network call: the answer is a function of the candidate's class and one knob.
#
# The call site is `# >>> preplan readiness (BH-2543)` in bin/preplan-tick.sh,
# which logs the reason once per key through preplan_small_log and skips the
# key. The class is the third column bin/preplan-candidates.sh prints.
#
# THE V1 RULES (BH-2543.3):
#   - `blocked` is NOT ready. bin/preplan-candidates.sh emits it for a parent
#     nobody has started yet (the `blocked_left` arm, ~line 433-439), and a
#     pre-plan expires at the tick's 24h housekeeping, so a plan bought now is
#     a plan the build will most likely never adopt.
#   - `queued`, `hotfix`, `child`, `child-building` and `ahead` are ready.
#   - An empty or unknown class is ready (fail-open: a class this lib has not
#     heard of launches exactly as it did before the filter existed).
#   - With the knob off, everything is ready.
#
# NOT DUPLICATED HERE. Two other gates already refuse a key before spend:
# HOLD by `# >>> preplan hold gate` in bin/run-preplan.sh (BH-1526), and
# waiting-on-client by bin/preplan-candidates.sh (the needs_clarification +
# waitingOn=client skip, ~line 667), which never lists the key at all.
#
# Knob: PREPLAN_READY_ONLY (catalog/lanes.d/preplan-tick.json, default 1), read
# per project through `lane_knob preplan-tick PREPLAN_READY_ONLY <project>` when
# lane-gate.sh is loaded, otherwise from the environment.

# preplan_ready_on <harness> [project] — rc 0 when the readiness filter is
# switched on for that project. On only when the value is exactly 1.
preplan_ready_on() {
  local p="${2:-}" v
  if command -v lane_knob >/dev/null 2>&1; then
    v=$(lane_knob preplan-tick PREPLAN_READY_ONLY "$p")
  else
    v=${PREPLAN_READY_ONLY:-}
  fi
  [ -n "$v" ] || v=1
  [ "$v" = 1 ]
}

# preplan_not_ready <harness> <project> <key> <class> — rc 0 and a reason on
# stdout when the key is NOT ready to pre-plan; rc 1 (ready), silent, otherwise.
# The reason carries no tab or newline: the tick puts it in a log line.
preplan_not_ready() {
  local h="${1:-}" p="${2:-}" c="${4:-}"
  preplan_ready_on "$h" "$p" || return 1
  case "$c" in
    blocked) echo 'blocker not started: cannot build within the pre-plan TTL'; return 0 ;;
  esac
  return 1
}
