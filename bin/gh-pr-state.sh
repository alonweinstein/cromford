#!/bin/bash
# bin/gh-pr-state.sh — ONE pull request's state, read over REST, in a child.
#
#   bin/gh-pr-state.sh https://github.com/<owner>/<repo>/pull/<n>
#
#   rc 0   prints OPEN | MERGED | CLOSED
#   rc 44  GitHub says there is no such PR (act on it)
#   rc 75  UNVERIFIABLE — rate limit, network, non-2xx, empty body. Prints
#          nothing. The caller leaves its state exactly as it is.
#   rc 2   the argument is not a github.com pull-request url.
#
# WHY A CHILD PROCESS AND NOT TWO LINES IN THE CALLER (BH-655 follow-up).
# `gh_auth_reset` in bin/lib/gh-app-auth.sh restores the GH_TOKEN the SOURCING
# shell started with, so a lane that sources that library above its own env load
# hands the pre-env snapshot back to every later step of the same tick — the
# BH-470 regression. A child that dies the moment it has answered cannot touch
# the caller's environment on any path, and it is also the only way a python
# brake inside a bash lane can make the SAME armed read the bash half makes:
# one implementation, one identity, two callers.
#
# WHY REST AND NEVER `gh pr view` (#768, 2026-09-18). The GraphQL-backed CLI got
# rate-limited and answered an EMPTY STRING; the decision path read that silence
# as "no such PR" and rewrote five real PRs. gh_rest_pr_state keeps "GitHub said
# no such thing" (44) and "GitHub said come back later" (75) apart, which is the
# whole reason a caller may act on one and must not act on the other.
#
# Driven by tests/alert-fixpr-suppress-test.sh (its gh stub answers the REST
# read, and the argv it records is the assertion).
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
LIB="$HARNESS/bin/lib"
[ -r "$LIB/gh-rest.sh" ] || LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
. "$LIB/gh-rest.sh" || exit 75
# Sourced AFTER gh-rest.sh and never above an env load: this process makes one
# read and exits, so the snapshot gh_auth_reset would restore never matters.
. "$LIB/gh-app-auth.sh" 2>/dev/null || true

URL="${1:-}"
if [[ ! "$URL" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)/?$ ]]; then
  exit 2
fi
SLUG="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
NUM="${BASH_REMATCH[3]}"

# rc 1 leaves the environment untouched on a box that mints no App token, which
# is why this is `|| true` and not a failure: an unarmed box reads on the PAT
# exactly as it did before.
command -v gh_auth_for_url >/dev/null 2>&1 && gh_auth_for_url "$URL" || true

# Through a FILE and never `$( )`: GH_REST_STATUS only survives in the shell that
# called the helper, and `cmd || rc=$?` never `cmd; rc=$?` so a 44/75 return
# still reaches the mapping below.
OUT=$(mktemp "${TMPDIR:-/tmp}/gh-pr-state.XXXXXX") || exit 75
RC=0
gh_rest_pr_state "$SLUG" "$NUM" > "$OUT" || RC=$?
STATE=$(tr -d '[:space:]' < "$OUT" 2>/dev/null | tr 'a-z' 'A-Z')
rm -f "$OUT"
[ "$RC" = 0 ] || exit "$RC"
[ -n "$STATE" ] || exit 75
printf '%s\n' "$STATE"
exit 0
