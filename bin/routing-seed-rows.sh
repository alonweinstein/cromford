#!/bin/bash
# bin/routing-seed-rows.sh — BH-1627: write one `routing` row per fleet project
# from THIS box's flags/ files, so that flipping `routing_rows` on hands routing
# to rows that say exactly what the files say. Run it on the hub, where the
# enrollment writers keep the files, BEFORE the flip.
#
# The live probe on 2026-09-24 found the table empty. Flipped like that, every
# row read is a 404, the files alone keep routing, and the flip does nothing.
# `routing-sync-all` cannot fill the table: it copies rows INTO the files, and
# with the knob off it sends no request at all.
#
#   dry run (default): print the row each project would get, and PUT nothing.
#   --apply:           PUT the rows through routing_set, which writes the files
#                      first, then the row.
#
# SAFE BY CONSTRUCTION:
# - A project is seeded only when its derived row leaves its files
#   byte-identical, mtimes included (routing_row_drift prints nothing).
# - A file set that no row can express makes the WHOLE run refuse before any
#   PUT: an orphan fly-pool-<p>, an empty fly-pool-app-<p>, an app file on a
#   project that is not a pool, or (BH-2010) a pool_app name the row would
#   refuse. Fix the files, then run it again.
# - Every PUT is AUDITED (BH-2010): actor `routing-seed`, and a reason naming
#   this box, land in the worker's routing_changes.
# - A PROJECT ADDED TO fleet.conf LATER has no row; routing-flip-preflight.sh
#   check 5 then reports it NOT READY. Re-run this script: it seeds only the
#   projects with no row and skips every matching one.
# - A project whose row already matches is skipped, so a re-run is a no-op.
# - A row that DIFFERS from the files is never overwritten: it is named and the
#   run fails. That row is someone's newer decision (a writer, the console).
# - The knob is neither read nor written. routing_set is not knob-gated
#   (BH-1369), so the rows land while routing still comes from the files.
#
# Usage: HARNESS=/root/harness bin/routing-seed-rows.sh [--apply]
# Exit:  0 every fleet project has a matching row (or would, in a dry run),
#        1 refused or a PUT failed, 2 usage error or no client.
set -uo pipefail
H="${HARNESS:-/root/harness}"
APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  "") ;;
  *) echo "usage: routing-seed-rows.sh [--apply]" >&2; exit 2 ;;
esac
export ROUTING_ROWS=off   # never sync rows INTO the files from here
# A DRY RUN IS A READ (BH-2010): during a worker outage it fails on the list
# read, but it must not raise the jobs client's once-a-day "harness-jobs
# unreachable" ALERTS line — the lanes that depend on the worker own that alert.
[ "$APPLY" = 1 ] || export JOBS_ALERT=0
# shellcheck source=/dev/null
{ [ -r "$H/bin/jobs-client.sh" ] && [ -d "$H/bin/lib/jobs" ] && . "$H/bin/jobs-client.sh"; } \
  || { echo "routing-seed-rows: no jobs client under $H/bin"; exit 2; }
command -v routing_row_from_files >/dev/null 2>&1 || { echo "routing-seed-rows: the client has no routing_row_from_files (deploy BH-1627)"; exit 2; }

PROJECTS=$("$H/bin/fleet-conf.sh" --projects 2>/dev/null)
[ -n "$PROJECTS" ] || { echo "routing-seed-rows: fleet-conf.sh --projects listed nothing"; exit 1; }
HAVE_ROWS=$(routing_list) || { echo "routing-seed-rows: GET /api/routing failed; nothing written"; exit 1; }

# Pass 1: validate every project. No PUT happens unless all of them pass.
REFUSE=""; TODO=""; SAME=0
for p in $PROJECTS; do
  derived=$(routing_row_from_files "$p") || { REFUSE="$REFUSE\n  $p: unusable project name"; continue; }
  IFS='|' read -r b a h <<< "$derived"
  # The same name rule routing_set applies, so it refuses the WHOLE run here
  # instead of failing one PUT after the others have landed (BH-2010).
  if [ -n "$a" ] && ! _routing_name_ok "$a"; then REFUSE="$REFUSE\n  $p: pool_app '$a' is not a valid name (flags/fly-pool-app-$p)"; continue; fi
  drift=$(routing_row_drift "$p" "$b" "$a" "$h")
  if [ -n "$drift" ]; then REFUSE="$REFUSE\n  files no row can express: $(printf '%s' "$drift" | paste -sd';' -)"; continue; fi
  have=$(printf '%s\n' "$HAVE_ROWS" | awk -F'\t' -v p="$p" '$1 == p { print $2 "|" $3 "|" $4 }')
  if [ -z "$have" ]; then TODO="$TODO $p|$b|$a|$h"
  elif [ "$have" = "$b|$a|$h" ]; then SAME=$((SAME+1))
  else REFUSE="$REFUSE\n  $p: existing row $have differs from the files $b|$a|$h (not overwritten)"; fi
done
if [ -n "$REFUSE" ]; then
  printf 'routing-seed-rows: REFUSED, nothing written:%b\n' "$REFUSE"; exit 1
fi

N=0; BAD=0
for t in $TODO; do
  IFS='|' read -r p b a h <<< "$t"
  if [ "$APPLY" = 1 ]; then
    if routing_set "$p" "$b" "$a" "$h" routing-seed "BH-1627 seed from $(hostname 2>/dev/null || echo this box)'s flags/ files"; then echo "seeded $p builder=$b pool_app=${a:--} halted=$h"; N=$((N+1))
    else echo "FAILED $p builder=$b pool_app=${a:--} halted=$h (http=${JOBS_HTTP:-none})"; BAD=$((BAD+1)); fi
  else echo "would seed $p builder=$b pool_app=${a:--} halted=$h"; N=$((N+1)); fi
done
echo "routing-seed-rows: $([ "$APPLY" = 1 ] && echo seeded || echo "would seed") $N, already matching $SAME, failed $BAD"
[ "$BAD" = 0 ]
