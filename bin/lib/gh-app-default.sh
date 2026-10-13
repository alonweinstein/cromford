#!/bin/bash
# bin/lib/gh-app-default.sh — C2 (2026-09-24): a cron lane with no GH_TOKEN
# spends the GitHub App, not the operator's personal token. Sourced, never executed.
#
#   gh_app_default_slug <gh argv...>   the owner/repo that gh invocation targets,
#                                      or rc 1 when it cannot be told
#   gh_app_default_token <owner/repo>  a ghs_ installation token for it, or rc 1
#   gh_app_default_export <gh argv...> both, then `export GH_TOKEN`; rc 1 and the
#                                      environment UNTOUCHED when it did not
#   gh_pat_from_file                   the escape hatch's PAT: env/gh-pat, or rc 1
#
# WHY. Every box's gh keyring is logged in as operator. A lane that never calls
# gh_auth_for (bin/lib/gh-app-auth.sh) runs `gh` with GH_TOKEN empty, and gh
# answers from the keyring: the operator's PAT, one 5,000/h bucket for the whole fleet
# and a credential whose leak is permanent. The 48h ledger on 2026-09-24 named
# the callers: the blocked resolver (~12.5k calls), the tickets snapshot push
# (~8k), run-preplan on the small box (~4.5k), review-prs on most boxes, the
# wake loop, pipeline-health, ci-runners-status, claude-auth-check. Opting each
# lane in by hand is how this was left half done, so the default moves instead:
# bin/gh-ledger/gh (the first `gh` on every cron PATH) and gh_rest ask this file
# before the call, and a example-org target gets the App.
#
# WHAT IT NEVER DOES
#   - replace a token the caller chose. GH_TOKEN or GITHUB_TOKEN non-empty is
#     the caller's decision, and nothing here runs.
#   - hand out anything but an installation token. bin/gh-token.sh prints the PAT
#     when a mint fails; that answer is refused here, so a failed mint leaves gh
#     on exactly the credential it used before this file existed.
#   - mint for a repo it cannot name. An unresolvable target (a GraphQL query
#     with no owner/name, `gh api user`) keeps today's credential: a repo-scoped
#     token for the wrong repo is a 404, which is worse than the PAT.
#   - recurse. gh-token.sh's own PAT ladder runs `gh api repos/…` through the
#     shim; GH_LEDGER_NO_APP=1 rides every mint this file starts, and a process
#     that carries it never mints.
#
# THE ESCAPE. GH_USE_PAT=1 on a call keeps it off the App — the admin
# operations an installation token cannot do (repo hooks, rulesets, runner
# registration). With the keyring logged out there is no PAT behind gh any more,
# so the escape reads env/gh-pat (mode 600, one line: the PAT, optionally as
# GH_TOKEN=… or GH_PAT=…) and exports that for the one call.
#
# THE KNOBS ARE ROWS (catalog/lanes.d/_lib.gh-app-default.json):
#   GH_APP_DEFAULT             1 = on (default), 0 = every call is today's call
#   GH_APP_DEFAULT_OWNERS      comma list of owners the App is installed on
#                              (default example-org); anything else keeps its PAT
#   GH_APP_DEFAULT_MIN_LIFE_S  life a cached token must still have (default 600)
#   GH_APP_DEFAULT_MINT_TIMEOUT_S  longest wait for one mint (default 15)
#   GH_APP_DEFAULT_FAIL_TTL_S  after a failed mint, seconds that repo skips the
#                              mint (default 60; see the negative cache below)
# Resolved through lib_env_apply at most once a minute per box into
# state/gh-app-default.knobs, because this runs in front of every gh call a
# lane makes and bin/lib/lane-gate.sh is a jq pass over the registry. A
# resolve that fails keeps the code defaults. flags/gh-app-default-off (or the
# `switch.gh-app-default-off` settings row) is the no-DB kill switch;
# flags/gh-app-tokens-off and GH_APP_TOKENS=0 still stop every mint inside
# bin/gh-token.sh.
#
# NO TOKEN VALUE IS EVER PRINTED EXCEPT ON STDOUT OF gh_app_default_token, and
# nothing here writes a log line.
[ -n "${_GHAD_LOADED:-}" ] && return 0
_GHAD_LOADED=1

_ghad_h() { printf '%s' "${HARNESS:-/root/harness}"; }
# BH-4080: the owner default is HARNESS_GH_OWNER (the owner half of
# HARNESS_REPO), from the deployment defaults home beside this file. Soft: with
# it missing the owner list is empty, no call is aimed at an App owner, and every
# call keeps its PAT, which is the behaviour before C2.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-${BASH_SOURCE[0]%/*}/deployment.sh}" 2>/dev/null || :

_ghad_env_dir() {
  local h; h=$(_ghad_h)
  if [ -n "${HARNESS_ENV_DIR:-}" ]; then printf '%s' "$HARNESS_ENV_DIR"; return 0; fi
  if [ -d "$h/env" ] && [ ! -L "$h/env" ]; then printf '%s' "$h/env"; return 0; fi
  if [ -d "${ETC_HARNESS_ENV:-/etc/harness/env}" ]; then printf '%s' "${ETC_HARNESS_ENV:-/etc/harness/env}"; return 0; fi
  printf '%s' "$h/env"
}

# _ghad_norm <owner/repo[/anything]> — prints owner/repo, rc 1 for anything that
# is not two clean path segments. `.git` and a trailing path are dropped.
_ghad_norm() {
  local s="${1:-}" o r
  s="${s%%[?#]*}"
  o="${s%%/*}"; r="${s#*/}"
  [ "$o" != "$s" ] || return 1
  r="${r%%/*}"; r="${r%.git}"
  [[ "$o" =~ ^[A-Za-z0-9_.-]+$ ]] && [[ "$r" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  printf '%s/%s' "$o" "$r"
}

# _ghad_cwd — the owner/repo of the working directory's origin, the repo gh
# itself would pick for a repo-scoped command with no -R.
_ghad_cwd() {
  local u
  u=$(git config --get remote.origin.url 2>/dev/null) || return 1
  case "$u" in
    https://github.com/*) u="${u#https://github.com/}" ;;
    https://*@github.com/*) u="${u#https://*@github.com/}" ;;
    git@github.com:*) u="${u#git@github.com:}" ;;
    ssh://git@github.com/*) u="${u#ssh://git@github.com/}" ;;
    *) return 1 ;;
  esac
  _ghad_norm "$u"
}

gh_app_default_slug() {
  local sub="${1:-}" a prev="" s="" own="" nam="" re
  [ -n "$sub" ] || return 1
  # 1. What gh itself is told: -R/--repo, then GH_REPO.
  for a in "$@"; do
    case "$prev" in -R|--repo) s="$a"; break ;; esac
    case "$a" in --repo=*) s="${a#--repo=}"; break ;; esac
    prev="$a"
  done
  [ -n "$s" ] || s="${GH_REPO:-}"
  if [ -n "$s" ]; then
    s="${s#https://}"; s="${s#github.com/}"
    _ghad_norm "$s"; return $?
  fi
  # 2. An argument that IS a repo address. Anchored prefixes only, and never the
  #    value of a text flag: a PR body that starts with another repo's URL must
  #    not decide which repo the token can see.
  prev=""
  for a in "$@"; do
    case "$prev" in -b|--body|-t|--title|-m|--message|-F|--body-file|--subject|--notes|-n) prev="$a"; continue ;; esac
    prev="$a"
    case "$a" in
      https://api.github.com/repos/*) _ghad_norm "${a#https://api.github.com/repos/}" && return 0 ;;
      https://github.com/*)           _ghad_norm "${a#https://github.com/}" && return 0 ;;
      /repos/*|repos/*)               a="${a#/}"; _ghad_norm "${a#repos/}" && return 0 ;;
    esac
  done
  # 3. GraphQL: -f owner=… -f name=… (or repo=…), or repository(owner:"…",name:"…").
  if [ "$sub" = api ]; then
    re='repository\([[:space:]]*owner:[[:space:]]*"([A-Za-z0-9_.-]+)"[[:space:]]*,[[:space:]]*name:[[:space:]]*"([A-Za-z0-9_.-]+)"'
    for a in "$@"; do
      case "$a" in
        owner=*) own="${a#owner=}" ;;
        name=*|repo=*) nam="${a#*=}" ;;
        query=*) [[ "$a" =~ $re ]] && { own="${BASH_REMATCH[1]}"; nam="${BASH_REMATCH[2]}"; } ;;
      esac
    done
    if [ -n "$own" ] && [ -n "$nam" ]; then _ghad_norm "$own/$nam"; return $?; fi
  fi
  # 4. `gh repo <verb> owner/repo`.
  if [ "$sub" = repo ]; then
    case "${3:-}" in [!-]*/*) _ghad_norm "$3" && return 0 ;; esac
  fi
  # 5. The working directory's origin — gh's own default for these commands,
  #    and what `{owner}/{repo}` in an api path expands to.
  case "$sub" in
    pr|issue|run|workflow|release|label|cache|secret|variable|ruleset|browse|repo) _ghad_cwd; return $? ;;
    api) case "$*" in *'{owner}'*|*'{repo}'*) _ghad_cwd; return $? ;; esac ;;
  esac
  return 1
}

# _ghad_knobs — sets _GHAD_ON, _GHAD_OWNERS, _GHAD_MIN_LIFE, _GHAD_MINT_TIMEOUT
# and _GHAD_FAIL_TTL (see the header).
_ghad_knobs() {
  local h f now at on ow ml mt ft ae v
  h=$(_ghad_h); f="$h/state/gh-app-default.knobs"
  now=$(date -u +%s 2>/dev/null) || now=0
  _GHAD_ON=1; _GHAD_OWNERS=${HARNESS_GH_OWNER:-}; _GHAD_MIN_LIFE=600; _GHAD_MINT_TIMEOUT=15; _GHAD_FAIL_TTL=60; _GHAD_ALERT_EVERY=3600
  if [ -r "$f" ] && read -r at on ow ml mt ft ae < "$f" 2>/dev/null \
     && [[ "${at:-}" =~ ^[0-9]+$ ]] && [ $((now - at)) -lt 60 ] && [ $((now - at)) -ge 0 ] && [ -n "${ae:-}" ]; then
    :
  else
    on=""; ow=""; ml=""; mt=""; ft=""; ae=""
    if [ -r "$h/bin/lib/lane-gate.sh" ]; then
      v=$(
        # shellcheck source=bin/lib/lane-gate.sh
        { . "$h/bin/lib/lane-gate.sh" && command -v lib_env_apply && lib_env_apply gh-app-default; } >/dev/null 2>&1
        printf '%s %s %s %s %s %s' "${GH_APP_DEFAULT:-1}" "${GH_APP_DEFAULT_OWNERS:-${HARNESS_GH_OWNER:-}}" "${GH_APP_DEFAULT_MIN_LIFE_S:-600}" \
          "${GH_APP_DEFAULT_MINT_TIMEOUT_S:-15}" "${GH_APP_DEFAULT_FAIL_TTL_S:-60}" "${GH_APP_DEFAULT_ALERT_EVERY_S:-3600}"
      ) 2>/dev/null || v=""
      read -r on ow ml mt ft ae <<<"$v"
    fi
    [ -n "$on" ] || on="${GH_APP_DEFAULT:-1}"
    [ -n "$ow" ] || ow="${GH_APP_DEFAULT_OWNERS:-${HARNESS_GH_OWNER:-}}"
    [ -n "$ml" ] || ml="${GH_APP_DEFAULT_MIN_LIFE_S:-600}"
    [ -n "$mt" ] || mt="${GH_APP_DEFAULT_MINT_TIMEOUT_S:-15}"
    [ -n "$ft" ] || ft="${GH_APP_DEFAULT_FAIL_TTL_S:-60}"
    [ -n "$ae" ] || ae="${GH_APP_DEFAULT_ALERT_EVERY_S:-3600}"
    { mkdir -p "${f%/*}" && printf '%s %s %s %s %s %s %s\n' "$now" "$on" "$ow" "$ml" "$mt" "$ft" "$ae" > "$f.$$" && mv -f "$f.$$" "$f"; } >/dev/null 2>&1
    rm -f "$f.$$" 2>/dev/null
  fi
  case "${on:-}" in 0|1) _GHAD_ON=$on ;; esac
  [[ "${ow:-}" =~ ^[A-Za-z0-9_.,-]+$ ]] && _GHAD_OWNERS=$ow
  [[ "${ml:-}" =~ ^[0-9]+$ ]] && _GHAD_MIN_LIFE=$ml
  [[ "${mt:-}" =~ ^[1-9][0-9]*$ ]] && _GHAD_MINT_TIMEOUT=$mt
  [[ "${ft:-}" =~ ^[0-9]+$ ]] && _GHAD_FAIL_TTL=$ft
  [[ "${ae:-}" =~ ^[0-9]+$ ]] && _GHAD_ALERT_EVERY=$ae
  return 0
}

# THE NEGATIVE CACHE (review of #2231). This lib runs in front of every cron gh
# call, so a GitHub that hangs or refuses the mint must cost ONE bounded wait
# (GH_APP_DEFAULT_MINT_TIMEOUT_S, and bin/gh-token.sh's own curls carry -m 10)
# and then nothing: a per-slug stamp in state/gh-app-default.fail/ holding the
# failure's epoch sends every call for that repo straight to today's credential
# for GH_APP_DEFAULT_FAIL_TTL_S seconds. 0 = no negative cache.
_ghad_fail_file() { printf '%s/state/gh-app-default.fail/%s' "$(_ghad_h)" "$(printf '%s' "${1//\//-}" | tr -c 'A-Za-z0-9._-' '_')"; }
_ghad_failed_recently() { # <slug> — rc 0 inside the failure window
  local f at now
  [ "${_GHAD_FAIL_TTL:-0}" -gt 0 ] || return 1
  f=$(_ghad_fail_file "$1"); [ -r "$f" ] || return 1
  at=$(head -c 20 "$f" 2>/dev/null | tr -dc '0-9'); [ -n "$at" ] || return 1
  now=$(date -u +%s 2>/dev/null) || return 1
  [ $((now - at)) -ge 0 ] && [ $((now - at)) -lt "$_GHAD_FAIL_TTL" ]
}
_ghad_mark_failed() { # <slug>
  local f; f=$(_ghad_fail_file "$1")
  { mkdir -p "${f%/*}" && date -u +%s > "$f.$$" && mv -f "$f.$$" "$f"; } >/dev/null 2>&1
  rm -f "$f.$$" 2>/dev/null
  gh_app_default_alert "$1" gh-app-default "APP MINT FAILED for $1 on $(_ghad_host): gh calls for this repo fall back to the keyring PAT (or run with no identity once the keyring is logged out) until a mint succeeds. Check env/github-app.env and its key, the App's installation on ${1%%/*}, and flags/gh-app-tokens-off."
  return 0
}

# A FALLBACK TO THE PAT IS LOUD (lead review of #2231). Every caller drops
# gh-token.sh's stderr, so without this an expired App key, an uninstalled repo
# or a kill switch left on would put the fleet back on the operator's PAT with no signal
# but the ledger's pat-default column. One ALERTS.log line per <source, slug> per
# GH_APP_DEFAULT_ALERT_EVERY_S (default 3600; 0 = every new failure stamp).
# ALERTS.log is re-beaten by poll-commands.sh and bin/lib/alert-state.sh's
# shipped severity rules route both sentences to `warn`: the batched digest,
# never a page of their own. Never a token value, only the slug.
_ghad_host() { hostname 2>/dev/null || uname -n 2>/dev/null || echo box; }
gh_app_default_alert() { # <slug> <source> <text>
  local slug="$1" src="$2" text="$3" h d f at now
  h=$(_ghad_h)
  [ -n "${_GHAD_ALERT_EVERY:-}" ] || _ghad_knobs
  d="$h/state/gh-app-default.alerted"
  f="$d/$src-$(printf '%s' "${slug//\//-}" | tr -c 'A-Za-z0-9._-' '_')"
  now=$(date -u +%s 2>/dev/null) || return 0
  if [ -r "$f" ]; then
    at=$(head -c 20 "$f" 2>/dev/null | tr -dc '0-9')
    [ -n "$at" ] && [ $((now - at)) -ge 0 ] && [ $((now - at)) -lt "${_GHAD_ALERT_EVERY:-3600}" ] && return 0
  fi
  { mkdir -p "$d" "$h/logs" && printf '%s\n' "$now" > "$f" \
    && printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$src" "$text" >> "$h/logs/ALERTS.log"; } >/dev/null 2>&1
  return 0
}

gh_app_default_token() {
  local slug="${1:-}" h henv owner tok o
  [ -z "${GH_LEDGER_NO_APP:-}" ] || return 1
  [ "${GH_USE_PAT:-0}" != 1 ] || return 1
  case "$slug" in */*) ;; *) return 1 ;; esac
  h=$(_ghad_h)
  # lane-switch.sh loads on the first read, not when this lib is sourced.
  command -v lane_switch >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }
  ! HARNESS="$h" lane_switch gh-app-default-off || return 1
  [ -x "$h/bin/gh-token.sh" ] || return 1
  # An unarmed box costs nothing: no env/github-app.env, no fork.
  henv=$(_ghad_env_dir)
  [ -r "$henv/github-app.env" ] || return 1
  _ghad_knobs
  [ "$_GHAD_ON" = 1 ] || return 1
  owner=$(printf '%s' "${slug%%/*}" | tr '[:upper:]' '[:lower:]')
  for o in ${_GHAD_OWNERS//,/ }; do
    [ "$(printf '%s' "$o" | tr '[:upper:]' '[:lower:]')" = "$owner" ] || continue
    _ghad_failed_recently "$slug" && return 1
    if command -v timeout >/dev/null 2>&1; then
      tok=$(GH_LEDGER_NO_APP=1 timeout -k 2 "$_GHAD_MINT_TIMEOUT" "$h/bin/gh-token.sh" --min-life "$_GHAD_MIN_LIFE" "$slug" 2>/dev/null) || tok=""
    else
      tok=$(GH_LEDGER_NO_APP=1 "$h/bin/gh-token.sh" --min-life "$_GHAD_MIN_LIFE" "$slug" 2>/dev/null) || tok=""
    fi
    case "$tok" in ghs_*) printf '%s' "$tok"; return 0 ;; esac
    _ghad_mark_failed "$slug"
    return 1
  done
  return 1
}

gh_pat_from_file() {
  local f l
  f="$(_ghad_env_dir)/gh-pat"
  [ -r "$f" ] || return 1
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in ''|'#'*) continue ;; esac
    l="${l#export }"; l="${l#GH_TOKEN=}"; l="${l#GH_PAT=}"
    l="${l//\"/}"; l="${l//\'/}"; l="${l//[[:space:]]/}"
    [ -n "$l" ] || continue
    printf '%s' "$l"; return 0
  done < "$f"
  return 1
}

# gh_default_token_for_path <api path> — the token gh_rest should put on this
# one call when its caller holds none: the App for a repos/<owner>/<repo> path,
# env/gh-pat under GH_USE_PAT=1. rc 1 = leave the call as it is.
gh_default_token_for_path() {
  local slug
  [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ] || return 1
  if [ "${GH_USE_PAT:-0}" = 1 ]; then gh_pat_from_file; return $?; fi
  slug=$(gh_app_default_slug api "${1:-}") || return 1
  gh_app_default_token "$slug"
}

gh_app_default_export() {
  local slug tok
  [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ] || return 1
  if [ "${GH_USE_PAT:-0}" = 1 ]; then
    tok=$(gh_pat_from_file) || return 1
    export GH_TOKEN="$tok"; return 0
  fi
  slug=$(gh_app_default_slug "$@") || return 1
  tok=$(gh_app_default_token "$slug") || return 1
  export GH_TOKEN="$tok"
  return 0
}
