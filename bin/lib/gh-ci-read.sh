#!/bin/bash
# shellcheck disable=SC2034  # GH_CI_READ_TOKEN is read by the sourcing script
# bin/lib/gh-ci-read.sh — one Actions read that survives a token which cannot see
# Actions. Sourced, never executed.
#
#   gh_ci_api <owner/repo> <gh api args...>
#
# THE INCIDENT (collaborator-1's PRs, 2026-09-14). Every box-side CI read goes through
# `gh api repos/<slug>/actions/runs?head_sha=...` because the checks API has been
# 403 for our PATs for months. On the project-2 box the fine-grained PAT answers
# 403 "Resource not accessible by personal access token" on actions/runs TOO, and on
# check-runs, on commits/status, and on the statusCheckRollup GraphQL. So
# bin/review-prs.sh read "CI status unavailable" on every tick, deferred the
# re-review forever, alerted once at 12h and then went quiet. example-org/
# project-2 #294/#488/#489 sat approved-but-unmerged for days behind that
# one unreadable endpoint.
#
# A GitHub App installation token minted by bin/gh-token.sh reads the same
# endpoint fine (verified on the hub, 2026-09-14). So the read is no longer one
# credential's opinion: the default token answers first — byte for byte what this
# fleet has always done — and ONLY when it fails does the helper retry once with
# a READ-ONLY App token (`gh-token.sh --read <slug>`, which deliberately ignores
# the write-side kill switches; see that script's header).
#
# WHAT IT NEVER DOES. It never retries a SUCCESSFUL read: an empty run list is a
# real answer (a head GitHub has not created runs for yet) and the callers all
# fail closed on it already. It never retries with a token identical to the one
# that just failed — an unarmed box gets the PAT back from gh-token.sh, and
# spending a second 403 on it would be pure latency. And no token value ever
# reaches a log: the helper logs which CREDENTIAL answered, never the credential.
#
# IT IS NOT ONLY ACTIONS ANY MORE (BH-872). The same PAT that cannot see
# actions/runs cannot see pulls/N/reviews either, and bin/review-prs.sh now reads
# that endpoint as its dedupe ledger — a read it must not lose, because losing it
# defers every review on that box. Callers reading something other than
# actions/runs name it in GH_CI_READ_WHAT so the fallback line says which
# endpoint the default token refused; unset, it reads "actions/runs" exactly as
# before.
#
# After a call:
#   stdout                the API answer, unchanged
#   rc 0                  one of the two reads worked
#   rc non-zero           BOTH failed — the caller's "CI status unavailable" path
#   $GH_CI_READ_TOKEN     default | app-read | pat | none  (which token answered;
#                         `pat` is C2's last rung, see the end of gh_ci_api)
#
# WHICH CREDENTIAL ANSWERED IS WRITTEN, NOT RETURNED. Every caller reads this
# through `X=$(gh_ci_api ... | jq ...)`, and a command substitution is a
# subshell: a variable this function sets there dies with it. So the fallback
# writes ONE line, to $GH_CI_READ_LOG if the caller named one (review-prs.sh
# points it at logs/pr-reviews.log, with $GH_CI_READ_TAG carrying the PR it is
# about) and to logs/gh-ci-read.log otherwise. Only the FALLBACK is logged: the
# default token answering is the status quo and a line per read for it is noise.
[ -n "${GH_CI_READ_LIB:-}" ] && return 0 2>/dev/null
GH_CI_READ_LIB=1
GH_CI_READ_TOKEN=none

# Resolved at call time, not at source time: a caller may set HARNESS after it
# sources this file, and tests point HARNESS at a scratch tree.
_ghci_home() { printf '%s' "${HARNESS:-/root/harness}"; }

_ghci_note() { # _ghci_note <owner/repo>
  local f
  f="${GH_CI_READ_LOG:-$(_ghci_home)/logs/gh-ci-read.log}"
  mkdir -p "$(dirname "$f")" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') ${GH_CI_READ_TAG:+$GH_CI_READ_TAG }CI read answered by the read-only App token (the default token refused ${GH_CI_READ_WHAT:-actions/runs} on $1)" >> "$f" 2>/dev/null
  return 0
}

gh_ci_api() { # gh_ci_api <owner/repo> <gh api args...>
  local slug="${1:-}"; shift
  local out rc tok home
  GH_CI_READ_TOKEN=none
  out=$(gh api "$@" 2>/dev/null); rc=$?
  if [ "$rc" = 0 ]; then
    GH_CI_READ_TOKEN=default
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
  fi
  case "$slug" in */*) ;; *) return "$rc" ;; esac
  home=$(_ghci_home)
  [ -x "$home/bin/gh-token.sh" ] || return "$rc"
  tok=$("$home/bin/gh-token.sh" --read "$slug" 2>/dev/null) || return "$rc"
  [ -n "$tok" ] || return "$rc"
  # An unarmed box answers with the very PAT that just 403'd — spending a second
  # request on it is pure latency. (A box authenticating out of gh's keyring
  # instead of the environment cannot be compared this way; it pays one wasted
  # request and lands on the same "both refused" answer, which is today's.)
  case "$tok" in "${GH_TOKEN:-}"|"${GITHUB_TOKEN:-}") return "$rc" ;; esac
  out=$(GH_TOKEN="$tok" GITHUB_TOKEN="$tok" gh api "$@" 2>/dev/null); rc=$?
  if [ "$rc" = 0 ]; then
    GH_CI_READ_TOKEN=app-read
    _ghci_note "$slug"
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
  fi
  # C2 (2026-09-24): with no token of its own, the FIRST read above already went
  # out on the App — bin/gh-ledger/gh makes the installation token the default
  # identity — so the retry was the same credential twice. The PAT is the one
  # opinion not yet asked: once, through the shim's GH_USE_PAT escape (env/gh-pat
  # when the keyring is logged out). A caller that chose a token never gets here,
  # and neither does an unarmed box: its retry token was already the PAT.
  if [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ] && [ "${GH_USE_PAT:-0}" != 1 ] \
     && case "$tok" in ghs_*) true ;; *) false ;; esac; then
    out=$(GH_USE_PAT=1 gh api "$@" 2>/dev/null); rc=$?
    if [ "$rc" = 0 ]; then
      GH_CI_READ_TOKEN=pat
      # Loud, once per slug per hour (lead review of #2231): the PAT answering
      # here means the App could not read this repo's CI.
      { command -v gh_app_default_alert >/dev/null 2>&1 || . "$home/bin/lib/gh-app-default.sh"; } 2>/dev/null
      command -v gh_app_default_alert >/dev/null 2>&1 && gh_app_default_alert "$slug" gh-ci-read \
        "PAT RUNG for $slug on $(hostname 2>/dev/null || echo box): the App installation token could not read CI (${GH_CI_READ_WHAT:-gh api $1}) and the read was answered by the PAT. Check the App's installation and Actions/Checks read permission on ${slug%%/*}."
      [ -n "$out" ] && printf '%s\n' "$out"
      return 0
    fi
  fi
  GH_CI_READ_TOKEN=none
  return "${rc:-1}"
}
