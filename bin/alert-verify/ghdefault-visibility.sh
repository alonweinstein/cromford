#!/bin/bash
# bin/alert-verify/ghdefault-visibility.sh — the verify script of the `ghdefault-visibility` row of
# alert_family_scripts (BH-2577). Protocol: the header of
# bin/triage-family-scripts.sh; shared reads: bin/lib/alert-verify.sh.
#
# The auth check lane's `DEFAULT GH TOKEN CANNOT SEE <slug> ` page. ONE REST read,
# GET repos/<slug>, on the DEFAULT token this process inherited: 200 clears it,
# 404 still reproduces. An empty GH_TOKEN is doubt, because gh_rest's quota gate
# would lend a tokenless caller the App token and prove the App's visibility
# instead. GH_ADMIN_TOKEN is dropped for the same reason. The token is never
# printed.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
LIB="$HARNESS/bin/lib"
[ -r "$LIB/alert-verify.sh" ] || LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
. "$LIB/alert-verify.sh" || exit 75
unset GH_ADMIN_TOKEN
[ -n "${GH_TOKEN:-}" ] || exit 75
M=$(av_field line | av_one "DEFAULT GH TOKEN CANNOT SEE $AV_SLUG ") || exit 75
SLUG=${M#DEFAULT GH TOKEN CANNOT SEE }; SLUG=${SLUG% }
RC=0
gh_rest GET "repos/$SLUG" >/dev/null || RC=$?
case "$RC" in
  0) [ "$GH_REST_STATUS" = 200 ] || exit 75
     echo "ghdefault-visibility: the default token sees $SLUG (HTTP 200)" ;;
  44) exit 1 ;;
  *) exit 75 ;;
esac
