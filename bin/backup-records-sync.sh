#!/bin/bash
# bin/backup-records-sync.sh — hub cron (*/5): turn every box's own backup
# report into the record the fleet already reads.
#
# WHY THIS EXISTS (BH-1031, state→DB slice 6). "When did this box last get a
# VERIFIED off-box copy" is the quietest failure in the fleet — nothing errors,
# nothing is late, and the only symptom is the day you need it (#399, after the
# hub wipe #388). The hub used to COLLECT that fact by ssh: the probe in
# bin/lib/backup-freshness.sh rode the 15-minute hop bin/fleet-heartbeat.sh
# already made to every box. This slice deletes that lane, because it answered
# "can the HUB REACH the box", not "is the lane alive" — and deleting it would
# have taken the backup signal with it, blinding bin/fleet-status-push.sh,
# bin/pipeline-health.sh and the console's Fleet column in the same commit.
#
# So the fact reverses direction instead of dying. bin/state-backup.sh states
# this box's three facts on the tick that produced them (box_backup_set), and
# this lane reads every box's answer in ONE call and writes the record the hub's
# readers have always read. One collector — the machine that owns the fact — and
# nine ssh hops an hour become one HTTP GET.
#
# THE READERS DO NOT MOVE. bin/lib/backup-freshness.sh's bf_rows still reads
# state/fleet-heartbeat/backup-<box>, still three tab-separated fields, still
# dated by the file's mtime. That is deliberate: the record's SHAPE is a
# published contract with three consumers and a rendered console screen, and a
# slice about who COLLECTS a fact has no business also changing what the fact
# looks like.
#
# THE MTIME IS THE COLLECTION TIME, AND IT IS SET FROM THE ROW — never left at
# "when this lane last ran". bf_rows drops a record older than
# BF_RECORD_FRESH_MIN because a kept-but-frozen answer is how an outage becomes
# ~48 false `backupstale` pages (box-project-1-1, 2026-08). If this lane
# stamped every file with its own clock, a box that STOPPED reporting would have
# its stale facts re-dated every five minutes and could never age out — the
# exact bug that bound exists to prevent, reintroduced one layer down. So a row
# is written only while the BOX's own report is current, with the file's mtime
# set to the moment the box spoke.
#
# FAIL-OPEN AND SILENT. No client, no jq, no worker: nothing is written and
# every record keeps whatever it last said, which then ages out on its own
# exactly as an ssh outage used to make it. A reader that cannot run must never
# be the reason the hub does less.
#
# Knobs: none of its own. BF_RECORD_FRESH_MIN comes from the one library.
# Run by hand: bin/backup-records-sync.sh   (writes records, prints nothing)
set -uo pipefail
H="${HARNESS:-/root/harness}"
# BH-4080: HARNESS_HUB_BOX, the hub's fleet name when HUB_BOX_NAME is unset.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 1
# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s/env\n' "${1:-$H}"; }
HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-backup-records-sync
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off backup-records-sync.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit backup-records-sync
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    backup-records-sync
STATE="$H/state/fleet-heartbeat"
LOG="$H/logs/backup-records-sync.log"
NOW="${BACKUP_SYNC_NOW:-$(date +%s)}"

log() {
  mkdir -p "$H/logs" 2>/dev/null
  printf '%s [backup-records-sync] %s\n' "$(date -u '+%F %T')Z" "$*" >> "$LOG"
}

# The one library, for BF_RECORD_FRESH_MIN. Its absence is not a reason to
# invent a window here: two definitions of "still an answer" would disagree the
# first time one of them changed, and the disagreement would read as a healthy
# fleet.
for _BFL in "$H/bin/lib/backup-freshness.sh" "$(dirname "${BASH_SOURCE[0]}")/lib/backup-freshness.sh"; do
  # shellcheck source=bin/lib/backup-freshness.sh
  [ -r "$_BFL" ] && { . "$_BFL"; break; }
done
command -v bf_facts_local >/dev/null 2>&1 \
  || { log "no bin/lib/backup-freshness.sh beside this script — nothing written"; exit 0; }

CLI="${BACKUP_SYNC_CLIENT:-$H/bin/jobs-client.sh}"
[ -r "$CLI" ] || { log "no $CLI — nothing written"; exit 0; }

# Sourced in a SUBSHELL with global.env, the bin/heartbeat-reaper.sh idiom: this
# script writes files and must not carry every credential in global.env in its
# own environment for whatever it later runs.
ROWS=$(
  ( set -a; [ -r "$HENV/global.env" ] && . "$HENV/global.env" 2>/dev/null; set +a
    # shellcheck source=/dev/null
    . "$CLI" >/dev/null 2>&1 || exit 0
    command -v box_backups >/dev/null 2>&1 || exit 0
    box_backups 2>/dev/null ) 2>/dev/null
)
RC=$?
# A read that failed and a fleet that reported nothing are different facts, and
# only one of them is worth a log line. Neither writes anything.
if [ "$RC" -ne 0 ] || [ -z "${ROWS:-}" ]; then
  log "no rows from the ledger (rc=$RC) — every record keeps what it last said and ages out on its own"
  exit 0
fi

mkdir -p "$STATE" 2>/dev/null
# EVERY NAME THIS MACHINE ANSWERS TO, not just one. bf_rows reads the hub's own
# row straight off local disk and skips `${HUB_BOX_NAME:-box-hub}`; this
# lane does not source global.env into its own environment (it writes files and
# must not carry credentials for whatever it later runs), so HUB_BOX_NAME may be
# set for the readers and unset here. Matching on one name would then let the
# hub appear TWICE in the fleet's backup table — once off local disk, once
# through a record — which is the one shape a table of per-box states must never
# have. All three candidates are skipped, which is safe in every direction: the
# hub's own row never needed a record in the first place.
HUB_SELF="${HUB_BOX_NAME:-}"
HUB_FILE=$(tr -dc 'A-Za-z0-9._-' < "$H/state/box-name" 2>/dev/null)
HUB_ENV=$(sed -n 's/^HUB_BOX_NAME=//p' "$HENV/global.env" 2>/dev/null | tr -dc 'A-Za-z0-9._-' | head -1)
WINDOW=$(( ${BF_RECORD_FRESH_MIN:-35} * 60 ))
WROTE=0; SKIPPED=0

# CUT BY POSITION, NEVER `IFS=$'\t' read`. Tab is IFS WHITESPACE, so read
# collapses a run of tabs and drops the leading ones: a box with no stamp and no
# markers reports three empty fields, and `read` would hand this loop the
# REPORTED time in $TS and nothing in $REPORTED — every healthy quiet box
# silently skipped, and the loop would look perfectly correct doing it. This is
# the same trap bf_state_age documents on the reading side, and the reason both
# ends of this record are parsed the same way.
while IFS= read -r LINE; do
  [ -n "${LINE:-}" ] || continue
  # Four tabs or it is not a row this lane produced — a torn read, never five
  # fields' worth of guesses.
  case "$LINE" in
    *$'\t'*$'\t'*$'\t'*$'\t'*) ;;
    *) SKIPPED=$((SKIPPED+1)); continue ;;
  esac
  BOX=${LINE%%$'\t'*};  _R=${LINE#*$'\t'}
  TS=${_R%%$'\t'*};     _R=${_R#*$'\t'}
  OFF=${_R%%$'\t'*};    _R=${_R#*$'\t'}
  UNC=${_R%%$'\t'*};    REPORTED=${_R#*$'\t'}
  [ -n "${BOX:-}" ] || continue
  # The hub reads its own tree off local disk every tick (bf_rows), so a record
  # of the same name would be the same box twice — once through a stale copy.
  case "$BOX" in
    "$HARNESS_HUB_BOX"|"${HUB_SELF:-@}"|"${HUB_FILE:-@}"|"${HUB_ENV:-@}") continue ;;
  esac
  case "$BOX" in *[!A-Za-z0-9._-]*) continue ;; esac
  # A report with no collection time cannot be dated, and an undatable record is
  # one that can never age out. Dropped, not defaulted.
  #
  # THE SHAPE GATE RUNS BEFORE `date`, AND THAT ORDER IS THE WHOLE POINT
  # (BH-1308). GNU date reads an EMPTY string as today's 00:00:00 and exits 0,
  # so `date -u -d "" +%s` hands this loop a perfectly numeric answer and the
  # check below cannot tell it from a real reading. For the BF_RECORD_FRESH_MIN
  # minutes after 00:00Z that fabricated midnight is inside the window, so an
  # undatable row was written; every other minute of the day it was skipped as
  # stale, which is why it read as a flaky test rather than as this bug. A
  # blank value and every relative word date would otherwise guess at ("now",
  # "today", "yesterday") go the same way: the value must START with a real
  # YYYY-MM-DD or date never sees it. bin/lib/jobs/boxes.sh emits the worker's
  # server-stamped ISO string verbatim, so every real row passes.
  case "${REPORTED:-}" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) ;;
    *) SKIPPED=$((SKIPPED+1)); continue ;;
  esac
  REP=$(date -u -d "${REPORTED:-}" +%s 2>/dev/null) || REP=""  # determinism: ok date-empty-stamp the case above skips any REPORTED that does not start with YYYY-MM-DD
  case "${REP:-}" in ''|*[!0-9]*) SKIPPED=$((SKIPPED+1)); continue ;; esac
  # STALE REPORTS ARE NOT WRITTEN AT ALL. Rewriting one would hand bf_rows a
  # fresh-looking file full of old facts; leaving the existing file alone lets
  # it age past BF_RECORD_FRESH_MIN and drop out, which is what "this box went
  # quiet" is supposed to look like.
  [ $(( NOW - REP )) -gt "$WINDOW" ] && { SKIPPED=$((SKIPPED+1)); continue; }
  # A clock ahead of the hub's is skew, not a fresher answer; it is still a
  # current report, so it is written — dated no later than now, so it cannot
  # outlive the window.
  [ "$REP" -gt "$NOW" ] && REP="$NOW"
  F="$STATE/backup-$BOX"
  # Three fields ALWAYS, the same shape bf_facts_local produces and the same
  # shape the ssh probe put here: "answered, nothing stamped" and "no answer at
  # all" must never look alike, and bf_state_age reads a shorter line as
  # `unknown` rather than as the `missing` that pages.
  printf '%s\t%s\t%s\n' "${TS:-}" "${OFF:-}" "${UNC:-}" > "$F.tmp" 2>/dev/null \
    && mv -f "$F.tmp" "$F" 2>/dev/null || { rm -f "$F.tmp" 2>/dev/null; SKIPPED=$((SKIPPED+1)); continue; }
  # The mtime is the moment the BOX spoke, not the moment this lane ran. GNU
  # first, then the portable form, because a record whose mtime silently stayed
  # at "now" is the frozen-record bug this lane is careful about.
  touch -d "@$REP" "$F" 2>/dev/null \
    || touch -t "$(date -u -d "@$REP" +%Y%m%d%H%M.%S 2>/dev/null)" "$F" 2>/dev/null \
    || log "$BOX: could not date $F from its report — it will age from this run instead"
  # The heartbeat wrote this marker and cleared it when a box answered again;
  # nothing writes it any more, so a marker left behind by the old lane would
  # drop this box's row for ever with nothing able to retract it. A box that
  # just answered is, by definition, not unreachable.
  rm -f "$STATE/unreachable-$BOX" "$STATE/unreach-told-$BOX" 2>/dev/null
  WROTE=$((WROTE+1))
done <<EOF
$ROWS
EOF

log "wrote $WROTE record(s), skipped $SKIPPED"
exit 0
