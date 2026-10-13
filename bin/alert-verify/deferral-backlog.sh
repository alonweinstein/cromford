#!/bin/bash
# bin/alert-verify/deferral-backlog.sh — the verify script of the `deferral-backlog` row of
# alert_family_scripts (BH-2577). Protocol: the header of
# bin/triage-family-scripts.sh; shared reads: bin/lib/alert-verify.sh.
#
# bin/alert-triage.sh's `[alert-triage] DEFERRAL BACKLOG: <n> lines spooled`
# page (NOT the alerts-medic line of the same words). Cleared when the spool,
# $HARNESS/state/alert-triage-deferred.tsv, is at or under TRIAGE_SPOOL_ALERT
# (the lane's knob, default 40; the lane pages only ABOVE it). No spool file, or
# a knob that is not a positive integer, is doubt. Since BH-5942 the page says
# `... lines spooled for project <p> —`, and then the spool is that project's
# state/alert-triage/<p>/deferred.tsv and the lock its locks/alert-triage-<p>.lock.
#
# THE SPOOL IS ONLY THE BACKLOG BETWEEN TICKS. A tick drains it into its own
# temp file first (bin/alert-triage.sh:185) and puts the backlog back only after
# the family registry has run the verify scripts (:1264), so read mid-tick it
# holds just the lines that arrived since, and a clear from it would settle a
# live page. While bin/alert-triage.sh's lock is held — by the tick that called
# this script, or by one running beside it — a short spool is doubt; an over-cap
# one is still a repro, since everything in it is still spooled when the tick
# measures. The lock is checked before AND after the read, so a tick that starts
# in between is caught; one that starts and ends in between leaves the settled
# spool, which is a true read. The check is a flock -n on a read-only open: it
# creates nothing, and outside a tick it holds the lock for an instant only.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
LIB="$HARNESS/bin/lib"
[ -r "$LIB/alert-verify.sh" ] || LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
. "$LIB/alert-verify.sh" || exit 75
PAGE=$(av_field line | av_one '\[alert-triage\] DEFERRAL BACKLOG: [0-9]+ lines spooled( for project [A-Za-z0-9._-]+)?') || exit 75
TH=${TRIAGE_SPOOL_ALERT:-40}
case "$TH" in ''|*[!0-9]*) exit 75 ;; esac
[ "$TH" -ge 1 ] || exit 75
F="$AV_HARNESS/state/alert-triage-deferred.tsv"
L="$AV_HARNESS/locks/alert-triage.lock"
# BH-5942: the lane runs per project, and its page names the project. That
# project's run owns the spool it counted, under that project's run lock.
case "$PAGE" in
  *" for project "*)
    P="${PAGE##* for project }"
    case "$P" in .*) exit 75 ;; esac
    F="$AV_HARNESS/state/alert-triage/$P/deferred.tsv"
    L="$AV_HARNESS/locks/alert-triage-$P.lock" ;;
esac
# lane_idle — rc 0 when no alert-triage tick holds its lock. No lock file means
# the lane never ran on this tree; an unreadable one is not idle.
lane_idle() {
  [ -e "$L" ] || return 0
  ( exec 7<"$L" && flock -n 7 ) 2>/dev/null
}
IDLE_BEFORE=0; lane_idle && IDLE_BEFORE=1
[ -r "$F" ] || exit 75
N=$(wc -l < "$F") || exit 75
N=${N//[[:space:]]/}
[ "$N" -le "$TH" ] || exit 1
[ "$IDLE_BEFORE" = 1 ] && lane_idle || exit 75
echo "deferral-backlog: spool holds $N lines between ticks, not over TRIAGE_SPOOL_ALERT=$TH"
