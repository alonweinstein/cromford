#!/bin/bash
# shellcheck shell=bash
# bin/lib/ticket-branch.sh — BH-3835: the one parser from a ticket branch name
# to its ticket. Sourced, never run; it defines functions and nothing else.
#
#   ticket_branch_key <ref>    prints <PREFIX>-<n> (BH-77), rc 1 and nothing otherwise
#   ticket_branch_issue <ref>  prints <n> (77), rc 1 and nothing otherwise
#
# Grammar: ticket/<prefix>-<n> and its rebuild-ladder form ticket/<prefix>-<n>-r<k>
# (run-build always writes the lower-case -r). A split child ticket/bh-1510-0 and
# a ticket/bh-1486-local branch are NOT accepted: the split child is its own
# issue, and mapping it to 1510 would act on the parent. bin/lib/ticket-ownership.sh
# to_pr_identity keeps its own, looser grammar for that reason.
# Bash 3.2 safe: unquoted regex variable, upper-casing through tr.

ticket_branch_key() {
  local r="${1:-}" re='^ticket/([A-Za-z][A-Za-z0-9]*)-([0-9]+)(-r[0-9]+)?$'
  [[ $r =~ $re ]] || return 1
  printf '%s-%s' "$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')" "${BASH_REMATCH[2]}"
}

ticket_branch_issue() {
  local k
  k=$(ticket_branch_key "${1:-}") || return 1
  printf '%s' "${k##*-}"
}
