#!/bin/bash
# bin/lib/wake-conductor-keys.sh — turn a checks wake's head sha into the open
# PR(s) it heads, for bin/wake-loop.sh's keyed conductor launch (BH-5521).
# Sourced, never executed.
#
# The wake loop first maps a sha through the conductor's pr-state.tsv. A sha
# that file does not know (a head the conductor has not seen yet, a main-branch
# CI run, a pre-queue run on main) used to make the whole batch unkeyed: a
# fleet-wide full tick for one event. This asks GitHub once instead.
#
# gh-rest: no-graphql
#
# No side effect at source time, no `exit`, no root default (D43).

if ! command -v gh_rest_var >/dev/null 2>&1; then
  # shellcheck source=bin/lib/gh-rest.sh
  [ -r "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh"
fi

# wck_sha_prs <lrepo> <sha> — print `<lrepo>#<n>` for each OPEN PR whose head
# starts with <sha>, deduped. rc 0 = one or more printed; rc 1 = GitHub answered
# and no open PR has that head (a merge commit on main, a moved head); rc 2 =
# unreadable (bad input, no gh_rest_var, rate limited, not a list). Never guesses.
wck_sha_prs() {
  local lrepo="${1:-}" sha="${2:-}" body out
  [[ "$lrepo" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]] || return 2
  [[ "$sha" =~ ^[0-9a-f]{7,64}$ ]] || return 2
  command -v gh_rest_var >/dev/null 2>&1 || return 2
  # gh_rest_var, never $(gh_rest ...): a command substitution drops the
  # GH_REST_STATUS the helper sets (gh-rest-no-subshell-lint).
  gh_rest_var body GET "repos/$lrepo/commits/$sha/pulls" || return 2
  out=$(jq -r --arg s "$sha" 'if type=="array" then .[] | select(.state=="open")
          | select(((.head.sha // "") | ascii_downcase | startswith($s))) | .number
        else error("not a list") end' <<<"$body" 2>/dev/null) || return 2
  out=$(grep -E '^[0-9]+$' <<<"$out" | awk '!seen[$0]++')
  [ -n "$out" ] || return 1
  sed "s|^|$lrepo#|" <<<"$out"
}
