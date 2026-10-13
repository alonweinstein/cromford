#!/bin/bash
# bin/lib/gh-token-live.sh — read the GitHub token a builder should use RIGHT NOW,
# instead of the one its environment was born with. Sourced, never executed.
#
#   gh_token_live [owner/repo]   exports GH_TOKEN from /run/harness-env/gh-token when that file
#                   exists and is non-empty; rc 1 and the ENVIRONMENT IS UNTOUCHED
#                   otherwise, so every caller is written `gh_token_live || true`.
#                   With the token it moves GH_TOKEN_INSTALLATION_ID to the
#                   gh-installation-id file beside it, when there is one (BH-1602).
#
#   gh_token_live_sync_env [env-file]   rewrites the GH_TOKEN= line of env-file
#                   (default ${HARNESS_ENV_DIR:-/run/harness-env}/global.env) from the
#                   gh-token file beside it. rc 0 when it now holds the live token
#                   (written, or already equal), rc 1 and the file UNTOUCHED otherwise.
#                   Never prints the token (BH-5025).
#
# THE INCIDENT (2026-09-14 13:44-14:15Z, project-5 pool). bin/fly-pool.sh swaps the
# fleet PAT for a repo-scoped GitHub App installation token in each pool machine's
# env bundle. An installation token lives exactly one hour. A pool build takes
# 40-75 minutes, and the bundle's token was already 47 minutes old when TK-680/681/
# 682 were spawned, so their pre-PR push answered `remote: Invalid username or
# token` and three finished builds were thrown away and requeued.
#
# The env bundle is read ONCE, at the top of bin/run-build.sh, which is the wrong
# clock for a credential that expires: whatever GH_TOKEN held at minute 0 is what
# minute 60 pushes with. So the hub re-mints and pushes a fresh token to this file
# while the build runs (bin/fly-pool.sh's per-machine tick), and the build reads
# the FILE at the moment it needs the token — immediately before a push, a
# `gh pr create`, or the builder-direct close-out.
#
# WHY A FILE, AND global.env AS WELL (BH-5025). A running process cannot be made to
# re-source its own environment, so a running build still reads the FILE at call
# time. But the next job on the same machine starts by sourcing global.env
# (fly/builder-runner.sh load_env), and its GH_TOKEN= was the spawn-time token, dead
# an hour after spawn: on 2026-10-07 17 pool machines answered 401 on the global.env
# token and 200 on the gh-token file beside it, so every job after the first hour
# ran its prelude gh reads on a dead credential. gh_token_live_sync_env rewrites
# global.env for the NEXT process: whole, into a tmp in the same directory, then one
# atomic mv. A concurrent reader sees the old file or the new one, never a torn one,
# which is the race this paragraph used to cite as the reason not to.
#
# KILL FLAG: with GH_APP_TOKENS=0 or flags/gh-app-tokens-off (or the
# `switch.gh-app-tokens-off` settings row), bin/fly-pool.sh never
# writes the file and never rotates, so there is nothing to read and this returns 1
# — today's behaviour, byte for byte. The two checks below are the belt to that
# braces: a box that turns App tokens off mid-build must stop reading a token the
# App minted, even if the file is still lying on the tmpfs.
_GHTL_FILE_DEFAULT=/run/harness-env/gh-token

gh_token_live() {
  local h="${HARNESS:-/root/harness}" f="${GH_TOKEN_LIVE_FILE:-$_GHTL_FILE_DEFAULT}" tok
  # lane-switch.sh loads on the first read, not when this lib is sourced.
  command -v lane_switch >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }
  HARNESS="$h" lane_switch gh-app-tokens-off && return 1
  [ "${GH_APP_TOKENS:-1}" = 0 ] && return 1
  if [ -s "$f" ]; then
    # Whitespace-stripped: the file is written by a base64 round trip through a
    # console, and a trailing newline in an Authorization header is the CRON_SECRET
    # class of bug — an equality that silently stops being one.
    tok=$(tr -d ' \t\r\n' < "$f" 2>/dev/null)
    [ -n "$tok" ] || return 1
    export GH_TOKEN="$tok"
    # THE BUCKET MOVES WITH THE TOKEN (BH-1602). The rotation pushes the id of the
    # installation that minted this token beside it, so the #1484 ledger here
    # names the bucket actually spent. No sidecar: the spawn-time hint is left as
    # it is (it describes the spawn token). A sidecar that names no id: the hint
    # is unset, because a hint not known to belong to this token must not name one.
    local hf="${GH_TOKEN_INSTALLATION_LIVE_FILE:-$(dirname "$f")/gh-installation-id}" inst
    if [ -f "$hf" ]; then
      inst=$(tr -d ' \t\r\n' < "$hf" 2>/dev/null)
      case "$inst" in
        ''|*[!0-9]*) unset GH_TOKEN_INSTALLATION_ID ;;
        *) export GH_TOKEN_INSTALLATION_ID="$inst" ;;
      esac
    fi
    return 0
  fi
  # No live file: this is a watcher box or the hub, where nothing rotates the
  # token under a running build. 2026-09-15 22:11Z, box-small, BH-375:
  # the pre-PR push answered "Invalid username or token" on the minute-0 App
  # token and a finished build parked BUILD_DEFERRED. When the caller NAMES the
  # repo, mint a fresh token for it through bin/gh-token.sh (cached per repo).
  # Called without a slug, with no minter on the tree, or with an empty mint, the
  # environment stays untouched — the contract every existing caller relied on.
  local slug="${1:-}"
  [ -n "$slug" ] && [ -x "$h/bin/gh-token.sh" ] || return 1
  tok=$("$h/bin/gh-token.sh" "$slug" 2>/dev/null | tr -d ' \t\r\n')
  [ -n "$tok" ] || return 1
  export GH_TOKEN="$tok"
  return 0
}

# gh_token_live_sync_env [env-file] — see the header. Only builtins hold the token:
# it is never in argv, a log line or stdout. Lines written `export GH_TOKEN=` or
# indented are not the bundle's shape (bin/fly-envbundle.sh writes NAME=value) and
# are copied as they are.
gh_token_live_sync_env() {
  local envf="${1:-${HARNESS_ENV_DIR:-/run/harness-env}/global.env}"
  local h="${HARNESS:-${H:-}}" live hf tok="" inst="" keep_inst=0 line n=0 same=0 tmp
  [ -n "$h" ] || return 1
  live="${GH_TOKEN_LIVE_FILE:-${envf%/*}/gh-token}"
  hf="${GH_TOKEN_INSTALLATION_LIVE_FILE:-${live%/*}/gh-installation-id}"
  command -v lane_switch >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-}}/flags/$1" ]; }
  HARNESS="$h" lane_switch gh-app-tokens-off && return 1
  [ "${GH_APP_TOKENS:-1}" = 0 ] && return 1
  [ -f "$envf" ] && [ -s "$live" ] || return 1
  tok=$(tr -d ' \t\r\n' < "$live" 2>/dev/null)
  # global.env is SOURCED by sh: a token that is not one plain word is never written.
  [[ $tok =~ ^[A-Za-z0-9_.-]+$ ]] || { tok=""; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in GH_TOKEN=*) n=$((n + 1)); [ "$line" = "GH_TOKEN=$tok" ] && same=1 ;; esac
  done < "$envf"
  # The rotation writes the id with the token, so an equal token has the right id.
  if [ "$n" = 1 ] && [ "$same" = 1 ]; then tok=""; return 0; fi
  if [ -f "$hf" ]; then
    inst=$(tr -d ' \t\r\n' < "$hf" 2>/dev/null)
    case "$inst" in ''|*[!0-9]*) inst="" ;; esac
  else
    keep_inst=1
  fi
  tmp="$envf.bh5025.$$"
  if ( umask 077
       while IFS= read -r line || [ -n "$line" ]; do
         case "$line" in
           GH_TOKEN=*) continue ;;
           GH_TOKEN_INSTALLATION_ID=*) [ "$keep_inst" = 1 ] || continue ;;
         esac
         printf '%s\n' "$line"
       done < "$envf" > "$tmp" || exit 1
       printf 'GH_TOKEN=%s\n' "$tok" >> "$tmp" || exit 1
       [ -z "$inst" ] || printf 'GH_TOKEN_INSTALLATION_ID=%s\n' "$inst" >> "$tmp" || exit 1
     ) 2>/dev/null && chmod 600 "$tmp" 2>/dev/null && mv -f "$tmp" "$envf" 2>/dev/null; then
    tok=""; return 0
  fi
  rm -f "$tmp"; tok=""
  return 1
}
