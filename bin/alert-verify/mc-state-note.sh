#!/bin/bash
# bin/alert-verify/mc-state-note.sh — the verify script of the `mc-state-note` row of
# alert_family_scripts (BH-2577). Protocol: the header of
# bin/triage-family-scripts.sh; shared reads: bin/lib/alert-verify.sh.
#
# A merge-conductor page, `conductor: <slug>#<n> <STATE> — …`. Cleared once the
# PR is MERGED or CLOSED. A line whose own state is already MERGED/CLOSED is
# about something else ("closed and its issue is still open"), so it is doubt.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
LIB="$HARNESS/bin/lib"
[ -r "$LIB/alert-verify.sh" ] || LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
. "$LIB/alert-verify.sh" || exit 75
M=$(av_field line | av_one "conductor: $AV_SLUG#[0-9]+ [A-Z_]+ ") || exit 75
read -r _ KEY ST <<<"$M"
case "$ST" in MERGED|CLOSED) exit 75 ;; esac
av_pr_verdict mc-state-note "https://github.com/${KEY%#*}/pull/${KEY##*#}"
