#!/bin/bash
# bin/lib/qrf/build.sh — BH-2339 (BH-2313.1): the build gate, sourced by
# bin/queue-rows-flip-preflight.sh. Before build_queue_rows_only goes to 1,
# every file-store entry on this box must already have its build_queue row:
#
#   1. live probe: GET /api/queue?status=claimed and ?status=queued, limit=500
#      each. The worker keeps done/failed/dropped rows, so an unfiltered list
#      would sit at the clamp; the live statuses are listed instead. A failed
#      or incomplete probe skips parity: an outage is never "0 rows".
#   2. every state/fly/<p>-active.json .key has a claimed (p,key) row.
#   3. every state/build-queue/<p>/<KEY>.json has a queued or claimed row. One
#      that has neither gets a per-key read so the FAIL says which case it is.
#   4. a live row no file names is info only: another box may hold it.
#
# Read-only: GETs through qrf_get/qrf_list, no queue_* writer, no file written.

# The worker clamps ?limit= to [1,500] (worker/jobs/src/routes/queue.js).
QRF_BUILD_LIMIT=500

qrf_gate_build() {
  local claimed queued st f p k rel n=0 bad=0 st_row
  for st in claimed queued; do
    qrf_list build "/api/queue?status=$st&limit=$QRF_BUILD_LIMIT" .queue "$QRF_BUILD_LIMIT" "$QRF_TMP" || return 0
    # One "project<TAB>key" per line; $QRF_TMP is reused by the next read.
    printf -v "$st" '%s' "$(jq -r '.queue[] | [.project, .ticket_key] | @tsv' "$QRF_TMP")"
  done
  local -A named=()
  # 2. the fly dispatcher's active builds.
  for f in "$QRF_STATE"/fly/*-active.json; do
    [ -e "$f" ] || continue
    n=$((n+1)); p=$(basename "$f" -active.json); rel="state/fly/$p-active.json"
    k=$(jq -r '.key // empty' "$f" 2>/dev/null)
    if [ -z "$k" ]; then qrf_fail build "$rel: no .key"; bad=1; continue; fi
    named["$p"$'\t'"$k"]=1
    if ! grep -qxF "$p"$'\t'"$k" <<< "$claimed"; then
      qrf_fail build "$rel key $k has no claimed row; fix: queue_put $p $k (then queue_claim $p fly $k)"; bad=1
    fi
  done
  # 3. the build-queue files. Dot-prefixed pull temps do not match the glob.
  for f in "$QRF_STATE"/build-queue/*/*.json; do
    [ -e "$f" ] || continue
    n=$((n+1)); p=$(basename "$(dirname "$f")"); k=$(basename "$f" .json); rel="state/build-queue/$p/$k.json"
    named["$p"$'\t'"$k"]=1
    if grep -qxF "$p"$'\t'"$k" <<< "$claimed" || grep -qxF "$p"$'\t'"$k" <<< "$queued"; then continue; fi
    bad=1
    if ! qrf_get "/api/queue?project=$p&key=$k&limit=1" "$QRF_TMP" || ! jq -e '.queue | type == "array"' "$QRF_TMP" >/dev/null 2>&1; then
      qrf_fail build "$rel: row unreadable http=$QRF_HTTP"; continue
    fi
    st_row=$(jq -r '.queue[0].status // empty' "$QRF_TMP")
    if [ -z "$st_row" ]; then qrf_fail build "$rel has no row; fix: queue_put $p $k"
    else qrf_fail build "$rel row is $st_row, not queued/claimed; fix: queue_put $p $k only if the build is still owed, else remove the leftover file"; fi
  done
  # 4. live rows no file on this box names.
  local line
  for st in claimed queued; do
    while IFS= read -r line; do
      [ -n "$line" ] && [ -z "${named[$line]:-}" ] || continue
      qrf_info "row with no file on this box: ${line/$'\t'//} ($st)"
    done <<< "${!st}"
  done
  [ "$bad" = 0 ] && qrf_pass "row parity: $n file entries on this box, every one has a row"
  return 0
}
