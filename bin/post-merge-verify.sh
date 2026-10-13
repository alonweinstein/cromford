#!/bin/bash
# gh-identity: app-token
# post-merge-verify.sh <project> --target <t> --merged <sha> --served <sha|"">
#                      [--slug <owner/repo>] [--log <file>]
# BH-3690: after a merge deploys, does prod serve it? The contract every
# deploying lane calls with the sha it merged and the sha prod reports.
#   deploy.<project>.kind=none   one SKIP line, before any gh call or ledger write
#   served == merged (or prefix) match: ledger verified, one log line, silent
#   otherwise, with --slug       gh compare merged...served; ahead|identical is a
#                                match, behind|diverged a mismatch (one page, one
#                                ticket), anything else unreadable (never paged)
# The judge and the side effects are bin/lib/post-merge-verify.sh.
# ALWAYS exits 0: a verifier that fails never changes its caller's verdict
# (bin/deploy-verify.sh's rc is the deploy verdict bin/deploy-request.sh reads).
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"; export HARNESS
PROJECT="${1:-}"; [ $# -gt 0 ] && shift
TARGET=""; MERGED=""; SERVED=""; SLUG=""; LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:-}"; shift 2 ;;
    --merged) MERGED="${2:-}"; shift 2 ;;
    --served) SERVED="${2:-}"; shift 2 ;;
    --slug)   SLUG="${2:-}"; shift 2 ;;
    --log)    LOG="${2:-}"; shift 2 ;;
    *) echo "post-merge-verify: unknown argument '$1'" >&2; exit 0 ;;
  esac
done
if [ -z "$PROJECT" ] || [ -z "$TARGET" ] || [ -z "$MERGED" ]; then
  echo "usage: post-merge-verify.sh <project> --target <t> --merged <sha> --served <sha|\"\"> [--slug o/r] [--log f]" >&2
  exit 0
fi
[ -n "$LOG" ] || LOG="$HARNESS/logs/post-merge-verify.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

# shellcheck source=bin/lib/post-merge-verify.sh
. "$HARNESS/bin/lib/post-merge-verify.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/post-merge-verify.sh" 2>/dev/null || {
  echo "$(STAMP) [$PROJECT] post-merge-verify NOT RUN: bin/lib/post-merge-verify.sh missing" >> "$LOG"; exit 0; }
# shellcheck source=bin/lib/deploy-kind.sh
. "$HARNESS/bin/lib/deploy-kind.sh" 2>/dev/null || deploy_kind() { return 2; }

# A project that deploys nothing on a merge has nothing to verify. An outage
# (rc 1) or no row (rc 2) is never a skip (BH-3387's rule).
KIND=$(deploy_kind "$PROJECT" 2>/dev/null) && [ "$KIND" = none ] && {
  echo "$(STAMP) [$PROJECT] post-merge-verify SKIP (deploy.kind=none): ${TARGET} ${MERGED:0:8}" >> "$LOG"; exit 0; }

CMP=""; NOTE=""
if [ "$(pmv_judge "$MERGED" "$SERVED" "")" = unreadable ] && [[ "$(pmv_norm "$SERVED")" =~ ^[0-9a-f]{7,40}$ ]]; then
  # The shas differ: ask GitHub whether the served commit contains the merge.
  if [ -n "$SLUG" ]; then
    CMP=$(
      # shellcheck source=bin/lib/gh-app-auth.sh
      [ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh" 2>/dev/null
      command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$SLUG" >/dev/null 2>&1 || true; }
      timeout 30 gh api "repos/$SLUG/compare/$(pmv_norm "$MERGED")...$(pmv_norm "$SERVED")" -q .status 2>/dev/null
    ) || CMP=""
    [ -n "$CMP" ] || NOTE="compare $SLUG unreadable"
  else
    NOTE="no --slug to compare with"
  fi
fi
VERDICT=$(pmv_judge "$MERGED" "$SERVED" "$CMP")
[ "$VERDICT" = unreadable ] && [ -z "$NOTE" ] && [ -n "$SERVED" ] && NOTE="compare said '${CMP}'"
[ "$VERDICT" = unreadable ] && [ -z "$SERVED" ] && NOTE="no served sha"
(
  # The ticket goes to the harness repo, on its own token.
  # shellcheck source=bin/lib/gh-app-auth.sh
  [ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh" 2>/dev/null
  pmv_act "$PROJECT" "$TARGET" "$MERGED" "$SERVED" "$VERDICT" "$LOG" "$NOTE"
) || echo "$(STAMP) [$PROJECT] post-merge-verify NOT RUN: pmv_act refused ($TARGET ${MERGED:0:8})" >> "$LOG"
exit 0
