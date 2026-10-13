#!/bin/bash
# bin/box-console-commands.sh — BH-2655 (BH-2528.2). EVERY box except the hub,
# every minute: claim the console commands the hub forwarded to THIS box (the
# box_console_commands queue, bin/lib/jobs/box-console-commands.sh), run each
# one here with bcx_run (bin/lib/box-cmd-exec.sh) and post the outcome back to
# its row. Replaces the hub's ssh forward for the project-scoped types once the
# hub side forwards into the queue; until the worker routes are deployed every
# claim fails, which is one log line and exit 0.
#
# Per row, in this order: ownership (the row's project must resolve through
# box-for.sh to THIS box, so a row addressed to the wrong box is refused and not
# run), staleness (a row whose created_at is older than
# BOX_CONSOLE_COMMANDS_TTL_S is refused and not run; the hub's expire owns rows
# without one), then bcx_run, then the result post. A row whose post fails stays
# `claimed` and is NOT run again here: the hub's expire reports it stale. A
# fetch_artifact/fetch_log body (kind artifact_tail/log_tail) is then also sent
# through bin/beat.sh, because /api/dash/logs/<id> is beat-fed (BH-3945); a
# failed beat is one log line and never changes the row's outcome.
#
# Bounded: 4 cycles 15 s apart, at most BOX_CONSOLE_COMMANDS_CLAIM_LIMIT rows a
# cycle, `timeout 30` on every synchronous script. The lock is dedupe only
# (`flock -n`); detached children never inherit it (bcx closes fd 9).
#
# Log: logs/box-console-commands.log, one line per run that claimed anything,
# nothing for an idle tick. Switch: flags/lane-off-box-console-commands.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# global.env carries JOBS_URL and HARNESS_SECRET; cron does not source it.
set -a +u; . "$HENV/global.env" 2>/dev/null; set +a -u

# >>> lane gate — flags/all-off or flags/lane-off-box-console-commands stops the
# lane; lane_env_apply puts its settings rows into the ${KNOB:-default} reads.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit box-console-commands
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    box-console-commands

# shellcheck disable=SC1091
. "$H/bin/jobs-client.sh" >/dev/null 2>&1 || exit 0
# shellcheck disable=SC1091
. "$H/bin/lib/jobs/box-console-commands.sh" || exit 0
# shellcheck disable=SC1091
. "$H/bin/lib/box-id.sh" || exit 0
# shellcheck disable=SC1091
. "$H/bin/lib/cron-lines.sh" || exit 0
# shellcheck disable=SC1091
. "$H/bin/lib/box-cmd-exec.sh" || exit 0

BOX=$(box_id_require box-console-commands) || exit 0
[ "$BOX" = hub ] && exit 0

mkdir -p "$H/locks" "$H/logs"
exec 9>"$H/locks/box-console-commands.lock"
flock -n 9 || exit 0

LOG="$H/logs/box-console-commands.log"
LIMIT=${BOX_CONSOLE_COMMANDS_CLAIM_LIMIT:-10}
TTL=${BOX_CONSOLE_COMMANDS_TTL_S:-300}
# A claim outage is this log's line, not a page: the routes ship in a sibling
# slice, and the lanes that depend on the worker already alert on it.
JOBS_ALERT=0
ts() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# Ids and types are row data: keep a log line to a safe charset and length.
safe() { printf '%s' "${1:-}" | tr -dc 'A-Za-z0-9_.:-' | head -c 64; }

CLAIMED=0; DONE=0; FAILED=0
for CYCLE in 1 2 3 4; do
  NOW=$(date -u +%s)
  # Not in $(...): JOBS_HTTP must survive into this shell for the log line.
  CF=$(mktemp -t bccmd-claim-XXXXXX) || break
  box_ccmd_claim "$BOX" "$LIMIT" > "$CF"; RC=$?
  ROWS=$(cat "$CF"); rm -f "$CF"
  if [ "$RC" -ne 0 ]; then
    echo "$(ts) claim failed rc=$RC http=${JOBS_HTTP:-none}" >> "$LOG"
    break
  fi
  # Rows ride fd 3, so no script a row runs can read the rest of the batch.
  while IFS= read -r R <&3; do
    [ -n "$R" ] || continue
    CLAIMED=$((CLAIMED+1))
    ID=$(jq -r '.command_id // ""' <<<"$R")
    TYPE=$(jq -r '.type // ""' <<<"$R")
    PROJ=$(jq -r '.project // ""' <<<"$R"); case "$PROJ" in null) PROJ="" ;; esac
    PAYLOAD=$(jq -r '.payload // ""' <<<"$R")
    CREATED=$(jq -r '.created_at // ""' <<<"$R"); case "$CREATED" in null) CREATED="" ;; esac
    if [ -z "$ID" ]; then
      FAILED=$((FAILED+1)); echo "$(ts) row without command_id (type=$(safe "$TYPE")) cannot be answered" >> "$LOG"
      continue
    fi
    OWNER=""
    [ -n "$PROJ" ] && OWNER=$("$H/bin/box-for.sh" "$PROJ" 2>/dev/null)
    AGE=""
    if [ -n "$CREATED" ] && C=$(date -u -d "$CREATED" +%s 2>/dev/null); then AGE=$((NOW - C)); fi
    if [ -z "$OWNER" ] || [ "$(cron_box_id_for "$OWNER")" != "$BOX" ]; then
      BCX_OK=0; BCX_RESULT="refused: $PROJ is not owned by $BOX"; BCX_BODY=""
    elif [ -n "$AGE" ] && [ "$AGE" -gt "$TTL" ]; then
      BCX_OK=0; BCX_RESULT="refused: expired (queued ${AGE}s ago, ttl ${TTL}s)"; BCX_BODY=""
    else
      bcx_run "$TYPE" "$PROJ" "$PAYLOAD" "$ID"
    fi
    if [ -n "$BCX_BODY" ]; then
      BF=$(mktemp -t bccmd-body-XXXXXX)
      printf '%s' "$BCX_BODY" > "$BF"
      box_ccmd_result "$ID" "$BOX" "$BCX_OK" "$BCX_RESULT" "$BF" >/dev/null; PRC=$?
      rm -f "$BF"
      # BH-3945: the row is what the console UI reads, but /api/dash/logs/<id>
      # (the harness MCP's fetch_artifact/fetch_log) is fed by the beat, and the
      # hub's far-box branch sends none. Beat the same JSON after the row, even
      # if the row post failed: idempotent on rkey, never changes the outcome.
      if [ -x "$H/bin/beat.sh" ] \
         && jq -e '.kind == "artifact_tail" or .kind == "log_tail"' <<<"$BCX_BODY" >/dev/null 2>&1; then
        BEAT_STRICT=1 timeout 30 "$H/bin/beat.sh" "$BCX_BODY" >/dev/null 2>&1; BRC=$?
        [ "$BRC" -eq 0 ] || echo "$(ts) beat failed id=$(safe "$ID") type=$(safe "$TYPE") rc=$BRC" >> "$LOG"
      fi
    else
      box_ccmd_result "$ID" "$BOX" "$BCX_OK" "$BCX_RESULT" >/dev/null; PRC=$?
    fi
    if [ "$PRC" -ne 0 ]; then
      FAILED=$((FAILED+1))
      echo "$(ts) result post failed id=$(safe "$ID") type=$(safe "$TYPE") rc=$PRC http=${JOBS_HTTP:-none}" >> "$LOG"
    elif [ "$BCX_OK" = 1 ]; then
      DONE=$((DONE+1))
    else
      FAILED=$((FAILED+1))
    fi
  done 3< <(jq -c '.[]' <<<"$ROWS" 2>/dev/null)
  [ "$CYCLE" -lt 4 ] && sleep 15
done

[ "$CLAIMED" -gt 0 ] && echo "$(ts) claimed=$CLAIMED done=$DONE failed=$FAILED" >> "$LOG"
exit 0
