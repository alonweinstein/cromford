#!/bin/bash
# bin/alert-verify/main-red.sh — the verify script of the `main-red` row of
# alert_family_scripts (BH-2577). Protocol: the header of
# bin/triage-family-scripts.sh; shared reads: bin/lib/alert-verify.sh.
#
# The main-red detector's `<slug> main is (STILL) RED` page. ONE REST read of
# main's check-runs: cleared when every run is completed, every conclusion is
# success/neutral/skipped and at least one is a success. A failed run is a
# repro. No runs, more than one page of them, a run still going, or any read
# failure is doubt.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
LIB="$HARNESS/bin/lib"
[ -r "$LIB/alert-verify.sh" ] || LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
. "$LIB/alert-verify.sh" || exit 75
M=$(av_field line | av_one "\[orchestrator/main-red\] $AV_SLUG main is (STILL )?RED") || exit 75
read -r _ SLUG _ <<<"$M"
av_gh_get "repos/$SLUG/commits/main/check-runs?per_page=100" || exit 75
V=$(jq -r '
  if (.total_count|type) != "number" or (.check_runs|type) != "array" then "doubt"
  elif .total_count > 100 or (.check_runs|length) != .total_count then "doubt"
  elif any(.check_runs[]; .status != "completed") then "doubt"
  elif any(.check_runs[]; .conclusion as $c | ["failure","timed_out","cancelled","action_required","startup_failure"] | index([$c])) then "red"
  elif all(.check_runs[]; .conclusion as $c | ["success","neutral","skipped"] | index([$c]))
       and any(.check_runs[]; .conclusion == "success") then "green \(.total_count) \(.check_runs[0].head_sha // "-")"
  else "doubt" end' "$AV_BODY" 2>/dev/null) || exit 75
case "$V" in
  red) exit 1 ;;
  green*) read -r _ N SHA <<<"$V"
          echo "main-red: $SLUG main ${SHA:0:8} has $N check-runs, all completed, none failed" ;;
  *) exit 75 ;;
esac
