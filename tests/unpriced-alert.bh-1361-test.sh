#!/bin/bash
# tests/unpriced-alert.bh-1361-test.sh — the UNPRICED alert names the exact
# catalog line to add.
#
# THE FAILURE (BH-1361, from #1360). The alert says "add the model to
# catalog/model-prices.json" and stops there, so closing it means working out
# which OpenRouter slug prices the model — from a 400-entry API list — before
# anything can be edited. Both times it fired (grok 2026-08-19,
# claude-opus-4-8 2026-09-22) the spend kept reading as $0.00 for days. Now the
# map is data (catalog/model-slugs.json, BH-1361) so the fix is ONE line, and
# the alert is the thing that knows enough to write it.
#
# Both halves are driven, not grepped: the suggestion runs inside the script's
# own unpriced_pairs() against a fixture CSV, and the shell alert block is
# extracted from the script and fired against a fixture summary.json.
#
# SRC=<path> runs it against another copy of bin/cost-rollup.sh (the red proof).
# Run from anywhere: tests/unpriced-alert.bh-1361-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="${SRC:-$DIR/bin/cost-rollup.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
mkdir -p "$T/logs" "$T/flags" "$T/cost" "$T/state"
mkdir -p "$T/bin"; cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$T/bin/"
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

# ── A. the suggestion, inside the shipped unpriced_pairs() ───────────────────
# Same extraction the sibling suite uses, with H pointed at the scratch tree so
# the helper finds state/openrouter-models.json where the refresh writes it.
python3 - "$SRC" "$T/core.py" <<'EXTRACT'
import sys
src = open(sys.argv[1]).read()
body = src[src.index("import csv, json, glob, os, re, sys, datetime, subprocess"):]
def grab(name, upto):
    i = body.index(name)
    return body[i:body.index(upto, i)]
out = ["import csv, json, datetime, sys\n"
       "H = sys.argv[4]\nCD = sys.argv[1]\n"
       "prices = json.load(open(sys.argv[2]))\n"
       "now = datetime.datetime.fromisoformat(sys.argv[3])\n"]
out.append(grab("def row_cost(r):", "# per-build exact attribution"))
out.append(grab("def unpriced_pairs(days=1):", "# Real projects come from fleet.conf"))
out.append("print(json.dumps(unpriced_pairs(1)))\n")
open(sys.argv[2], "w").write("\n".join(out))
EXTRACT
[ -s "$T/core.py" ] && grep -q 'def unpriced_pairs' "$T/core.py" && ok \
  || bad "could not extract row_cost/unpriced_pairs from cost-rollup.sh — markers moved?"

# claude-opus-5 IS in the table, priced to zero: it still lands in the pairs
# list, and it is the control for "a priced model never gets a suggestion".
cat > "$T/prices.json" <<'EOF'
{"claude-opus-5": {"prompt": 0, "completion": 0}}
EOF
cat > "$T/cost/fleet-cost.csv" <<'EOF'
ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode
2026-09-22T11:00:00Z,box1,alpha-os,execute,claude,claude-opus-4-8,0,60,19000000,500000,0,0,,subscription
2026-09-22T11:01:00Z,box1,alpha-os,review,openrouter,deepseek/deepseek-v4-flash,0,60,5000000,200000,0,0,,metered
2026-09-22T11:02:00Z,box1,beta-os,triage,grok,grok-4.6,0,60,1000,100,0,0,,metered
2026-09-22T11:03:00Z,box1,beta-os,plan,weird,zzz-unrelated-9000,0,60,900,100,0,0,,metered
2026-09-22T11:04:00Z,box1,beta-os,execute,claude,claude-opus-5,0,60,1000,100,0,0,,subscription
EOF
# The list the refresh persists. Two grok ids on purpose: the hint must pick the
# one the model actually names, not merely something that looks close.
cat > "$T/state/openrouter-models.json" <<'EOF'
{"fetched_at":"2026-09-22T04:30:00Z","ids":["anthropic/claude-opus-4.8","anthropic/claude-opus-5","deepseek/deepseek-v4-flash","x-ai/grok-4.6","x-ai/grok-4.5","openai/gpt-6-astra"]}
EOF
pairs() { python3 "$T/core.py" "$T/cost" "$T/prices.json" 2026-09-22T12:00:00 "$T"; }
J=$(pairs)
sug() { jq -r --arg m "$1" '[.[]|select(.model==$m)][0].suggested_slug' <<<"$J"; }

[ "$(sug 'deepseek/deepseek-v4-flash')" = "deepseek/deepseek-v4-flash" ] && ok \
  || bad "A1: a model that IS an openrouter id must suggest itself (got $(sug 'deepseek/deepseek-v4-flash'))"
[ "$(sug 'claude-opus-4-8')" = "anthropic/claude-opus-4.8" ] && ok \
  || bad "A2: claude-opus-4-8 must fuzzy-match anthropic/claude-opus-4.8 (got $(sug 'claude-opus-4-8'))"
[ "$(sug 'grok-4.6')" = "x-ai/grok-4.6" ] && ok \
  || bad "A3: the closest id wins, not merely a near one (got $(sug 'grok-4.6'))"
[ "$(sug 'zzz-unrelated-9000')" = null ] && ok \
  || bad "A4: a model with no close id must suggest nothing, never invent a slug (got $(sug 'zzz-unrelated-9000'))"
[ "$(sug 'claude-opus-5')" = null ] && ok \
  || bad "A5: a model that HAS a price row needs no slug (got $(sug 'claude-opus-5'))"
# The pairs themselves must be unchanged by the addition.
[ "$(jq -r '[.[]|select(.model=="claude-opus-4-8")][0].calls' <<<"$J")" = 1 ] && ok \
  || bad "the existing pair fields must survive the suggestion"

# A6/A7: the hint is optional everywhere. state/ is hub-only, and a box that
# has never run the refresh (or has a half-written file) must still get its
# alert — a missing hint is a missing hint, not a missing alert.
mv "$T/state/openrouter-models.json" "$T/orm.keep"
J=$(pairs); RC=$?
[ "$RC" = 0 ] && [ "$(jq -r '[.[]|select(.suggested_slug != null)]|length' <<<"$J")" = 0 ] && ok \
  || bad "A6: with no id list every suggestion is null and the rollup still runs (rc=$RC)"
printf 'not json\n' > "$T/state/openrouter-models.json"
J=$(pairs); RC=$?
[ "$RC" = 0 ] && [ "$(jq -r '[.[]|select(.suggested_slug != null)]|length' <<<"$J")" = 0 ] && ok \
  || bad "A7: an unreadable id list must degrade to null, not raise (rc=$RC)"
mv "$T/orm.keep" "$T/state/openrouter-models.json"

# ── B. the ALERTS line, extracted and fired ──────────────────────────────────
awk '/^# >>> unpriced call alert/{f=1;next} /^# <<< unpriced call alert/{exit} f' "$SRC" > "$T/alert.sh"
[ -s "$T/alert.sh" ] && ok || bad "could not extract the unpriced alert block — markers missing?"
fire() { # fire <summary-json> -> appends to ALERTS.log in the fixture tree
  rm -f "$T/logs/ALERTS.log" "$T/flags/"*
  printf '%s' "$1" > "$T/cost/summary.json"
  H="$T" CD="$T/cost" bash -c 'STAMP(){ echo TS; }; . "$0"' "$T/alert.sh"
}

fire '{"fleet_unpriced_calls_24h":28,"prices_loaded":40,"fleet_unpriced_pairs_24h":[
  {"runner":"claude","model":"claude-opus-4-8","calls":28,"tokens":19500000,"in_price_table":false,"suggested_slug":"anthropic/claude-opus-4.8"}]}'
L=$(tail -1 "$T/logs/ALERTS.log" 2>/dev/null)
grep -qF 'add to catalog/model-slugs.json: "claude-opus-4-8": "anthropic/claude-opus-4.8"' <<<"$L" && ok \
  || bad "B1: the alert must name the exact catalog line to add (got: '$L')"
grep -qF 'claude/claude-opus-4-8 (28 call(s), 19500000 tokens)' <<<"$L" && ok \
  || bad "B1: the pair and its counts must survive (got: '$L')"

fire '{"fleet_unpriced_calls_24h":3,"prices_loaded":40,"fleet_unpriced_pairs_24h":[
  {"runner":"claude","model":"claude-opus-4-8","calls":3,"tokens":900,"in_price_table":false,"suggested_slug":null}]}'
L=$(tail -1 "$T/logs/ALERTS.log" 2>/dev/null)
grep -qF '"claude-opus-4-8": "<slug?>"' <<<"$L" && ok \
  || bad "B2: with no match the line must show the key and an honest placeholder (got: '$L')"
grep -q 'no close openrouter match' <<<"$L" && ok \
  || bad "B2: with no match the alert must say so and point at the id list (got: '$L')"
grep -q 'openrouter.ai/api/v1/models' <<<"$L" && ok \
  || bad "B2: the operator must be told where the ids come from (got: '$L')"

# A summary written by the PREVIOUS rollup carries no suggested_slug at all.
# Under `set -u` that must read as "no suggestion", never as an error.
fire '{"fleet_unpriced_calls_24h":3,"prices_loaded":40,"fleet_unpriced_pairs_24h":[
  {"runner":"claude","model":"claude-opus-4-8","calls":3,"tokens":900,"in_price_table":false}]}' && ok \
  || bad "B3: a summary without the new key must not fail the rollup"
L=$(tail -1 "$T/logs/ALERTS.log" 2>/dev/null)
grep -qF '"claude-opus-4-8": "<slug?>"' <<<"$L" && ok \
  || bad "B3: an absent key must behave exactly like a null one (got: '$L')"

# B4: everything the line already said, it still says. The refreshed price row
# still has to land in the committed fallback, and the family note is what tells
# a reader the call-site guard exists.
fire '{"fleet_unpriced_calls_24h":20,"prices_loaded":40,"fleet_unpriced_pairs_24h":[
  {"runner":"fireworks","model":"kimi-k3","calls":12,"tokens":1100,"in_price_table":false,"suggested_slug":null},
  {"runner":"grok","model":"grok-4.6","calls":5,"tokens":0,"in_price_table":true,"suggested_slug":null},
  {"runner":"openrouter","model":"deepseek","calls":3,"tokens":900,"in_price_table":true,"suggested_slug":null}]}'
L=$(tail -1 "$T/logs/ALERTS.log" 2>/dev/null)
for S in '20 call(s) in the last 24h are UNPRICED' 'No price-table entry:' 'catalog/model-prices.json' \
         'No tokens reported: grok/grok-4.6 (5 call(s))' 'Priced model, still $0: openrouter/deepseek' \
         'cost-capture-parity'; do
  grep -qF "$S" <<<"$L" && ok || bad "B4: the alert lost '$S' (got: '$L')"
done
# A priced model is not sent to the slug catalog: its row exists, the parse is
# the problem, and naming a slug there would send the operator to the wrong file.
[ "$(grep -cF 'add to catalog/model-slugs.json: "grok-4.6"' <<<"$L")" = 0 ] && ok \
  || bad "B4: a priced pair must not be given a catalog line (got: '$L')"

echo "unpriced-alert.bh-1361-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
