#!/bin/bash
# tests/cost-row-priced-test.sh — every runner's row is PRICED at write time,
# and a row that could not be priced says so instead of shipping a silent blank.
#
# THE FAILURE (BH-1020, the 2026-09-17..19 spend audit). run_attempt captures
# tokens for the codex-driven lanes and only the grok branch ever priced them:
# bin/agent-call.sh:1195 (codex), :1266 (openrouter) and :1332 (fireworks) each
# read `IN OUTT CR CW` out of the CLI's own ledger and no line after them
# assigns USD. The row assembly then wrote `$USD` as it found it — empty — and
# cost_rows-push.sh mirrored that blank into the DB. 1,987 rows and about $3.5K
# in three days read as $0.00 on every cost view: the DB mirror, run-build.sh's
# COST_LINE, builder-direct.sh's per-build cost, run-triage.sh's spend line and
# cost-reconcile.sh itself. Only bin/cost-rollup.sh prices a blank row from its
# tokens, and every reader that does not go through the rollup saw the fleet's
# busiest runners as weightless.
#
# The fix is one choke point: cost_row_price in bin/lib/cost-row.sh, called once
# in run_attempt for EVERY runner, immediately before the row is assembled.
#
# Sections:
#   A. cost_row_price itself, extracted by its markers and executed
#   B. bin/agent-call.sh DRIVEN (the production entry point) across openrouter
#      and grok, plus the mutation guard that proves B1 goes red without the
#      function
#
# Run from anywhere: tests/cost-row-priced-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1510.1: agent-call reads its ladders from model_routes; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" testproj
FIX="$DIR/tests/fixtures"
mkdir -p "$T/bin/lib" "$T/logs" "$T/flags" "$T/locks" "$T/fakebin" "$T/.codex/sessions"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }

# The table every section prices against. anthropic/claude-fable-5.1 carries the
# rates catalog/model-prices.json actually publishes today (prompt 1e-5,
# completion 5e-5, cache_read 2.5e-7, cache_write 1.25e-5) — cache_read is the
# ticket's own "as reported", so it must be multiplied by the count the vendor
# gave and never dropped. grok-4.6's null cache_write rate is a rate xAI does
# not publish: it contributes 0 without voiding the row.
cat > "$T/prices.json" <<'EOF'
{"per_token": {
  "anthropic/claude-fable-5.1": {"prompt": 0.00001, "completion": 0.00005,
                                 "cache_read": 2.5e-7, "cache_write": 0.0000125},
  "grok-4.6": {"prompt": 0.000002, "completion": 0.000006,
               "cache_read": 5e-7, "cache_write": null}
}}
EOF

# ── A. cost_row_price ────────────────────────────────────────────────────────
echo "--- A. cost_row_price"
# Extracted by MARKERS, so a build that deletes the fence fails here rather than
# quietly testing nothing. cost_price_tokens rides along because cost_row_price
# is the thing that CALLS it — a pricer tested against a stub would prove the
# plumbing and not the price.
awk '/^# >>> cost_price_tokens/{f=1;next} /^# <<< cost_price_tokens/{exit} f' \
  "$DIR/bin/lib/cost-row.sh" > "$T/bin/price.sh"
awk '/^# >>> cost_row_price/{f=1;next} /^# <<< cost_row_price/{exit} f' \
  "$DIR/bin/lib/cost-row.sh" > "$T/bin/priced.sh"
[ -s "$T/bin/price.sh" ] && grep -q 'cost_price_tokens()' "$T/bin/price.sh" && ok \
  || bad "A could not extract cost_price_tokens from bin/lib/cost-row.sh — markers missing?"
[ -s "$T/bin/priced.sh" ] && grep -q 'cost_row_price()' "$T/bin/priced.sh" && ok \
  || bad "A could not extract cost_row_price from bin/lib/cost-row.sh — markers missing?"

pr() { # pr <args...> — cost_row_price against the fixture table
  ( MODEL_PRICES="$T/prices.json"; . "$T/bin/price.sh"; . "$T/bin/priced.sh"
    cost_row_price "$@" )
}
pr_notable() { # the same call with the price table missing entirely
  ( MODEL_PRICES="$T/no-such-table.json"; . "$T/bin/price.sh"; . "$T/bin/priced.sh"
    cost_row_price "$@" )
}

# A1. THE TICKET'S OWN CASE: fable via openrouter, at the catalog's API rate,
# with cache_read priced at the count the vendor reported.
#   1000*1e-5 + 100*5e-5 + 4000*2.5e-7 + 0 = 0.010 + 0.005 + 0.001 = 0.016
OUT=$(pr openrouter anthropic/claude-fable-5.1 0 1000 100 4000 0 "" "")
[ "$OUT" = "0.016000|" ] && ok \
  || bad "A1 an openrouter row with tokens must price to the catalog product: expected '0.016000|', got '$OUT'"
# ...and dropping cache_read would answer 0.015000, which is the number a
# reader would never know was short. Pin the difference, not just the total.
OUT2=$(pr openrouter anthropic/claude-fable-5.1 0 1000 100 "" "" "" "")
[ "$OUT2" = "0.015000|" ] && [ "$OUT2" != "$OUT" ] && ok \
  || bad "A1 cache_read must move the price — with it '$OUT', without it '$OUT2'"

# A2. the ticket's second case: a grok row with zero tokens. UNPRICED in the
# note, and cost_usd EMPTY — never 0, which would read as "this call was free".
OUT=$(pr grok grok-4.6 0 "" "" "" "" "" "")
[ "$OUT" = "|UNPRICED:no-usage" ] && ok \
  || bad "A2 a billed call that reported no usage must be marked UNPRICED: got '$OUT'"
[ "${OUT%%|*}" != "0" ] && ok || bad "A2 an unpriceable row must be EMPTY, never 0: got '$OUT'"

# A3. NEGATIVE: a failed call was never billed. No marker, no change at all —
# the same reading cost_parity_alert and the rollup's unpriced_pairs apply.
OUT=$(pr grok grok-4.6 1 "" "" "" "" "" "")
[ "$OUT" = "|" ] && ok || bad "A3 a failed call must not be marked as unpriced spend: got '$OUT'"

# A4. tokens, but no price row for the model. That is a DIFFERENT fault from no
# usage — one needs a catalog entry, the other needs the runner's usage capture
# fixed — so it gets its own reason and names the model to add.
OUT=$(pr fireworks accounts/fireworks/models/nobody-knows 0 10 1 "" "" "" "")
[ "$OUT" = "|UNPRICED:no-price:accounts/fireworks/models/nobody-knows" ] && ok \
  || bad "A4 a model the table does not carry must say no-price and name it: got '$OUT'"

# A5. NEGATIVE: a vendor's own dollar figure is never overwritten by a catalog
# price. grok's costUsdTicks and claude's transcript dollars stay what they were.
OUT=$(pr grok grok-4.6 0 402118 11003 128044 2011 0.905636 "")
[ "$OUT" = "0.905636|" ] && ok \
  || bad "A5 a vendor dollar figure must survive untouched: got '$OUT'"

# A6. the note column already carries the cliff-route decision on some rows
# (BH-656). A marker JOINS it; it does not replace it.
OUT=$(pr grok grok-4.6 0 "" "" "" "" "" "cliff-routed:grok:300000>200000")
[ "$OUT" = "|cliff-routed:grok:300000>200000;UNPRICED:no-usage" ] && ok \
  || bad "A6 an existing note must survive beside the marker: got '$OUT'"

# A7. NO TABLE AT ALL is not a zero either. A box whose catalog sync has not
# landed prices nothing and says so.
OUT=$(pr_notable openrouter anthropic/claude-fable-5.1 0 1000 100 "" "" "" "")
[ "$OUT" = "|UNPRICED:no-price:anthropic/claude-fable-5.1" ] && ok \
  || bad "A7 a missing price table must be no-price, never 0: got '$OUT'"

# A8. a vendor that reports literal zero counts HAS reported. That is its
# statement, not an absence, so it prices to 0.000000 and carries no marker.
OUT=$(pr openrouter anthropic/claude-fable-5.1 0 0 0 0 0 "" "")
[ "$OUT" = "0.000000|" ] && ok \
  || bad "A8 literal zero counts are a vendor statement, not a blank: got '$OUT'"

# ── B. the production entry point: bin/agent-call.sh ─────────────────────────
echo "--- B. bin/agent-call.sh (driven)"
# A green section A would prove nothing on its own: the blank rows came out of
# THIS script, and the whole point of the fix is that one line every runner's
# row passes through now prices it.
cp "$DIR/bin/codex-usage.sh" "$T/bin/"
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"; chmod +x "$T/bin/billing-mode.sh"

# The REAL captured codex ledger shape, verbatim from tests/codex-usage-test.sh
# section 0 (a live hub session, 2026-08-24): the counts live nested at
# .payload.info.total_token_usage. An invented fixture here would reproduce the
# original bug with a green tick on top.
cat > "$T/codex-real.jsonl" <<'EOF'
{"timestamp":"2026-08-24T13:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":44450,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":18,"reasoning_output_tokens":0,"total_tokens":44468}}}}
EOF

cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
# fake codex CLI: writes the session ledger the test asked for, then answers the
# way the real one does (the final message goes to --output-last-message).
OUTF=""
while [ $# -gt 0 ]; do
  case "$1" in --output-last-message) OUTF="${2:-}"; shift 2 ;; *) shift ;; esac
done
if [ -n "${CODEX_FIXTURE:-}" ]; then
  mkdir -p "$HOME/.codex/sessions/run"
  cp "$CODEX_FIXTURE" "$HOME/.codex/sessions/run/rollout-x.jsonl"
fi
[ -n "$OUTF" ] && echo "DECISION: BH-1020 :: skip :: fake" > "$OUTF"
echo "fake codex done"
exit "${CODEX_EXIT:-0}"
EOF
chmod +x "$T/fakebin/codex"

# The grok half of B3, same fake CLI the sibling suite uses.
mkdir -p "$T/.grok/bin"
cat > "$T/.grok/bin/grok" <<'EOF'
#!/bin/bash
if [ -n "${GROK_FIXTURE:-}" ]; then
  mkdir -p "$HOME/.grok/sessions/s-run"
  cp "$GROK_FIXTURE" "$HOME/.grok/sessions/s-run/updates.jsonl"
fi
echo "DECISION: BH-1020 :: skip :: fake"
exit 0
EOF
chmod +x "$T/.grok/bin/grok"

# GNU timeout is not on every dev box and agent-call.sh wraps every runner in
# it. Same shim the sibling suite uses: strip --kill-after and the duration.
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/timeout"

# THE FENCE. On a real fleet box every vendor key is in the ambient env with a
# real CLI on PATH, so an unfenced drive of this suite spends actual money on
# whichever lane the ladder reaches. Every key but the fake OPENROUTER one is
# dropped, and the fake codex on PATH is what the openrouter lane resolves.
drive() { # drive <harness-root> <script> <runner> <codex-fixture> <grok-fixture> <model>
  rm -rf "${T:?}/.codex/sessions" "${T:?}/.grok/sessions"
  mkdir -p "$T/.codex/sessions"
  ( unset XAI_API_KEY GROK_CODE_XAI_API_KEY OPENAI_API_KEY CODEX_API_KEY \
          GEMINI_API_KEY ANTHROPIC_API_KEY FIREWORKS_API_KEY OPENROUTER_API_KEY
    export HOME="$T" HARNESS="$1" PATH="$T/fakebin:$PATH" \
           MODEL_PRICES="$T/prices.json" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           CODEX_FIXTURE="${4:-}" GROK_FIXTURE="${5:-}" \
           RUNNER_TRIAGE="$3" RUNNER_TRIAGE_FALLBACK="$3"
    [ "$3" = openrouter ] && export OPENROUTER_API_KEY=fake
    bash "$2" triage testproj "$6" 60 "$T/out.txt" "hello" >/dev/null 2>&1 )
  echo $?
}
col()  { tail -1 "$T/logs/cost.csv" | awk -F, -v c="$1" '{print $c}'; }
mcol() { tail -1 "$T/mut/logs/cost.csv" | awk -F, -v c="$1" '{print $c}'; }
pcount() { grep -c '\[cost-parity\] UNPRICED' "$T/logs/ALERTS.log" 2>/dev/null || true; }

rm -f "$T/logs/cost.csv" "$T/logs/ALERTS.log"; rm -f "$T/flags/"alerted-cost-parity-*

# B1. an openrouter call whose codex ledger reports 44450/18 must land PRICED.
#   44450*1e-5 + 18*5e-5 = 0.4445 + 0.0009 = 0.4454
RC=$(drive "$T" "$DIR/bin/agent-call.sh" openrouter "$T/codex-real.jsonl" "" claude-fable-5-1)
[ "$RC" = 0 ] && ok || bad "B1 the driven call failed (rc=$RC): $(tail -3 "$T/logs/ALERTS.log" 2>/dev/null)"
[ -s "$T/logs/cost.csv" ] && ok || bad "B1 no cost row was written at all"
[ "$(col 5)" = openrouter ] && ok || bad "B1 the row must be an openrouter row (got '$(col 5)')"
[ "$(col 6)" = "anthropic/claude-fable-5.1" ] && ok \
  || bad "B1 the row must carry the openrouter slug for the stage model: got '$(col 6)'"
[ "$(col 9)" = 44450 ] && ok || bad "B1 input_toks (col 9) must be the codex ledger's: got '$(col 9)'"
[ "$(col 10)" = 18 ] && ok   || bad "B1 output_toks (col 10): got '$(col 10)'"
[ "$(col 13)" = 0.445400 ] && ok \
  || bad "B1 cost_usd (col 13) must be the catalog product, not blank: got '$(col 13)'"
# TEST-CHANGE BH-3986: the openrouter slug is not the argv model, so the note
# now carries exactly `requested_model=claude-fable-5-1` (the served model is
# col 6). Still no UNPRICED marker: the whole note is pinned, not just its absence.
[ "$(col 24)" = "requested_model=claude-fable-5-1" ] && ok || bad "B1 a priced row must carry no UNPRICED marker, only requested_model=: got '$(col 24)'"
[ -z "$(col 19)" ] && ok || bad "B1 result_usd (col 19) must stay empty — the vendor reported no dollars: got '$(col 19)'"
[ "$(pcount)" = 0 ] && ok || bad "B1 a priced call must not page: $(pcount) line(s)"

# B2. the same lane with NO ledger at all: cost_usd stays empty, the note says
# why, and the existing first-call pager still fires exactly once.
RC=$(drive "$T" "$DIR/bin/agent-call.sh" openrouter "" "" claude-fable-5-1)
[ "$RC" = 0 ] && ok || bad "B2 the driven call failed (rc=$RC)"
[ "$(col 5)" = openrouter ] && ok || bad "B2 the row must still land: '$(tail -1 "$T/logs/cost.csv")'"
[ -z "$(col 13)" ] && ok || bad "B2 cost_usd must be EMPTY, not 0, when nothing was reported: got '$(col 13)'"
# TEST-CHANGE BH-3986: same requested_model= token, after the pricer's marker.
[ "$(col 24)" = "UNPRICED:no-usage;requested_model=claude-fable-5-1" ] && ok \
  || bad "B2 the note (col 24) must say the row could not be priced: got '$(col 24)'"
[ "$(pcount)" = 1 ] && ok || bad "B2 the first unpriced call must page exactly once: $(pcount) line(s)"

# B3. THE GROK BRANCH IS UNCHANGED. It priced its own rows before this ticket
# and must still answer the same number — 0.285000 is the figure
# tests/cost-grok-usage-test.sh D2 already pins.
rm -f "$T/logs/cost.csv"
RC=$(drive "$T" "$DIR/bin/agent-call.sh" grok "" "$FIX/grok-usage-no-ticks.jsonl" grok-4.6)
[ "$RC" = 0 ] && ok || bad "B3 the driven grok call failed (rc=$RC)"
[ "$(col 5)" = grok ] && ok || bad "B3 the row must be a grok row (got '$(col 5)')"
[ "$(col 13)" = 0.285000 ] && ok \
  || bad "B3 the grok branch's own price must be untouched: got '$(col 13)'"
[ -z "$(col 24)" ] && ok || bad "B3 a priced grok row must carry no marker: got '$(col 24)'"

# B4. THE MUTATION GUARD (D1). With the cost_row_price fence cut out of the
# library, agent-call.sh falls back to its stale-library stub — which is an
# identity, i.e. exactly today's behaviour — and B1's row lands with col 13
# EMPTY. This is what proves B1 is not asserting something that already worked.
mkdir -p "$T/mut/bin/lib" "$T/mut/logs" "$T/mut/flags" "$T/mut/locks"
cp "$DIR/bin/agent-call.sh" "$DIR/bin/codex-usage.sh" "$DIR/bin/grok-usage.sh" \
   "$DIR/bin/auth-fingerprint.sh" "$T/bin/billing-mode.sh" "$T/mut/bin/"
cp "$DIR"/bin/lib/*.sh "$T/mut/bin/lib/"
mrs_fixture "$T/mut" testproj   # BH-1510.1: the mutated box needs the same route cache
awk '/^# >>> cost_row_price/{skip=1} /^# <<< cost_row_price/{skip=0;next} !skip' \
  "$DIR/bin/lib/cost-row.sh" > "$T/mut/bin/lib/cost-row.sh"
grep -q 'cost_row_price()' "$T/mut/bin/lib/cost-row.sh" \
  && bad "B4 the mutated library still defines cost_row_price — the guard proves nothing" || ok
RC=$(drive "$T/mut" "$T/mut/bin/agent-call.sh" openrouter "$T/codex-real.jsonl" "" claude-fable-5-1)
[ "$RC" = 0 ] && ok || bad "B4 the mutated drive failed (rc=$RC) — it must run, just unpriced"
[ "$(mcol 9)" = 44450 ] && ok \
  || bad "B4 the mutated drive must still capture tokens (that half always worked): got '$(mcol 9)'"
[ -z "$(mcol 13)" ] && ok \
  || bad "B4 without cost_row_price the row must be blank — B1's green comes from the fix: got '$(mcol 13)'"

echo "cost-row-priced-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
