#!/bin/bash
# tests/model-prices-catalog-stale.bh-3990-test.sh — the committed price
# catalog is a seeded fallback, and its AGE is watched (BH-3990).
#
# catalog/model-prices.json moves only when a human lands a PR, and a box whose
# DB sync never landed prices from it. bin/update-model-prices.sh (hub, daily)
# reads its `updated_at` BEFORE the OpenRouter fetch and raises one warn
# lane-alert (id model-prices-catalog-stale) when it is older than
# MODEL_PRICES_CATALOG_MAX_AGE_DAYS (default 14, 0 = off), resolving it when the
# catalog is within the threshold. An unreadable stamp alerts: absent is not
# fresh.
#
#   a  20 days old -> one alert naming the age and the threshold 14
#   b  3 days old -> resolved, no alert
#   c  no updated_at -> alert
#   d  OpenRouter fetch fails -> the stale alert still fires
#   e  knob 0 -> no stale call at all
#   f  knob 30, 20 days old -> resolved, no alert
#   g  no lane-alert.sh -> one alert-line.sh line
#
# The real script runs whole against a scratch $HARNESS, harnessed like
# tests/update-model-prices.bh-1754-test.sh: a fixture `curl`, no jobs client
# (no price-source marks to read), a recording lane-alert.sh and alert-line.sh.
# Run from anywhere: tests/model-prices-catalog-stale.bh-3990-test.sh (exit 0 = pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export ENDPOINT_OPENROUTER=https://openrouter.ai
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/fakebin" "$T/lib"
cp "$DIR/bin/update-model-prices.sh" "$T/update-model-prices.sh"
cp "$DIR/bin/lib/endpoints.sh" "$T/lib/"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
[ -n "${CURL_RC:-}" ] && exit "$CURL_RC"
cat "$CURL_BODY"
SH
chmod +x "$T/fakebin/curl"
printf '%s\n' '{"m1":"v/m1","m2":"v/m2","m3":"v/m3","m4":"v/m4","m5":"v/m5"}' > "$T/slugs.json"
printf '%s\n' '{"data":[{"id":"v/m1","pricing":{"prompt":"0.000001","completion":"0.000002"}},{"id":"v/m2","pricing":{"prompt":"0.000001","completion":"0.000002"}},{"id":"v/m3","pricing":{"prompt":"0.000001","completion":"0.000002"}},{"id":"v/m4","pricing":{"prompt":"0.000001","completion":"0.000002"}},{"id":"v/m5","pricing":{"prompt":"0.000001","completion":"0.000002"}}]}' > "$T/openrouter.json"

# run <case> <updated_at or - for none> [env...]
run() {
  local c="$1" ua="$2" d="$T/$1"; shift 2
  mkdir -p "$d/bin" "$d/logs" "$d/state" "$d/checkout/catalog"
  if [ "$ua" = - ]; then
    printf '%s\n' '{"source":"catalog","per_token":{"m1":{"prompt":1e-6,"completion":2e-6}}}' > "$d/checkout/catalog/model-prices.json"
  else
    printf '{"updated_at":"%s","source":"catalog","per_token":{"m1":{"prompt":1e-6,"completion":2e-6}}}\n' "$ua" > "$d/checkout/catalog/model-prices.json"
  fi
  if [ "${NO_LANE_ALERT:-0}" != 1 ]; then
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.calls"\n' "$d" > "$d/bin/lane-alert.sh"
    chmod +x "$d/bin/lane-alert.sh"
  fi
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alert-line.calls"\n' "$d" > "$d/bin/alert-line.sh"
  chmod +x "$d/bin/alert-line.sh"
  : > "$d/lane-alert.calls"; : > "$d/alert-line.calls"
  ( unset MODEL_PRICES_CATALOG_MAX_AGE_DAYS
    export HARNESS="$d" HARNESS_CHECKOUT="$d/checkout" MODEL_SLUGS="$T/slugs.json" \
           PATH="$T/fakebin:$PATH" CURL_BODY="$T/openrouter.json" LANE_GATE_DISABLE=1
    env "$@" bash "$T/update-model-prices.sh" ) >"$d/run.out" 2>"$d/run.err"
}
ago() { date -u -d "$1 days ago" '+%Y-%m-%dT%H:%M:%SZ'; }
stale_alerts()  { grep -c -- '^--severity warn --id model-prices-catalog-stale model-prices ' "$T/$1/lane-alert.calls"; }
# A resolve names the lane: lane-alert.sh refuses one without it.
stale_resolve() { grep -c -- '--resolve --id model-prices-catalog-stale model-prices ' "$T/$1/lane-alert.calls"; }
stale_any()     { grep -c 'model-prices-catalog-stale' "$T/$1/lane-alert.calls"; }

# a
run a "$(ago 20)"
[ "$(stale_alerts a)" = 1 ] \
  && ok || bad "a: a 20-day-old catalog raised $(stale_alerts a) stale alerts, want 1: $(cat "$T/a/lane-alert.calls")"
L=$(grep -- '--id model-prices-catalog-stale' "$T/a/lane-alert.calls")
grep -q '20 days' <<<"$L" && grep -q 'threshold 14' <<<"$L" && grep -q 'catalog/model-prices.json' <<<"$L" \
  && ok || bad "a: the alert does not name the file, its age (20 days) and the threshold (14): $L"
grep -q -- '--severity warn' <<<"$L" \
  && ok || bad "a: the stale alert is not warn severity: $L"

# b
run b "$(ago 3)"
[ "$(stale_alerts b)" = 0 ] && [ "$(stale_resolve b)" = 1 ] \
  && ok || bad "b: a 3-day-old catalog: want a resolve and no alert: $(cat "$T/b/lane-alert.calls")"

# c
run c -
[ "$(stale_alerts c)" = 1 ] && grep -q 'has no readable updated_at' "$T/c/lane-alert.calls" \
  && ok || bad "c: a catalog with no updated_at did not alert as unreadable: $(cat "$T/c/lane-alert.calls")"
run c2 "last tuesday-ish"
[ "$(stale_alerts c2)" = 1 ] && grep -q 'has no readable updated_at' "$T/c2/lane-alert.calls" \
  && ok || bad "c2: an unparseable updated_at did not alert as unreadable: $(cat "$T/c2/lane-alert.calls")"

# d
run d "$(ago 20)" CURL_RC=22
grep -q 'fetch failed' "$T/d/alert-line.calls" \
  && ok || bad "d: fixture: the OpenRouter fetch did not fail: $(cat "$T/d/alert-line.calls")"
[ "$(stale_alerts d)" = 1 ] \
  && ok || bad "d: a failed fetch hid the stale alert: $(cat "$T/d/lane-alert.calls")"

# e
run e "$(ago 20)" MODEL_PRICES_CATALOG_MAX_AGE_DAYS=0
[ "$(stale_any e)" = 0 ] \
  && ok || bad "e: knob 0 still checked the catalog's age: $(cat "$T/e/lane-alert.calls")"

# f
run f "$(ago 20)" MODEL_PRICES_CATALOG_MAX_AGE_DAYS=30
[ "$(stale_alerts f)" = 0 ] && [ "$(stale_resolve f)" = 1 ] \
  && ok || bad "f: knob 30, 20 days old: want a resolve and no alert: $(cat "$T/f/lane-alert.calls")"

# f2: a knob that is not a whole number is the default, not off
run f2 "$(ago 20)" MODEL_PRICES_CATALOG_MAX_AGE_DAYS=lots
[ "$(stale_alerts f2)" = 1 ] \
  && ok || bad "f2: a non-integer knob did not fall back to 14: $(cat "$T/f2/lane-alert.calls")"

# g
NO_LANE_ALERT=1 run g "$(ago 20)"
[ "$(grep -c 'model-prices-catalog-stale' "$T/g/alert-line.calls")" = 1 ] \
  && ok || bad "g: with no lane-alert.sh the stale catalog wrote no single alert-line: $(cat "$T/g/alert-line.calls")"

echo "model-prices-catalog-stale.bh-3990-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
