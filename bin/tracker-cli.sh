#!/bin/bash
# bin/tracker-cli.sh <project> <verb> [args…] — the triage session's hands on a
# project whose tickets are NOT on GitHub Issues. prompts/TEMPLATE-LINEAR.md
# tells the session to use this where TEMPLATE-GH.md says `gh issue …`.
#
#   list                          open tickets with the build label, JSON array
#   read <id>                     one ticket and its whole thread, JSON
#   comment <id> <bodyfile|->     `-` reads the body from stdin
#   label-add <id> <label>
#   label-remove <id> <label>     rc 44 when the ticket does not carry it
#   transition <id> <todo|in_progress|review|done|closed>
#
# WHICH TRACKER is bin/lib/tracker.sh's tracker_adapter. Only `linear` is
# served: its context is trk_linear_context <project> (LINEAR_API_KEY from the
# project's env file, the tracker_linear.<project>.* rows). Any other adapter
# is rc 3 with one line naming it; a GitHub-Issues project keeps `gh`.
#
# THE TEAM GUARD. An id must be <TEAM>-<n> of the context's team. Every verb
# that names a ticket first asks trk_linear_gate_raw, which refuses an issue
# Linear answers from another team (a moved issue keeps answering to its old
# identifier), so a write never lands on another project's ticket.
#
# Every write is logged to logs/tracker-cli.log (TRK_LOG). TRK_DRY=1 sends no
# write. Exit codes are the tracker contract's (0, 1, 3, 44, 75); 2 is usage.
set -uo pipefail
usage() { echo "usage: tracker-cli.sh <project> list|read <id>|comment <id> <bodyfile|->|label-add <id> <label>|label-remove <id> <label>|transition <id> <status>" >&2; exit 2; }
[ "$#" -ge 2 ] || usage
P="$1" VERB="$2"; shift 2
HARNESS="${HARNESS:-/root/harness}"; export HARNESS
BIN=$(cd "$(dirname "$0")" && pwd)

# shellcheck source=bin/lib/tracker.sh
. "$BIN/lib/tracker.sh" || { echo "tracker-cli: bin/lib/tracker.sh did not load" >&2; exit 1; }
# TRK_DRY=0 for this one read: a dry run reads no settings row, and the
# fleet.conf fallback would answer github-issues for every Linear project.
A=$(TRK_DRY=0 tracker_adapter "$P") || { echo "tracker-cli: no tracker resolved for $P" >&2; exit 1; }
[ "$A" = linear ] || { echo "tracker-cli: $P is on $A, which this CLI does not serve (GitHub Issues: use gh)" >&2; exit 3; }
tracker_load linear || { echo "tracker-cli: bin/lib/tracker/linear.sh did not load" >&2; exit 1; }
trk_linear_context "$P" || exit 1
[ -d "$HARNESS/logs" ] && export TRK_LOG="$HARNESS/logs/tracker-cli.log"

ticket() { # ticket <id> — the team guard, then the id is safe to send
  [[ "${1:-}" =~ ^${TRK_LINEAR_TEAM}-[0-9]+$ ]] || { echo "tracker-cli: ${1:-<none>} is not a $TRK_LINEAR_TEAM ticket" >&2; exit 1; }
  local rc=0
  trk_linear_gate_raw "$1" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || { echo "tracker-cli: $1 could not be read as a $TRK_LINEAR_TEAM ticket (rc $rc)" >&2; exit "$rc"; }
}

rc=0
case "$VERB" in
  list)
    [ "$#" = 0 ] || usage
    tracker_list || rc=$? ;;
  read)
    [ "$#" = 1 ] || usage; ticket "$1"
    tracker_read "$1" || rc=$? ;;
  comment)
    [ "$#" = 2 ] || usage; ticket "$1"
    f="$2"
    if [ "$f" = - ]; then
      f=$(mktemp "${TMPDIR:-/tmp}/tracker-cli.XXXXXX") || exit 1
      cat > "$f"
    fi
    [ -s "$f" ] || { echo "tracker-cli: the comment body is empty" >&2; [ "$2" = - ] && rm -f "$f"; exit 2; }
    tracker_comment "$1" "$f" || rc=$?
    [ "$2" = - ] && rm -f "$f" ;;
  label-add)
    [ "$#" = 2 ] || usage; ticket "$1"
    tracker_label_add "$1" "$2" || rc=$? ;;
  label-remove)
    [ "$#" = 2 ] || usage; ticket "$1"
    tracker_label_remove "$1" "$2" || rc=$? ;;
  transition)
    [ "$#" = 2 ] || usage; ticket "$1"
    tracker_transition "$1" "$2" || rc=$? ;;
  *) usage ;;
esac
exit "$rc"
