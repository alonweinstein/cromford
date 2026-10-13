#!/bin/bash
# bin/alert-verify/pr-url-reconcile-verdict.sh — the verify script of the `pr-url-reconcile-verdict` row of
# alert_family_scripts (BH-2577). Protocol: the header of
# bin/triage-family-scripts.sh; shared reads: bin/lib/alert-verify.sh.
#
# bin/pr-url-reconcile.sh's `<pr-url> owes a verdict and nothing can produce one`
# page. At most two reads: GET repos/<slug>/pulls/<n>, then, only if it is
# open, vd_standing for its CURRENT head (bin/lib/verdicts.sh). Closed clears
# it (no verdict owed), a standing verdict clears it, none still reproduces,
# and an unverifiable verdict or PR read is doubt, 404 included.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
LIB="$HARNESS/bin/lib"
[ -r "$LIB/alert-verify.sh" ] || LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
. "$LIB/alert-verify.sh" || exit 75
URL=$(av_field line | av_one "https://github\.com/$AV_SLUG/pull/[0-9]+ owes a verdict") || exit 75
URL=${URL% owes a verdict}
N=${URL##*/}; SLUG=${URL#https://github.com/}; SLUG=${SLUG%/pull/*}
av_gh_get "repos/$SLUG/pulls/$N" || exit 75
read -r ST HEAD < <(jq -r '"\(.state // "-") \(.head.sha // "-")"' "$AV_BODY" 2>/dev/null) || exit 75
case "$ST" in
  closed) echo "pr-url-reconcile-verdict: $URL is closed, no verdict owed"; exit 0 ;;
  open) ;;
  *) exit 75 ;;
esac
. "$AV_LIB/verdicts.sh" 2>/dev/null || exit 75
# Read-only: the library's own log and route-missing stamp are writes.
_vd_log() { :; }; _vd_route_missing() { :; }
RC=0
VD=$(vd_standing "$SLUG" "$N" "$HEAD") || RC=$?
case "$RC" in
  0) IFS=$'\t' read -r V _ ID _ <<<"$VD"
     [ -n "$V" ] || exit 75
     echo "pr-url-reconcile-verdict: $URL has a standing $V verdict (id $ID) on ${HEAD:0:8}" ;;
  1) exit 1 ;;
  *) exit 75 ;;
esac
