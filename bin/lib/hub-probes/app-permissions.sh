#!/bin/bash
# shellcheck shell=bash
# bin/lib/hub-probes/app-permissions.sh — BH-3449 (BH-3434.2): what does the
# GitHub App <slug> declare it may do? Sourced by common.sh's hp_run.
#
# hp_probe_app_permissions <app-slug>
#   GET apps/<slug> under the caller's own identity (the endpoint is public).
#   PASS (rc 0): a 2xx whose .permissions is an object; prints one `key=value`
#   line per permission (an empty object prints none). A 2xx without that
#   object → `FAIL no-permissions`; 404 → `HTTP 404` + `FAIL not-found`; rc 75 →
#   `HTTP <code>` + `FAIL unverifiable`. HP_HTTP_STATUS is the read's status.
command -v gh_rest >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../gh-rest.sh"

hp_probe_app_permissions() {
  local tmp rc=0
  tmp=$(mktemp "${TMPDIR:-/tmp}/hp-perms.XXXXXX") || { echo "FAIL unverifiable"; HP_HTTP_STATUS=000; return 1; }
  gh_rest GET "apps/$1" > "$tmp" || rc=$?
  HP_HTTP_STATUS=${GH_REST_STATUS:-000}
  case "$rc" in
    0) ;;
    44) rm -f "$tmp"; echo "HTTP ${GH_REST_STATUS:-000}"; echo "FAIL not-found"; return 1 ;;
    *) rm -f "$tmp"; echo "HTTP ${GH_REST_STATUS:-000}"; echo "FAIL unverifiable"; return 1 ;;
  esac
  if ! jq -e '.permissions | type == "object"' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; echo "FAIL no-permissions"; return 1
  fi
  jq -r '.permissions | to_entries[] | "\(.key)=\(.value)"' "$tmp"
  rm -f "$tmp"
  return 0
}
