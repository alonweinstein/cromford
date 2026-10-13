#!/bin/bash
# bin/lib/qrf/deploy.sh — BH-2341 (BH-2313.3), sourced by
# bin/queue-rows-flip-preflight.sh: the deploy gate's checks for the
# deploy_queue_rows knob.
#
# Live probe: two GET /api/deploy-queue lists (the route and .deploy_queue[]
# path deploy_queue_list reads), one per status the deploy train treats as
# pending, queued and claimed. Each sends limit=200, the worker's default cap,
# so the row count qrf_list compares is the cap the server applied. One
# unfiltered list would fill with `done` rows, which the worker never prunes,
# and sit at the cap. A list that fails or is capped is a FAIL and parity is
# not checked; it is never read as "0 rows".
#
# Row parity: every regular file state/deploy-queue/<p>/<epoch>-<sha8> (what
# bin/deploy-request.sh writes) needs a queued or claimed row for <p> whose sha
# starts with <sha8>, case-insensitive. A file without one is a FAIL naming
# deploy_queue_put, the existing idempotent put that also re-opens a terminal
# row. A row with no file is info only: the rows are a superset of the files.
#
# Read-only: GETs through qrf_list and reads under $QRF_STATE. It reuses
# $QRF_TMP and writes nothing else.
qrf_gate_deploy() {
  local st route rows="" f d p name hex sha build rp rs rst k hit n=0 bad=0
  local -a keys=()
  for st in queued claimed; do
    route="/api/deploy-queue?status=$st&limit=200"
    if ! qrf_list deploy "$route" .deploy_queue 200 "$QRF_TMP"; then
      qrf_info "row parity: not checked (the list did not answer in full)"; return 0
    fi
    if ! k=$(jq -r '.deploy_queue[] | [.project, (.sha | ascii_downcase), .status] | @tsv' "$QRF_TMP" 2>/dev/null); then
      qrf_fail deploy "live probe $route: a row has no readable project/sha/status"
      qrf_info "row parity: not checked (the list did not answer in full)"; return 0
    fi
    [ -n "$k" ] && rows+="$k"$'\n'
  done
  for d in "$QRF_STATE"/deploy-queue/*/; do
    [ -d "$d" ] || continue
    p=$(basename "$d")
    for f in "$d"*; do
      [ -f "$f" ] || continue
      name=${f##*/}
      if ! [[ "$name" =~ ^[0-9]+-[0-9a-fA-F]{7,40}$ ]]; then
        qrf_fail deploy "state/deploy-queue/$p/$name: unrecognised queue file name"; bad=$((bad+1)); continue
      fi
      hex=${name#*-}; hex=${hex,,}
      keys+=("$p $hex"); n=$((n+1)); hit=0
      while IFS=$'\t' read -r rp rs rst; do
        [ "$rp" = "$p" ] && [[ "$rs" == "$hex"* ]] && { hit=1; break; }
      done <<< "$rows"
      if [ "$hit" = 0 ]; then
        sha=""; build=""
        read -r sha build _ < "$f"
        qrf_fail deploy "row parity: state/deploy-queue/$p/$name has no queued/claimed deploy_queue row. Fix: deploy_queue_put $p ${sha:--} ${build:--}"
        bad=$((bad+1))
      fi
    done
  done
  [ "$bad" = 0 ] && qrf_pass "row parity: $n deploy file(s), each with a queued/claimed row"
  while IFS=$'\t' read -r rp rs rst; do
    [ -n "$rp" ] || continue
    hit=0
    for k in "${keys[@]}"; do
      [ "${k%% *}" = "$rp" ] && [[ "$rs" == "${k#* }"* ]] && { hit=1; break; }
    done
    [ "$hit" = 0 ] && qrf_info "row $rp@${rs:0:8} ($rst) has no file on this box"
  done <<< "$rows"
  return 0
}
