#!/bin/bash
# bin/alert-verify/merge-queue-pr.sh — the verify script of the `merge-queue-pr` row of
# alert_family_scripts (BH-2577). Protocol: the header of
# bin/triage-family-scripts.sh; shared reads: bin/lib/alert-verify.sh.
#
# bin/merge-queue.sh's `Merge queue: #<n> …: <pr-url>` pages. Cleared once the PR
# is not OPEN. The #<n> and the URL must name the same PR.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
LIB="$HARNESS/bin/lib"
[ -r "$LIB/alert-verify.sh" ] || LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
. "$LIB/alert-verify.sh" || exit 75
L=$(av_field line) || exit 75
N=$(printf '%s\n' "$L" | av_one 'Merge queue: #[0-9]+ ') || exit 75
URL=$(printf '%s\n' "$L" | av_one "https://github\.com/$AV_SLUG/pull/[0-9]+") || exit 75
N=${N#Merge queue: #}; N=${N% }
[ "${URL##*/}" = "$N" ] || exit 75
av_pr_verdict merge-queue-pr "$URL"
