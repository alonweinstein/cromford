#!/bin/bash
# tests/pricing-one-table.bh-3990-test.sh — ONE price table: the DB row wins
# over the committed catalog in every reader, and the catalog carries the
# missing rows (BH-3990).
#
# The DB (worker/jobs model_prices) is the canonical table. bin/model-prices-sync.sh
# pulls it into $HARNESS/state/model-prices.json, and every box-side reader
# resolves that file before any catalog/model-prices.json. This suite runs the
# REAL sync against a fake GET whose claude-haiku-4-5 row disagrees with the
# committed catalog, then prices 1,000,000 input + 1,000,000 output tokens
# through each reader:
#
#   1  DB table present: every reader answers the DB rate ($9.00)
#   2  no state file: every reader falls back to the committed catalog rate
#   3  committed catalog: claude-haiku-4-5-20251001 prices > 0 with no
#      UNPRICED:no-price note, and a refresh run carries it into the live table
#   4  committed catalog: deepseek/deepseek-v4-flash (the one DeepSeek id the
#      ledger flagged UNPRICED:no-price since 2026-09-19) prices > 0
#
# Readers, each at the entry its production caller uses:
#   cost_price_tokens       bin/lib/cost-row.sh, sourced (agent-call, claude-cost)
#   transcript-cost.sh      run whole on a fixture session file
#   cost-rollup row_cost    its python, extracted (as tests/unpriced-alert.bh-1361-test.sh does)
#   cost_budget_rates_tsv   bin/lib/cost-budget.sh, sourced
#   planned-files-cheap     its catalog pick + floor-model choice, extracted
#   cache-hit-report        lane_cache_efficiency, extracted, its window_usd column
#   orchestrate             turn_cost_usd, extracted, with a fake claude-usage.sh
# The extracted readers have /root/harness-checkout swapped for a scratch
# checkout holding the committed catalog, so the host's own checkout (or its
# absence) never decides a case.
# Run from anywhere: tests/pricing-one-table.bh-3990-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }
unset MODEL_PRICES PLANNED_FILES_MODEL
CAT="$DIR/catalog/model-prices.json"
M=claude-haiku-4-5
mkdir -p "$T/bin" "$T/state/cost" "$T/logs" "$T/flags" "$T/catalog" "$T/checkout/catalog" "$T/noenv"
cp "$CAT" "$T/catalog/model-prices.json"; cp "$CAT" "$T/checkout/catalog/model-prices.json"

# The DB's answer: the committed table with $M repriced, plus a Claude-family
# row cheaper than anything in the catalog (planned-files-cheap's floor pick).
jq --arg m "$M" '.updated_at = "2026-10-03T04:30:00Z" | .source = "db"
  | .per_token[$m] = {"prompt":3e-6,"completion":6e-6,"cache_read":3e-7,"cache_write":3.75e-6,"slug":"anthropic/claude-haiku-4.5"}
  | .per_token["fixture-floor-claude"] = {"prompt":1e-9,"completion":1e-9,"slug":"anthropic/fixture-floor"}' \
  "$CAT" > "$T/db-get.json"
DB_USD=9.000000
CAT_USD=$(jq -r --arg m "$M" '.per_token[$m] | (1000000*.prompt + 1000000*.completion)' "$CAT" | awk '{printf "%.6f", $1}')
[ "$CAT_USD" != "$DB_USD" ] && awk -v c="$CAT_USD" 'BEGIN{exit !(c+0 > 0)}' \
  && ok || bad "fixture: the committed $M rate ($CAT_USD) must be > 0 and differ from the DB fixture's ($DB_USD)"
CAT_FLOOR=$(python3 -c '
import json, sys
rows = json.load(open(sys.argv[1]))["per_token"]
print(min((v["prompt"], k) for k, v in rows.items() if "/" not in k and isinstance(v, dict)
          and str(v.get("slug", "")).startswith("anthropic/") and isinstance(v.get("prompt"), (int, float)))[1])' "$CAT")

# --- the readers --------------------------------------------------------------
pin() { sed "s#/root/harness-checkout#$T/checkout#g"; }
# cost-rollup: its table pick, table load and row_cost, extracted.
python3 - "$DIR/bin/cost-rollup.sh" "$T/rollup.py" <<'EXTRACT'
import sys
src = open(sys.argv[1]).read()
i = src.index("def _prices_path():")
body = src[i:src.index("# per-build exact attribution", i)]
open(sys.argv[2], "w").write("import json, os, sys\nH = sys.argv[1]\n" + body
  + "r = dict(zip(['model','input_toks','output_toks','cache_read','cache_write','cost_usd','note'], sys.argv[2:9]))\n"
  + "print('%.6f' % row_cost(r))\n")
EXTRACT
pin < "$T/rollup.py" > "$T/rollup.pinned.py"
grep -q 'def row_cost' "$T/rollup.pinned.py" && grep -q 'def _prices_path' "$T/rollup.pinned.py" \
  && ok || bad "could not extract _prices_path/row_cost from bin/cost-rollup.sh — markers moved?"
sed -n '/^CAT=""$/,/^\[ -n "\$MODEL" \]/p' "$DIR/bin/planned-files-cheap.sh" | sed '$d' | pin > "$T/pfc.sh"
grep -q 'model-prices.json' "$T/pfc.sh" && grep -q '^MODEL=' "$T/pfc.sh" \
  && ok || bad "could not extract the catalog pick from bin/planned-files-cheap.sh"
sed -n '/^lane_cache_efficiency() {$/,/^}$/p' "$DIR/bin/cache-hit-report.sh" | pin > "$T/chr.sh"
grep -q 'cache-lane.csv' "$T/chr.sh" \
  && ok || bad "could not extract lane_cache_efficiency from bin/cache-hit-report.sh"
sed -n '/^turn_cost_usd() {/,/^}$/p' "$DIR/bin/orchestrate.sh" | pin > "$T/orc.sh"
grep -q 'claude-usage.sh' "$T/orc.sh" \
  && ok || bad "could not extract turn_cost_usd from bin/orchestrate.sh"
printf '#!/bin/bash\necho "1000000|1000000|0|0"\n' > "$T/bin/claude-usage.sh"; chmod +x "$T/bin/claude-usage.sh"
printf '{"type":"assistant","uuid":"u1","timestamp":"2026-10-03T10:00:00Z","message":{"id":"msg_1","model":"%s","usage":{"input_tokens":1000000,"output_tokens":1000000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$M" > "$T/session.jsonl"

r_cost_row()  { ( HARNESS="$T"; . "$DIR/bin/lib/cost-row.sh" && cost_price_tokens "$1" 1000000 1000000 ); }
r_transcript() { HARNESS="$T" HARNESS_ENV_DIR="$T/noenv" bash "$DIR/bin/transcript-cost.sh" "$T/session.jsonl" 2>/dev/null | cut -d'|' -f5 | awk 'NF{printf "%.6f", $1}'; }
r_rollup()    { python3 "$T/rollup.pinned.py" "$T" "$1" 1000000 1000000 0 0 "" ""; }
r_budget()    { ( HARNESS="$T"; . "$DIR/bin/lib/cost-budget.sh" && cost_budget_rates_tsv ) \
                  | awk -F'\t' -v m="$1" '$1 == m {printf "%.6f", 1000000*$2 + 1000000*$3}'; }
r_pfc()       { ( HARNESS="$T"; HERE="$DIR/bin"; MODEL=""; . "$T/pfc.sh"; printf '%s' "$MODEL" ); }
r_cachehit()  {
  rm -f "$T/logs/cache-lane.csv"
  printf 'ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,note\n2026-10-03T10:00:00Z,b,p,eval,claude,%s,0,1,1000000,1000000,0,1,,\n' "$1" > "$T/state/cost/fleet-cost.csv"
  ( H="$T"; STAMP() { date -u +%FT%TZ; }; alert_emit() { :; }; . "$T/chr.sh"; lane_cache_efficiency )
  tail -1 "$T/logs/cache-lane.csv" 2>/dev/null | awk -F, '{print $6}'
}
r_orc()       { ( HARNESS="$T"; ORC="$T"; ORC_MODEL="$1"; . "$T/orc.sh"; turn_cost_usd 0 "$1" ); }

# --- 1. the REAL sync lands the DB's table, and every reader prices from it ---
cat > "$T/bin/jobs-client.sh" <<SH
. "$DIR/bin/lib/jobs/cost.sh"
_jobs_req() { cat "$T/db-get.json"; }
SH
( HARNESS="$T" HARNESS_ENV_DIR="$T/noenv" bash "$DIR/bin/model-prices-sync.sh" ) >/dev/null 2>&1
jq -e --arg m "$M" '.source == "db" and .per_token[$m].prompt == 3e-6' "$T/state/model-prices.json" >/dev/null 2>&1 \
  && ok || bad "1: bin/model-prices-sync.sh did not land the DB table in state/model-prices.json"

[ "$(r_cost_row "$M")" = "$DB_USD" ] \
  && ok || bad "1: cost_price_tokens priced from '$(r_cost_row "$M")', want the DB's $DB_USD"
[ "$(r_transcript)" = "$DB_USD" ] \
  && ok || bad "1: transcript-cost.sh priced '$(r_transcript)', want the DB's $DB_USD"
[ "$(r_rollup "$M")" = "$DB_USD" ] \
  && ok || bad "1: cost-rollup row_cost priced '$(r_rollup "$M")', want the DB's $DB_USD"
[ "$(r_budget "$M")" = "$DB_USD" ] \
  && ok || bad "1: cost_budget_rates_tsv priced '$(r_budget "$M")', want the DB's $DB_USD"
[ "$(r_pfc)" = fixture-floor-claude ] \
  && ok || bad "1: planned-files-cheap chose '$(r_pfc)' as the floor, want the DB table's fixture-floor-claude"
[ "$(r_cachehit "$M")" = 9.00 ] \
  && ok || bad "1: cache-hit-report window_usd is '$(r_cachehit "$M")', want the DB's 9.00"
[ "$(r_orc "$M")" = 9.00 ] \
  && ok || bad "1: orchestrate turn_cost_usd is '$(r_orc "$M")', want the DB's 9.00"

# --- 2. no state file: the committed catalog is the seeded fallback ----------
rm -f "$T/state/model-prices.json"
CAT2=$(awk -v c="$CAT_USD" 'BEGIN{printf "%.2f", c}')
[ "$(r_cost_row "$M")" = "$CAT_USD" ] \
  && ok || bad "2: with no state file cost_price_tokens priced '$(r_cost_row "$M")', want the catalog's $CAT_USD"
[ "$(r_transcript)" = "$CAT_USD" ] \
  && ok || bad "2: with no state file transcript-cost.sh priced '$(r_transcript)', want the catalog's $CAT_USD"
[ "$(r_rollup "$M")" = "$CAT_USD" ] \
  && ok || bad "2: with no state file row_cost priced '$(r_rollup "$M")', want the catalog's $CAT_USD"
[ "$(r_budget "$M")" = "$CAT_USD" ] \
  && ok || bad "2: with no state file cost_budget_rates_tsv priced '$(r_budget "$M")', want the catalog's $CAT_USD"
[ "$(r_pfc)" = "$CAT_FLOOR" ] \
  && ok || bad "2: with no state file planned-files-cheap chose '$(r_pfc)', want the catalog's floor $CAT_FLOOR"
[ "$(r_cachehit "$M")" = "$CAT2" ] \
  && ok || bad "2: with no state file cache-hit-report window_usd is '$(r_cachehit "$M")', want the catalog's $CAT2"
[ "$(r_orc "$M")" = "$CAT2" ] \
  && ok || bad "2: with no state file orchestrate turn_cost_usd is '$(r_orc "$M")', want the catalog's $CAT2"

# --- 3. the dated Haiku 4.5 id, against the COMMITTED catalog -----------------
H45=claude-haiku-4-5-20251001
P=$(r_cost_row "$H45")
awk -v c="$P" 'BEGIN{exit !(c+0 > 0)}' \
  && ok || bad "3: cost_price_tokens $H45 priced '${P:-<nothing>}', want > 0"
PN=$( ( HARNESS="$T"; . "$DIR/bin/lib/cost-row.sh" && cost_row_price claude "$H45" 0 1000 1000 "" "" "" "" ) )
case "$PN" in *UNPRICED*) bad "3: cost_row_price $H45 still notes it unpriced: $PN" ;; *) ok ;; esac
P=$(r_rollup "$H45")
awk -v c="$P" 'BEGIN{exit !(c+0 > 0)}' \
  && ok || bad "3: cost-rollup row_cost priced a $H45 row at '$P', want > 0"
# The live table is built from catalog/model-slugs.json alone: a refresh run on
# the committed map must carry the key into state/model-prices.json (and so the DB).
R="$T/refresh"; mkdir -p "$R/bin/lib" "$R/state" "$R/logs" "$R/checkout/catalog" "$T/fakebin"
cp "$DIR/bin/update-model-prices.sh" "$R/bin/"; cp "$DIR/bin/lib/endpoints.sh" "$R/bin/lib/"
cp "$CAT" "$R/checkout/catalog/model-prices.json"
jq '{data: [ [.[]] | unique | .[] | {id: ., pricing: {prompt: "0.000001", completion: "0.000005"}} ]}' \
  "$DIR/catalog/model-slugs.json" > "$R/openrouter.json"
printf '#!/bin/bash\ncat "%s/openrouter.json"\n' "$R" > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
printf '#!/bin/bash\nexit 0\n' > "$R/bin/lane-alert.sh"; chmod +x "$R/bin/lane-alert.sh"
( HARNESS="$R" HARNESS_CHECKOUT="$R/checkout" MODEL_SLUGS="$DIR/catalog/model-slugs.json" \
  ENDPOINT_OPENROUTER=https://openrouter.ai PATH="$T/fakebin:$PATH" \
  bash "$R/bin/update-model-prices.sh" ) >/dev/null 2>&1
[ "$(jq -r --arg m "$H45" '.per_token[$m].slug // empty' "$R/state/model-prices.json" 2>/dev/null)" = anthropic/claude-haiku-4.5 ] \
  && ok || bad "3: a refresh on the committed slug map left $H45 out of the live table (the DB never gets the row)"

# --- 4. the DeepSeek id the ledger flagged UNPRICED:no-price -----------------
P=$(r_cost_row deepseek/deepseek-v4-flash)
awk -v c="$P" 'BEGIN{exit !(c+0 > 0)}' \
  && ok || bad "4: cost_price_tokens deepseek/deepseek-v4-flash priced '${P:-<nothing>}', want > 0"

echo "pricing-one-table.bh-3990-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
