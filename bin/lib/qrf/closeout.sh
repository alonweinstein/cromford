#!/bin/bash
# bin/lib/qrf/closeout.sh — BH-2342 (BH-2313.4), sourced by
# bin/queue-rows-flip-preflight.sh: the closeout_aged_table gate.
#
# Live probe: GET /api/closeout-aged must answer 2xx with an array .aged; any
# other answer FAILs with http= and parity is "not checked".
# Row parity: every unique build dir (field 2) of state/closeout-aged-out.tsv
# answers closeout_aged_has rc 0. rc 2 (no row) FAILs, naming the dir and the
# closeout_aged_put that writes it. Any other rc is an outage: a FAIL for the
# live probe, and the loop stops there, so a down worker is never a pass and is
# not asked again. An aged row with no tsv line is info: the rows are a
# superset. GETs only; the one file written is $QRF_TMP.
qrf_gate_closeout() {
  local tsv="$QRF_STATE/closeout-aged-out.tsv" rows dirs dir project rc n=0 bad=0 extra=0 d
  if ! qrf_get /api/closeout-aged "$QRF_TMP" || ! jq -e '.aged | type == "array"' "$QRF_TMP" >/dev/null 2>&1; then
    qrf_fail closeout "live probe /api/closeout-aged http=$QRF_HTTP"
    qrf_fail closeout "row parity: not checked (live probe failed)"; return
  fi
  qrf_pass "live probe /api/closeout-aged http=$QRF_HTTP rows=$(jq '.aged | length' "$QRF_TMP")"
  rows=$(jq -r '.aged[].build_dir // empty' "$QRF_TMP" | sort -u)
  if [ -r "$tsv" ]; then dirs=$(awk -F'\t' '$2 != "" && !seen[$2]++ { print $1 "\t" $2 }' "$tsv")
  else qrf_info "no closeout-aged-out.tsv on this box"; dirs=""; fi
  local seen=$'\n'
  while IFS=$'\t' read -r project dir; do
    [ -n "$dir" ] || continue
    seen="$seen$dir"$'\n'
    # closeout_aged_has reads inside $(...), so JOBS_HTTP never comes back from
    # it; the client's own http= line goes to stderr instead.
    closeout_aged_has "$dir"; rc=$?
    case "$rc" in
      0) n=$((n+1)) ;;
      2) qrf_fail closeout "closeout tsv dir has no aged row: $dir — fix: closeout_aged_put ${project:-<project>} $dir"
         bad=$((bad+1)) ;;
      *) qrf_fail closeout "live probe /api/closeout-aged?build_dir=$dir failed: closeout_aged_has rc=$rc (outage; http= on stderr)"
         qrf_fail closeout "row parity: not checked past $dir (outage)"
         return ;;
    esac
  done <<< "$dirs"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$seen" in *$'\n'"$d"$'\n'*) ;; *) extra=$((extra+1)) ;; esac
  done <<< "$rows"
  [ "$extra" = 0 ] || qrf_info "$extra aged row(s) with no tsv line (rows are a superset, not a failure)"
  [ "$bad" = 0 ] && qrf_pass "row parity: $n tsv dir(s) matched"
}
