#!/bin/bash
# bin/qa-unbanned.sh <project> <role|user_id> -- <command> [args...]
#
# Run <command> with a QA account temporarily unbanned in Clerk, and put the ban
# back — ALWAYS, on success, on failure, on a non-zero exit, on SIGINT/SIGTERM.
#
# THE BUG THIS CLOSES (SDLC item 3a, 2026-08-29). Privileged QA accounts are
# BANNED at rest by our own design (project-3 qa-administrator has been banned since
# 2026-08-16; project-1 qa-owner/qa-admin the same). Clerk still MINTS a sign-in
# ticket for a banned user — POST /v1/sign_in_tokens answers 200 — and the
# refusal only happens when the browser presents it. So the drive bounced to
# /sign-in, screenshotted the sign-in page and reported coverage. Every authed
# observation in such a report was of a screen nobody ever loaded.
#
# THE SHAPE, and why it is a wrapper rather than two calls in a skill:
#   * the ban must be restored by the process that OWNS the drive. A skill that
#     says "unban, drive, re-ban" restores nothing when the drive is killed at
#     step two, and a QA account left unbanned in production is a standing
#     privilege escalation nobody is watching.
#   * so the re-ban lives in an EXIT trap here, and everything that happens
#     between is somebody else's argv.
#
# RESTORE MEANS RESTORE, NOT BAN. It re-bans only if the account was OBSERVED
# banned at entry. Blindly banning on the way out would take an account that is
# deliberately active at rest (project-4's qa-harness, project-1' `user`) and disable
# it on the first drive — turning a QA fix into an outage of the QA lane. The
# guarantee callers need is "never left MORE privileged than we found it", and
# that is what restoring the observed state gives.
#
# A FAILED RESTORE IS LOUD AND IS THE EXIT CODE. Three attempts, then an
# ALERTS.log line naming the project and account plus a fleet_alert beat, and
# this script exits non-zero no matter how well the drive went. A drive that
# passed while leaving a privileged account unbanned is not a pass.
#
# EXCLUSIVE. flock per (project, user) for the whole unban window, so two
# concurrent drives cannot have one re-ban the account out from under the other.
# A second waiter blocks up to QA_UNBAN_WAIT (default 300s) and then declines —
# it never proceeds against an account whose window belongs to someone else.
#
# Exit codes: the command's own rc, EXCEPT 90 when the restore failed (and 91
# when the unban itself could not be verified, so nothing was ever driven).
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
ALERTS="$HARNESS/logs/ALERTS.log"
LOG="$HARNESS/logs/qa-drive.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

P="${1:-}"; ROLE="${2:-}"; SEP="${3:-}"
[ -n "$P" ] && [ -n "$ROLE" ] && [ "$SEP" = "--" ] || {
  echo "usage: qa-unbanned.sh <project> <role|user_id> -- <command> [args...]" >&2; exit 2; }
shift 3
[ "$#" -gt 0 ] || { echo "qa-unbanned.sh: nothing to run after --" >&2; exit 2; }

mkdir -p "$HARNESS/logs" "$HARNESS/locks" 2>/dev/null || true
note() { echo "$(STAMP) [$P] qa-unbanned($ROLE): $*" >> "$LOG"; }

UID_=$("$SELF/qa-account.sh" "$P" "$ROLE" user_id) || exit 2
SHORT="${UID_:0:12}…"

# The lock is taken BEFORE the state is read: reading "active" and then waiting
# for a lock would be reading the state of somebody else's unban window and
# concluding the account is active at rest — the one misreading that would make
# this script leave a ban off permanently.
LOCK="$HARNESS/locks/qa-unban-$P-$UID_.lock"
exec 9>"$LOCK" || exit 2
if ! flock -w "${QA_UNBAN_WAIT:-300}" 9; then
  echo "qa-unbanned.sh: another drive holds the unban window for $P/$ROLE — declining" >&2
  note "declined: unban window busy"
  exit 75   # EX_TEMPFAIL: retry later, nothing was touched
fi

BAN() { "$SELF/qa-clerk-ban.sh" "$P" "$UID_" "$1" 2>/dev/null; }

STATE0=$(BAN status) || {
  echo "qa-unbanned.sh: cannot read Clerk ban state for $P/$ROLE ($SHORT) — refusing to drive blind" >&2
  note "FAIL: ban state unreadable — nothing driven"
  exit 91
}

RESTORE=0
if [ "$STATE0" = banned ]; then
  AFTER=$(BAN unban) || AFTER=""
  if [ "$AFTER" != active ]; then
    echo "qa-unbanned.sh: unban did not take for $P/$ROLE ($SHORT) — Clerk still says '${AFTER:-unreadable}'" >&2
    note "FAIL: unban did not take (state=${AFTER:-unreadable}) — nothing driven"
    exit 91
  fi
  RESTORE=1
  note "unbanned $SHORT for the drive (rest state: banned)"
fi

RESTORE_RC=0
restore() {
  [ "$RESTORE" = 1 ] || return 0
  RESTORE=0                      # idempotent: safe if the trap fires twice
  local i state=""
  for i in 1 2 3; do
    state=$(BAN ban) || state=""
    [ "$state" = banned ] && break
    sleep 3
  done
  if [ "$state" = banned ]; then
    note "re-banned $SHORT (rest state restored)"
    return 0
  fi
  RESTORE_RC=90
  echo "$(STAMP) [$P] QA ACCOUNT LEFT UNBANNED: $ROLE ($SHORT) could not be re-banned after 3 attempts (Clerk says '${state:-unreadable}'). A privileged QA account is live in production — re-ban it by hand via the app's users screen or POST https://api.clerk.com/v1/users/$UID_/ban" >> "$ALERTS"
  "$SELF/beat.sh" "$(jq -nc --arg p "$P" --arg akey "qaunban:$P:$UID_" \
    --arg l "QA account $ROLE could not be RE-BANNED after a prod drive — it is live in production right now. Re-ban by hand." \
    '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  return 1
}
# rc is captured BEFORE restore runs, because restore's own commands overwrite
# $? — the drive's exit code is the thing this trap exists to preserve.
trap 'RC=$?; restore; exit $(( RESTORE_RC != 0 ? RESTORE_RC : RC ))' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$@"
exit $?
