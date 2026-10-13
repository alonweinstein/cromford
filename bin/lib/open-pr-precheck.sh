#!/bin/bash
# bin/lib/open-pr-precheck.sh — "is there already an open PR for this ticket?"
# Sourced, never executed. No caller yet (BH-3948, slice C0 of BH-3943).
#
# open_pr_for_key <owner/repo> <KEY>
#   rc 0  prints `#<n>`: an open PR whose head is exactly <owner>:agent/<KEY>,
#         else exactly <owner>:ticket/<key lowercased>
#   rc 1  prints nothing: both heads read cleanly and neither has an open PR
#   rc 2  prints nothing: a read failed or came back unreadable, or bad args.
#         Unreadable is never "none".
# BH-1485: each probe is gh_rest_pr_list_var in this shell, never a `$( )`, so
# GH_REST_STATUS / GH_REST_REASON from a failed read survive for the caller.
#
# gh-rest: no-graphql
#
# No `set -e`, no `exit`, no output at source time.
if [ -n "${OPEN_PR_PRECHECK_LIB:-}" ]; then return 0 2>/dev/null; fi
OPEN_PR_PRECHECK_LIB=1
if ! declare -F gh_rest_pr_list_var >/dev/null; then
  . "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh" 2>/dev/null || true
fi

open_pr_for_key() {
  local _oppc_slug="${1:-}" _oppc_key="${2:-}" _oppc_owner _oppc_br _oppc_body _oppc_n _oppc_rc
  case "$_oppc_slug" in */*) ;; *) return 2 ;; esac
  _oppc_owner="${_oppc_slug%%/*}"
  [ -n "$_oppc_key" ] && [ -n "$_oppc_owner" ] || return 2
  for _oppc_br in "agent/$_oppc_key" "ticket/${_oppc_key,,}"; do
    _oppc_rc=0
    gh_rest_pr_list_var _oppc_body "$_oppc_slug" open "$_oppc_owner:$_oppc_br" 1 || _oppc_rc=$?
    [ "$_oppc_rc" = 0 ] && [ -n "$_oppc_body" ] || return 2
    printf '%s' "$_oppc_body" | jq -e 'type == "array"' >/dev/null 2>&1 || return 2
    _oppc_n=$(printf '%s' "$_oppc_body" | jq -r --arg br "$_oppc_br" \
      '[.[] | select(.head.ref == $br and .state == "open")][0] | if . == null then "" else (.number // "?") end' 2>/dev/null) || return 2
    [ -z "$_oppc_n" ] && continue
    [[ "$_oppc_n" =~ ^[0-9]+$ ]] || return 2
    printf '#%s\n' "$_oppc_n"
    return 0
  done
  return 1
}
