#!/bin/bash
# shellcheck shell=bash
# bin/lib/comment-mark.sh — BH-2317: the "this comment is already on the thread"
# markers, as D1 rows first and state files second. Sourced, never run.
#
# Five client-visible comments are posted once and guarded by a marker:
#   blocked <project> <KEY>       bin/lib/rb/execute.sh's BUILD BLOCKED notice
#   merge-close <owner/repo> <n>  bin/lib/rb/pr.sh's tier-1 "Merged in …" close
#   parent-close <project> <N>    bin/decompose-parent-close.sh's split close
#   rebuild <project> <cap-key>   bin/blocked-resolver.sh's rebuild outcome
#   sequenced <project> <KEY>:<OTHER>  bin/plan-sibling.sh's sibling-sequencing note
# Each marker used to be a file under $HARNESS/state only, so a wiped or rebuilt
# box posted the same comment again, and a re-offer had to ssh to the owning box
# to rm it. Each is now also a `ledgers` row: kind `commented`, key the string
# above, status `commented` (detail = the token) or `cleared`.
#
# THE READ RULE (cm_has). The row answers only what it can prove:
#   * status `cleared`                      -> NOT marked, whatever file is left
#                                              (that is how a hub-side clear
#                                              replaces the ssh rm)
#   * status `commented`, detail == token   -> marked
#   * anything else — another token, an unknown status, no row (rc 2, which is
#     every marker stamped before this shipped), an outage (rc 1), no client
#     loaded — falls through to the file, i.e. to exactly today's answer.
# An outage is therefore never read as "not commented" while a file says it is.
#
# The token is the build dir's basename for `blocked` (one notice per blocked
# build) and `-` for the rest. Keys are built only by the callers named above,
# identically at every read and write; they are never globbed, so TK-9 can never
# match TK-91.
#
# The jobs client (job_ledger_row / job_ledger_put) is the CALLER's to load:
# every caller above already sources bin/jobs-client.sh. Without it every row
# read is an outage and every answer is the file's.

# cm_has <key> <token> <file> — rc 0 when the comment is already on the thread.
cm_has() {
  local key="$1" tok="$2" file="$3" row rc st det
  if command -v job_ledger_row >/dev/null 2>&1; then
    row=$(job_ledger_row commented "$key" 2>/dev/null </dev/null); rc=$?
    if [ "$rc" = 0 ]; then
      st=$(printf '%s' "$row" | jq -r '.status // ""' 2>/dev/null)
      det=$(printf '%s' "$row" | jq -r '.detail // ""' 2>/dev/null)
      [ "$st" = cleared ] && return 1
      [ "$st" = commented ] && [ "$det" = "$tok" ] && return 0
    fi
  fi
  [ -e "$file" ]
}

# cm_put <key> <token> <file> — record the comment: the row, then the file.
#   rc 0 when at least one of the two landed.
cm_put() {
  local key="$1" tok="$2" file="$3" rrc=1 frc=1
  command -v job_ledger_put >/dev/null 2>&1 \
    && job_ledger_put commented "$key" commented "$tok" >/dev/null 2>&1 </dev/null && rrc=0
  mkdir -p "$(dirname "$file")" 2>/dev/null
  : > "$file" 2>/dev/null && frc=0
  [ "$rrc" = 0 ] || [ "$frc" = 0 ]
}

# cm_clear <key> <file-glob> — forget the comment, so the next one is posted.
#   Flips the row to `cleared` (never deletes it: a stale file somewhere can
#   then never outvote the clear) and removes the local files the glob names.
#   rc is the ROW write's: 0 = cleared fleet-wide, 1 = the row was not written
#   (outage, no client), and a caller that must reach another box's file falls
#   back to doing that itself.
cm_clear() {
  local key="$1" glob="$2" f rc=1
  command -v job_ledger_put >/dev/null 2>&1 \
    && job_ledger_put commented "$key" cleared - >/dev/null 2>&1 </dev/null && rc=0
  # shellcheck disable=SC2086  # the glob is the argument's whole point
  for f in $glob; do [ -e "$f" ] && rm -f "$f" 2>/dev/null; done
  return "$rc"
}
