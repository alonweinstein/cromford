#!/bin/bash
# Remediation handler — akey health:stalepr:<project>
#
# pipeline-health check 7 lists harness PRs open >12h. The list is built from a
# `gh pr list --state open` snapshot, so by the time a human reads the page the
# PRs may already be closed or merged — project-3 #229 paged as aging work while its
# work had already landed as #247 (2026-08-25).
#
# Suppress ONLY when EVERY PR the line names is CLOSED or MERGED on GitHub. One
# still-open PR, one unreadable answer, or no PR reference at all -> non-zero,
# and the alert pages exactly as today. READ-ONLY: `gh pr view` only.
set -uo pipefail
H="${HARNESS:-/root/harness}"
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"
AKEY="${1:-}"; LINE="${2:-}"

command -v gh >/dev/null 2>&1 || { echo "gh unavailable"; exit 1; }

PROJ=$(cut -d: -f3 <<<"$AKEY")
SLUG=""
[ -n "$PROJ" ] && SLUG=$("$H/bin/fleet-conf.sh" "$PROJ" repo 2>/dev/null || true)

# Full URLs win (they carry their own repo); bare #123 refs need the project's
# slug, so without one there is nothing to look up.
REFS=$(grep -oE "https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+" <<<"$LINE" || true)
if [ -z "$REFS" ] && [ -n "$SLUG" ]; then
  REFS=$(grep -oE "#[0-9]+" <<<"$LINE" | tr -d '#' || true)
fi
[ -n "$REFS" ] || { echo "no PR reference in line"; exit 1; }

SETTLED=""; OPEN=""
while read -r R; do
  [ -n "$R" ] || continue
  # #425: a full URL carries its own repo, a bare #123 uses the project's slug.
  case "$R" in https://*) command -v gh_auth_for_url >/dev/null 2>&1 && gh_auth_for_url "$R" || true ;; *) command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true ;; esac
  case "$R" in
    https://*) ST=$(gh pr view "$R" --json state,mergedAt -q .state 2>/dev/null || true) ;;
    *)         ST=$(gh pr view "$R" -R "$SLUG" --json state,mergedAt -q .state 2>/dev/null || true) ;;
  esac
  case "$ST" in
    MERGED|CLOSED) SETTLED="$SETTLED #$R=$ST" ;;
    *)             OPEN="$OPEN #$R=${ST:-unreadable}" ;;
  esac
done <<<"$REFS"
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset

if [ -n "$OPEN" ]; then
  echo "still open or unreadable:$OPEN — alerting"; exit 1
fi
echo "every referenced PR is settled:$SETTLED"
exit 0
