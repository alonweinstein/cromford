#!/bin/bash
# bin/lib/triage-gh-token.sh — a triage tick arms a GitHub App token that
# outlives the tick. Sourced, never executed; defines one function and runs
# nothing on source. Its own file so bin/run-triage.sh stays under the driver
# ceiling (tests/rt-split-layout-test.sh A6).
#
# A TICK IS NOT A MINUTE (project-4, 2026-09-24). The token cache hands a token
# out until 5 minutes before it dies, which is right for a shard and wrong for a
# full tick: those run 10-20 minutes, and the session's `git fetch origin` goes
# through `gh auth git-credential`, i.e. the GH_TOKEN the driver exports. The
# ticks that started at 17:58Z and 18:58Z armed a token with ~7 minutes left and
# stopped on "Invalid username or token" mid-run, four times that day. So the
# driver asks the minter for a token that outlives the tick BEFORE it arms: a
# shorter cached one is re-minted, a longer one is reused, and the arming then
# reads that cache row. gh_app_premint (bin/lib/gh-app-auth.sh) honours the
# App kill switches and is a no-op on a box that does not mint.
#
# TRIAGE_TOKEN_MIN_LIFE (catalog/lanes.d/run-triage.json, default 3000) is the
# life asked for, in seconds. An installation token lives 3600s, so the value
# is held to 300..3500: under 300 is what the cache already guarantees, over
# 3500 would re-mint on every tick. Unparseable text falls back to the default.

# triage_gh_premint <owner/repo> — rc 1 when there is no slug or no minter.
triage_gh_premint() {
  local slug="${1:-}" life="${TRIAGE_TOKEN_MIN_LIFE:-3000}"
  case "$life" in ''|*[!0-9]*) life=3000 ;; esac
  life=$((10#$life))
  [ "$life" -lt 300 ] && life=300
  [ "$life" -gt 3500 ] && life=3500
  [ -n "$slug" ] && command -v gh_app_premint >/dev/null 2>&1 || return 1
  gh_app_premint "$slug" "$life"
}
