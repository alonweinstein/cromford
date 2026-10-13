#!/bin/bash
# tests/cost-grok-reprice.bh-3984-test.sh — a grok row's cost_usd is the
# fleet's own price of its tokens, not the vendor's figure, and no ladder
# runner's row with tokens lands blank.
#
# THE FAILURE (BH-3984, 2026-10-03). In D1, 169 grok-4.6 rows since 2026-09-21
# recorded $41.31 against a $770.31 reprice by cost_price_tokens over the same
# tokens. Every row that disagreed had taken its dollars from the ledger's
# costUsdTicks: bin/agent-call.sh priced the tokens only when the ticks were
# absent, and cost_row_price treated any dollar figure on the row as final.
# bin/grok-envelope-probe.sh did the same with the envelope's total_cost_usd.
#
#   R1  agent-call, below the cliff: col 13 = cost_price_tokens, col 19 = ticks.
#   R2  agent-call, above the cliff: col 13 = the function's doubled figure.
#   R3  agent-call, model absent from the table: col 13 = the ticks, no UNPRICED.
#   R4  grok-envelope-probe, priced model: col 13 = catalog, col 19 = 0.001200.
#   R5  agent-call, failed call with no ledger: col 13 EMPTY, not 0.
#   L1-L6 every survival-ladder runner/model the live ledger carries prices a
#       tokens row against the REAL catalog/model-prices.json.
# MUTATION (D1): revert the grok hunk in bin/agent-call.sh and R1/R2 go red;
# swap the probe's precedence back and R4 goes red.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/cost-grok-reprice.bh-3984-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# grok-4.6 at the catalog's real rates, cliff included.
cat > "$T/prices.json" <<'EOF'
{"per_token": {
  "grok-4.6": {"prompt": 0.000002, "completion": 0.000006, "cache_read": 5e-7, "cache_write": null, "cliff_tokens": 200000},
  "grok-4.7": {"prompt": 0.000002, "completion": 0.000006, "cache_read": 5e-7, "cache_write": null, "cliff_tokens": 200000}
}}
EOF
echo '{"per_token": {"grok-4.7": {"prompt": 0.000002, "completion": 0.000006}}}' > "$T/prices-no46.json"

# The pricer under test, sourced from the real library, read against the
# fixture table: what each row must equal.
price() ( export MODEL_PRICES="$1"; shift; . "$DIR/bin/lib/cost-row.sh"; cost_price_tokens "$@" )
near() { awk -v a="$1" -v b="$2" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(a!="" && b!="" && d<=0.01)}'; }

# ── R1-R3, R5: bin/agent-call.sh, driven ─────────────────────────────────────
A="$T/ac"; mkdir -p "$A/logs" "$A/flags" "$A/locks" "$A/.grok/bin" "$A/fakebin"
mrs_fixture "$A" testproj
cat > "$A/.grok/bin/grok" <<'EOF'
#!/bin/bash
# fake grok CLI: writes the ledger the test asked for, then answers.
if [ -n "${GROK_FIXTURE:-}" ]; then
  mkdir -p "$HOME/.grok/sessions/s-run"
  cp "$GROK_FIXTURE" "$HOME/.grok/sessions/s-run/updates.jsonl"
fi
echo "DECISION: BH-3984 :: skip :: fake"
exit "${GROK_EXIT:-0}"
EOF
chmod +x "$A/.grok/bin/grok"
printf '#!/bin/bash\necho subscription\n' > "$A/fakebin/billing-mode.sh"; chmod +x "$A/fakebin/billing-mode.sh"
printf '#!/bin/bash\n[ "${1:-}" = --kill-after ] && shift 2\ncase "${1:-}" in --kill-after=*) shift ;; esac\nshift\nexec "$@"\n' > "$A/fakebin/timeout"
chmod +x "$A/fakebin/timeout"

# ledger <file> <in> <out> <cache_read> <ticks> — the verified 2026-08-20 shape
# (usage nested in params.update, costUsdTicks in 1e-10 USD), one record.
ledger() {
  printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-3984","update":{"sessionUpdate":"usage","usage":{"inputTokens":%s,"outputTokens":%s,"cachedReadTokens":%s,"costUsdTicks":%s}}}}\n' \
    "$2" "$3" "$4" "$5" > "$1"
}
drive() { # drive <fixture-or-empty> <grok-exit> <prices>
  scratch_rm "$A/.grok/sessions"; rm -f "$A/logs/cost.csv"
  # The survival ladder must not engage: no vendor keys, fallback pinned to grok.
  ( unset OPENROUTER_API_KEY FIREWORKS_API_KEY XAI_API_KEY GROK_CODE_XAI_API_KEY \
          OPENAI_API_KEY CODEX_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY HARNESS_SECRET
    export HOME="$A" HARNESS="$A" PATH="$A/fakebin:$PATH" MODEL_PRICES="$3" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           GROK_FIXTURE="$1" GROK_EXIT="$2" \
           RUNNER_TRIAGE=grok RUNNER_TRIAGE_FALLBACK=grok
    bash "$DIR/bin/agent-call.sh" triage testproj grok-4.6 60 "$A/out.txt" "hello" >/dev/null 2>&1 )
}
col() { tail -1 "$A/logs/cost.csv" 2>/dev/null | awk -F, -v c="$1" '{print $c}'; }

# R1. below the cliff: 120000 + 50000 = 170000 context, ticks $0.05.
ledger "$T/r1.jsonl" 120000 4000 50000 500000000
drive "$T/r1.jsonl" 0 "$T/prices.json"
WANT=$(price "$T/prices.json" grok-4.6 120000 4000 50000 "")
[ "$WANT" = 0.289000 ] && ok || bad "R1 the fixture price is not what this suite assumes: '$WANT'"
[ "$(col 5)" = grok ] && [ "$(col 9)" = 120000 ] && ok || bad "R1 no grok row with the ledger's tokens: '$(tail -1 "$A/logs/cost.csv" 2>/dev/null)'"
near "$(col 13)" "$WANT" && ok || bad "R1 cost_usd (col 13) must be cost_price_tokens over the row's tokens ($WANT), not the vendor's ticks: got '$(col 13)'"
[ "$(col 13)" = "$WANT" ] && ok || bad "R1 cost_usd must equal the function exactly: got '$(col 13)' want '$WANT'"
[ "$(col 19)" = 0.050000 ] && ok || bad "R1 result_usd (col 19) must keep the vendor's ticks: got '$(col 19)'"
[ "$(col 18)" = ledger ] && ok || bad "R1 row_source (col 18): got '$(col 18)'"

# R2. above the cliff: 260000 + 40000 = 300000 > 200000, ticks $0.10.
ledger "$T/r2.jsonl" 260000 4000 40000 1000000000
drive "$T/r2.jsonl" 0 "$T/prices.json"
WANT=$(price "$T/prices.json" grok-4.6 260000 4000 40000 "")
[ "$WANT" = 1.128000 ] && ok || bad "R2 the fixture's cliff price is not doubled as this suite assumes: '$WANT'"
near "$(col 13)" "$WANT" && ok || bad "R2 cost_usd above the cliff must be the function's doubled figure ($WANT): got '$(col 13)'"
[ "$(col 19)" = 0.100000 ] && ok || bad "R2 result_usd (col 19) must keep the vendor's ticks: got '$(col 19)'"

# R3. the table cannot price grok-4.6: the vendor's ticks are the best figure.
drive "$T/r1.jsonl" 0 "$T/prices-no46.json"
[ "$(col 13)" = 0.050000 ] && ok || bad "R3 an unpriceable model keeps the vendor's ticks as cost_usd: got '$(col 13)'"
case "$(col 24)" in *UNPRICED*) bad "R3 a row priced by the vendor must not say UNPRICED: '$(col 24)'" ;; *) ok ;; esac

# R5. negative: a failed call with no ledger stays blank, never 0.
drive "" 1 "$T/prices.json"
[ "$(col 5)" = grok ] && [ "$(col 7)" != 0 ] && ok || bad "R5 the failed call's row must still land with its rc: '$(tail -1 "$A/logs/cost.csv" 2>/dev/null)'"
[ -z "$(col 13)" ] && ok || bad "R5 a failed call with no tokens must leave cost_usd EMPTY: got '$(col 13)'"

# ── R4: bin/grok-envelope-probe.sh, driven ────────────────────────────────────
H="$T/h"; GH="$T/home"
mkdir -p "$H/logs" "$H/env" "$H/state/model-routes" "$GH/.grok/bin"
: > "$H/env/global.env"
printf '0\tgrok-4.7\tgrok\n' > "$H/state/model-routes/grok.default.tsv"
cat > "$GH/.grok/bin/grok" <<'EOF'
#!/bin/bash
if [ "${1:-}" = --version ]; then echo "grok 1.0.40 (eb1a2256660d)"; exit 0; fi
P=""; while [ $# -gt 0 ]; do case "$1" in -p) P="$2"; shift 2 ;; *) shift ;; esac; done
jq -nc --arg n "${P##* }" '{type:"result",result:$n,session_id:"sess-3984",usage:{input_tokens:812,output_tokens:9},total_cost_usd:0.0012}'
EOF
chmod +x "$GH/.grok/bin/grok"
cat > "$T/jobs" <<'EOF'
#!/bin/bash
case "$1" in ledger-get) echo; exit 2 ;; ledger-put) exit 0 ;; esac
exit 2
EOF
chmod +x "$T/jobs"
POUT=$(env -u HARNESS_SECRET -u JOBS_URL -u GROK_MODEL \
       HOME="$GH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" PATH="$A/fakebin:$PATH" \
       GROK_PROBE_HOME="$GH" GROK_PROBE_JOBS="$T/jobs" HARNESS_ALERTS="$H/logs/ALERTS.log" \
       GROK_PROBE_CATALOG="$DIR/catalog/cli-min-versions.json" MODEL_PRICES="$T/prices.json" \
       bash "$DIR/bin/grok-envelope-probe.sh" --out "$T/probe-out" 2>&1); PRC=$?
pc() { tail -1 "$H/logs/cost.csv" 2>/dev/null | awk -F, -v n="$1" '{print $n}'; }
[ "$PRC" = 0 ] && ok || bad "R4 the probe must exit 0 (rc=$PRC): $POUT"
[ "$(pc 4)" = grok-envelope-probe ] && [ "$(pc 6)" = grok-4.7 ] && ok || bad "R4 no probe row: '$(tail -1 "$H/logs/cost.csv" 2>/dev/null)'"
WANT=$(price "$T/prices.json" grok-4.7 "$(pc 9)" "$(pc 10)" "$(pc 11)" "$(pc 12)")
[ -n "$WANT" ] && [ "$WANT" != 0.001200 ] && ok || bad "R4 the fixture must price the envelope's tokens to something other than the vendor's figure: '$WANT'"
[ "$(pc 13)" = "$WANT" ] && ok || bad "R4 the probe's cost_usd (col 13) must be the catalog price ($WANT), not the envelope's 0.0012: got '$(pc 13)'"
[ "$(pc 19)" = 0.001200 ] && ok || bad "R4 result_usd (col 19) must keep the envelope's dollars: got '$(pc 19)'"

# ── L1-L6: the survival ladder, against the real catalog ─────────────────────
# MODEL_PRICES unset and HARNESS a scratch root with no state table, so the
# chain resolves to this checkout's catalog/model-prices.json. A catalog
# regression that drops a ladder model goes red here.
mkdir -p "$T/empty-root"
n=0
while IFS='|' read -r runner model; do
  n=$((n+1))
  got=$( unset MODEL_PRICES; export HARNESS="$T/empty-root"; unset H
         . "$DIR/bin/lib/cost-row.sh"; cost_row_price "$runner" "$model" 0 1000 200 300 "" "" "" )
  usd="${got%%|*}"
  [ -n "$usd" ] && ok || bad "L$n $runner/$model: a row with tokens must never write a blank cost_usd (got '$got')"
  awk -v u="$usd" 'BEGIN{exit !(u+0 > 0)}' && ok || bad "L$n $runner/$model: cost_usd must be a positive price: '$usd'"
done <<'EOF'
claude|claude-opus-5-5
codex|gpt-6-astra
openrouter|anthropic/claude-opus-5.5
fireworks|accounts/fireworks/models/kimi-k2p7-code
grok|grok-4.7
openrouter|deepseek/deepseek-v4-flash
EOF

echo "cost-grok-reprice.bh-3984-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
