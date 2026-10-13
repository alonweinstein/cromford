#!/bin/bash
# bin/lib/cost-live.sh — the LIVE-COST seam (BH-3481.0) and its bodies
# (BH-3481.3 / BH-3500). Sourced by bin/agent-call.sh; no side effect at source
# time beyond defining functions.
#
# While a claude session runs, a meter beside it reads the session's own
# transcript every COST_LIVE_POLL_S seconds and, every COST_LIVE_PUSH_S
# seconds, offers ONE live row per (box, session) to the hub
# (POST /api/cost/live). The row is overwritten upward on the same row_hash, and
# the final cost_rows row, written the way it always was, settles it. For a
# build call the meter also asks the build tripwire (tw_check_build) and stops
# the session when it trips. After every cost row, a boundary push starts the
# 10-minute cost-rows-push.sh early instead of waiting for its tick.
#
# Root: ${HARNESS:-${H:-}} and nothing else. An empty root answers "off".
# Knobs (lib.cost-live.* settings rows, catalog/lanes.d/_lib.cost-live.json):
#   COST_LIVE (1), COST_LIVE_PUSH_S (300), COST_LIVE_POLL_S (60),
#   COST_LIVE_STALE_S (900), COST_ROWS_PUSH_AT_BOUNDARY (1).
# Every failure is fail-open: a line in logs/cost-live.log, never a failed call.
#
#   cost_live_on
#       rc 0 = live cost is on for this call; rc 1 = off, with the reason in
#       CL_OFF (no-root, knob, sandbox, testproj, no-secret, no-jobs-url,
#       runner=<x>). The first OFF says so once per process in claude-cost.log.
#   cost_live_row <box> <sid> <tc-line>
#       Prints one live row (compact JSON) for a transcript-cost line;
#       rc 1 = no row (empty box or sid, a token field that is not an integer).
#   cost_live_push <json-row>
#       Offers one live row to the hub. Always rc 0.
#   cost_live_meter <cli-pid> <sid> <cwd>
#       Runs in the background beside a claude session while <cli-pid> lives;
#       agent-call kills and reaps it after the wait. Always rc 0.
#   cost_live_boundary_push
#       Called once after agent-call writes a cost row: spawns cost-rows-push.sh
#       detached unless one already holds its lock. Always rc 0.
#   cost_live_stale_s
#       The age past which a reader treats a live row as stale
#       (GET /api/cost/live?stale_s=). Nothing calls it yet.

_cl_root() {
  local r="${HARNESS:-${H:-}}"
  [ -n "$r" ] || return 1
  printf '%s\n' "$r"
}

# The one clock read; a test redefines it.
_cl_now() { date +%s; }

# _cl_int <val> <default> — <val> when it is a positive integer, else <default>.
_cl_int() {
  case "${1:-}" in ''|*[!0-9]*|0) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

_cl_log() {
  local r
  r=$(_cl_root) || return 0
  mkdir -p "$r/logs" 2>/dev/null || true
  printf '%s [%s] %s: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "${PROJECT:-?}" "${STAGE:-?}" "${1:-}" \
    >> "$r/logs/cost-live.log" 2>/dev/null || true
  return 0
}

cost_live_stale_s() { _cl_int "${COST_LIVE_STALE_S:-}" 900; }

cost_live_on() {
  local root
  CL_OFF=""
  if [ -z "${_CL_ENV_DONE:-}" ]; then
    _CL_ENV_DONE=1
    [ "${LANE_GATE_DISABLE:-0}" = 1 ] || { command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply cost-live; } || true
  fi
  root=$(_cl_root) || root=""
  if [ -z "$root" ]; then CL_OFF=no-root; return 1; fi
  case "${COST_LIVE:-1}" in 0|no|off|false) CL_OFF=knob ;; esac
  [ -z "$CL_OFF" ] && [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && CL_OFF=sandbox
  [ -z "$CL_OFF" ] && [ "${PROJECT:-}" = testproj ] && CL_OFF=testproj
  [ -z "$CL_OFF" ] && [ -z "${HARNESS_SECRET:-}" ] && CL_OFF=no-secret
  if [ -z "$CL_OFF" ] && { [ -z "${JOBS_URL:-}" ] || ! declare -F _jobs_req >/dev/null 2>&1; }; then
    CL_OFF=no-jobs-url
  fi
  [ -z "$CL_OFF" ] && [ "${runner:-}" != claude ] && CL_OFF="runner=${runner:-}"
  [ -n "$CL_OFF" ] || return 0
  if [ -z "${_CL_OFF_SAID:-}" ]; then
    _CL_OFF_SAID=1
    printf '%s [%s] %s: cost live: OFF (%s)\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "${PROJECT:-?}" "${STAGE:-?}" "$CL_OFF" \
      >> "$root/logs/claude-cost.log" 2>/dev/null || true
  fi
  return 1
}

cost_live_row() {
  local box="${1:-}" sid="${2:-}" tc="${3:-}" in out cr cw usd model _m _f unp v h run tk
  [ -n "$box" ] && [ -n "$sid" ] || return 1
  IFS='|' read -r in out cr cw usd model _m _f unp <<<"$tc"
  for v in "$in" "$out" "$cr" "$cw"; do
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
  done
  h=$(printf 'live|%s|%s' "$box" "$sid" | sha256sum | cut -d' ' -f1)
  run="${COST_RUN_ID:-}"
  [ -n "$run" ] || case "${OUT:-}" in */builds/*/*) run=$(basename "$(dirname "$OUT")") ;; esac
  tk="${COST_KEY:-${AGENT_CALL_TICKET:-${HARNESS_TICKET:-}}}"
  # An unpriced model is null, never 0 (D11). Tested here so jq never errors.
  [[ "$usd" =~ ^[0-9]+(\.[0-9]+)?$ ]] || usd=""
  jq -nc --arg box "$box" --arg h "$h" --arg sid "$sid" --arg run "$run" --arg tk "$tk" \
    --arg project "${PROJECT:-}" --arg stage "${STAGE:-}" --arg model "$model" \
    --arg in "$in" --arg out "$out" --arg cr "$cr" --arg cw "$cw" --arg usd "$usd" --arg unp "$unp" \
    --arg st "${CL_STARTED_AT:-}" --arg up "$(date -u -d "@$(_cl_now)" +%FT%TZ)" '
    def n: if . == "" then null else . end;
    {box: $box, row_hash: $h, session_id: $sid, run_id: ($run|n), ticket: ($tk|n),
     project: ($project|n), stage: ($stage|n), model: ($model|n),
     input_toks: ($in|tonumber), output_toks: ($out|tonumber),
     cache_read: ($cr|tonumber), cache_write: ($cw|tonumber),
     cost_usd: (if $usd == "" then null else ($usd|tonumber) end),
     unpriced: ($unp|n), started_at: ($st|n), updated_at: $up}'
}

cost_live_push() {
  local row="${1:-}" body sid rc=0 http
  printf '%s' "$row" | jq -e '.box' >/dev/null 2>&1 || return 0
  [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && return 0
  [ "$(printf '%s' "$row" | jq -r '.project // ""' 2>/dev/null)" = testproj ] && return 0
  declare -F _jobs_req >/dev/null 2>&1 || return 0
  body=$(printf '%s' "$row" | jq -c '{box: .box, rows: [.]}' 2>/dev/null) || return 0
  # Not inside $(...), so JOBS_HTTP survives. One attempt, bounded at ~10 s.
  JOBS_TIMEOUT=10 JOBS_RETRIES=0 _jobs_req POST /api/cost/live "$body" >/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    sid=$(printf '%s' "$row" | jq -r '.session_id // ""' 2>/dev/null)
    http="${JOBS_HTTP:-none}"
    [ "$rc" = 2 ] && http="404 (route not deployed yet)"
    _cl_log "push FAILED session=$sid http=$http rc=$rc"
  fi
  return 0
}

cost_live_meter() {
  local pid="${1:-}" sid="${2:-}" cwd="${3:-}" root tcb box poll push last now line row usd v adv au bd="" k="" said="" nap="" otrap
  root=$(_cl_root) || return 0
  [ -n "$pid" ] && [ -n "$sid" ] || return 0
  tcb="${BASH_SOURCE[0]%/*}/../transcript-cost.sh"
  [ -x "$tcb" ] || tcb="$root/bin/transcript-cost.sh"
  if [ ! -x "$tcb" ]; then
    _cl_log "meter off for session $sid: bin/transcript-cost.sh is not executable"
    return 0
  fi
  # No identity, no row: the same rule as cost_row_emit.
  box=$(cost_row_box_id 2>/dev/null) || box=""
  if [ -z "$box" ]; then
    _cl_log "meter off for session $sid: no box id"
    return 0
  fi
  CL_STARTED_AT=$(date -u +%FT%TZ)
  last=$(_cl_now)
  poll=$(_cl_int "${COST_LIVE_POLL_S:-}" 60)
  push=$(_cl_int "${COST_LIVE_PUSH_S:-}" 300)
  # The tripwire is asked about build calls only. run-build's $KEY is not
  # exported into agent-call; HARNESS_TICKET is.
  case "${OUT:-}" in
    */builds/*/*) bd=$(dirname "$OUT"); k="${KEY:-${AGENT_CALL_TICKET:-${HARNESS_TICKET:-}}}" ;;
  esac
  # agent-call TERMs the meter when the session ends and then waits on it. A
  # TERM with no trap kills the meter at once and orphans whatever $(...) it
  # was inside (a transcript read, a push's curl) as a fork that outlives the
  # call and can land a live row after the final one (BH-4750). The trap runs
  # once that command finishes, so the wait covers it; the nap is backgrounded
  # so a TERM during it ends the meter at once rather than after $poll.
  otrap=$(trap -p TERM)
  trap '[ -n "$nap" ] && kill "$nap" 2>/dev/null; exit 0' TERM
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$poll" & nap=$!
    wait "$nap"; nap=""
    kill -0 "$pid" 2>/dev/null || break
    if ! line=$(eval "${ACCT_EXPORTS:-}"; "$tcb" "$sid" --cwd "$cwd" 2>/dev/null) || [ -z "$line" ]; then
      [ -n "$said" ] || { said=1; _cl_log "could not read session $sid; no live row this poll, meter keeps polling"; }
      continue
    fi
    # An --advisor attempt (BH-3491, ADV_ATTEMPT): the default sum above is
    # executor-only, and the advisor's advisor_message iterations are priced by
    # --advisor. Add them, so the live row and the tripwire see the whole spend
    # the phase will be charged (agent-call adds ADV_USD to PHASE_USD). Exit 4
    # (not consulted yet) or an unpriced side leaves the executor's number.
    if [ -n "${ADV_ATTEMPT:-}" ] && adv=$(eval "${ACCT_EXPORTS:-}"; "$tcb" "$sid" --advisor --cwd "$cwd" 2>/dev/null) && [ -n "$adv" ]; then
      au=$(printf '%s' "$adv" | cut -d'|' -f5); usd=$(printf '%s' "$line" | cut -d'|' -f5)
      if [[ "$au" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ "$usd" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        line=$(printf '%s\n' "$line" | awk -F'|' -v OFS='|' -v a="$au" '{ $5 = sprintf("%.6f", $5 + a); print }')
      fi
    fi
    now=$(_cl_now)
    if [ $((now - last)) -ge "$push" ]; then
      row=$(cost_live_row "$box" "$sid" "$line") && cost_live_push "$row"
      last=$now
    fi
    [ -n "$bd" ] || continue
    usd=$(printf '%s' "$line" | cut -d'|' -f5)
    [[ "$usd" =~ ^[0-9]+(\.[0-9]+)?$ ]] || usd=0
    declare -F tw_check_build >/dev/null 2>&1 || continue
    if v=$(tw_check_build "${PROJECT:-}" "$k" "$bd" "$usd"); then
      # The first field of the marker is the rule: tw_eval prints
      # trip<TAB><rule><TAB>...; agent-call notes the row tripwire:<rule>.
      v="${v//$'\t'/ }"; v="${v#trip }"
      printf '%s\n' "$v" > "$OUT.tripwire"
      kill -TERM "$pid" 2>/dev/null
      break
    fi
  done
  eval "${otrap:-trap - TERM}"
  return 0
}

cost_live_boundary_push() {
  local root crp box
  case "${COST_ROWS_PUSH_AT_BOUNDARY:-1}" in 0|no|off|false) return 0 ;; esac
  root=$(_cl_root) || return 0
  # No secret or no worker: the push could send nothing, so spawn nothing.
  # Every suite that runs the real agent-call lands here (tests/lib/scratch.sh
  # empties both), so no push is left running into a scratch tree.
  [ -n "${HARNESS_SECRET:-}" ] && [ -n "${JOBS_URL:-}" ] || return 0
  mkdir -p "$root/locks" 2>/dev/null || return 0
  # Dedupe, never wait: the cron lane's own lock. The spawned script takes it
  # with flock -n too, so the probe/spawn window is harmless.
  if ! flock -n "$root/locks/cost-rows-push.lock" true 2>/dev/null; then
    _cl_log "boundary push skipped (push in flight)"
    return 0
  fi
  crp="${BASH_SOURCE[0]%/*}/../cost-rows-push.sh"
  [ -x "$crp" ] || crp="$root/bin/cost-rows-push.sh"
  [ -x "$crp" ] || return 0
  box=$(cost_row_box_id 2>/dev/null) || box=""
  # Detached with no inherited fds, so a $(agent-call ...) caller never waits.
  if command -v setsid >/dev/null 2>&1; then
    setsid "$crp" ${box:+"$box"} </dev/null >/dev/null 2>&1 &
  else
    "$crp" ${box:+"$box"} </dev/null >/dev/null 2>&1 &
  fi
  return 0
}
