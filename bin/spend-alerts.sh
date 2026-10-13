#!/bin/bash
# bin/spend-alerts.sh — the arithmetic behind the spend ALERTS (BH-5526, slice
# C2). bin/pipeline-health.sh's `# >>> spend alerts` block calls it and raises
# the alerts; this script only reads the files it is given and prints TSV.
#
# IT REFUSES NOTHING. It writes no flag, no hold, no pause and no settings row.
# The one file it writes is the per-PR hold state named by `perpr --state`,
# which says since when a project has been an outlier.
#
#   baseline --rows <csv> --until <YYYY-MM-DD> --days <n> --min-days <n>
#       The p99 daily spend of each project and each lane over the UTC days
#       [until - days, until). Prints `axis<TAB>key<TAB>p99<TAB>days`, axis is
#       `project` or `lane`. The lane is `lane_id`, else `stage` when lane_id is
#       empty (rows from before BH-2303). A key with fewer than --min-days days
#       of rows prints nothing. Same rule as bin/budget-defaults.sh: identical
#       lines count once, `row_source` refused and settled are not spend, a day
#       with no rows is not a sample, p99 is nearest-rank sorted[ceil(0.99n)-1].
#       A csv with no ts/project/cost_usd header (or an empty file) exits 1
#       and prints nothing, for `over` too: unreadable is never $0.
#
#   over --rows <csv> --baseline <tsv> --since <iso> --mult <x>
#       Today's spend per (axis, key) from rows with ts >= since, against the
#       baseline. Prints `axis<TAB>key<TAB>today<TAB>p99<TAB>threshold<TAB>days`
#       where today >= mult x p99 and p99 > 0. A key with no baseline line
#       prints nothing.
#
#   perpr --summary <json> --state <file> --now <epoch> --mult <x> --min-prs <n> --hold-s <s>
#       Cost per merged PR (state/cost/summary.json, 7d) against the fleet
#       median. Eligible: not `other` or `fleet`, merged_prs_7d >= min-prs, and
#       a numeric cost_per_merged_pr_7d (null is skipped, never read as 0).
#       Fewer than 3 eligible, or a median of 0, prints
#       `noeval<TAB><n eligible><TAB><reason>` and leaves the state alone.
#       Else it rewrites the state (`project<TAB>first_over_epoch`, earliest
#       kept, a project no longer over dropped) and prints
#       `project<TAB>rate<TAB>median<TAB>ratio<TAB>first_over` for each project
#       above mult x median for at least hold-s seconds.
#
#   unpriced --rows <csv> --since <iso>
#       Billed calls stored with no cost, per lane, from rows with ts >= since
#       (BH-6175). Prints `lane<TAB>calls<TAB>pairs<TAB>projects`, sorted by
#       lane; pairs is `runner/model:n` by count, projects sorted, both
#       comma-joined. A row counts when its cost_usd is blank or not a number
#       and its row_source is not refused, settled or unbilled. A row with rc
#       not 0 and 0 tokens was never billed and does not count (the
#       bin/cost-rollup.sh rule). Identical lines count once.
#
# Exit: 0 printed an answer (maybe empty), 1 unreadable input, 2 usage.
set -uo pipefail

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
isnum() { case "${1:-}" in ''|*[!0-9.]*|*.*.*|.) return 1 ;; esac; return 0; }

CMD="${1:-}"; [ -n "$CMD" ] || usage; shift
ROWS="" UNTIL="" DAYS="" MIN_DAYS="" BASE="" SINCE="" MULT="" SUMMARY="" STATE="" NOW_E="" MIN_PRS="" HOLD_S=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --rows) ROWS=$2 ;; --until) UNTIL=$2 ;; --days) DAYS=$2 ;; --min-days) MIN_DAYS=$2 ;;
    --baseline) BASE=$2 ;; --since) SINCE=$2 ;; --mult) MULT=$2 ;;
    --summary) SUMMARY=$2 ;; --state) STATE=$2 ;; --now) NOW_E=$2 ;;
    --min-prs) MIN_PRS=$2 ;; --hold-s) HOLD_S=$2 ;;
    *) usage ;;
  esac
  shift 2
done

# rows_awk <mode> — the shared cost.csv reader. Header-name lookup, mawk-safe.
# mode "days": prints `axis<TAB>key<TAB>day<TAB>usd` per (axis, key, UTC day)
# for lo <= day < hi. mode "since": prints `axis<TAB>key<TAB>usd` for ts >= lo.
rows_awk() {
  awk -F, -v mode="$1" -v lo="$2" -v hi="${3:-}" '
    function num(x) { return (x ~ /^[0-9]+(\.[0-9]+)?$/) ? x + 0 : 0 }
    function add(ax, k) { if (k == "") return; key = ax SUBSEP k SUBSEP grp; if (!(key in s)) o[++n] = key; s[key] += usd }
    NR == 1 {
      for (i = 1; i <= NF; i++) c[$i] = i
      if (!c["ts"] || !c["project"] || !c["cost_usd"]) { bad = 1; exit 1 }
      next
    }
    !seen[$0]++ {
      rs = c["row_source"] ? $c["row_source"] : ""
      if (rs == "refused" || rs == "settled") next
      ts = $c["ts"]; day = substr(ts, 1, 10)
      if (day !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) next
      if (mode == "days") { if (day < lo || day >= hi) next; grp = day }
      else { if (ts < lo) next; grp = "" }
      usd = num($c["cost_usd"])
      lane = c["lane_id"] ? $c["lane_id"] : ""
      if (lane == "" && c["stage"]) lane = $c["stage"]
      add("project", $c["project"]); add("lane", lane)
    }
    END {
      if (bad || NR == 0) exit 1
      for (i = 1; i <= n; i++) {
        split(o[i], a, SUBSEP)
        if (mode == "days") printf "%s\t%s\t%s\t%.6f\n", a[1], a[2], a[3], s[o[i]]
        else printf "%s\t%s\t%.6f\n", a[1], a[2], s[o[i]]
      }
    }' "$ROWS"
}

case "$CMD" in
baseline)
  [ -r "$ROWS" ] || { echo "spend-alerts.sh baseline: cannot read --rows '$ROWS'" >&2; exit 1; }
  isnum "$DAYS" && isnum "$MIN_DAYS" || usage
  [ -n "$UNTIL" ] && START=$(date -u -d "$UNTIL -$DAYS days" +%F 2>/dev/null) && [ "$(date -u -d "$UNTIL" +%F 2>/dev/null)" = "$UNTIL" ] \
    || { echo "spend-alerts.sh baseline: --until '$UNTIL' is not a YYYY-MM-DD date" >&2; exit 2; }
  DAYROWS=$(rows_awk days "$START" "$UNTIL") \
    || { echo "spend-alerts.sh baseline: '$ROWS' is not a cost.csv (no ts/project/cost_usd header)" >&2; exit 1; }
  [ -n "$DAYROWS" ] || exit 0
  printf '%s\n' "$DAYROWS" | awk -F'\t' -v min="$MIN_DAYS" '
    function ceil(x,  i) { i = int(x); return (x > i) ? i + 1 : i }
    { k = $1 "\t" $2; if (!(k in n)) o[++m] = k; v[k, ++n[k]] = $4 + 0 }
    END {
      for (i = 1; i <= m; i++) {
        k = o[i]; c = n[k]; if (c < min + 0) continue
        for (j = 1; j <= c; j++) x[j] = v[k, j]
        for (j = 2; j <= c; j++) { t = x[j]; l = j - 1; while (l > 0 && x[l] > t) { x[l + 1] = x[l]; l-- } x[l + 1] = t }
        r = ceil(0.99 * c); if (r < 1) r = 1
        printf "%s\t%.2f\t%d\n", k, x[r], c
      }
    }' | LC_ALL=C sort
  ;;
over)
  [ -r "$ROWS" ] && [ -r "$BASE" ] || { echo "spend-alerts.sh over: cannot read --rows '$ROWS' or --baseline '$BASE'" >&2; exit 1; }
  isnum "$MULT" && [ -n "$SINCE" ] || usage
  TODAY=$(rows_awk since "$SINCE") \
    || { echo "spend-alerts.sh over: '$ROWS' is not a cost.csv (no ts/project/cost_usd header)" >&2; exit 1; }
  [ -n "$TODAY" ] || exit 0
  printf '%s\n' "$TODAY" | awk -F'\t' -v mult="$MULT" -v bf="$BASE" '
    BEGIN { while ((getline ln < bf) > 0) { if (split(ln, a, "\t") < 4) continue; P[a[1] "\t" a[2]] = a[3] + 0; D[a[1] "\t" a[2]] = a[4] } }
    { k = $1 "\t" $2; if (!(k in P) || P[k] <= 0) next
      th = mult * P[k]; u = $3 + 0
      if (u >= th) printf "%s\t%.2f\t%.2f\t%.2f\t%s\n", k, u, P[k], th, D[k] }' | LC_ALL=C sort
  ;;
perpr)
  [ -r "$SUMMARY" ] || { echo "spend-alerts.sh perpr: cannot read --summary '$SUMMARY'" >&2; exit 1; }
  [ -n "$STATE" ] && isnum "$NOW_E" && isnum "$MULT" && isnum "$MIN_PRS" && isnum "$HOLD_S" || usage
  ELIG=$(jq -r --argjson min "$MIN_PRS" '
    .projects // {} | to_entries[]
    | select(.key != "other" and .key != "fleet")
    | select((.value.merged_prs_7d | type) == "number" and .value.merged_prs_7d >= $min)
    | select((.value.cost_per_merged_pr_7d | type) == "number")
    | "\(.key)\t\(.value.cost_per_merged_pr_7d)"' "$SUMMARY" 2>/dev/null) \
    || { echo "spend-alerts.sh perpr: '$SUMMARY' is not a cost summary (jq could not read .projects)" >&2; exit 1; }
  NE=$(printf '%s' "$ELIG" | grep -c .)
  [ "$NE" -ge 3 ] || { printf 'noeval\t%s\tfewer than 3 projects with %s+ merged PRs in 7d\n' "$NE" "$MIN_PRS"; exit 0; }
  MED=$(printf '%s\n' "$ELIG" | cut -f2 | LC_ALL=C sort -g | awk '{ v[NR] = $1 + 0 } END { if (NR % 2) print v[(NR + 1) / 2]; else print (v[NR / 2] + v[NR / 2 + 1]) / 2 }')
  awk -v m="$MED" 'BEGIN { exit !(m + 0 > 0) }' \
    || { printf 'noeval\t%s\tthe fleet median cost per merged PR is 0\n' "$NE"; exit 0; }
  mkdir -p "$(dirname "$STATE")" || exit 1
  TMPS="$STATE.tmp.$$"
  OUT=$(printf '%s\n' "$ELIG" | awk -F'\t' -v med="$MED" -v mult="$MULT" -v now="$NOW_E" -v hold="$HOLD_S" -v sf="$STATE" -v tf="$TMPS" '
    BEGIN { while ((getline ln < sf) > 0) { if (split(ln, a, "\t") >= 2 && a[2] ~ /^[0-9]+$/) F[a[1]] = a[2] } printf "" > tf }
    $2 + 0 > mult * med {
      f = ($1 in F && F[$1] + 0 <= now + 0) ? F[$1] : now
      printf "%s\t%s\n", $1, f > tf
      if (now - f >= hold + 0) printf "%s\t%.2f\t%.2f\t%.2f\t%s\n", $1, $2, med, $2 / med, f
    }') || { rm -f "$TMPS"; exit 1; }
  LC_ALL=C sort -o "$TMPS" "$TMPS" && mv -f "$TMPS" "$STATE" || { rm -f "$TMPS"; exit 1; }
  [ -z "$OUT" ] || printf '%s\n' "$OUT" | LC_ALL=C sort
  ;;
unpriced)
  [ -n "$SINCE" ] || usage
  [ -r "$ROWS" ] || { echo "spend-alerts.sh unpriced: cannot read --rows '$ROWS'" >&2; exit 1; }
  HITS=$(awk -F, -v lo="$SINCE" '
    function f(n) { return c[n] ? $c[n] : "" }
    function tok(n,  v) { v = f(n); return (v ~ /^[0-9]+$/) ? v + 0 : 0 }
    NR == 1 {
      for (i = 1; i <= NF; i++) c[$i] = i
      if (!c["ts"] || !c["project"] || !c["cost_usd"]) { bad = 1; exit 1 }
      next
    }
    !seen[$0]++ {
      if ($c["ts"] < lo) next
      rs = f("row_source")
      if (rs == "refused" || rs == "settled" || rs == "unbilled") next
      if ($c["cost_usd"] ~ /^[0-9]+(\.[0-9]+)?$/) next
      rc = f("rc")
      if (rc != "" && rc != "0" && tok("input_toks") + tok("output_toks") + tok("cache_read") + tok("cache_write") == 0) next
      lane = f("lane_id"); if (lane == "") lane = f("stage"); if (lane == "") lane = "(none)"
      printf "%s\t%s/%s\t%s\n", lane, f("runner"), f("model"), $c["project"]
    }
    END { if (bad || NR == 0) exit 1 }' "$ROWS") \
    || { echo "spend-alerts.sh unpriced: '$ROWS' is not a cost.csv (no ts/project/cost_usd header)" >&2; exit 1; }
  [ -n "$HITS" ] || exit 0
  printf '%s\n' "$HITS" | cut -f1 | LC_ALL=C sort -u | while IFS= read -r L; do
    LH=$(printf '%s\n' "$HITS" | awk -F'\t' -v l="$L" '$1 == l')
    N=$(printf '%s\n' "$LH" | grep -c .)
    PAIRS=$(printf '%s\n' "$LH" | cut -f2 | LC_ALL=C sort | uniq -c \
      | awk '{ print $1 "\t" $2 }' | LC_ALL=C sort -t"$(printf '\t')" -k1,1nr -k2,2 \
      | awk -F'\t' '{ printf "%s%s:%s", (NR > 1 ? "," : ""), $2, $1 }')
    PROJS=$(printf '%s\n' "$LH" | cut -f3 | LC_ALL=C sort -u | paste -sd, -)
    printf '%s\t%s\t%s\t%s\n' "$L" "$N" "$PAIRS" "$PROJS"
  done
  ;;
*) usage ;;
esac
