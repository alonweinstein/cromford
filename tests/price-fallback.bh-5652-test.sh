#!/bin/bash
# tests/price-fallback.bh-5652-test.sh — the price reader's chain is API ->
# box cache -> committed catalog, and a box that falls back to its cache says
# so in ALERTS.log once a day (BH-5652).
#
# bin/model-prices-sync.sh pulls GET /api/model-prices into
# $HARNESS/state/model-prices.json, and every price reader prefers that file to
# catalog/model-prices.json. Before BH-5652 a failed pull with a cache present
# wrote only to agent-rules.log, so a box could price from a stale cache for
# weeks and nothing paged.
#
#   F1  API down, cache present: sync exits 0, cache bytes unchanged, and the
#       real cost_price_tokens prices from the CACHE, not the catalog
#   F2  three runs on one day -> exactly ONE model-prices-sync ALERTS line
#   F3  API answers `{}` -> cache bytes unchanged
#   F4  API answers HTTP 500 -> cache bytes unchanged
#   F5  no cache and API down -> the committed catalog prices the row (never
#       empty, never 0), and the existing no-cache ALERTS line is still written
#
# The real bin/model-prices-sync.sh and the real jobs client run against a
# scratch $HARNESS; only `curl` is a fixture.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "jq/python3 missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/catalog" "$T/fakebin"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=http://jobs.fixture.invalid\n' > "$H/env/global.env"
# The lane gate is not under test here and must not reach a network.
printf 'lane_gate_or_exit() { :; }\nlane_env_apply() { :; }\n' > "$H/bin/lib/lane-gate.sh"
scratch_install_closure bin/model-prices-sync.sh "$H" >/dev/null || bad "could not install the sync closure"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "could not install the jobs client closure"
# The ALERTS lines go through bin/alert-line.sh, which the sync calls rather than sources.
scratch_install_closure bin/alert-line.sh "$H" >/dev/null || bad "could not install the alert-line closure"
cp "$DIR/catalog/model-prices.json" "$H/catalog/model-prices.json"
SYNC="$H/bin/model-prices-sync.sh"

# The fixture transport. CURL_MODE: down (rc 7), empty (`{}` 200), 500.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
case "${CURL_MODE:-down}" in
  down)  exit 7 ;;
  empty) printf '{}\n200' ;;
  500)   printf '{"error":"fixture"}\n500' ;;
esac
SH
chmod +x "$T/fakebin/curl"

# A cache that differs from the catalog on purpose: every rate x10, so a price
# read from the catalog cannot be mistaken for one read from the cache.
jq '.per_token |= map_values(.prompt = ((.prompt // 0) * 10))' "$DIR/catalog/model-prices.json" > "$T/cache.json"
M=$(jq -r '[.per_token | to_entries[] | select((.value.prompt // 0) > 0)][0].key' "$DIR/catalog/model-prices.json")
[ -n "$M" ] && [ "$M" != null ] && ok || bad "the catalog has no model with a prompt rate"

sync() { ( export HARNESS="$H" PATH="$T/fakebin:$PATH" CURL_MODE="$1" JOBS_RETRIES=0; bash "$SYNC" ) >/dev/null 2>&1; echo $?; }
price() { ( unset MODEL_PRICES; export HARNESS="$H"; . "$DIR/bin/lib/cost-row.sh"; cost_price_tokens "$M" 1000000 0 0 0 ); }
alerts() { grep -c 'model-prices-sync' "$H/logs/ALERTS.log" 2>/dev/null || true; }

# ── F1 ───────────────────────────────────────────────────────────────────────
cp "$T/cache.json" "$H/state/model-prices.json"
RC=$(sync down)
[ "$RC" = 0 ] && ok || bad "F1 a box with a cache must exit 0 (rc $RC)"
cmp -s "$H/state/model-prices.json" "$T/cache.json" && ok || bad "F1 a failed sync changed the cache"
WANT=$(MODEL_PRICES="$T/cache.json" bash -c '. "$1"; cost_price_tokens "$2" 1000000 0 0 0' _ "$DIR/bin/lib/cost-row.sh" "$M")
CAT=$(MODEL_PRICES="$DIR/catalog/model-prices.json" bash -c '. "$1"; cost_price_tokens "$2" 1000000 0 0 0' _ "$DIR/bin/lib/cost-row.sh" "$M")
GOT=$(price)
[ -n "$GOT" ] && [ "$GOT" = "$WANT" ] && [ "$GOT" != "$CAT" ] && ok \
  || bad "F1 the reader must price $M from the cache ($WANT), not the catalog ($CAT): got '$GOT'"
[ "$(alerts)" = 1 ] && ok || bad "F1 the fallback must write ONE ALERTS line: $(alerts)"
grep 'model-prices-sync' "$H/logs/ALERTS.log" 2>/dev/null | grep -q "$H/state/model-prices.json" \
  && ok || bad "F1 the ALERTS line must name the cache it prices from: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'model-prices-sync' "$H/logs/agent-rules.log" 2>/dev/null \
  && ok || bad "F1 the agent-rules.log line must stay (tests/model-prices-table-test.sh pins it)"

# ── F2 ───────────────────────────────────────────────────────────────────────
sync down >/dev/null; sync down >/dev/null
[ "$(alerts)" = 1 ] && ok || bad "F2 three failed runs on one day must leave ONE ALERTS line, got $(alerts)"

# ── F3 / F4 ──────────────────────────────────────────────────────────────────
rm -f "$H/flags/"alerted-model-prices-sync-*; : > "$H/logs/ALERTS.log"
RC=$(sync empty)
[ "$RC" = 0 ] && cmp -s "$H/state/model-prices.json" "$T/cache.json" && ok \
  || bad "F3 a {} body must leave the cache unchanged (rc $RC)"
[ "$(alerts)" = 1 ] && ok || bad "F3 a {} body is a failed sync and alerts once: $(alerts)"
rm -f "$H/flags/"alerted-model-prices-sync-*; : > "$H/logs/ALERTS.log"
RC=$(sync 500)
[ "$RC" = 0 ] && cmp -s "$H/state/model-prices.json" "$T/cache.json" && ok \
  || bad "F4 an HTTP 500 must leave the cache unchanged (rc $RC)"
grep 'model-prices-sync' "$H/logs/ALERTS.log" 2>/dev/null | grep -q 'http=500' \
  && ok || bad "F4 the ALERTS line must say what the API answered (http=500): $(cat "$H/logs/ALERTS.log" 2>/dev/null)"

# ── F5 ───────────────────────────────────────────────────────────────────────
rm -f "$H/state/model-prices.json" "$H/flags/"alerted-model-prices-sync-*; : > "$H/logs/ALERTS.log"
RC=$(sync down)
[ "$RC" = 1 ] && ok || bad "F5 no cache and no API is the one rc 1 (got $RC)"
[ ! -e "$H/state/model-prices.json" ] && ok || bad "F5 a failed sync must not invent a cache"
GOT=$(price)
WANT=$(MODEL_PRICES="$H/catalog/model-prices.json" bash -c '. "$1"; cost_price_tokens "$2" 1000000 0 0 0' _ "$DIR/bin/lib/cost-row.sh" "$M")
[ -n "$GOT" ] && [ "$GOT" = "$WANT" ] && [ "$GOT" != 0.000000 ] && ok \
  || bad "F5 with no cache the catalog must price $M ($WANT): got '$GOT'"
grep -q 'has no .*model-prices.json' "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "F5 the existing no-cache ALERTS line must stay: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
[ "$(alerts)" = 1 ] && ok || bad "F5 one line, not two: $(alerts)"

echo "price-fallback.bh-5652-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
