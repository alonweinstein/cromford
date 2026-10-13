#!/bin/bash
# Fleet cost read-out. Runs ON THE HUB, operator-run: renders the headline table
# of $HARNESS/state/cost/summary.json (written by bin/cost-rollup.sh) to
# $HARNESS/logs/cost-readout-<YYYYMMDD>.md and posts it to the console as a
# cost_readout beat. No model, no ssh, no cron self-removal (BH-2550): the rollup has
# already done the arithmetic, and a table needs no prose.
#
# Exit 0 = rendered and beat posted (beat.sh never fails the caller).
# Exit 2 = summary.json missing, empty or not a JSON object; nothing written.
# A null in summary.json means UNKNOWN (cost-rollup's convention) and renders
# `unknown`, never 0. A summary older than 26h (one daily rollup plus slack) is
# still rendered, under a STALE line naming its generated_at.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SUMMARY="$H/state/cost/summary.json"
STAMP=$(date -u +%Y%m%d)
OUT="$H/logs/cost-readout-$STAMP.md"
STALE_AFTER_S=$((26 * 3600))

[ -f "$SUMMARY" ] || { echo "cost-readout: $SUMMARY missing — run bin/cost-rollup.sh first" >&2; exit 2; }
jq -e 'type == "object"' "$SUMMARY" >/dev/null 2>&1 \
  || { echo "cost-readout: $SUMMARY is empty or not a JSON object" >&2; exit 2; }

GEN=$(jq -r '.generated_at // ""' "$SUMMARY")
GEN_S=""
[ -n "$GEN" ] && { GEN_S=$(date -u -d "$GEN" +%s 2>/dev/null) || GEN_S=""; }
STALE=""
if [ -z "$GEN_S" ]; then
  STALE="STALE: summary.json generated_at '$GEN' could not be read, so the age of these figures is unknown"
elif [ $(( $(date -u +%s) - GEN_S )) -gt "$STALE_AFTER_S" ]; then
  STALE="STALE: summary.json generated_at $GEN is more than 26h old — these figures are not current"
fi

TMP=$(mktemp "$H/logs/.cost-readout.XXXXXX") || { echo "cost-readout: cannot write to $H/logs" >&2; exit 2; }
trap 'rm -f "$TMP"' EXIT
jq -r --arg stamp "$STAMP" --arg stale "$STALE" '
  def money: if . == null then "unknown" else (. * 100 | round) as $c
    | (if $c < 0 then "-" else "" end) + "$"
      + ((if $c < 0 then -$c else $c end) as $a
         | (($a / 100 | floor) | tostring) + "."
           + (($a % 100) | tostring | if length < 2 then "0" + . else . end)) end;
  def count: if . == null then "unknown" else tostring end;
  def pct: if . == null then "unknown" else ((. * 100 | round | tostring) + "%") end;
  "# Fleet cost read-out — \($stamp)",
  "",
  "summary generated_at \(.generated_at // "unknown")",
  (if $stale != "" then $stale else empty end),
  "",
  "Fleet: notional 7d \(.fleet_notional_7d | money) | cash 7d \(.fleet_cash_7d | money) | cash 7d total \(.fleet_cash_7d_total | money) | unpriced calls 24h \(.fleet_unpriced_calls_24h | count)",
  "cash note: \(.cash_note // "unknown")",
  "",
  "| project | cost 24h | cost 7d | cash 7d | merged PRs 7d | $/merged PR 7d | triage share 7d |",
  "|---|---|---|---|---|---|---|",
  (if ((.projects // {}) | length) == 0 then "(no project rows in summary.json)"
   else (.projects | to_entries | sort_by(.key)[]
     | "| \(.key) | \(.value.cost_24h | money) | \(.value.cost_7d | money) | \(.value.cash_cost_7d | money) | \(.value.merged_prs_7d | count) | \(.value.cost_per_merged_pr_7d | money) | \(.value.triage_share_7d | pct) |")
   end)
' "$SUMMARY" > "$TMP" || { echo "cost-readout: could not render $SUMMARY" >&2; exit 2; }
mv "$TMP" "$OUT" || { echo "cost-readout: could not write $OUT" >&2; exit 2; }
trap - EXIT

"$H/bin/beat.sh" "$(jq -nc --arg akey "cost-readout:$STAMP" \
  --arg l "COST READ-OUT ($STAMP) — full file: $OUT" --arg d "$(head -c 7000 "$OUT")" \
  '{kind:"cost_readout",project:"fleet",akey:$akey,line:$l,detail:$d}')"
exit 0
