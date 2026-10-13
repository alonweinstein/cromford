#!/bin/bash
# shellcheck shell=bash
# bin/lib/hub-probes/app-status-write.sh — BH-3449 (BH-3434.2): can the GitHub
# App write a commit status on <repo>@<sha>? Sourced by common.sh's hp_run.
#
# hp_probe_app_status_write <owner/repo> <sha>
#   1. gh_app_only_for <repo>. No installation token → `FAIL app-token-unavailable`,
#      HP_HTTP_STATUS=000, rc 1, and no REST call at all: the PAT never stands in.
#   2. POST repos/<repo>/statuses/<sha> with context `hub-probe`, then
#      gh_app_only_release on every path, so the token covers that one call.
#   3. GET repos/<repo>/commits/<sha>/statuses under the caller's own identity.
#      GitHub lists newest first; the first `hub-probe` entry is the verdict.
#      Prints `state=<state|none>` and `creator.type=<type|none>`.
#   PASS (rc 0) only when that entry is state `success` AND creator.type `Bot`.
#   A 2xx POST alone is never PASS. rc 75 from either call → `HTTP <code>` +
#   `FAIL unverifiable`; a 404 POST → `FAIL post-rejected`; a 404 read →
#   `FAIL not-found`; an unreadable body → `FAIL unparseable`.
command -v gh_rest >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../gh-rest.sh"
command -v gh_app_only_for >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../gh-app-auth.sh"

hp_probe_app_status_write() {
  local repo="$1" sha="$2" tmp rc=0 entry state ctype
  if ! gh_app_only_for "$repo"; then
    echo "FAIL app-token-unavailable"; HP_HTTP_STATUS=000; return 1
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/hp-status.XXXXXX") || { gh_app_only_release; echo "FAIL unverifiable"; HP_HTTP_STATUS=000; return 1; }
  gh_rest POST "repos/$repo/statuses/$sha" -f state=success -f context=hub-probe \
    -f "description=hub probe write check" > "$tmp" || rc=$?
  gh_app_only_release
  if [ "$rc" != 0 ]; then
    rm -f "$tmp"
    HP_HTTP_STATUS=${GH_REST_STATUS:-000}
    echo "HTTP ${GH_REST_STATUS:-000}"
    if [ "$rc" = 44 ]; then echo "FAIL post-rejected"; else echo "FAIL unverifiable"; fi
    return 1
  fi
  rc=0
  gh_rest GET "repos/$repo/commits/$sha/statuses" > "$tmp" || rc=$?
  HP_HTTP_STATUS=${GH_REST_STATUS:-000}
  case "$rc" in
    0) ;;
    44) rm -f "$tmp"; echo "HTTP ${GH_REST_STATUS:-000}"; echo "FAIL not-found"; return 1 ;;
    *) rm -f "$tmp"; echo "HTTP ${GH_REST_STATUS:-000}"; echo "FAIL unverifiable"; return 1 ;;
  esac
  entry=$(jq -c 'if type == "array" then ([.[] | select(.context == "hub-probe")][0] // {}) else error end' "$tmp" 2>/dev/null)
  rm -f "$tmp"
  if [ -z "$entry" ]; then echo "FAIL unparseable"; return 1; fi
  state=$(printf '%s' "$entry" | jq -r '.state // "none" | tostring')
  ctype=$(printf '%s' "$entry" | jq -r '.creator.type? // "none" | tostring')
  echo "state=$state"
  echo "creator.type=$ctype"
  [ "$state" = success ] && [ "$ctype" = Bot ] && return 0
  return 1
}
