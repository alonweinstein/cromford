#!/bin/bash
# bin/lib/token-health.sh — BH-2644 (BH-2516.0) seam, BH-2646 (BH-2516.2)
# reporter. Sourced, never executed. Defines one function and one constant:
# sourcing reads no file, writes no file and prints nothing.
#
#   token_health_report <kind> <subject> <ok|fail> [expires_at_iso] [error]
#       kind     oauth (subject = the Claude login label) or gh_app
#                (subject = app-<installation id>, or app-unresolved-<owner>
#                when the installation lookup itself failed)
#
# FAIL-OPEN: always rc 0 and never a byte on stdout. It is called from
# gh-token.sh, whose stdout IS the token, and from bin/oauth-refresh.sh, whose
# callers run under set -euo pipefail, so a report must never change what its
# caller prints or whether its caller survives. The only stderr line is local
# misuse (bad kind, empty subject, bad status), and misuse sends nothing.
#
# WHAT IT SENDS: one POST {kind, subject, box, ok, expires_at, error} to
# /api/account-leases/token-health through bin/jobs-client.sh's _jobs_req, with
# JOBS_TIMEOUT=5 (curl -m 5), no retry and no ALERTS line: this is observation,
# and the lanes that depend on the worker already page for an outage. No
# request when TOKEN_HEALTH_REPORT=0, when JOBS_URL is empty (before or after
# the client adopts global.env), or when no jobs-client.sh with its
# lib/jobs/ modules sits beside this lib.
#
# The send runs in a SUBSHELL. jobs-client.sh sets `-uo pipefail` at top level
# and `exit 1`s a shell that lacks its modules; inside ( ... ) neither can reach
# the caller.
#
# The error text is scrubbed before it leaves the box: newlines become spaces,
# any word carrying a token shape (gh[pousr]_, github_pat_, sk-ant-, eyJ) is
# dropped, and what is left is cut to 200 characters.

# The knobs this seam owns, named here so tests/lanes-registry-test.sh can tie
# the catalog/lanes.d/_lib.token-health.json registration to this file.
# token_health_report reads TOKEN_HEALTH_REPORT; TOKEN_HEALTH_WARN_H is the
# shell name of the worker settings row lib.token-health.token_health_warn_h
# and nothing on the box reads it yet.
TOKEN_HEALTH_KNOBS="TOKEN_HEALTH_WARN_H TOKEN_HEALTH_REPORT"

_TH_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

_th_scrub() { # _th_scrub <text> -> scrubbed text on stdout
  local w out="" words
  # read -a, not an unquoted $(...): a word like `*` must never glob.
  read -r -a words <<< "$(printf '%s' "$1" | tr '\n\r\t' '   ')"
  for w in "${words[@]}"; do
    case "$w" in
      *ghp_*|*gho_*|*ghu_*|*ghs_*|*ghr_*|*github_pat_*|*sk-ant-*|*eyJ*) continue ;;
    esac
    out="${out:+$out }$w"
  done
  printf '%s' "${out:0:200}"
}

token_health_report() {
  local kind="${1:-}" subject="${2:-}" status="${3:-}" exp="${4:-}" err="${5:-}"
  case "$kind" in oauth|gh_app) ;; *) echo "token_health_report: bad kind '$kind'" >&2; return 0 ;; esac
  [ -n "$subject" ] || { echo "token_health_report: empty subject" >&2; return 0; }
  case "$status" in ok|fail) ;; *) echo "token_health_report: bad status '$status'" >&2; return 0 ;; esac
  [ "${TOKEN_HEALTH_REPORT:-1}" = 0 ] && return 0
  [ -n "${JOBS_URL+set}" ] && [ -z "$JOBS_URL" ] && return 0
  local client="$_TH_SELF_DIR/../jobs-client.sh"
  [ -r "$client" ] && [ -r "$_TH_SELF_DIR/jobs/req.sh" ] || return 0
  err=$(_th_scrub "$err")
  (
    # shellcheck source=/dev/null
    . "$client"
    [ -n "${JOBS_URL:-}" ] || exit 0
    command -v _jobs_req >/dev/null 2>&1 || exit 0
    JOBS_TIMEOUT=5 JOBS_RETRIES=0 JOBS_ALERT=0
    body=$(jq -nc --arg k "$kind" --arg s "$subject" --arg b "$JOBS_BOX" --arg st "$status" \
      --arg e "$exp" --arg r "$err" \
      '{kind:$k, subject:$s, box:$b, ok:($st=="ok"),
        expires_at:(if $e=="" then null else $e end),
        error:(if $r=="" then null else $r end)}') || exit 0
    _jobs_req POST /api/account-leases/token-health "$body"
  ) >/dev/null 2>&1 || true
  return 0
}
