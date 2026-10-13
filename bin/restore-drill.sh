#!/bin/bash
# bin/restore-drill.sh — hub cron (Sundays 06:00Z): the weekly restore drill.
#
# WHY THIS EXISTS (#400). A backup nobody has restored is a hope. This lane
# will, once a week, borrow a fresh Orgo computer, restore the newest off-box
# state backup onto it, check that what came back is usable, and delete the
# computer again, so "can we actually come back from a hub wipe" is a measured
# answer instead of an assumption (#388, #396).
#
# THE LIFECYCLE (BH-1731), in run order. A failed reap and every stop after the
# spend guard go through ONE finalizer (EXIT/INT/TERM): it beats once, deletes the box
# this run created, then writes the marker:
#   lock        flock -n locks/restore-drill.lock; held = another run, exit 0.
#   reap        a leaked id in state/restore-drill-inflight is DELETEd first;
#               if that fails: one ALERTS line, FAIL, and no new box is bought.
#   spend guard marker ts newer than RESTORE_DRILL_MIN_INTERVAL_H hours -> exit
#               0, no beat, no marker, unless --force.
#   configured  ORGO_API_KEY, RESTORE_DRILL_TEMPLATE_REF, BACKUP_S3_ENDPOINT,
#               BACKUP_S3_ACCESS_KEY_ID, BACKUP_S3_SECRET_ACCESS_KEY and
#               state/box-id; any missing -> SKIP naming them, no Orgo call.
#   create      POST /computers {name, template_ref, ram, cpu} (never a
#               snapshot). 403 with RAM_ADDON in the body -> SKIP; any other
#               non-2xx -> FAIL. On 2xx the id is persisted to inflight first.
#   wait        GET /computers/<id> until .status is running, bounded by
#               RESTORE_DRILL_DEADLINE_S.
#   steps       drill_on_box <id> <hub box-id>; OK only on rc 0 AND
#               DRILL_VERDICT=OK.
# Exit: 0 OK/SKIP/guard, 1 FAIL, 2 bad argument, 143/130 on TERM/INT.
# The libraries:
#   bin/lib/restore-drill-orgo.sh    orgo / remote — the Orgo API seam
#   bin/lib/restore-drill-steps.sh   drill_on_box  — what runs on the borrowed box
#                                    (a stub that FAILs until #1732)
#
# STATE FILES (pinned here so the sibling slices cannot disagree):
#   state/restore-drill-inflight    one line: the Orgo computer id this lane
#                                   created and has not yet deleted. Written
#                                   BEFORE anything else happens on the box and
#                                   removed only after the delete succeeds; a
#                                   run that finds it set deletes that computer
#                                   before it creates another.
#   state/restore-drill-last.json   {ts, verdict: "OK"|"FAIL"|"SKIP", detail,
#                                    rpo_s (number|null), deleted (bool),
#                                    last_ok_ts (epoch|null), first_run_ts (epoch)}
# This lane is the ONLY writer of both. bin/pipeline-health.sh reads
# restore-drill-last.json and never writes it.
#
# Knobs (catalog/lanes.d/restore-drill.json): RESTORE_DRILL_MIN_INTERVAL_H (24),
# RESTORE_DRILL_DEADLINE_S (2700), RESTORE_DRILL_POLL_S (15),
# RESTORE_DRILL_RAM_GB (8), RESTORE_DRILL_CPU (2), RESTORE_DRILL_HEALTH_PROJECT
# (cromford), RESTORE_DRILL_TEMPLATE_REF and RESTORE_DRILL_IDENTITY_FILE
# (no default); RESTORE_DRILL_CALL_TIMEOUT_S and ORGO_API_BASE are read by the
# Orgo seam. Secrets (ORGO_API_KEY, BACKUP_S3_*) are env only, never knobs.
# Docs: docs/RESTORE.md section 6.
# Run by hand: bin/restore-drill.sh [--force]   (--force skips the spend guard)
set -uo pipefail
H="${HARNESS:-/root/harness}"
# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s/env\n' "${1:-$H}"; }
HENV=$(harness_env_dir "$H")
set -a
# shellcheck disable=SC1091
. "$HENV/global.env" 2>/dev/null
set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-restore-drill
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off restore-drill.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit restore-drill
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    restore-drill

# shellcheck source=bin/lib/restore-drill-orgo.sh
. "$H/bin/lib/restore-drill-orgo.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/restore-drill-orgo.sh" || exit 1
# shellcheck source=bin/lib/restore-drill-steps.sh
. "$H/bin/lib/restore-drill-steps.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/restore-drill-steps.sh" || exit 1

FORCE=0
case "$#:${1:-}" in
  0:) ;;
  1:--force) FORCE=1 ;;
  *) echo "usage: bin/restore-drill.sh [--force]" >&2; exit 2 ;;
esac

LOG="$H/logs/restore-drill.log"
ALERTS="$H/logs/ALERTS.log"
MARK="$H/state/restore-drill-last.json"
INF="$H/state/restore-drill-inflight"
IDRE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
mkdir -p "$H/locks" "$H/state" "$H/logs"
say()   { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
alert() { printf '%s restore-drill: %s\n' "$(date -u +%FT%TZ)" "$*" >> "$ALERTS"; }

# Dedupe, never a queue: taken BEFORE the reap, so a second run can never
# delete the box a live run is using.
exec 9>"$H/locks/restore-drill.lock"
flock -n 9 || exit 0

TS=$(date +%s)
V="" DETAIL="" RPO="" CREATED="" DELETED=false FINALIZED=0 SIGNALLED=""
PREV_TS=$(jq -r '.ts // empty' "$MARK" 2>/dev/null)
PREV_OK=$(jq -r '.last_ok_ts // empty' "$MARK" 2>/dev/null)
PREV_FIRST=$(jq -r '.first_run_ts // empty' "$MARK" 2>/dev/null)
[[ "$PREV_TS" =~ ^[0-9]+$ ]] || PREV_TS=""
[[ "$PREV_OK" =~ ^[0-9]+$ ]] || PREV_OK=null
[[ "$PREV_FIRST" =~ ^[0-9]+$ ]] || PREV_FIRST=$TS

# finalize — beat once, delete the box this run created, write the marker last.
finalize() {
  local rc=$? line rpo_json=null last_ok=$PREV_OK
  [ "$FINALIZED" = 1 ] && return
  FINALIZED=1
  trap '' TERM INT
  if [ -z "$V" ]; then
    V=FAIL
    if [ -n "$SIGNALLED" ]; then DETAIL="interrupted by $SIGNALLED"; else DETAIL="stopped before a verdict (rc=$rc)"; fi
  fi
  DETAIL=${DETAIL//$'\n'/ }
  [[ "$RPO" =~ ^[0-9]+$ ]] && rpo_json=$RPO || RPO=""
  line="restore-drill: $V${DETAIL:+ $DETAIL} RPO=${RPO:-unknown}"
  # Before the delete, so the verdict reaches the console even if the delete
  # hangs. Its own failure is not the drill's.
  "$H/bin/beat.sh" "$(jq -nc --arg rk "restore-drill:$TS" --arg v "$V" --arg l "$line" \
    --arg ts "$(date -u +%FT%TZ)" \
    '{kind:"fleet_event",project:"fleet",event:"restore_drill",rkey:$rk,verdict:$v,line:$l,ts:$ts}')" \
    >/dev/null 2>&1 9>&- || true
  if [ -n "$CREATED" ]; then
    if orgo DELETE "/computers/$CREATED" || [ "$ORGO_HTTP" = 404 ]; then
      DELETED=true
      rm -f "$INF"
      say "deleted $CREATED (HTTP $ORGO_HTTP)"
    else
      alert "could not delete Orgo computer $CREATED (HTTP $ORGO_HTTP); state/restore-drill-inflight kept, next run retries — or delete it by hand (docs/RESTORE.md §6)"
    fi
  fi
  [ "$V" = OK ] && last_ok=$TS
  jq -nc --argjson ts "$TS" --arg v "$V" --arg d "$DETAIL" --argjson r "$rpo_json" --argjson del "$DELETED" \
    --argjson lo "$last_ok" --argjson fr "$PREV_FIRST" \
    '{ts:$ts,verdict:$v,detail:$d,rpo_s:$r,deleted:$del,last_ok_ts:$lo,first_run_ts:$fr}' > "$MARK.tmp.$$" \
    && mv "$MARK.tmp.$$" "$MARK"
  say "$line deleted=$DELETED"
}
arm() {
  trap finalize EXIT
  trap 'SIGNALLED=TERM; exit 143' TERM
  trap 'SIGNALLED=INT; exit 130' INT
}
# done_with <OK|SKIP|FAIL> <detail> — record the verdict and stop; the EXIT
# trap does the rest.
done_with() {
  V=$1 DETAIL=$2
  [ "$V" = FAIL ] && exit 1
  exit 0
}

# Reap. Only an id that is wholly what this lane writes ever reaches a URL.
if [ -s "$INF" ]; then
  OLD=$(head -n1 "$INF" | tr -d '[:space:]')
  if ! [[ "$OLD" =~ $IDRE ]]; then
    say "inflight held no usable id; cleared"
    rm -f "$INF"
  elif [ -n "${ORGO_API_KEY:-}" ]; then
    if orgo DELETE "/computers/$OLD" || [ "$ORGO_HTTP" = 404 ]; then
      rm -f "$INF"
      say "reaped $OLD (HTTP $ORGO_HTTP)"
    else
      alert "could not delete leaked Orgo computer $OLD (HTTP $ORGO_HTTP); state/restore-drill-inflight kept"
      arm
      done_with FAIL "inflight $OLD not deleted"
    fi
  fi
fi

# Spend guard. An absent or unreadable marker is not a recent run.
MIN_H=${RESTORE_DRILL_MIN_INTERVAL_H:-24}
if ! [[ "$MIN_H" =~ ^[0-9]+$ ]]; then
  say "RESTORE_DRILL_MIN_INTERVAL_H=$MIN_H is not an integer; using 24"
  MIN_H=24
fi
if [ "$FORCE" = 0 ] && [ -n "$PREV_TS" ] && [ "$MIN_H" -gt 0 ]; then
  AGE=$((TS - PREV_TS))
  if [ "$AGE" -ge 0 ] && [ "$AGE" -lt $((MIN_H * 3600)) ]; then
    say "skip: last run ${AGE}s ago"
    exit 0
  fi
fi

arm

# Configured? Read by name so no secret is mistaken for a knob.
MISS=""
for n in ORGO_API_KEY RESTORE_DRILL_TEMPLATE_REF BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
  [ -n "${!n:-}" ] || MISS="$MISS $n"
done
HUB_BOX=$(tr -dc 'A-Za-z0-9._-' 2>/dev/null < "$H/state/box-id")
[ -n "$HUB_BOX" ] || MISS="$MISS state/box-id"
[ -z "$MISS" ] || done_with SKIP "not configured - missing:$MISS"

RAM=${RESTORE_DRILL_RAM_GB:-8}
CPU=${RESTORE_DRILL_CPU:-2}
POLL=${RESTORE_DRILL_POLL_S:-15}
DEADLINE=${RESTORE_DRILL_DEADLINE_S:-2700}
[[ "$RAM" =~ ^[1-9][0-9]*$ ]]      || done_with FAIL "bad RESTORE_DRILL_RAM_GB"
[[ "$CPU" =~ ^[1-9][0-9]*$ ]]      || done_with FAIL "bad RESTORE_DRILL_CPU"
[[ "$POLL" =~ ^[1-9][0-9]*$ ]]     || done_with FAIL "bad RESTORE_DRILL_POLL_S"
[[ "$DEADLINE" =~ ^[1-9][0-9]*$ ]] || done_with FAIL "bad RESTORE_DRILL_DEADLINE_S"

# Create. A 2xx is billed, so from here the finalizer deletes it.
BODY=$(jq -nc --arg n "restore-drill-$TS" --arg t "$RESTORE_DRILL_TEMPLATE_REF" --argjson r "$RAM" --argjson c "$CPU" \
  '{name:$n,template_ref:$t,ram:$r,cpu:$c}')
if orgo POST /computers "$BODY"; then
  ID=$(printf '%s' "$ORGO_BODY" | jq -r '.id // empty' 2>/dev/null)
  if ! [[ "$ID" =~ $IDRE ]]; then
    alert "create answered HTTP $ORGO_HTTP with no usable computer id; a restore-drill-$TS computer may exist on the Orgo account and needs deleting by hand"
    done_with FAIL "create returned no id"
  fi
  CREATED=$ID
  printf '%s\n' "$ID" > "$INF.tmp.$$" && mv "$INF.tmp.$$" "$INF"
elif [ "$ORGO_HTTP" = 403 ] && [[ "$ORGO_BODY" == *RAM_ADDON* ]]; then
  done_with SKIP "account RAM pool cannot fit a ${RAM}GB box (RAM_ADDON)"
else
  done_with FAIL "create HTTP $ORGO_HTTP"
fi
say "created $CREATED"

# Wait for running, bounded by wall time.
START=$(date +%s)
while :; do
  ST=""
  orgo GET "/computers/$CREATED" \
    && ST=$(printf '%s' "$ORGO_BODY" | jq -r '.status // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')
  [ "$ST" = running ] && break
  EL=$(( $(date +%s) - START ))
  [ $((EL + POLL)) -le "$DEADLINE" ] \
    || done_with FAIL "not running after ${EL}s (last status ${ST:-none}, HTTP $ORGO_HTTP)"
  sleep "$POLL"
done

# Steps. OK needs both the return code and the verdict.
DRILL_VERDICT=FAIL DRILL_DETAIL="" DRILL_RPO_S=""
export RESTORE_DRILL_IDENTITY_FILE="${RESTORE_DRILL_IDENTITY_FILE:-}" \
       RESTORE_DRILL_HEALTH_PROJECT="${RESTORE_DRILL_HEALTH_PROJECT:-cromford}"
drill_on_box "$CREATED" "$HUB_BOX"; SRC=$?
RPO=$DRILL_RPO_S
if [ "$SRC" = 0 ] && [ "$DRILL_VERDICT" = OK ]; then
  done_with OK "$DRILL_DETAIL"
fi
done_with FAIL "${DRILL_DETAIL:-steps rc=$SRC}"
