#!/bin/bash
# bin/lib/steer.sh — BH-5839: the build's side of the ticket page's "Step in"
# composer. Sourced by bin/agent-call.sh; defines functions only.
#
#   steer_take <job_id>
#     Asks the jobs worker for this job's notes (POST /api/steer/take). A hold
#     note sent to this job sets STEER_HOLD_ID / STEER_HOLD_TEXT, and then no
#     "now" note is taken: the stage refuses, so those stay pending. Otherwise
#     each pending "now" note is claimed ONCE (status taken), its id goes into
#     STEER_TAKEN_IDS, and the notes print as one prompt block on stdout
#     (nothing when there are none).
#     rc 0 always. A worker that does not answer costs the stage one try, no
#     retry (JOBS_RETRIES=0): no block, one line in logs/steer.log. A note is
#     never lost that way: it stays pending and the next step boundary takes it.
#
#   steer_settle <job_id> <rc>
#     The call's exit (agent-call.sh runs it from its EXIT trap). rc 0: the
#     taken notes were in the prompt of a call that ran, so the worker marks
#     them read. Any other rc: a gate refused the call or the runner failed, so
#     the notes go back to pending for the next step. A settle the worker does
#     not answer leaves them taken; the worker takes them again after the
#     steer.take_lease_s settings row.
#
# THE STEP BOUNDARY is agent-call.sh just before prompt_guard, on every model
# call CC() in bin/lib/rb/plan.sh makes for a build (CC() sets
# AGENT_CALL_STEER=1). A direct agent-call.sh caller inside a build (replan,
# repro drive, decompose) takes nothing: it does not stop on a hold refusal.
# A hold note makes the call refuse (rc 74 steer-hold), and CC() turns the
# refusal into BUILD_DEFERRED: the build stops after the step it was in. The
# hold LABEL (bin/lib/ticket-hold-cmd.sh, applied by bin/lib/steer-deliver.sh)
# keeps it from starting again until a person resumes it.

STEER_HOLD_ID="" STEER_HOLD_TEXT="" STEER_TAKEN_IDS=""

# The root is the caller's: no HARNESS and no H means no log line, never a path
# built from an empty root.
_steer_log() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 0
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [steer] $*" >> "$root/logs/steer.log" 2>/dev/null
}

steer_take() {
  local job="${1:-}" resp body
  STEER_HOLD_ID="" STEER_HOLD_TEXT="" STEER_TAKEN_IDS=""
  [ -n "$job" ] || return 0
  command -v _jobs_req >/dev/null 2>&1 || return 0
  body=$(jq -nc --arg j "$job" '{job_id:$j}' 2>/dev/null) || return 0
  if ! resp=$(JOBS_RETRIES=0 _jobs_req POST /api/steer/take "$body" 2>/dev/null) || [ -z "$resp" ]; then
    _steer_log "job $job: take not answered (http=${JOBS_HTTP:-none}); notes stay pending for the next step"
    return 0
  fi
  if jq -e '.hold | type == "object"' >/dev/null 2>&1 <<<"$resp"; then
    STEER_HOLD_ID=$(jq -r '.hold.id // ""' <<<"$resp" 2>/dev/null)
    STEER_HOLD_TEXT=$(jq -r '.hold.text // ""' <<<"$resp" 2>/dev/null)
    _steer_log "job $job: hold note #$STEER_HOLD_ID taken; the stage refuses"
    return 0
  fi
  STEER_TAKEN_IDS=$(jq -r '[(.notes // [])[] | .id | numbers] | map(tostring) | join(" ")' <<<"$resp" 2>/dev/null)
  jq -r '
    (.notes // []) | select(length > 0)
    | "A person sent these notes from Mission Control while this build ran. Read them before your next step:\n"
      + ([ .[] | "- Note #\(.id) from \(.actor // "a person") at \(.created_at // "?"): \(.text)" ] | join("\n"))' \
    <<<"$resp" 2>/dev/null
  return 0
}

steer_settle() {
  local job="${1:-}" rc="${2:-1}" read=false body
  [ -n "$job" ] && [ -n "${STEER_TAKEN_IDS:-}" ] || return 0
  command -v _jobs_req >/dev/null 2>&1 || return 0
  [ "$rc" = 0 ] && read=true
  # shellcheck disable=SC2086 # the ids are digits split on spaces
  body=$(jq -nc --arg j "$job" --argjson r "$read" '{job_id:$j, read:$r, ids:($ARGS.positional | map(tonumber))}'     --args $STEER_TAKEN_IDS 2>/dev/null) || return 0
  if JOBS_RETRIES=0 _jobs_req POST /api/steer/settle "$body" >/dev/null 2>&1; then
    _steer_log "job $job: notes $STEER_TAKEN_IDS settled read=$read (rc $rc)"
  else
    _steer_log "job $job: notes $STEER_TAKEN_IDS not settled (http=${JOBS_HTTP:-none}); they stay taken until steer.take_lease_s"
  fi
  STEER_TAKEN_IDS=""
  return 0
}
