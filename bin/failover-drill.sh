#!/bin/bash
# bin/failover-drill.sh — hand-run on the hub: the failover drill (BH-2749, parent #402).
#
# WHY THIS EXISTS (#402). The #401 watchdog promotes the standby when the hub
# goes quiet. A promoter nobody has watched promote is a hope. This drill makes
# the hub look dead (renew paused, watchdog ping off), waits for the watchdog to
# move the lease to the declared standby, proves the standby did the hub's work,
# hands the lease back and checks the standby went quiet again.
#
# RUN ORDER:
#   1 lock        flock -n locks/failover-drill.lock; held -> "already running", exit 0.
#   2 preflight   refuse (exit 3, one stderr line, one ALERTS line, nothing
#                 written) when flags/failover-drill-ok is absent (it is never
#                 consumed), this box is not the hub, a knob is bad, then (after
#                 the spend guard) when hub-lease.sh check is not rc 0, there is
#                 not exactly one standby for this hub, it has no tailnet IP,
#                 ssh to it fails, hub.promote_enabled is not 1, or the start
#                 epoch cannot be read from /api/hub/recovery.
#   3 spend guard state/failover-drill-last.json .ts newer than
#                 FAILOVER_DRILL_MIN_INTERVAL_H -> exit 0 with no call and no
#                 write, unless --force.
#   4 pause       write $FD_RENEW_PAUSE_FLAG (content: now + DEADLINE + 120)
#                 and flags/lane-off-watchdog-ping, re-asserted every poll; wait
#                 for lease.holder == standby at an epoch past the start epoch.
#                 A failed read, an empty body or a non-integer epoch is never a
#                 promote. A promote to any other box is a FAIL with no promote-back.
#                 bin/hub-lease.sh does not honor the pause flag yet (a BH-402
#                 sibling adds that); until it does the pause flag has no effect.
#   5 unpause     remove both pause flags; hub-lease.sh check here must go rc 1
#                 within FAILOVER_DRILL_DEMOTE_SETTLE_S, else FAIL and stop.
#   6 proofs      write flags/lane-off-poll-commands; fd_proof_poll_commands,
#                 fd_proof_chat, fd_proof_pool; fd_promote_back; then (only with a
#                 promote-back) fd_proof_ledger over [t_promote, FD_T_BACK] and
#                 fd_standby_quiet.
#   7 finalizer   (EXIT/INT/TERM, once) remove every flag this run wrote. With
#                 no promote-back, if the standby holds the lease: one ALERTS
#                 line with the fail-back command; it never promotes back itself.
#   8 report      then the report, then the marker, then one beat, then one log line.
# Verdict: PASS only with four OK proofs, the old-hub check passed, a
# promote-back and fd_standby_quiet OK. FAIL if anything failed. Otherwise
# INCOMPLETE.
#
# STATE FILES (this script is the only writer):
#   state/failover-drill-last.json  {ts, verdict: PASS|INCOMPLETE|FAIL, detail, report}
#   <report-dir>/FAILOVER-DRILL-<YYYY-MM-DD>.md  (default state/failover-drill;
#                 an existing name gets -<HHMMSSZ>, then -<pid>; never overwritten)
#   logs/failover-drill.log         one line per run past the preflight
# Flags written and always removed: $FD_RENEW_PAUSE_FLAG,
# flags/lane-off-watchdog-ping, flags/lane-off-poll-commands. Read only:
# flags/failover-drill-ok (the operator's go-ahead).
#
# Knobs (env/global.env or the environment; a non-integer refuses):
#   FAILOVER_DRILL_PROMOTE_DEADLINE_S (1500, must be < 1740)
#   FAILOVER_DRILL_POLL_S (30)  FAILOVER_DRILL_DEMOTE_SETTLE_S (180)
#   FAILOVER_DRILL_MIN_INTERVAL_H (24)
# Usage: bin/failover-drill.sh [--force] [--report-dir <dir>]
# exit codes: 0 PASS (or already running / spend guard), 1 FAIL or INCOMPLETE,
#   2 bad argument, 3 REFUSED.
set -uo pipefail
H="${HARNESS:-/root/harness}"
USAGE="usage: bin/failover-drill.sh [--force] [--report-dir <dir>]"
FORCE=0 REPORT_DIR="$H/state/failover-drill"
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --report-dir) [ -n "${2:-}" ] || { echo "$USAGE" >&2; exit 2; }; REPORT_DIR=$2; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "$USAGE" >&2; exit 2 ;;
  esac
  shift
done

# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s/env\n' "${1:-$H}"; }
set -a
# shellcheck disable=SC1091
. "$(harness_env_dir "$H")/global.env" 2>/dev/null
set +a
for lib in jobs-client.sh lib/hub-box.sh lib/failover-drill-common.sh lib/failover-drill-proofs.sh lib/failover-drill-demote.sh; do
  # shellcheck disable=SC1090
  . "$H/bin/$lib" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/$lib" 2>/dev/null \
    || { echo "failover drill: cannot load bin/$lib" >&2; exit 1; }
done

mkdir -p "$H/locks" "$H/state" "$H/logs" "$H/flags"
exec 9>"$H/locks/failover-drill.lock"
flock -n 9 || { echo "already running"; exit 0; }

MARK="$H/state/failover-drill-last.json"
refuse() { echo "failover drill refused: $*" >&2; fd_alert "refused: $*"; exit 3; }
int() { [[ "${1:-}" =~ ^(0|[1-9][0-9]{0,11})$ ]]; }

# Local checks first, then the spend guard, then the network: a guarded run makes no call.
[ -e "$H/flags/failover-drill-ok" ] || refuse "flags/failover-drill-ok is absent"
HUB=$(hub_box_name) BOX=$(local_box_name)
[ "$BOX" = "$HUB" ] || refuse "this box (${BOX:-unnamed}) is not the hub ($HUB)"
DEADLINE=${FAILOVER_DRILL_PROMOTE_DEADLINE_S:-1500} POLL=${FAILOVER_DRILL_POLL_S:-30}
SETTLE=${FAILOVER_DRILL_DEMOTE_SETTLE_S:-180} MIN_H=${FAILOVER_DRILL_MIN_INTERVAL_H:-24}
{ int "$DEADLINE" && [ "$DEADLINE" -gt 0 ] && [ "$DEADLINE" -lt 1740 ]; } \
  || refuse "FAILOVER_DRILL_PROMOTE_DEADLINE_S=$DEADLINE must be an integer from 1 to 1739 (under the 1740s bound)"
{ int "$POLL" && [ "$POLL" -gt 0 ]; } || refuse "FAILOVER_DRILL_POLL_S=$POLL is not a positive integer"
int "$SETTLE" || refuse "FAILOVER_DRILL_DEMOTE_SETTLE_S=$SETTLE is not an integer"
int "$MIN_H" || refuse "FAILOVER_DRILL_MIN_INTERVAL_H=$MIN_H is not an integer"

T_START=$(fd_now); int "$T_START" || refuse "the clock did not answer"
PREV_TS=$(jq -r '.ts // empty' "$MARK" 2>/dev/null)
if [ "$FORCE" = 0 ] && int "$PREV_TS" && [ $((T_START - PREV_TS)) -lt $((MIN_H * 3600)) ]; then
  echo "last drill $(fd_iso "$PREV_TS") is newer than ${MIN_H}h; --force to run anyway"
  exit 0
fi

"$H/bin/hub-lease.sh" check >/dev/null 2>&1 || refuse "bin/hub-lease.sh check says this box does not hold the lease"
SB_LINES=$("$H/bin/fleet-conf.sh" --standby 2>/dev/null | awk -v h="$HUB" '$2 == h')
SB_N=$(printf '%s' "$SB_LINES" | grep -c .)
[ "$SB_N" = 1 ] || refuse "need exactly one standby for $HUB, found $SB_N"
STANDBY=$(printf '%s\n' "$SB_LINES" | awk '{print $1}')
IP=$("$H/bin/fleet-conf.sh" --tailnet-ip-of-box "$STANDBY" 2>/dev/null) && [ -n "$IP" ] \
  || refuse "standby $STANDBY has no tailnet IP in fleet.conf"
fd_ssh "$IP" true >/dev/null 2>&1 </dev/null || refuse "ssh root@$IP (standby $STANDBY) failed"
PE=$(fd_api_get /api/settings/hub.promote_enabled | jq -r '.setting.value // empty' 2>/dev/null)
[ "$PE" = 1 ] || refuse "hub.promote_enabled reads '${PE:-unreadable}', not 1"
REC=$(fd_api_get /api/hub/recovery) || refuse "cannot read the start epoch (GET /api/hub/recovery failed)"
START_EPOCH=$(printf '%s' "$REC" | jq -r '.lease.epoch // empty' 2>/dev/null)
START_HOLDER=$(printf '%s' "$REC" | jq -r '.lease.holder // empty' 2>/dev/null)
int "$START_EPOCH" || refuse "cannot read the start epoch (lease.epoch is '${START_EPOCH}')"

ISO_START=$(fd_iso "$T_START")
RUN="fd-$(printf '%s' "$ISO_START" | tr -d ':-')"
V="" DETAIL="" STAGE_FAIL="" SIGNALLED="" DONE=0 FINALIZED=0 WROTE=""
PROMOTED=0 EPOCH="" ROW="" OLDHUB="not reached" BACK="not reached" BACK_OK=0 FD_T_BACK=""
FD_DEMOTE_VERDICT="" FD_DEMOTE_DETAIL="" FD_DEMOTE_UNOBSERVABLE=""
T_PAUSE="" T_PROMOTE="" T_UNPAUSE="" T_P1="" T_P2="" T_P3="" T_P4="" T_OBS=""

put_flag() { # put_flag <rel> [content] — tracked only when this run created it
  [ -e "$H/$1" ] || case " $WROTE " in *" $1 "*) ;; *) WROTE="$WROTE $1" ;; esac
  printf '%s' "${2:-}" > "$H/$1"
}
drop_flag() { case " $WROTE " in *" $1 "*) rm -f "$H/$1" ;; esac; }
fail_with() { STAGE_FAIL=$1; exit 1; }
recovery() { # recovery -> HOLDER, EP (EP empty when unreadable or non-integer)
  local b; HOLDER="" EP=""
  b=$(fd_api_get /api/hub/recovery) || return 1
  HOLDER=$(printf '%s' "$b" | jq -r '.lease.holder // empty' 2>/dev/null)
  EP=$(printf '%s' "$b" | jq -r '.lease.epoch // empty' 2>/dev/null)
  int "$EP" || { EP=""; return 1; }
  REC=$b
}

write_report() { # -> REPORT (empty when no name could be created)
  local d=${ISO_START%%T*} hms n body f
  hms=$(printf '%s' "${ISO_START#*T}" | tr -d ':Z')
  body=$(
    printf '# Failover drill %s\n\n' "$RUN"
    printf -- '- hub: %s\n- standby: %s (%s)\n- start: %s at epoch %s\n' "$HUB" "$STANDBY" "$IP" "${START_HOLDER:-?}" "$START_EPOCH"
    printf -- '- promote epoch: %s; hub_lease_changes: %s\n\n' "${EPOCH:--}" "${ROW:--}"
    printf '| stage | UTC |\n|---|---|\n'
    for n in t_start:T_START t_pause:T_PAUSE t_promote:T_PROMOTE t_unpause:T_UNPAUSE P1:T_P1 P2:T_P2 P3:T_P3 P4:T_P4 t_back:FD_T_BACK t_observe_end:T_OBS; do
      f=${n#*:}; printf '| %s | %s |\n' "${n%%:*}" "$(fd_iso "${!f}" 2>/dev/null || echo -)"
    done
    printf '\n'
    fd_proof_line 1 poll-commands; fd_proof_line 2 chat; fd_proof_line 3 pool; fd_proof_line 4 ledger
    printf '\n## Demotion\n- old hub lease check: %s\n- promote-back: %s\n' "$OLDHUB" "$BACK"
    printf -- '- standby quiet: %s — %s\n- unobservable: %s\n' "${FD_DEMOTE_VERDICT:-not run}" "${FD_DEMOTE_DETAIL:--}" "${FD_DEMOTE_UNOBSERVABLE:-none}"
    printf '\n%s\n\nVerdict: %s\n' "$DETAIL" "$V")
  REPORT=""
  mkdir -p "$REPORT_DIR" 2>/dev/null || return 0
  for f in "FAILOVER-DRILL-$d.md" "FAILOVER-DRILL-$d-${hms}Z.md" "FAILOVER-DRILL-$d-${hms}Z-$$.md"; do
    if (set -C; printf '%s\n' "$body" > "$REPORT_DIR/$f") 2>/dev/null; then REPORT="$REPORT_DIR/$f"; return 0; fi
  done
}

finish() {
  local rc=$? f n v bad="" line
  [ "$FINALIZED" = 1 ] && return
  FINALIZED=1
  trap '' TERM INT
  for f in $WROTE; do rm -f "$H/$f"; done
  if [ "$BACK_OK" = 0 ]; then
    if recovery && [ "$HOLDER" = "$STANDBY" ]; then EPOCH=${EPOCH:-$EP}
    elif [ -z "$EP" ] && [ "$PROMOTED" = 1 ]; then HOLDER=$STANDBY
    else HOLDER=""; fi
    [ "$HOLDER" = "$STANDBY" ] && fd_alert "failover drill $RUN stopped with $STANDBY holding the lease at epoch ${EP:-$EPOCH}; to fail back run: bin/hub-lease.sh promote --holder $HUB --override-live-lease"
  fi
  for n in 1 2 3 4; do v="PROOF_${n}_VERDICT"; [ "${!v:-}" = FAIL ] && bad="${bad:+$bad, }proof $n failed"; done
  if [ -n "$STAGE_FAIL" ]; then V=FAIL DETAIL=$STAGE_FAIL
  elif [ -n "$SIGNALLED" ]; then V=FAIL DETAIL="interrupted by $SIGNALLED"
  elif [ "$DONE" != 1 ]; then V=FAIL DETAIL="stopped before a verdict (rc=$rc)"
  elif [ -n "$bad" ]; then V=FAIL DETAIL=$bad
  elif [ "$BACK_OK" != 1 ]; then V=FAIL DETAIL="promote-back failed: ${FD_DEMOTE_DETAIL:-no detail}"
  elif [ "$FD_DEMOTE_VERDICT" = FAIL ]; then V=FAIL DETAIL="standby not quiet: $FD_DEMOTE_DETAIL"
  elif [ "${PROOF_1_VERDICT:-}${PROOF_2_VERDICT:-}${PROOF_3_VERDICT:-}${PROOF_4_VERDICT:-}" = OKOKOKOK ] \
       && [ "$FD_DEMOTE_VERDICT" = OK ]; then V=PASS DETAIL="promoted to $STANDBY at epoch $EPOCH and back"
  else V=INCOMPLETE DETAIL="a proof or the standby-quiet check is UNPROVEN"; fi
  DETAIL=${DETAIL//$'\n'/ }
  write_report
  [ -n "$REPORT" ] || DETAIL="$DETAIL; report not written to $REPORT_DIR"
  jq -nc --argjson ts "$T_START" --arg v "$V" --arg d "$DETAIL" --arg r "$REPORT" \
    '{ts:$ts,verdict:$v,detail:$d,report:$r}' > "$MARK.tmp.$$" && mv "$MARK.tmp.$$" "$MARK"
  line="failover-drill: $V $DETAIL"
  "$H/bin/beat.sh" "$(jq -nc --arg rk "failover-drill:$RUN" --arg v "$V" --arg l "$line" --arg ts "$(fd_iso "$(fd_now)")" \
    '{kind:"fleet_event",project:"fleet",event:"failover_drill",rkey:$rk,verdict:$v,line:$l,ts:$ts}')" >/dev/null 2>&1 9>&- || true
  printf '%s %s %s %s report=%s\n' "$(fd_iso "$(fd_now)")" "$RUN" "$V" "$DETAIL" "${REPORT:-none}" >> "$H/logs/failover-drill.log"
  echo "$line${REPORT:+ ($REPORT)}"
  [ "$V" = PASS ] && exit 0
  exit 1
}
trap finish EXIT
trap 'SIGNALLED=TERM; exit 1' TERM
trap 'SIGNALLED=INT; exit 1' INT

# 4. Pause and wait for the watchdog promote.
PAUSE_UNTIL=$(( $(fd_now) + DEADLINE + 120 ))
put_flag "$FD_RENEW_PAUSE_FLAG" "$PAUSE_UNTIL"
put_flag flags/lane-off-watchdog-ping
T_PAUSE=$(fd_now)
polls=0
while :; do
  if [ $(( $(fd_now) - T_PAUSE )) -ge "$DEADLINE" ] || [ "$polls" -ge $((DEADLINE / POLL + 1)) ]; then
    fail_with "watchdog never promoted within ${DEADLINE}s (is KV cfg:failover=on and cfg:failover_hub_fence_s set?)"
  fi
  sleep "$POLL"; polls=$((polls + 1))
  put_flag "$FD_RENEW_PAUSE_FLAG" "$PAUSE_UNTIL"
  put_flag flags/lane-off-watchdog-ping
  recovery || continue
  [ "$EP" -gt "$START_EPOCH" ] || continue
  if [ "$HOLDER" = "$STANDBY" ]; then break; fi
  if [ -n "$HOLDER" ] && [ "$HOLDER" != "$HUB" ]; then
    fd_alert "failover drill $RUN: the lease went to $HOLDER at epoch $EP, not the declared standby $STANDBY; no promote-back was attempted"
    fail_with "promoted to $HOLDER, not the declared standby $STANDBY"
  fi
done
T_PROMOTE=$(fd_now) EPOCH=$EP PROMOTED=1
ROW=$(printf '%s' "$REC" | jq -r --arg e "$EPOCH" \
  '[.recent_changes[]? | select(.action == "promote" and ((.after_epoch|tostring) == $e))][0] // empty | "actor \(.actor) at \(.at)"' 2>/dev/null)
ROW=${ROW:-no matching hub_lease_changes row}

# 5. Unpause; the old hub must see it no longer holds the lease.
drop_flag "$FD_RENEW_PAUSE_FLAG"; drop_flag flags/lane-off-watchdog-ping
T_UNPAUSE=$(fd_now)
polls=0
until "$H/bin/hub-lease.sh" check >/dev/null 2>&1; [ $? = 1 ]; do
  if [ $(( $(fd_now) - T_UNPAUSE )) -ge "$SETTLE" ] || [ "$polls" -gt $((SETTLE / POLL + 1)) ]; then
    OLDHUB="FAIL: still held after ${SETTLE}s"
    fail_with "old hub still believes it holds the lease"
  fi
  sleep "$POLL"; polls=$((polls + 1))
done
OLDHUB="OK: released"

# 6. Proofs, promote-back, ledger, quiet.
put_flag flags/lane-off-poll-commands
fd_proof_poll_commands "$RUN" "$IP"; T_P1=$(fd_now)
fd_proof_chat "$RUN" "$IP"; T_P2=$(fd_now)
fd_proof_pool "$RUN"; T_P3=$(fd_now)
FD_T_BACK=""
if fd_promote_back "$RUN" "$HUB" && int "$FD_T_BACK"; then
  BACK_OK=1 BACK="OK at $(fd_iso "$FD_T_BACK")"
  fd_proof_ledger "$RUN" "$HUB" "$STANDBY" "$T_PROMOTE" "$FD_T_BACK" "$SETTLE"; T_P4=$(fd_now)
  fd_standby_quiet "$STANDBY" "$IP" "$FD_T_BACK"; T_OBS=$(fd_now)
else
  FD_DEMOTE_DETAIL=${FD_DEMOTE_DETAIL:-"returned no FD_T_BACK"} FD_T_BACK=""
  BACK="promote-back failed: $FD_DEMOTE_DETAIL"
  fd_proof_set 4 UNPROVEN "no promote-back"
fi
DONE=1
