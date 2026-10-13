#!/bin/bash
# bin/lib/child-plan.sh — which model plans a split child (BH-3478). Sourced,
# never run.
#
#   child_plan_model <project> [fallback-model]
#     Prints one model; the first of these that answers wins:
#       1. $PLAN_MODEL_CHILD, the operator's pin for child plans.
#       2. rung 0 of role stage.plan.child, but only when its runner is rung 0's
#          runner of role plan. The plan call goes through the plan route's
#          runner, so a child model for another runner would be handed to the
#          wrong CLI. On a mismatch: one ALERTS line per day per project
#          (_mr_alert_once), and fall through.
#       3. rung 0 of role plan.
#       4. the fallback argument.
#     rc 75 and prints nothing when none of them answers.
#
# An unseeded stage.plan.child is the normal case, so that lookup runs with
# _MR_QUIET=1 and writes no ALERTS line. Nothing is cached here: a route PUT is
# what the next call reads. No model id is spelled in this file
# (tests/model-literal-lint.sh). Root is ${HARNESS:-${H:-}} only (D43).
# shellcheck shell=bash

_cpm_load() {
  command -v model_ladder >/dev/null 2>&1 && return 0
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] && [ -r "$root/bin/lib/model-route.sh" ] || return 1
  # shellcheck source=/dev/null
  HARNESS="$root" . "$root/bin/lib/model-route.sh" 2>/dev/null
  command -v model_ladder >/dev/null 2>&1
}

child_plan_model() {
  local project="${1:-}" fallback="${2:-}" c cm cr pr m
  if [ -n "${PLAN_MODEL_CHILD:-}" ]; then printf '%s\n' "$PLAN_MODEL_CHILD"; return 0; fi
  if _cpm_load; then
    if c=$(_MR_QUIET=1 model_ladder stage.plan.child "$project" 2>/dev/null); then
      cm=$(printf '%s\n' "$c" | awk -F'\t' 'NR==1{print $2}')
      cr=$(printf '%s\n' "$c" | awk -F'\t' 'NR==1{print $3}')
      pr=$(_MR_QUIET=1 model_ladder plan "$project" 2>/dev/null | awk -F'\t' 'NR==1{print $3}')
      if [ -n "$cm" ] && [ -n "$cr" ] && [ -n "$pr" ]; then
        [ "$cr" = "$pr" ] && { printf '%s\n' "$cm"; return 0; }
        _MR_QUIET=0 _mr_alert_once stage.plan.child-runner "$project" \
          "stage.plan.child runner $cr differs from the plan route's runner $pr — child plans stay on the plan route"
      fi
    fi
    m=$(_MR_QUIET=1 model_for plan "$project" 2>/dev/null)
    [ -n "$m" ] && { printf '%s\n' "$m"; return 0; }
  fi
  [ -n "$fallback" ] && { printf '%s\n' "$fallback"; return 0; }
  return 75
}
