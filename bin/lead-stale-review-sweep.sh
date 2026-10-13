#!/bin/bash
# bin/lead-stale-review-sweep.sh — BH-5213: the ONE-TIME sweep for lead BLOCK
# reviews left standing after a later green lead verdict. Run by hand by the
# operator, never from cron: the lanes dismiss their own stale reviews as they
# record a MERGE from now on (bin/lead-verdict.sh post, bin/lead-review-land.sh
# step 2d), and bin/pipeline-health.sh names any that remain (`stale-review`).
#
# For each open, non-draft PR of each repo whose head carries a `lead-verdict`
# success status, every standing CHANGES_REQUESTED review that is the lead
# lane's OWN (bot author, `<!-- lead-review:` marker, on an older commit; the
# rule is bin/lib/lead-stale-review.sh lsr_stale) is dismissed, and one line per
# review is printed: paste them on the ticket. A person's review is never
# touched. --dry-run reads and prints what it would dismiss, and writes nothing.
#
# usage: bin/lead-stale-review-sweep.sh [--dry-run] <owner/repo>...
# exit:  0 every eligible review dismissed (or none found), 1 a read or a
#        dismissal failed (named on stderr; rerun it), 2 usage.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${HARNESS:-$(cd "$SELF_DIR/.." && pwd)}"
export HARNESS
# shellcheck source=bin/lib/gh-rest.sh
. "$SELF_DIR/lib/gh-rest.sh" || { echo "lead-stale-review-sweep: bin/lib/gh-rest.sh did not load" >&2; exit 1; }
# shellcheck source=bin/lib/lead-stale-review.sh
. "$SELF_DIR/lib/lead-stale-review.sh" || { echo "lead-stale-review-sweep: bin/lib/lead-stale-review.sh did not load" >&2; exit 1; }

DRY=""; REPOS=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=--dry-run ;;
    */*) [[ "$a" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "lead-stale-review-sweep: repo must be owner/name, got '$a'" >&2; exit 2; }
         REPOS="$REPOS $a" ;;
    *) echo "usage: bin/lead-stale-review-sweep.sh [--dry-run] <owner/repo>..." >&2; exit 2 ;;
  esac
done
[ -n "$REPOS" ] || { echo "usage: bin/lead-stale-review-sweep.sh [--dry-run] <owner/repo>..." >&2; exit 2; }
RC=0
for R in $REPOS; do
  lsr_sweep "$R" ${DRY:+"$DRY"} || RC=1
done
exit "$RC"
