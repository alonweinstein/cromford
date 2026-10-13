#!/bin/bash
# tests/unpriced-pairs-priced.bh-2306-test.sh — every runner/model pair behind
# the unpriced cost rows of 2026-09-18..24 is priced by the shipped pricer.
#
# THE AUDIT (BH-2306, docs/notes/2026-09-25-BH-2306-unpriced-pairs.md). About
# 2,450 rows across cromford and project-5 carry cost_usd NULL in D1. Every
# model behind them was already in catalog/model-prices.json: the token-bearing
# rows predate the call-site pricer (cost_row_price, BH-1020), and the rest are
# failed calls that never consumed a token. So there was no price row to add.
# What this suite stops is the regression: one of these keys dropping out of
# the catalog (a refresh that renames it, a hand edit) and the same models going
# back to $0.00 on every cap and on the Costs page.
#
# It drives the real call-site pricer, bin/lib/cost-row.sh, the function every
# bin/agent-call.sh row passes through — not a jq over the catalog.
#
# MODEL_PRICES=<path> prices from another table (the red proof: a copy of the
# catalog without the kimi key must fail this suite).
# Run from anywhere: tests/unpriced-pairs-priced.bh-2306-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

export MODEL_PRICES="${MODEL_PRICES:-$DIR/catalog/model-prices.json}"
# shellcheck source=/dev/null
. "$DIR/bin/lib/cost-row.sh" || { echo "FAIL: could not source bin/lib/cost-row.sh"; exit 1; }
command -v cost_price_tokens >/dev/null 2>&1 && command -v cost_row_price >/dev/null 2>&1 \
  || { echo "FAIL: cost_price_tokens/cost_row_price not defined by bin/lib/cost-row.sh"; exit 1; }

gt0() { python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 0 else 1)' "$1" 2>/dev/null; }

# The model strings exactly as cost_rows.model carries them in the audit.
while read -r M; do
  [ -n "$M" ] || continue
  P=$(cost_price_tokens "$M" 1000 1000 0 0)
  if [ -n "$P" ] && gt0 "$P"; then ok; else bad "cost_price_tokens '$M' must price 1000/1000 tokens above zero (got '$P')"; fi
done <<'EOF'
deepseek/deepseek-v4-flash
accounts/fireworks/models/kimi-k2p7-code
anthropic/claude-fable-5.1
gpt-6-astra
grok-4.7
accounts/fireworks/models/deepseek-v4-flash-0731
anthropic/claude-opus-5
anthropic/claude-sonnet-5
claude-opus-5
EOF

# The call-site pricer on a successful token-bearing row with no vendor dollar
# figure: the usd half of "<usd>|<note>" must come back filled, and the note
# must not carry the UNPRICED marker.
for M in deepseek/deepseek-v4-flash accounts/fireworks/models/kimi-k2p7-code; do
  R=$(cost_row_price openrouter "$M" 0 1000 1000 0 0 "" "")
  USD=${R%%|*}
  if [ -n "$USD" ] && gt0 "$USD" && ! grep -q UNPRICED <<<"$R"; then ok
  else bad "cost_row_price for a billed $M row must fill the dollar half (got '$R')"; fi
done

echo "unpriced-pairs-priced: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
