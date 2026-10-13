#!/bin/bash
# bin/lib/qrf/merge.sh — BH-2340 (BH-2313.2), sourced by
# bin/queue-rows-flip-preflight.sh: may merge_queue_rows_only go to 1?
#
# The reader the knob switches on is mq_queue_list in bin/merge-queue.sh under
# MQROWS=1, i.e. merge_queue_list <project>. The gate does NOT send that
# reader's unfiltered GET /api/merge-queue?project=<p> (BH-3221): the worker
# keeps landed/dropped rows, so for any project with a history that list sits
# at its default limit of 200 and qrf_list rightly fails it as incomplete. It
# lists the live statuses instead, as qrf/build.sh does: per project directory
# under state/merge-queue/, ?project=<p>&status=queued and &status=blocked at
# limit=500, array at .merge_queue. The route has no offset or cursor, so a
# live status at 500 rows cannot be paged: it is incomplete and FAILs. The
# reader itself still sends the unfiltered call and needs the same live-status
# read before merge_queue_rows_only goes to 1. The gate then checks that the
# live rows are a superset of the files the reader reads today:
#   <pr>          needs a `queued` row  (fix: merge_queue_put <p> <pr>)
#   <pr>.blocked  needs a `blocked` row (fix: merge_queue_set <p> <pr> blocked,
#                 after merge_queue_put when the row is not `queued`, because
#                 landed -> blocked is not a legal move)
#   <pr> beside <pr>.blocked is shadowed, as in the reader: the .blocked governs.
#   *.absent and non-numeric names are skipped, as the reader skips them.
# A landed/dropped row is not listed, so a file whose row is terminal reads as
# having no row (same fix). A queued/blocked row with no file is info, never a
# FAIL. A failed or incomplete read of either status is a FAIL and that
# project's parity is reported as not checked, never as matched.
# With no project directory at all it sends one ?status=queued liveness probe.
#
# STRICTLY READ-ONLY: GETs through qrf_list only, rows held in a shell array
# read from $QRF_TMP, nothing written anywhere.

# The worker clamps ?limit= to [1,500] (worker/jobs/src/routes/merge-queue.js).
QRF_MERGE_LIMIT=500

qrf_gate_merge() {
  local root="$QRF_STATE/merge-queue" d p f name pr st matched mism orphans lines
  local -a dirs=()
  local -A row=() blk=() seen=()
  for d in "$root"/*/; do [ -d "$d" ] && dirs+=("${d%/}"); done
  if [ "${#dirs[@]}" = 0 ]; then
    # Never inside $(...): QRF_HTTP has to survive.
    qrf_list merge "/api/merge-queue?status=queued" .merge_queue 200 "$QRF_TMP"
    return 0
  fi
  for d in "${dirs[@]}"; do
    p="${d##*/}"
    lines=""
    for st in queued blocked; do
      if ! qrf_list merge "/api/merge-queue?project=$p&status=$st&limit=$QRF_MERGE_LIMIT" .merge_queue "$QRF_MERGE_LIMIT" "$QRF_TMP"; then
        qrf_info "row parity for $p not checked: live probe failed"
        continue 2
      fi
      # One "pr<TAB>status" per line; $QRF_TMP is reused by the next read.
      lines+=$(jq -r '.merge_queue[] | "\(.pr)\t\(.status)"' "$QRF_TMP")$'\n'
    done
    row=(); blk=(); seen=(); matched=0; mism=0; orphans=0
    while IFS=$'\t' read -r pr st; do
      [ -n "$pr" ] && row[$pr]="$st"
    done <<< "$lines"
    for f in "$d"/*.blocked; do
      [ -e "$f" ] || continue
      name="${f##*/}"; pr="${name%.blocked}"
      case "$pr" in ''|*[!0-9]*) continue ;; esac
      blk[$pr]=1; seen[$pr]=1; st="${row[$pr]:-}"
      if [ "$st" = blocked ]; then matched=$((matched + 1))
      elif [ "$st" = queued ]; then
        mism=$((mism + 1)); qrf_fail merge "state/merge-queue/$p/$name has row status queued, want blocked — fix: merge_queue_set $p $pr blocked"
      else
        mism=$((mism + 1)); qrf_fail merge "state/merge-queue/$p/$name has ${st:+row status $st, want blocked}${st:-no row} — fix: merge_queue_put $p $pr && merge_queue_set $p $pr blocked"
      fi
    done
    for f in "$d"/*; do
      name="${f##*/}"
      case "$name" in ''|*[!0-9]*) continue ;; esac
      [ -f "$f" ] || continue
      if [ -n "${blk[$name]:-}" ]; then
        qrf_info "state/merge-queue/$p/$name shadowed by $name.blocked (the .blocked governs, as in the reader)"
        continue
      fi
      seen[$name]=1; st="${row[$name]:-}"
      if [ "$st" = queued ]; then matched=$((matched + 1))
      else
        mism=$((mism + 1)); qrf_fail merge "state/merge-queue/$p/$name has ${st:+row status $st, want queued}${st:-no row} — fix: merge_queue_put $p $name"
      fi
    done
    for pr in "${!row[@]}"; do
      case "${row[$pr]}" in queued|blocked) [ -n "${seen[$pr]:-}" ] || orphans=$((orphans + 1)) ;; esac
    done
    [ "$orphans" = 0 ] || qrf_info "$p: $orphans queued/blocked row(s) with no file (rows are a superset; not a failure)"
    [ "$mism" = 0 ] && qrf_pass "row parity $p: $matched file(s) matched"
  done
  return 0
}
