#!/bin/bash
# tests/cost-row-price-version.bh-5652-test.sh — a cost row records the price
# version it was priced at (BH-5652).
#
# The model_prices table now carries a `version` per model (worker/jobs, bumped
# on every rate change with a price_audit row). GET /api/model-prices hands it
# to bin/model-prices-sync.sh, which writes it into state/model-prices.json. So
# a row that cost_row_price priced from that table says WHICH rates it used:
# `price_v:<n>` in the note column, which already reaches D1 cost_rows.note.
#
#   V1  a versioned table row -> `<usd>|price_v:7`
#   V2  an existing note keeps its place -> `|cache_ttl=1h;price_v:7`
#   V3  NEGATIVE: a table row with no version (the committed catalog, every
#       older fixture) adds no token — the exact output pins stay exact
#   V4  NEGATIVE: dollars with no version arg (envelope, vendor), no usage,
#       unknown model add no token (transcript dollars: tests/transcript-
#       price-version.bh-5652-test.sh)
#   V5  bin/agent-call.sh DRIVEN (the production entry point): the cost.csv
#       row's note column carries price_v:7 from $HARNESS/state/model-prices.json
#   V6  MUTATION (D1): cost_price_version answering nothing (`return 1` as its
#       first line) in a copy of bin/lib/cost-row.sh that still parses turns V1
#       red
#
# Run from anywhere: tests/cost-row-price-version.bh-5652-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# agent-call reads its ladders from model_routes; a worker-less box carries the
# resolver's cache (BH-1510.1), same as tests/cost-row-priced-test.sh.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "jq/python3 missing — skipping"; exit 0; }
mkdir -p "$T/bin"

# The same rates tests/cost-row-priced-test.sh uses, so the dollar figure is the
# one that suite already pins (0.016000), with a version on the row.
cat > "$T/prices-v.json" <<'EOF'
{"per_token": {
  "anthropic/claude-fable-5.1": {"prompt": 0.00001, "completion": 0.00005,
                                 "cache_read": 2.5e-7, "cache_write": 0.0000125, "version": 7}
}}
EOF
jq 'del(.per_token[].version)' "$T/prices-v.json" > "$T/prices-nov.json"

# extract <lib> <dest-prefix> — the two fenced blocks, by their markers.
extract() {
  awk '/^# >>> cost_price_tokens/{f=1;next} /^# <<< cost_price_tokens/{exit} f' "$1" > "$2-price.sh"
  awk '/^# >>> cost_row_price/{f=1;next} /^# <<< cost_row_price/{exit} f' "$1" > "$2-priced.sh"
}
extract "$DIR/bin/lib/cost-row.sh" "$T/bin/real"
grep -q 'cost_row_price()' "$T/bin/real-priced.sh" && grep -q 'cost_price_tokens()' "$T/bin/real-price.sh" \
  && ok || bad "could not extract cost_price_tokens / cost_row_price from bin/lib/cost-row.sh"

pr() { # pr <prefix> <table> <cost_row_price args...>
  local p="$1" tb="$2"; shift 2
  ( MODEL_PRICES="$tb"; . "$p-price.sh"; . "$p-priced.sh"; cost_row_price "$@" )
}
M=anthropic/claude-fable-5.1

# ── V1 ───────────────────────────────────────────────────────────────────────
OUT=$(pr "$T/bin/real" "$T/prices-v.json" openrouter "$M" 0 1000 100 4000 0 "" "")
[ "$OUT" = "0.016000|price_v:7" ] && ok || bad "V1 a versioned row must carry price_v:7: got '$OUT'"

# ── V2 ───────────────────────────────────────────────────────────────────────
OUT=$(pr "$T/bin/real" "$T/prices-v.json" openrouter "$M" 0 1000 100 4000 0 "" "cache_ttl=1h")
[ "$OUT" = "0.016000|cache_ttl=1h;price_v:7" ] && ok || bad "V2 the existing note must keep its place: got '$OUT'"

# ── V3 (negative) ────────────────────────────────────────────────────────────
OUT=$(pr "$T/bin/real" "$T/prices-nov.json" openrouter "$M" 0 1000 100 4000 0 "" "")
[ "$OUT" = "0.016000|" ] && ok || bad "V3 a row with no version must add no token: got '$OUT'"
# A version that is not a positive integer is not a version.
for BADV in 0 -3 '"7"' 2.5 null; do
  jq --argjson v "$BADV" '.per_token[].version = $v' "$T/prices-v.json" > "$T/prices-bad.json"
  OUT=$(pr "$T/bin/real" "$T/prices-bad.json" openrouter "$M" 0 1000 100 4000 0 "" "")
  [ "$OUT" = "0.016000|" ] && ok || bad "V3 version=$BADV must add no token: got '$OUT'"
done

# ── V4 (negative) ────────────────────────────────────────────────────────────
OUT=$(pr "$T/bin/real" "$T/prices-v.json" claude "$M" 0 1000 100 4000 0 0.905636 "")
[ "$OUT" = "0.905636|" ] && ok || bad "V4 dollars handed in with no version (arg 11) add no token: got '$OUT'"
OUT=$(pr "$T/bin/real" "$T/prices-v.json" openrouter "$M" 0 "" "" "" "" "" "")
[ "$OUT" = "|UNPRICED:no-usage" ] && ok || bad "V4 no usage must stay exactly UNPRICED:no-usage: got '$OUT'"
OUT=$(pr "$T/bin/real" "$T/prices-v.json" openrouter nobody/knows 0 10 1 "" "" "" "")
[ "$OUT" = "|UNPRICED:no-price:nobody/knows" ] && ok || bad "V4 an unknown model must stay exactly no-price: got '$OUT'"
OUT=$(pr "$T/bin/real" "$T/no-such-table.json" openrouter "$M" 0 1000 100 "" "" "" "")
[ "$OUT" = "|UNPRICED:no-price:$M" ] && ok || bad "V4 an unreadable MODEL_PRICES must stay no-price: got '$OUT'"

# ── V5: bin/agent-call.sh driven ─────────────────────────────────────────────
echo "--- V5. bin/agent-call.sh (driven)"
H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/state" "$T/fakebin" "$T/home/.codex/sessions"
mrs_fixture "$H" testproj
printf '#!/bin/bash\necho subscription\n' > "$H/bin/billing-mode.sh"; chmod +x "$H/bin/billing-mode.sh"
scratch_install_closure bin/agent-call.sh "$H" >/dev/null || bad "V5 could not install the agent-call closure"
# agent-call runs the usage reader by "$HARNESS/bin/<x>", which no source line names.
scratch_install_closure bin/codex-usage.sh "$H" >/dev/null || bad "V5 could not install bin/codex-usage.sh"
# The table the box prices from, with NO MODEL_PRICES override: the sync's cache.
cp "$T/prices-v.json" "$H/state/model-prices.json"
# The REAL captured codex ledger shape (tests/codex-usage-test.sh section 0).
cat > "$T/codex-real.jsonl" <<'EOF'
{"timestamp":"2026-08-24T13:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":44450,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":18,"reasoning_output_tokens":0,"total_tokens":44468}}}}
EOF
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
OUTF=""
while [ $# -gt 0 ]; do
  case "$1" in --output-last-message) OUTF="${2:-}"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$HOME/.codex/sessions/run"
cp "$CODEX_FIXTURE" "$HOME/.codex/sessions/run/rollout-x.jsonl"
[ -n "$OUTF" ] && echo "DECISION: BH-5652 :: skip :: fake" > "$OUTF"
echo "fake codex done"
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/codex" "$T/fakebin/timeout"
# The fence: every real vendor key dropped, only the fake OPENROUTER one set,
# and the fake codex on PATH is what the openrouter lane resolves.
drive() { # drive <harness-root>
  rm -rf "$T/home/.codex/sessions"; mkdir -p "$T/home/.codex/sessions"
  ( unset XAI_API_KEY GROK_CODE_XAI_API_KEY OPENAI_API_KEY CODEX_API_KEY \
          GEMINI_API_KEY ANTHROPIC_API_KEY FIREWORKS_API_KEY MODEL_PRICES
    export HOME="$T/home" HARNESS="$1" PATH="$T/fakebin:$PATH" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           CODEX_FIXTURE="$T/codex-real.jsonl" OPENROUTER_API_KEY=fixture-not-a-key \
           RUNNER_TRIAGE=openrouter RUNNER_TRIAGE_FALLBACK=openrouter
    bash "$1/bin/agent-call.sh" triage testproj claude-fable-5-1 60 "$T/out.txt" "hello" >/dev/null 2>&1 )
  echo $?
}
col() { tail -1 "$1/logs/cost.csv" | awk -F, -v c="$2" '{print $c}'; }
RC=$(drive "$H")
[ "$RC" = 0 ] && ok || bad "V5 the driven call failed (rc=$RC)"
[ "$(col "$H" 6)" = "$M" ] && ok || bad "V5 the row must be the fable slug: '$(tail -1 "$H/logs/cost.csv" 2>/dev/null)'"
#   44450*1e-5 + 18*5e-5 = 0.4454, the figure tests/cost-row-priced-test.sh B1 pins
[ "$(col "$H" 13)" = 0.445400 ] && ok || bad "V5 cost_usd (col 13): got '$(col "$H" 13)'"
case ";$(col "$H" 24);" in
  *";price_v:7;"*) ok ;;
  *) bad "V5 the note column (24) must carry price_v:7: got '$(col "$H" 24)'" ;;
esac
# The same box with the cache carrying no version: no token on the row.
cp "$T/prices-nov.json" "$H/state/model-prices.json"; rm -f "$H/logs/cost.csv"
RC=$(drive "$H")
[ "$RC" = 0 ] && [ "$(col "$H" 13)" = 0.445400 ] && ok || bad "V5 unversioned drive: rc=$RC usd='$(col "$H" 13)'"
case "$(col "$H" 24)" in
  *price_v:*) bad "V5 an unversioned table must add no token: got '$(col "$H" 24)'" ;;
  *) ok ;;
esac

# ── V6: mutation (D1) ────────────────────────────────────────────────────────
# A SEMANTIC mutation: the version reader answers nothing, and the copy still
# parses. Cutting lines instead left a dangling `fi` that passed V6 by a
# syntax error, not by the missing version.
grep -q '^cost_price_version() {$' "$DIR/bin/lib/cost-row.sh" \
  && ok || bad "V6 bin/lib/cost-row.sh has no 'cost_price_version() {' line — nothing to mutate"
sed 's/^cost_price_version() {$/cost_price_version() { return 1/' "$DIR/bin/lib/cost-row.sh" > "$T/cost-row-mut.sh"
extract "$T/cost-row-mut.sh" "$T/bin/mut"
bash -n "$T/bin/mut-price.sh" && bash -n "$T/bin/mut-priced.sh" \
  && ok || bad "V6 the mutant library does not parse — V6 would pass on a syntax error"
OUT=$(pr "$T/bin/mut" "$T/prices-v.json" openrouter "$M" 0 1000 100 4000 0 "" "" 2>/dev/null)
[ "$OUT" = "0.016000|" ] && ok \
  || bad "V6 with the version read cut out, V1's answer must change — V1 proves nothing: got '$OUT'"

echo "cost-row-price-version.bh-5652-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
