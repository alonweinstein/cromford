#!/bin/bash
# bin/lib/linear-build.sh — what the build pipeline and its close-out lanes do
# differently for a project whose tickets live on Linear (settings row
# tracker_adapter.<project> = linear). Functions lb_*. Sourced, never executed.
#
# The rest of the pipeline is the GitHub-Issues one: a Linear project sits at
# fleet.conf column 4 `-`, its code and PRs are on GitHub, and the planner reads
# the ticket through bin/tracker-cli.sh because prompts/<project>.md says so.
# Every site that would otherwise turn CRO-12 into GitHub issue #12 asks
# RB_LINEAR (set by bin/run-build.sh when lb_on answers 0) or lb_on itself.
#
#   lb_on <project>              rc 0 and the Linear context loaded (TRK_LINEAR_*);
#                                rc 1 not a linear project; rc 2 linear, but the
#                                context did not load (its stderr line says why)
#   lb_thread_fp <key>           16 hex: title, description, state and every
#                                comment not written by the key's own account;
#                                nothing on a failed read
#   lb_ticket_meta <key>         {title, labels:[{name}], body}, the shape
#                                bin/kind-gate.sh reads; nothing on a failed read
#   lb_closeout <key> <pr-url> <review|done> <bodyfile>
#                                link the PR, comment, then move the state
#   lb_partial <build dir>       rc 0 when the evidence REFUTED an acceptance claim
#   lb_close_merged <project> <key> <pr-url> <how> [<build dir>]
#                                the merge close-out: once per (key, PR), then
#                                done, or review when lb_partial says so;
#                                rc 3 when the project is not on Linear

_lb_dir() { dirname "${BASH_SOURCE[0]}"; }

lb_on() {
  local p="${1:-}" a
  command -v tracker_adapter >/dev/null 2>&1 || . "$(_lb_dir)/tracker.sh" 2>/dev/null || return 1
  a=$(TRK_DRY=0 tracker_adapter "$p" 2>/dev/null) || return 1
  [ "$a" = linear ] || return 1
  tracker_load linear || return 2
  trk_linear_context "$p" || return 2
  return 0
}

lb_thread_fp() {
  local t
  t=$(trk_linear_thread_raw "${1:-}" 2>/dev/null) || return 0
  t=$(printf '%s' "$t" | jq -cS '.me as $me | .ticket | {title, description, status,
      comments: [.comments[] | select(.author.userId != $me) | {id, body}]}' 2>/dev/null) || return 0
  [ -n "$t" ] && printf '%s' "$t" | sha256sum | cut -c1-16
}

# lb_partial <build dir> — rc 0 when the build's scored evidence REFUTED an
# acceptance claim (bin/lib/evidence.sh). The GitHub lane writes `Refs #n` for
# that and leaves the issue open; here the ticket stays in review, never done.
lb_partial() {
  [ -r "${1:-}/evidence.json" ] && jq -e '[.claims[]? | select(.verdict == "REFUTED")] | length > 0' "$1/evidence.json" >/dev/null 2>&1
}

lb_ticket_meta() {
  trk_linear_read "${1:-}" 2>/dev/null \
    | jq -c '{title: (.title // ""), labels: [(.labels // [])[] | {name: .}], body: (.body // "")}' 2>/dev/null
}

lb_closeout() {
  local key="${1:-}" url="${2:-}" to="${3:-review}" f="${4:-}" rc=0
  [[ "$key" =~ ^${TRK_LINEAR_TEAM:-.}-[0-9]+$ ]] && [ -r "$f" ] || return 1
  # The team guard first: an issue Linear moved to another team gets nothing.
  trk_linear_gate_raw "$key" >/dev/null 2>&1 || return 1
  # The attachment is de-duplicated by URL on Linear's side, so a retry is safe.
  [ -n "$url" ] && { trk_linear_link_pr "$key" "$url" || rc=$?; }
  trk_linear_comment "$key" "$f" || return $?
  trk_linear_transition "$key" "$to" || return $?
  return "$rc"
}

lb_close_merged() {
  local p="${1:-}" key="${2:-}" url="${3:-}" how="${4:-}" rec="${5:-}" h="${HARNESS:-/root/harness}" m f to=done rc=0
  lb_on "$p" 2>/dev/null; rc=$?
  case "$rc" in 0) ;; 1) return 3 ;; *) return "$rc" ;; esac
  m="$h/state/linear-merged-$p-$key-${url##*/}"
  [ -e "$m" ] && return 0
  f=$(mktemp "${TMPDIR:-/tmp}/linear-merged.XXXXXX") || return 1
  if [ -n "$rec" ] && lb_partial "$rec"; then
    to=review
    printf 'Merged in %s (%s), but not every acceptance item is met, so this stays open. See the PR body for what is missing.\n' "$url" "$how" > "$f"
  else
    printf 'Merged in %s (%s).\n' "$url" "$how" > "$f"
  fi
  lb_closeout "$key" "$url" "$to" "$f" || rc=$?
  rm -f "$f"
  [ "$rc" = 0 ] && { mkdir -p "$h/state" 2>/dev/null; : > "$m"; }
  return "$rc"
}
