#!/bin/bash
# tests/llm-sites-priced.bh-2541-test.sh — alerts-medic and watchdog-responder
# are priced in full, and the catalog says so.
#
# THE GAP (BH-2541, goal-gap audit C11). catalog/llm-sites.json marked both
# lanes "priced": "partial" because the 7d ledger carried NULL cost_usd rows for
# project medic and project responder. Every one of those rows was written on
# or before 2026-09-19T23:24:45Z, while the hub still ran agent-call.sh's
# identity stub for cost_row_price (bin/lib/cost-row.sh not yet synced). Every
# row since then carries dollars. Neither the codex usage parser nor a price key
# was broken, so this suite pins both facts: the catalog claim, and that the
# real medic and responder token shapes price today.
#
# Sections:
#   1. the catalog claim (both sites exist, both "yes")
#   2. bin/agent-call.sh DRIVEN as the medic calls it, fireworks rung, the real
#      medic row from 2026-09-21T02:57:20Z (296543 in / 254583 cached / 9989 out)
#   3. the same drive against a frozen one-row table: exact dollars
#   4. the mutation guard: the same drive without the price key goes UNPRICED
#   5. the responder's ledger shapes through cost_row_price, real price table
#
# Run from anywhere: tests/llm-sites-priced.bh-2541-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mkdir -p "$T/bin/lib" "$T/logs" "$T/flags" "$T/locks" "$T/fakebin" "$T/.codex/sessions"
mrs_fixture "$T" medic
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

MEDIC_MODEL="accounts/fireworks/models/deepseek-v4-flash-0731"

# ── 1. the catalog claim ─────────────────────────────────────────────────────
echo "--- 1. catalog/llm-sites.json"
for id in alerts-medic watchdog-responder; do
  # An absent id prints "absent", never an empty string that a != check could
  # read as a pass (D3).
  P=$(jq -r --arg id "$id" '[.sites[]|select(.id==$id)] | if length==0 then "absent" else .[0].priced end' \
      "$DIR/catalog/llm-sites.json")
  [ "$P" = yes ] && ok || bad "1 site '$id' must be \"priced\": \"yes\", got '$P'"
done

# ── 2-4. the production entry point: bin/agent-call.sh ───────────────────────
echo "--- 2-4. bin/agent-call.sh triage medic (driven, fireworks rung)"
cp "$DIR/bin/codex-usage.sh" "$T/bin/"
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"; chmod +x "$T/bin/billing-mode.sh"

# The codex token_count event shape tests/codex-usage-test.sh section 0 captured
# from a live hub session, carrying the counts of the real medic row.
SID="00000000-0000-0000-0000-000000002541"
cat > "$T/medic.jsonl" <<'EOF'
{"timestamp":"2026-09-21T02:57:20Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":296543,"cached_input_tokens":254583,"output_tokens":9989,"reasoning_output_tokens":0,"total_tokens":306532}}}}
EOF

cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
# fake codex CLI: writes the session ledger under this call's session id,
# prints the id banner on stderr like the real one, answers via
# --output-last-message.
OUTF=""
while [ $# -gt 0 ]; do
  case "$1" in --output-last-message) OUTF="${2:-}"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$HOME/.codex/sessions/2026/09/21"
cp "$CODEX_FIXTURE" "$HOME/.codex/sessions/2026/09/21/rollout-2026-09-21T02-57-20-$CODEX_SID.jsonl"
echo "session id: $CODEX_SID" >&2
[ -n "$OUTF" ] && echo "medic: nothing to do" > "$OUTF"
echo "fake codex done"
exit 0
EOF
chmod +x "$T/fakebin/codex"

cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/timeout"

# THE FENCE: every vendor key is dropped and only a fake FIREWORKS one is set,
# so the only CLI this drive can reach is the fake codex on PATH.
drive() { # drive <price-table>
  rm -rf "${T:?}/.codex/sessions" "${T:?}/logs/cost.csv"
  mkdir -p "$T/.codex/sessions"
  ( unset XAI_API_KEY GROK_CODE_XAI_API_KEY OPENAI_API_KEY CODEX_API_KEY \
          GEMINI_API_KEY ANTHROPIC_API_KEY FIREWORKS_API_KEY OPENROUTER_API_KEY
    export HOME="$T" HARNESS="$T" PATH="$T/fakebin:$PATH" \
           MODEL_PRICES="$1" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           CODEX_FIXTURE="$T/medic.jsonl" CODEX_SID="$SID" \
           FIREWORKS_API_KEY=fake AGENT_CALL_RUNNERS=fireworks \
           RUNNER_TRIAGE=fireworks RUNNER_TRIAGE_FALLBACK=fireworks \
           FIREWORKS_MODEL="$MEDIC_MODEL"
    bash "$DIR/bin/agent-call.sh" triage medic "$MEDIC_MODEL" 60 "$T/out.txt" "prompt" >/dev/null 2>&1 )
  echo $?
}
col() { tail -1 "$T/logs/cost.csv" 2>/dev/null | awk -F, -v c="$1" '{print $c}'; }
is_pos() { awk -v v="$1" 'BEGIN{exit !(v ~ /^[0-9]+(\.[0-9]+)?$/ && v+0 > 0)}'; }

# 2. the real catalog table
RC=$(drive "$DIR/catalog/model-prices.json")
[ "$RC" = 0 ] && ok || bad "2 the driven medic call failed (rc=$RC)"
[ "$(col 5)" = fireworks ] && ok || bad "2 runner (col 5) must be fireworks: '$(tail -1 "$T/logs/cost.csv" 2>/dev/null)'"
[ "$(col 3)" = medic ] && ok || bad "2 project (col 3) must be medic, got '$(col 3)'"
[ "$(col 4)" = triage ] && ok || bad "2 stage (col 4) must be triage, got '$(col 4)'"
[ "$(col 6)" = "$MEDIC_MODEL" ] && ok || bad "2 model (col 6) must be $MEDIC_MODEL, got '$(col 6)'"
[ "$(col 7)" = 0 ] && ok || bad "2 rc (col 7) must be 0, got '$(col 7)'"
[ "$(col 9)" = 296543 ] && ok || bad "2 input_toks (col 9) must be the ledger's 296543, got '$(col 9)'"
[ "$(col 10)" = 9989 ] && ok || bad "2 output_toks (col 10) must be 9989, got '$(col 10)'"
is_pos "$(col 13)" && ok || bad "2 cost_usd (col 13) must be a positive number, got '$(col 13)'"
case "$(col 24)" in *UNPRICED*) bad "2 a priced medic row must carry no UNPRICED note, got '$(col 24)'" ;; *) ok ;; esac

# 3. exact dollars against a frozen table, so a price refresh of the real
# catalog cannot turn this red:
#   296543*6e-8 + 9989*1.2e-7 + 254583*1.2e-8 = 0.01779258 + 0.00119868 + 0.00305500 = 0.022046
cat > "$T/frozen.json" <<'EOF'
{"per_token": {
  "accounts/fireworks/models/deepseek-v4-flash-0731": {"prompt": 6E-8, "completion": 1.2E-7,
                                                      "cache_read": 1.2E-8, "cache_write": null}
}}
EOF
RC=$(drive "$T/frozen.json")
[ "$RC" = 0 ] && ok || bad "3 the driven medic call failed (rc=$RC)"
[ "$(col 13)" = 0.022046 ] && ok || bad "3 cost_usd (col 13) must be 0.022046, got '$(col 13)'"

# 4. MUTATION GUARD (D1): the same drive with the key gone. Case 2's green is
# the price key doing its work, not a column that is always filled.
cat > "$T/nokey.json" <<'EOF'
{"per_token": {
  "deepseek/deepseek-v4-flash": {"prompt": 6E-8, "completion": 1.2E-7, "cache_read": 1.2E-8, "cache_write": null}
}}
EOF
RC=$(drive "$T/nokey.json")
[ "$RC" = 0 ] && ok || bad "4 the driven medic call failed (rc=$RC)"
[ -z "$(col 13)" ] && ok || bad "4 without the price key cost_usd must be blank, got '$(col 13)'"
[ "$(col 24)" = "UNPRICED:no-price:$MEDIC_MODEL" ] && ok \
  || bad "4 without the price key the note must name it, got '$(col 24)'"

# ── 5. the responder's ledger shapes, real price table ───────────────────────
echo "--- 5. cost_row_price over the responder shapes"
pr() { ( MODEL_PRICES="$DIR/catalog/model-prices.json"; . "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1
         cost_row_price "$@" ) }
while read -r m rc i o cr cw; do
  OUT=$(pr fireworks "$m" "$rc" "$i" "$o" "$cr" "$cw" "" "")
  is_pos "${OUT%%|*}" && ok || bad "5 $m ($i/$o/$cr/$cw rc $rc) must price > 0, got '$OUT'"
  case "$OUT" in *UNPRICED*) bad "5 $m must carry no UNPRICED note, got '$OUT'" ;; *) ok ;; esac
done <<'EOF'
accounts/fireworks/models/kimi-k2p7-code 0 974515 8512 912902 0
gpt-6-astra 0 436464 4155 385152 0
deepseek/deepseek-v4-flash 1 508239 11146 443070 0
EOF

echo "llm-sites-priced.bh-2541-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
