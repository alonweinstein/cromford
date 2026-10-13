#!/bin/bash
# bin/lib/lane-model.sh — BH-1510.2: how a NON-build lane learns its model.
# Sourced, never executed.
#
# Before this file every lane carried its own `${TRIAGE_MODEL:-<literal>}`: a
# second, hand-typed copy of a value that model_routes (worker/jobs/schema.sql)
# now owns. This is the one call those lanes make instead:
#
#   MODEL=$(lane_model TRIAGE_MODEL triage "$PROJECT") || exit 75
#
# PRECEDENCE, and why the env still wins. An explicitly set env var (the process
# env, which is where env/global.env, env/<project>.env and a settings row
# exported by lane_env_apply all land) is an operator's decision on THIS box,
# and a box already running on one must keep running on it the day its lane is
# converted — the #1515 review's finding 7: converting a lane must never
# silently drop a live override. With the var unset or empty, the answer is
# model_for <role> [project] (bin/lib/model-route.sh): the project's ladder,
# else the hub's, else this box's cached last good answer when the worker is
# unreachable.
#
# FAIL CLOSED. Nothing in DB, nothing cached: rc 75 and one ALERTS line per
# (role, day), written by model-route.sh. This file adds no model of its own —
# it cannot, it has none. A caller must stop (exit 75 / skip the call), never
# substitute a literal. A resolver that cannot even be loaded is the same
# answer, alerted here because model-route.sh never got to say it.
#
# SOURCING IS LAZY AND LEAVES THE CALLER'S SHELL OPTIONS ALONE. model-route.sh
# pulls in bin/jobs-client.sh, which runs `set -uo pipefail` at its top level;
# a lane sourcing this file must not inherit -u or pipefail it never asked for,
# so the options are captured before and restored after, and the load happens
# on the first call that needs the DB (an env override never loads it at all).

_lane_model_load() {
  command -v model_for >/dev/null 2>&1 && return 0
  local opts self
  opts=$(set +o)
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  # shellcheck source=/dev/null
  { [ -n "$self" ] && [ -r "$self/model-route.sh" ] && . "$self/model-route.sh"; } 2>/dev/null \
    || { [ -n "${HARNESS:-${H:-}}" ] && [ -r "${HARNESS:-${H:-}}/bin/lib/model-route.sh" ] \
           && . "${HARNESS:-${H:-}}/bin/lib/model-route.sh"; } 2>/dev/null
  eval "$opts"
  command -v model_for >/dev/null 2>&1 && return 0
  # Still rc 75 with no root; only the ALERTS line needs one (BH-2613.4).
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || return 75
  mkdir -p "$h/logs" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [lane-model] bin/lib/model-route.sh could not be loaded — no model resolved, nothing guessed" >> "$h/logs/ALERTS.log" 2>/dev/null
  return 75
}

# lane_model <ENV_NAME> <role> [project] -> the model on stdout.
#   rc 0 answered; rc 75 no route anywhere (fail closed); rc 1 a caller bug (a
#   malformed env name, role or project).
lane_model() {
  local env="${1:-}" role="${2:-}" project="${3:-}" v=""
  case "$env" in ""|*[!A-Z0-9_]*) return 1 ;; esac
  v="${!env:-}"
  if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
  _lane_model_load || return 75
  model_for "$role" "$project"
}

# lane_role_model <role> [project] -> the model on stdout, with NO env override:
#   for a call site that never had one (a bare literal before BH-1510.2), where
#   inventing an env name now would only be a second place for the value to live.
lane_role_model() {
  _lane_model_load || return 75
  model_for "$@"
}

# lane_model_ladder <role> [project] -> `position<TAB>model<TAB>runner` per rung.
#   Same rc contract as lane_model; for a lane that needs a failover rung or the
#   runner a rung names, not only the primary model.
lane_model_ladder() {
  _lane_model_load || return 75
  model_ladder "$@"
}

# lane_housekeeping_floor -> sets FLOOR_MODEL, FLOOR_RUNNER, FLOOR_FALLBACK,
#   FLOOR_RUNNERS_ONLY.
#   The housekeeping floor (alert-triage's re-occurring families, alerts-medic)
#   is ONE ladder, model_routes role `housekeeping.floor`: rung 0 is the cheap
#   open-model lane (its model AND its runner), rung 1 the claude model the
#   agent-call ladder falls back to when that lane exits nonzero.
#   HOUSEKEEPING_FLOOR_MODEL / HOUSEKEEPING_RUNNER still win for rung 0.
#   A ONE-RUNG ladder is an operator's shape (the MODELS screen writes whole
#   ladders): the floor then RUNS on that rung alone — FLOOR_FALLBACK is the
#   same model and FLOOR_RUNNERS_ONLY names its runner, which the caller hands
#   agent-call as AGENT_CALL_RUNNERS so no other vendor is reached. Only a
#   ladder with no usable rung 0 (no route, or no model/runner) is rc 75, and
#   that is always one ALERTS line: the resolver is loaded in THIS shell first,
#   so its alert function exists here and not only inside a $( ) subshell.
lane_housekeeping_floor() {
  local ladder
  FLOOR_MODEL=""; FLOOR_RUNNER=""; FLOOR_FALLBACK=""; FLOOR_RUNNERS_ONLY=""
  _lane_model_load || return 75
  ladder=$(model_ladder housekeeping.floor) || return 75
  FLOOR_MODEL="${HOUSEKEEPING_FLOOR_MODEL:-$(printf '%s\n' "$ladder" | awk -F'\t' 'NR==1{print $2}')}"
  FLOOR_RUNNER="${HOUSEKEEPING_RUNNER:-$(printf '%s\n' "$ladder" | awk -F'\t' 'NR==1{print $3}')}"
  FLOOR_FALLBACK=$(printf '%s\n' "$ladder" | awk -F'\t' 'NR==2{print $2}')
  if [ -z "$FLOOR_MODEL" ] || [ -z "$FLOOR_RUNNER" ]; then
    _mr_alert_once housekeeping.floor-rung0 "" \
      "model route housekeeping.floor has no usable rung 0 (model='$FLOOR_MODEL' runner='$FLOOR_RUNNER') — alert-triage's floor and alerts-medic are stopped. PUT a ladder with a model and runner."
    return 75
  fi
  if [ -z "$FLOOR_FALLBACK" ]; then
    FLOOR_FALLBACK="$FLOOR_MODEL"; FLOOR_RUNNERS_ONLY="$FLOOR_RUNNER"
    _mr_log "housekeeping.floor is one rung — the floor runs on $FLOOR_RUNNER/$FLOOR_MODEL only, no claude fallback"
  fi
  return 0
}
