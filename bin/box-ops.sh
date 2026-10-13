#!/bin/bash
# bin/box-ops.sh — every-box cron (* * * * *): run the console's box_commands
# rows addressed to THIS box.
#
# WHY THIS EXISTS (BH-2518, BH-2660). An operator asks for a box op from the
# console (backup now, harness-sync, CLI update, stop or destroy a Fly machine);
# the request is a box_commands row in the jobs worker. The box that owns the
# row claims it here, runs it locally and posts ok or fail with a detail line.
# No ssh anywhere: the hub never reaches into a box, the box pulls its own work.
#
# RUN ORDER (each step's failure is named in the log, the ALERTS line or the
# posted detail):
#   gate        lane_gate_or_exit box-ops (flags/all-off, flags/lane-off-box-ops)
#               — exit 0 before anything else; lane_env_apply before AND after
#               the env load.
#   lock        flock -n locks/box-ops.lock; held = a tick is going, exit 0.
#               Dedupe only, never a wait; the worker's claim CAS is the
#               cross-box guard. Every op runs with fd 9 closed, so no child can
#               keep the lock past the tick.
#   knobs       BOX_OPS_TIMEOUT_S / BOX_OPS_MAX_PER_TICK must be positive
#               integers; anything else is one ALERTS line and exit 1, nothing
#               claimed (never clamped).
#   identity    BOX from bin/box-name.sh. Empty = one ALERTS line, exit 1.
#               The claim asks for boxes [BOX], plus "hub" only while
#               bin/hub-lease.sh check passes.
#   claim       POST /api/box-commands/claim {claimer, boxes}, at most
#               BOX_OPS_MAX_PER_TICK times. 404 = the route is not deployed:
#               one log line, exit 0, no ALERTS. Any other failure: one log
#               line, exit 0 (the jobs client owns the outage alert).
#   run         the type's handler (the case below) under `timeout
#               BOX_OPS_TIMEOUT_S`; rc 124 is fail "timed out after <n>s". A row
#               for a box this tick did not ask for, an unknown type or a bad
#               Fly id is refused without running anything.
#   log+result  one logs/box-ops.log line, THEN POST
#               /api/box-commands/<id>/result {claimer, ok, detail<=500}. A POST
#               that is not a 2xx leaves the row claimed (re-offered after the
#               worker's box_commands_claim_ttl_s): ONE ALERTS line and exit 1.
# Exit: 0 done / nothing to do / gated / locked / worker down or not deployed,
# 1 bad knob, no box name, or a result not recorded.
#
# The Fly verbs call bin/lib/box-ops-fly.sh, which the Fly sibling (#2661)
# owns: its contract stub answers "refused: fly ops not built yet", and its
# executors refuse anything they are not allowed to stop or destroy.
# Knobs (catalog/lanes.d/box-ops.json): BOX_OPS_TIMEOUT_S (900; keep it below
# box_commands_claim_ttl_s, 1800), BOX_OPS_MAX_PER_TICK (3).
# Run by hand: bin/box-ops.sh
#
# ORGO VERBS. With a first argument this is an operator command, not the tick:
#   box-ops.sh restart|stop <id> [--account <a>] [--apply]
#   box-ops.sh resize <id> --account <a> [--vcpus N] [--mem-gb N] [--disk-gb N] [--apply --confirm-monthly-usd <n>]
#   box-ops.sh retire <id> [--to <box-id>] [--ip <old-ip>] [--root <dir>] [--apply] [--delete]
# They live in bin/lib/box-ops-orgo.sh (dry run by default, exit 0/1/2/3/4 as
# bin/box-launch.sh). They are not lane-gated and take no locks/box-ops.lock.
# Any other first argument is a usage error (exit 2). docs/ADDING-A-BOX.md,
# "Box operations".
set -uo pipefail
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
case "${1:-}" in
  restart|resize|stop|retire)
    # shellcheck source=bin/lib/box-ops-orgo.sh
    . "$(dirname "${BASH_SOURCE[0]}")/lib/box-ops-orgo.sh" || exit 1
    box_ops_orgo "$@"; exit $? ;;
  "") ;;
  *) echo "usage: box-ops.sh [restart|resize|stop|retire <id> ...]  (no argument = the cron tick)" >&2; exit 2 ;;
esac
# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s/env\n' "${1:-$H}"; }
HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-box-ops
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off box-ops.
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit box-ops
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    box-ops
set -a
# shellcheck disable=SC1091
. "$HENV/global.env" 2>/dev/null
set +a
# Again below the env load: global.env re-assigns any knob it also carries, and
# the settings row must win (tests/lanes-registry-test.sh section 16).
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    box-ops

# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || exit 1

LOG="$H/logs/box-ops.log"
ALERTS="$H/logs/ALERTS.log"
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
now() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log() { printf '%s [box-ops] %s\n' "$(now)" "$*" >> "$LOG"; }
# Alerts go through bin/alert-line.sh (the alert-writer ratchet, BH-2314): it
# stamps the line, dedups it and beats it to the console. \$ALERTS stays for the
# size/since reads below.
alert() { HARNESS="$H" "$H/bin/alert-line.sh" "[box-ops] $*"; }

exec 9>"$H/locks/box-ops.lock"
flock -n 9 || exit 0

TO="${BOX_OPS_TIMEOUT_S:-900}"
MAX="${BOX_OPS_MAX_PER_TICK:-3}"
[[ "$TO" =~ ^[1-9][0-9]*$ ]] \
  || { alert "box-ops: BOX_OPS_TIMEOUT_S '$TO' is not a positive integer; nothing claimed"; exit 1; }
[[ "$MAX" =~ ^[1-9][0-9]*$ ]] \
  || { alert "box-ops: BOX_OPS_MAX_PER_TICK '$MAX' is not a positive integer; nothing claimed"; exit 1; }

BOX=$("$H/bin/box-name.sh" 2>/dev/null | tr -dc 'A-Za-z0-9._-')
[ -n "$BOX" ] || { alert "box-ops: bin/box-name.sh gave no box name; nothing claimed"; exit 1; }
HUB=false
"$H/bin/hub-lease.sh" check >/dev/null 2>&1 && HUB=true
BOXES=$(jq -nc --arg b "$BOX" --argjson hub "$HUB" 'if $hub then [$b, "hub"] else [$b] end')

last_line() { printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | tail -1; }
size_of() { stat -c %s "$1" 2>/dev/null || echo 0; }
since() { tail -c +"$(( $2 + 1 ))" "$1" 2>/dev/null; } # since <file> <byte offset>: what was appended

# run_op — sets OK (true|false) and DETAIL for TYPE/TARGET/PROJECT/APP.
run_op() {
  local rc out line
  OK=false DETAIL=""
  case "$TYPE" in
    # >>> backup_now handler
    backup_now)
      # ok ONLY on rc 0 AND an upload stamp at or after T0. The stamp uses
      # state-backup's own fixed-width format, so a string compare is a time
      # compare. state-backup reports skips and refusals in its own log, so
      # the detail comes from what this run appended there.
      local sblog="$H/logs/state-backup.log" sb0 al0 key new T0 STAMP
      T0=$(date -u +%Y%m%dT%H%M%SZ)
      sb0=$(size_of "$sblog"); al0=$(size_of "$ALERTS")
      BACKUP_FORCE=1 timeout "$TO" "$H/bin/state-backup.sh" >/dev/null 2>&1 9>&-; rc=$?
      [ "$rc" = 124 ] && { DETAIL="timed out after ${TO}s"; return; }
      STAMP=$(jq -r '.ts // empty' "$H/state/backup-last.json" 2>/dev/null)
      key=$(jq -r '.key // empty' "$H/state/backup-last.json" 2>/dev/null)
      if [ "$rc" = 0 ] && [ -n "$STAMP" ] && ! [[ "$STAMP" < "$T0" ]]; then
        OK=true DETAIL="uploaded ${key:-?} (stamp $STAMP)"; return
      fi
      new=$(since "$sblog" "$sb0")
      if line=$(grep -m1 'skip: a backup is still running' <<<"$new"); then
        DETAIL="backup already running (lock held)"
      elif line=$(grep -m1 'not configured' <<<"$new"); then
        DETAIL="not configured: ${line#*\[state-backup\] }"
      elif line=$(grep -m1 'off:' <<<"$new"); then
        DETAIL="backup switched off: ${line#*\[state-backup\] }"
      elif line=$(since "$ALERTS" "$al0" | grep -m1 .); then
        DETAIL="$line"
      else
        DETAIL="state-backup rc=$rc; no upload stamp at or after $T0 (last ${STAMP:-none})"
      fi
      ;;
    # <<<
    # >>> harness_sync handler
    harness_sync)
      # harness-sync writes its own ALERTS line and stamp; box-ops adds none.
      out=$(timeout "$TO" "$H/bin/harness-sync.sh" 2>&1 9>&-); rc=$?
      line=$(last_line "$out")
      case "$rc" in
        124) DETAIL="timed out after ${TO}s" ;;
        0)   OK=true DETAIL="$line" ;;
        20)  DETAIL="not synced: $line" ;;
        30)  DETAIL="refused: $line" ;;
        *)   DETAIL="harness-sync rc=$rc: $line" ;;
      esac
      ;;
    # <<<
    # >>> cli_update handler
    cli_update)
      out=$(timeout "$TO" "$H/bin/cli-update.sh" 9>&-); rc=$?
      line=$(last_line "$out")
      case "$rc" in
        124) DETAIL="timed out after ${TO}s" ;;
        0)   OK=true DETAIL="$line" ;;
        *)   DETAIL="cli-update rc=$rc: $line" ;;
      esac
      ;;
    # <<<
    # >>> fly_machine_stop / fly_machine_destroy handler
    fly_machine_stop|fly_machine_destroy)
      # Checked here before a destructive verb runs, whatever the worker
      # already validated. Every value rides as a positional argument to the
      # lib function (a function cannot run under `timeout` directly), so the
      # id is never interpolated into a command line.
      if ! [[ "$TARGET" =~ ^[0-9a-z]{8,32}$ && "$PROJECT" =~ ^[A-Za-z0-9._-]{1,64}$ && "$APP" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
        DETAIL="refused: bad target/project/app"; return
      fi
      out=$(timeout "$TO" bash -c '. "$1" && "$2" "$3" "$4" "$5"' _ \
        "$H/bin/lib/box-ops-fly.sh" "box_ops_fly_${TYPE#fly_machine_}" "$TARGET" "$PROJECT" "$APP" 9>&-); rc=$?
      if [ "$rc" = 124 ]; then DETAIL="timed out after ${TO}s"
      elif [ "$rc" = 0 ]; then OK=true DETAIL="$out"
      else DETAIL="$out"
      fi
      ;;
    # <<<
    *) DETAIL="refused: unknown type $TYPE" ;;
  esac
}

for ((n=0; n<MAX; n++)); do
  CLAIM=$(_jobs_req POST /api/box-commands/claim "$(jq -nc --arg c "$BOX" --argjson b "$BOXES" '{claimer:$c, boxes:$b}')"); RC=$?
  if [ "$RC" = 2 ]; then
    log "claim route not deployed (HTTP 404); nothing claimed"; exit 0
  elif [ "$RC" != 0 ]; then
    log "claim failed (HTTP ${JOBS_HTTP:-none}); nothing claimed"; exit 0
  fi
  ID=$(jq -r '.command.id // empty' <<<"$CLAIM" 2>/dev/null)
  [ -n "$ID" ] || break
  if ! [[ "$ID" =~ ^[0-9]+$ ]]; then
    log "claim answered a non-numeric command id '$ID'; nothing run"; break
  fi
  TYPE=$(jq -r '.command.type // empty' <<<"$CLAIM")
  TARGET=$(jq -r '.command.target // empty' <<<"$CLAIM")
  CBOX=$(jq -r '.command.box // empty' <<<"$CLAIM")
  PROJECT=$(jq -r '.command.args.project? // empty' <<<"$CLAIM" 2>/dev/null)
  APP=$(jq -r '.command.args.app? // empty' <<<"$CLAIM" 2>/dev/null)

  if ! { [ "$CBOX" = "$BOX" ] || { [ "$CBOX" = hub ] && [ "$HUB" = true ]; }; }; then
    OK=false DETAIL="refused: claimed a row for box '$CBOX' this box does not serve"
  else
    run_op
  fi
  DETAIL=$(printf '%s' "$DETAIL" | tr '\n\r\t' '   ')
  DETAIL="${DETAIL:0:500}"
  log "cmd $ID type=$TYPE box=$CBOX target=$TARGET verdict=$([ "$OK" = true ] && echo ok || echo fail): $DETAIL"
  # JOBS_ALERT=0: the line below IS this failure's alert.
  if ! JOBS_ALERT=0 _jobs_req POST "/api/box-commands/$ID/result" \
      "$(jq -nc --arg c "$BOX" --argjson ok "$OK" --arg d "$DETAIL" '{claimer:$c, ok:$ok, detail:$d}')" >/dev/null; then
    alert "box-ops: result for command $ID ($TYPE) not recorded (HTTP ${JOBS_HTTP:-none}); the row stays claimed and is re-offered after box_commands_claim_ttl_s"
    exit 1
  fi
done
exit 0
