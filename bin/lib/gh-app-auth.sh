#!/bin/bash
# bin/lib/gh-app-auth.sh — one line for a lane that wants its GitHub calls to run
# on a short-lived, repo-scoped App installation token instead of the fleet's one
# shared PAT. Sourced, never executed.
#
#   gh_auth_for <owner/repo>   exports GH_TOKEN for that repo's installation
#                              token. rc 1 and the ENVIRONMENT IS UNTOUCHED when
#                              this box does not mint App tokens.
#   gh_auth_for_url <url>      the same, for a lane that holds a PR/issue URL
#                              rather than a slug: owner/repo is taken out of
#                              https://github.com/<owner>/<repo>[/...]. rc 1 and
#                              the ENVIRONMENT IS UNTOUCHED for any other shape.
#   gh_auth_reset              puts back the GH_TOKEN the sourcing shell started
#                              with (unsets it if there was none).
#   gh_auth_armed              rc 0 when minting is configured and not killed.
#
#   gh_default_auth_for_slug <owner/repo>   the DEFAULT identity for that repo:
#   gh_default_auth_for_project <project>   App token when we can mint one, the
#                                           PAT when we cannot, and GH_LIMIT_IDENTITY
#                                           set to app:<slug> or pat:<slug> either way.
#   gh_default_auth_reset                   undoes both halves and drops the tag.
#   (the three above are #469; the long note next to them is the why)
#
# WHY (the operator, 2026-09-14). One PAT is one 5000/h REST bucket for every lane on
# every box, which is the wall at 4000 builders, and it is one credential whose
# leak is fleet-wide and permanent. An installation token is per-installation
# rate-limited and dies in an hour. bin/gh-token.sh does the minting and the
# caching; this file is the two lines a caller needs.
#
# THE OFF SWITCH IS THE WHOLE SAFETY ARGUMENT. gh_auth_for returns 1 WITHOUT
# running a single process when env/github-app.env is absent, GH_APP_TOKENS=0, or
# flags/gh-app-tokens-off exists (or the `switch.gh-app-tokens-off` settings row
# is on) — so every caller is written `gh_auth_for "$SLUG"
# || true` and an unarmed box does exactly what it did on 2026-09-13, with no new
# fork, no new file and no new failure mode.
#
# THIS DOES NOT REPLACE bin/lib/gh-repo-token.sh. That file answers "which of our
# PATs can SEE this repo" and pages when none can; it stays the fallback and the
# alert. This one answers "can we avoid spending the shared PAT at all".
#
# SOURCE IT TWICE AND THE SECOND SOURCE DOES NOTHING. bin/merge-conductor.sh
# sources this file and then sources bin/lib/merge-conductor-lib.sh, which
# sources it again; without the guard below the second pass would save the
# ARMED token as "the default" and gh_auth_reset would put the App token back
# instead of the lane's own identity.
[ -n "${_GHAA_LOADED:-}" ] && return 0
_GHAA_LOADED=1
_GHAA_H="${HARNESS:-/root/harness}"
_GHAA_DEFAULT_TOK="${GH_TOKEN:-}"
_GHAA_SET="${GH_TOKEN+x}"

gh_auth_armed() {
  # lane-switch.sh loads on the first read, not when this lib is sourced.
  command -v lane_switch >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }
  HARNESS="$_GHAA_H" lane_switch gh-app-tokens-off && return 1
  [ "${GH_APP_TOKENS:-1}" = 0 ] && return 1
  [ -r "$_GHAA_H/env/github-app.env" ] || return 1
  [ -x "$_GHAA_H/bin/gh-token.sh" ] || return 1
  return 0
}

gh_auth_for() { # gh_auth_for <owner/repo>; rc 1 = env untouched, carry on as today
  local slug="${1:-}" tok
  [ -n "$slug" ] || return 1
  case "$slug" in */*) ;; *) return 1 ;; esac
  gh_auth_armed || return 1
  # gh-token.sh prints the PAT rather than nothing when a mint fails, so an empty
  # answer here is the only case worth refusing.
  tok=$("$_GHAA_H/bin/gh-token.sh" "$slug" 2>/dev/null) || return 1
  [ -n "$tok" ] || return 1
  export GH_TOKEN="$tok"
  return 0
}

# gh_app_only_for <owner/repo> — rc 0 ONLY when GH_TOKEN is now this repo's App
#   INSTALLATION token (ghs_…). gh_auth_for exports whatever gh-token.sh prints,
#   and that is the PAT when a mint fails; a caller that must never act as the
#   PAT (BH-1606: a merge-train PR, which the lead fence would hold as the
#   lead's) asks this instead. rc 1 = not an installation token, act on nothing.
#   THE CALLER'S IDENTITY COMES BACK (#1624 round 3): the token this found is
#   for the one call it guards, so gh_app_only_release puts GH_TOKEN back
#   exactly as it was before this ran (set to the old value, or unset) — call
#   it right after that call. rc 1 has already put it back.
gh_app_only_for() {
  _GHAA_PREV_SET="${GH_TOKEN+x}"; _GHAA_PREV_TOK="${GH_TOKEN:-}"
  if gh_auth_for "${1:-}"; then
    case "${GH_TOKEN:-}" in ghs_*) return 0 ;; esac
  fi
  gh_app_only_release
  return 1
}
gh_app_only_release() {
  if [ -n "${_GHAA_PREV_SET:-}" ]; then export GH_TOKEN="$_GHAA_PREV_TOK"; else unset GH_TOKEN; fi
  return 0
}

# gh_app_premint <owner/repo> <seconds> — ask the minter for an installation
#   token with at least <seconds> left, re-minting a shorter cached one. Nothing
#   is exported; the next gh_auth_for picks the fresh token out of the cache.
#   rc 1 without running a process when this box does not mint (BH-1630).
# gh_app_expires_at <owner/repo> — print the cached installation token's expiry
#   (ISO-8601 UTC). rc 1 and no output when the cache holds none for the repo.
#   Both live here, not in the caller, so a lane that arms the App for one call
#   does not read as converted to the gh-identity ratchet (tests/gh-app-ratchet-test.sh).
gh_app_premint() {
  gh_auth_armed || return 1
  "$_GHAA_H/bin/gh-token.sh" --min-life "${2:-}" "${1:-}" >/dev/null 2>&1
}
gh_app_expires_at() {
  [ -x "$_GHAA_H/bin/gh-token.sh" ] || return 1
  "$_GHAA_H/bin/gh-token.sh" --expires-at "${1:-}" 2>/dev/null
}

gh_auth_for_url() { # gh_auth_for_url <url>; rc 1 = env untouched, carry on as today
  local url="${1:-}" path owner rest repo
  case "$url" in
    https://github.com/*) path="${url#https://github.com/}" ;;
    *) return 1 ;;
  esac
  path="${path%%[?#]*}"
  # BOTH halves are checked BEFORE the slug is rebuilt. On "github.com/owner"
  # the two expansions below would each answer "owner", so a */* test applied
  # after the join can never fail and a half URL would mint for owner/owner.
  case "$path" in */*) ;; *) return 1 ;; esac
  owner="${path%%/*}"; rest="${path#*/}"; repo="${rest%%/*}"
  [ -n "$owner" ] && [ -n "$repo" ] || return 1
  gh_auth_for "$owner/$repo"
}

gh_auth_reset() {
  if [ -n "$_GHAA_SET" ]; then export GH_TOKEN="$_GHAA_DEFAULT_TOK"; else unset GH_TOKEN; fi
  return 0
}

# --- the DEFAULT identity (#469) ----------------------------------------------
# gh_auth_for is "get me an App token if this box mints them". The three
# functions below are "this repo's calls go out on the best identity we have,
# and we write down which one it was":
#
#   gh_default_auth_for_slug <owner/repo>    App token when we can mint one for
#                                            that repo, today's PAT when we
#                                            cannot. rc 1 = not a slug, or no
#                                            token can see the repo.
#   gh_default_auth_for_project <project>    the same, keyed on a fleet.conf row.
#   gh_default_auth_reset                    undo both halves and drop the tag.
#
# THE TAG IS A FACT ABOUT THE TOKEN, NEVER ABOUT A RETURN CODE. bin/gh-token.sh
# prints the PAT rather than failing when a mint does not work, so gh_auth_for
# answers rc 0 with a PAT in your hand on a box whose App is not installed on
# that repo. GH_LIMIT_IDENTITY therefore reads the token itself: only a `ghs_`
# installation token earns `app:<slug>`. bin/lib/gh-limit-logger.sh writes that
# tag down when GitHub refuses a call, and a tag that lied would send us looking
# for headroom in the wrong bucket. So the tag is written LAST, from whatever
# GH_TOKEN holds once the gh_repo_use_token fallback has had its turn — since
# BH-765 that fallback's own ladder can export an App token too.
#
# THE RESET AT THE TOP IS THE OTHER HALF. A lane loops repos in ONE process. A
# token minted for repo A can see nothing else, so if repo B cannot be minted
# for, B must fall back to the PROCESS's own PAT — not to A's installation
# token, which 404s every call and (worse) makes bin/gh-token.sh's own PAT
# fallback hand back A's token again.
#
# THIS FILE DOES NOT SOURCE bin/lib/gh-repo-token.sh. The PAT probe costs one
# `gh api repos/<slug>` per repo and pages when no token can see it; adding it
# here would give that probe to lanes that never had one (bin/reconcile-prs.sh
# runs on every box every 10 minutes). A lane that already sources the probe
# gets it; a lane that does not, does not.
gh_default_auth_for_slug() { # <owner/repo>; rc 1 = not a slug, or no token can see it
  local slug="${1:-}" rc=0
  [ -n "$slug" ] || return 1
  case "$slug" in */*) ;; *) return 1 ;; esac
  gh_auth_reset                     # never carry the previous repo's token into this one
  if gh_auth_for "$slug"; then
    case "${GH_TOKEN:-}" in ghs_*) export GH_LIMIT_IDENTITY="app:$slug"; return 0 ;; esac
  fi
  # The fallback runs BEFORE the tag is written, because since BH-765 its own
  # ladder can export an installation token (bin/lib/gh-repo-token.sh asks the
  # App first). A tag set to pat: above this call would name the wrong bucket
  # for a call that went out on ghs_.
  if command -v gh_repo_use_token >/dev/null 2>&1; then
    gh_repo_use_token "$slug"; rc=$?
  fi
  case "${GH_TOKEN:-}" in
    ghs_*) export GH_LIMIT_IDENTITY="app:$slug" ;;
    *)     export GH_LIMIT_IDENTITY="pat:$slug" ;;
  esac
  return "$rc"
}

gh_default_auth_for_project() { # <fleet.conf project>; rc 1 = no row, or no token
  local project="${1:-}" slug
  [ -n "$project" ] || return 1
  [ -x "$_GHAA_H/bin/fleet-conf.sh" ] || return 1
  slug=$("$_GHAA_H/bin/fleet-conf.sh" "$project" repo 2>/dev/null) || return 1
  [ -n "$slug" ] && [ "$slug" != "-" ] || return 1
  gh_default_auth_for_slug "$slug"
}

gh_limit_identity_label() { # -> app | pat, off the GH_LIMIT_IDENTITY tag
  # this file's own gh_default_auth_for_slug writes. A caller that wants to
  # SAY which credential a call ran on (BH-597 ticket item 2's `github auth:`
  # lines in bin/merge-conductor.sh, bin/merge-sweep.sh, bin/blocked-resolver.sh)
  # asks here rather than reading GH_LIMIT_IDENTITY itself: an env var a lane
  # script reads but never assigns is what tests/lanes-registry-test.sh
  # section 7 treats as an undeclared operator knob, and this one is auth
  # plumbing this file owns, not a knob an operator sets.
  case "${GH_LIMIT_IDENTITY:-}" in app:*) printf 'app' ;; *) printf 'pat' ;; esac
}

gh_default_auth_reset() {
  gh_auth_reset
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
  unset GH_LIMIT_IDENTITY
  return 0
}
