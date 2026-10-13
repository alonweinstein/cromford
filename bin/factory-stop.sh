#!/bin/bash
# bin/factory-stop.sh on|off|status [--reason <text>] [--actor <who>] — the
# factory-stop switch (BH-3687, slice BH-3712). Writes the settings row
# `switch.factory-stop` (the switch bin/lib/factory-stop.sh reads) and says
# ON/OFF only once a fresh re-read of that row shows it.
#
#   on|off   PUT /api/settings {key:"switch.factory-stop",value:"1"|"0",actor,
#            reason,note}, then re-read the switch with LANE_GATE_CACHE_S=0 (the
#            same read, and the same state/settings-cache.json, the lane gate
#            uses). --reason is required: it is the audit row's reason.
#            Actor: --actor, else $FACTORY_STOP_ACTOR, else <user>@<host>; never
#            the registry seed actor.
#   status   one GET of the row: state, since, how long, by whom, why.
#
# Exit codes:
#   0  on/off: the re-read shows the requested state from a settings row;
#      status: the worker answered
#   1  the PUT failed, or it answered 2xx and the re-read does not show the
#      requested state (NOT confirmed); status: the worker did not answer
#   2  bad arguments (verb, flag, blank reason, actor); nothing sent
#   3  no jobs client or JOBS_URL on this box (NOT recorded), or the lib is missing
#
# A stop that was NOT recorded pages once through bin/alert-line.sh: the
# operator asked for the factory to stop and it is still running. Every on/off
# that reached the write step appends one line to logs/factory-stop.log:
# `<ts>\t<on|off>\t<actor>\t<confirmed|not-confirmed|not-recorded>\t<reason>`.
set -uo pipefail

HARNESS="${HARNESS:-/root/harness}"
KEY=switch.factory-stop
# shellcheck source=lib/factory-stop.sh
. "$HARNESS/bin/lib/factory-stop.sh" 2>/dev/null || { echo "factory-stop: bin/lib/factory-stop.sh missing"; exit 3; }

usage() {
  echo "usage: bin/factory-stop.sh on|off|status [--reason <text>] [--actor <who>]"
  exit 2
}

VERB=""; REASON=""; ACTOR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reason) [ $# -ge 2 ] || usage; REASON="$2"; shift 2 ;;
    --actor)  [ $# -ge 2 ] || usage; ACTOR="$2"; ACTOR_SET=1; shift 2 ;;
    -*) usage ;;
    *) [ -z "$VERB" ] || usage; VERB="$1"; shift ;;
  esac
done
case "$VERB" in on|off|status) ;; *) usage ;; esac

if [ "$VERB" = status ]; then
  line=$(factory_stop_status) || { echo "factory-stop status unknown: the jobs worker did not answer"; exit 1; }
  IFS=$'\t' read -r state since actor note <<<"$line"
  if [ "$state" = none ]; then
    echo "factory-stop is OFF (no $KEY row)"
    exit 0
  fi
  echo "factory-stop is $(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')"
  if [ -n "$since" ]; then
    now="${FACTORY_STOP_NOW:-$(date -u +%s)}"
    if epoch=$(date -u -d "$since" +%s 2>/dev/null) && [ "$now" -ge "$epoch" ] && dur=$(factory_stop_dur $((now - epoch))); then
      echo "  since $since ($dur)"
    else
      echo "  since $since"
    fi
  fi
  [ -n "$actor" ] && echo "  by $actor"
  [ -n "$note" ] && echo "  reason: $note"
  exit 0
fi

REASON=$(printf '%s' "$REASON" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
[ -n "$REASON" ] || { echo "factory-stop: --reason is required"; exit 2; }
[ -n "${ACTOR_SET:-}" ] || ACTOR="${FACTORY_STOP_ACTOR:-$(id -un 2>/dev/null)@$(hostname -s 2>/dev/null)}"
if ! [[ "$ACTOR" =~ ^[A-Za-z0-9._@-]{1,96}$ ]] || [ "$ACTOR" = registry-seed ]; then
  echo "factory-stop: actor '$ACTOR' is not writable (^[A-Za-z0-9._@-]{1,96}\$, never registry-seed)"
  exit 2
fi

STATE=$(printf '%s' "$VERB" | tr '[:lower:]' '[:upper:]')
VALUE=0; [ "$VERB" = on ] && VALUE=1

oplog() {
  mkdir -p "$HARNESS/logs" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$VERB" "$ACTOR" "$1" "$(printf '%s' "$REASON" | tr '\t\n' '  ')" \
    >> "$HARNESS/logs/factory-stop.log" 2>/dev/null
}
page() {
  [ "$VERB" = on ] || return 0
  "$HARNESS/bin/alert-line.sh" --id factory-stop-unrecorded "factory-stop ON requested by $ACTOR was NOT recorded ($1) — nothing is stopped; retry bin/factory-stop.sh on or PUT the row"
}

body=$(jq -nc --arg k "$KEY" --arg v "$VALUE" --arg a "$ACTOR" --arg r "$REASON" \
  '{key:$k, value:$v, actor:$a, reason:$r, note:$r}')
# A subshell: the client is sourced here and nowhere else, and one that exits
# when sourced (a half-synced bin/) ends only the subshell.
HTTP=$( [ -r "$HARNESS/bin/jobs-client.sh" ] || exit 3
        # shellcheck disable=SC1091
        . "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1 || exit 3
        command -v _jobs_req >/dev/null 2>&1 || exit 3
        [ -n "${JOBS_URL:-}" ] || exit 3
        _jobs_req PUT /api/settings "$body" >/dev/null 2>&1
        printf '%s' "${JOBS_HTTP:-}"
        case "${JOBS_HTTP:-}" in 2*) exit 0 ;; esac
        exit 4 ); PRC=$?
case "$PRC" in
  0) ;;
  4) echo "factory-stop $STATE NOT recorded (http=${HTTP:-unreachable})"
     oplog not-recorded; page "http=${HTTP:-unreachable}"; exit 1 ;;
  *) echo "factory-stop $STATE NOT recorded: jobs not configured"
     oplog not-recorded; page "jobs not configured"; exit 3 ;;
esac

# confirmed — the switch re-read with a fresh settings fetch (TTL 0), so a
# cache filled before the PUT cannot answer for it. rc 0 only when a settings
# row shows the requested state AND that read reached the worker: a refresh
# that failed leaves the old cache, and the old cache is not a re-read.
confirmed() {
  local t0 fa rc
  t0=$(date -u +%s)
  LANE_GATE_CACHE_S=0 ls_isolated lane_switch factory-stop file; rc=$?
  CONF_SRC=${LANE_SWITCH_SRC:-none}
  fa=$(jq -r '.fetched_at // 0' "$HARNESS/state/settings-cache.json" 2>/dev/null)
  case "$fa" in ''|*[!0-9]*) fa=0 ;; esac
  if [ "$fa" -lt "$t0" ]; then CONF_SRC="the settings re-read did not reach the jobs worker"; return 1; fi
  case "$CONF_SRC" in box-row|fleet-row) CONF_SRC=$(lane_switch_src factory-stop) ;; *) return 1 ;; esac
  if [ "$VERB" = on ]; then [ "$rc" -eq 0 ]; else [ "$rc" -eq 1 ]; fi
}

if confirmed; then
  oplog confirmed
  echo "factory-stop is $STATE (settings $KEY)"
  exit 0
fi
oplog not-confirmed
echo "factory-stop $STATE NOT confirmed: $CONF_SRC"
exit 1
