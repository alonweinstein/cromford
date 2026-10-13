#!/bin/bash
# bin/alert-verify/pipeline-health-clean-open.sh — the verify script of the `pipeline-health-clean-open` row of
# alert_family_scripts (BH-2577). Protocol: the header of
# bin/triage-family-scripts.sh; shared reads: bin/lib/alert-verify.sh.
#
# bin/pipeline-health.sh's "APPROVE, OPEN and CLEAN and the sweep has not landed
# it" page. The PR comes from the akey (health:sweepstall:<slug>#<n>), never from
# the free text, which quotes a merge-sweep.log line that can name another PR.
# Cleared once the PR is not OPEN.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
LIB="$HARNESS/bin/lib"
[ -r "$LIB/alert-verify.sh" ] || LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
. "$LIB/alert-verify.sh" || exit 75
M=$(av_field akey | av_one "^health:sweepstall:$AV_SLUG#[0-9]+$") || exit 75
M=${M#health:sweepstall:}
av_pr_verdict pipeline-health-clean-open "https://github.com/${M%#*}/pull/${M##*#}"
