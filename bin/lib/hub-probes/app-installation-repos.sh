#!/bin/bash
# shellcheck shell=bash
# bin/lib/hub-probes/app-installation-repos.sh — BH-3449 (BH-3434.2): which
# repositories does the App's installation token see? Sourced by common.sh's hp_run.
#
# hp_probe_app_installation_repos
#   Mints through gh_app_only_for for HARNESS_REPO when that is an owner/repo
#   slug, else bin/lib/deployment.sh's HARNESS_REPO default. bin/gh-token.sh scopes that token to the
#   one repo, so the list is what GitHub returns for it, not a claim about the
#   whole installation. No installation token → `FAIL app-token-unavailable`,
#   HP_HTTP_STATUS=000, rc 1, no REST call.
#   GET installation/repositories?per_page=100, then gh_app_only_release on
#   every path. PASS (rc 0): one full_name line per repo, then
#   `total_count=<n>`, and `incomplete: <listed> of <total>` when GitHub holds
#   more than the page listed (D12). 404 → `FAIL not-found`; rc 75 →
#   `HTTP <code>` + `FAIL unverifiable`; a body without the array and the
#   number → `FAIL unparseable`.
command -v gh_rest >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../gh-rest.sh"
command -v gh_app_only_for >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../gh-app-auth.sh"

hp_probe_app_installation_repos() {
  local repo tmp rc=0 listed total
  # bin/fly-sync-harness.sh reads HARNESS_REPO as a checkout PATH; only a slug
  # counts here. Otherwise the documented default (BH-4080), read with the
  # path spelling out of the way.
  if [[ "${HARNESS_REPO:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then repo=$HARNESS_REPO
  else repo=$(unset HARNESS_REPO; . "${HARNESS_DEPLOYMENT_FILE-${BASH_SOURCE[0]%/*}/../deployment.sh}" && printf %s "$HARNESS_REPO"); fi
  if ! gh_app_only_for "$repo"; then
    echo "FAIL app-token-unavailable"; HP_HTTP_STATUS=000; return 1
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/hp-repos.XXXXXX") || { gh_app_only_release; echo "FAIL unverifiable"; HP_HTTP_STATUS=000; return 1; }
  gh_rest GET "installation/repositories?per_page=100" > "$tmp" || rc=$?
  gh_app_only_release
  HP_HTTP_STATUS=${GH_REST_STATUS:-000}
  case "$rc" in
    0) ;;
    44) rm -f "$tmp"; echo "HTTP ${GH_REST_STATUS:-000}"; echo "FAIL not-found"; return 1 ;;
    *) rm -f "$tmp"; echo "HTTP ${GH_REST_STATUS:-000}"; echo "FAIL unverifiable"; return 1 ;;
  esac
  if ! jq -e '(.repositories | type == "array") and (.total_count | type == "number")' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; echo "FAIL unparseable"; return 1
  fi
  jq -r '.repositories[].full_name' "$tmp"
  listed=$(jq -r '.repositories | length' "$tmp")
  total=$(jq -r '.total_count' "$tmp")
  rm -f "$tmp"
  echo "total_count=$total"
  [ "$total" -gt "$listed" ] && echo "incomplete: $listed of $total"
  return 0
}
