#!/bin/bash
# Prove that a local QUEUED_FLY stub handed custody to a newer pool result.
#
# usage: queued-fly-relayed.sh <project> <stub-build-dir>
# exit 0 only when the stub identity is intact and a newer pool build for the
# exact same key carries RELAYED. Every incomplete or ambiguous shape fails
# open so pipeline-health continues to page.
set -uo pipefail

H="${HARNESS:-/root/harness}"
PROJ="${1:-}"
STUB="${2:-}"

case "$PROJ" in ''|*[!A-Za-z0-9_-]*) exit 1 ;; esac
[ -d "$STUB" ] && [ -f "$STUB/RESULT" ] && [ -f "$STUB/job.json" ] || exit 1

KEY=$(jq -r '.key // empty' "$STUB/job.json" 2>/dev/null)
JOB_PROJ=$(jq -r '.project // empty' "$STUB/job.json" 2>/dev/null)
case "$KEY" in ''|*[!A-Za-z0-9_-]*) exit 1 ;; esac
[ "$JOB_PROJ" = "$PROJ" ] || exit 1
[ "$(awk 'NR==1 && $1=="QUEUED_FLY" {print $2}' "$STUB/RESULT" 2>/dev/null)" = "$KEY" ] || exit 1

for SUCCESSOR in "$H"/builds/pool-"$PROJ"-"$KEY"-*; do
  [ -f "$SUCCESSOR/RESULT" ] && [ -f "$SUCCESSOR/RELAYED" ] || continue
  # A prior build of the same ticket cannot discharge a newer queue handoff.
  [ "$SUCCESSOR/RESULT" -nt "$STUB/RESULT" ] || continue
  exit 0
done

exit 1
