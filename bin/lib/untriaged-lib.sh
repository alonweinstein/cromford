#!/bin/bash
# bin/lib/untriaged-lib.sh — the shared read layer for the untriaged lanes
# (BH-2751): which projects are GitHub-Issues boards, and their open `ai-build`
# issues. Sourced, never executed. The siblings import it so every lane reads
# the board the same way and none of them writes its own fetch.
#
# A FAILED READ IS NEVER "NO TICKETS" (docs/GH-REST.md, D9). ut_open_issues
# prints nothing and returns 1 on any declined read; `[]` under rc 0 is a real
# empty board. The paging, the `.pull_request` filter and the partial-page rule
# are gh_rest_issue_list's (bin/lib/gh-rest-list.sh), not repeated here.
#
# gh-rest: no-graphql
#
# No `set -e`, no `exit`, no side effect at source time, `set -u` safe.
if [ -n "${UNTRIAGED_LIB:-}" ]; then return 0 2>/dev/null; fi
UNTRIAGED_LIB=1
# shellcheck source=bin/lib/gh-rest-list.sh
if ! declare -F gh_rest_issue_list >/dev/null 2>&1; then
  . "$(dirname "${BASH_SOURCE[0]}")/gh-rest-list.sh" 2>/dev/null || return 0 2>/dev/null
fi

# ut_gh_projects [fleet_conf] — `<project> <owner/repo>` for every row whose
# board-api-prefix (col 4) is `-`: the complement of
# `bin/fleet-conf.sh --projects-with-board`, on the same predicate. A missing
# registry is rc 1 with no output, not "no GitHub boards".
ut_gh_projects() {
  local conf="${1:-${HARNESS:-/root/harness}/fleet.conf}"
  [ -r "$conf" ] || return 1
  awk '!/^[[:space:]]*(#|$)/ && NF>=4 && $4 == "-" {print $1, $2}' "$conf"
}

# ut_open_issues <owner/repo> [max_pages] — ONE compact JSON array of
# {number, comments, created_at, title, body} for open `ai-build` issues, PRs
# dropped. max_pages caps the read at max_pages*100 issues (default 5); a read
# that reaches the cap sets UT_OPEN_ISSUES_CAPPED=1 (D12), else 0.
ut_open_issues() {
  local slug="${1:-}" max="${2:-5}" tmp out rc=0
  UT_OPEN_ISSUES_CAPPED=0
  case "$max" in ''|*[!0-9]*|0*) return 1 ;; esac
  tmp=$(mktemp "${TMPDIR:-/tmp}/ut.XXXXXX") || return 1
  # A plain command with `> file`, never `$( )`: GH_REST_STATUS/GH_REST_REASON
  # must still be in the caller's shell for gh_rest_alert.
  gh_rest_issue_list "$slug" open ai-build "$((max*100))" > "$tmp" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$tmp"; return 1; fi
  out=$(jq -c 'map({number, comments, created_at, title, body})' "$tmp" 2>/dev/null) || rc=$?
  rm -f "$tmp"
  if [ "$rc" != 0 ] || [ -z "$out" ]; then return 1; fi
  if [ "$(jq 'length' <<<"$out")" -ge "$((max*100))" ]; then UT_OPEN_ISSUES_CAPPED=1; fi
  printf '%s\n' "$out"
}
