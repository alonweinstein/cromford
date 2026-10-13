#!/bin/bash
# tests/update-model-prices.bh-1754-test.sh — the price_source read fails
# closed, and the vendor-direct price lives in D1 (BH-1754).
#
# BH-1613 made the daily refresh keep the vendor's own rate for a model marked
# `price_source = vendor-direct`. Two gaps are closed here:
#   C1-C3  a failed read of those marks used to re-price EVERY model from
#          OpenRouter and say so only in agent-rules.log. Now it raises one
#          lane-alert and exits with yesterday's table untouched (file and DB).
#   C4-C9  the vendor price itself comes from the model_prices row
#          (`vendor_direct` on a marked row of the GET), with the committed
#          catalog row as the fallback, so an edit in D1 is picked up on the
#          next refresh with no code change.
#   E1     the operator verb that writes that price.
#
# The real bin/update-model-prices.sh runs whole against a scratch $HARNESS,
# harnessed like tests/update-model-prices.bh-1613-test.sh: a fixture `curl`, a
# fake bin/jobs-client.sh serving the model_prices GET and recording the push,
# and a recording lane-alert.sh. SCRIPT= points the suite at another copy of the
# script (the red-first run against the pre-change code).
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-1941: the script under test resolves its vendor base URL through
# endpoint_url (env, else the registry default); this sandbox composes no
# registry, so the env carries today's URL — the registry default itself.
export ENDPOINT_OPENROUTER=https://openrouter.ai
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

mkdir -p "$T/fakebin"
cp "${SCRIPT:-$DIR/bin/update-model-prices.sh}" "$T/update-model-prices.sh"
mkdir -p "$T/lib"; cp "$DIR/bin/lib/endpoints.sh" "$T/lib/"   # BH-1941: beside the script copy

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
cat "$CURL_BODY"
SH
chmod +x "$T/fakebin/curl"

cat > "$T/slugs.json" <<'JSON'
{"claude-fable-5-1":"anthropic/claude-fable-5.1","claude-opus-5":"anthropic/claude-opus-5",
 "claude-sonnet-5":"anthropic/claude-sonnet-5","claude-haiku-4-5":"anthropic/claude-haiku-4.5",
 "gpt-6-astra":"openai/gpt-6-astra","grok-4.7":"x-ai/grok-4.7","x-ai/grok-4.7":"x-ai/grok-4.7"}
JSON

# fixtures <run-dir> — openrouter.json (grok-4.7 at 1.6e-6 / 4.8e-6 / 4e-7) and
# the committed catalog, which carries grok-4.7 at 2e-6 / 6e-6 / 5e-7, cliff 200000.
fixtures() {
  local d="$1"
  mkdir -p "$d/checkout/catalog"
  python3 - "$T/slugs.json" "$d" <<'PY'
import json, sys
slugs = json.load(open(sys.argv[1])); d = sys.argv[2]
rates = {
  "anthropic/claude-fable-5.1": ("0.000015", "0.000075", "0.0000015", "0.00001875"),
  "anthropic/claude-opus-5":    ("0.000005", "0.000025", "0.0000005", "0.00000625"),
  "anthropic/claude-sonnet-5":  ("0.000003", "0.000015", "0.0000003", "0.00000375"),
  "anthropic/claude-haiku-4.5": ("0.000001", "0.000005", "0.0000001", "0.00000125"),
  "openai/gpt-6-astra":         ("0.0000025", "0.00001", "0.00000025", None),
  "x-ai/grok-4.7":              ("0.0000016", "0.0000048", "0.0000004", None),
}
data = []
for s, (p, c, cr, cw) in rates.items():
    pr = {"prompt": p, "completion": c, "input_cache_read": cr}
    if cw is not None: pr["input_cache_write"] = cw
    data.append({"id": s, "pricing": pr})
json.dump({"data": data}, open(d + "/openrouter.json", "w"))
num = lambda x: None if x is None else float(x)
per = {}
for k, s in slugs.items():
    p, c, cr, cw = rates[s]
    per[k] = {"prompt": num(p), "completion": num(c), "cache_read": num(cr), "cache_write": num(cw), "slug": s}
per["grok-4.7"] = {"prompt": 2e-6, "completion": 6e-6, "cache_read": 5e-7, "cache_write": None,
                   "slug": "x-ai/grok-4.7", "cliff_tokens": 200000}
json.dump({"updated_at": "2026-09-01T00:00:00Z", "source": "catalog", "per_token": per},
          open(d + "/checkout/catalog/model-prices.json", "w"))
PY
}

# getbody <run-dir> <json object model -> extra keys for that row> — the GET answer.
getbody() {
  python3 - "$2" > "$1/get.json" <<'PY'
import json, sys
extra = json.loads(sys.argv[1])
per = {m: {"prompt": 1e-6, "completion": 1e-6} for m in
       ["claude-fable-5-1", "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5", "gpt-6-astra", "grok-4.7", "x-ai/grok-4.7"]}
for m, kv in extra.items():
    per.setdefault(m, {"prompt": 1e-6, "completion": 1e-6}).update(kv)
print(json.dumps({"updated_at": "2026-09-22T04:30:00Z", "source": "openrouter", "per_token": per}))
PY
}

# run <run-dir> [env...] — one refresh against its own scratch $HARNESS. The
# lane-alert sink and agent-rules.log are reset per run.
run() {
  local d="$1"; shift
  mkdir -p "$d/bin" "$d/logs" "$d/state"
  : > "$d/logs/agent-rules.log"; : > "$d/lane-alert.calls"; rm -f "$d/put.json"
  # The REAL model_prices_get (bin/lib/jobs/cost.sh) with only the transport
  # stubbed, so its row floor and parse are the ones production runs.
  cat > "$d/bin/jobs-client.sh" <<SH
. "$DIR/bin/lib/jobs/cost.sh"
_jobs_req() { [ -n "\${GET_RC:-}" ] && return "\$GET_RC"; cat "\$GET_BODY"; }
model_prices_put() { cp "\$1" "\$PUT_OUT"; }
SH
  cat > "$d/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$LANE_SINK"
SH
  chmod +x "$d/bin/lane-alert.sh"
  # The catalog-age alert (BH-3990) is off here: the fixture catalog's date is
  # fixed, so its age grows daily, and these cases count the price-source calls
  # alone. tests/model-prices-catalog-stale.bh-3990-test.sh pins that alert.
  ( export HARNESS="$d" HARNESS_CHECKOUT="$d/checkout" MODEL_SLUGS="$T/slugs.json" \
           PATH="$T/fakebin:$PATH" CURL_BODY="$d/openrouter.json" GET_BODY="$d/get.json" \
           PUT_OUT="$d/put.json" LANE_SINK="$d/lane-alert.calls" MODEL_PRICES_CATALOG_MAX_AGE_DAYS=0 "$@"
    bash "$T/update-model-prices.sh" ) >"$d/run.out" 2>"$d/run.err"
  RC=$?
}
row() { jq -c --arg k "$2" '.per_token[$k]' "$1/state/model-prices.json" 2>/dev/null; }
field() { jq -r --arg k "$2" --arg f "$3" '.per_token[$k][$f]' "$1/state/model-prices.json" 2>/dev/null; }
feq() { python3 -c 'import sys; sys.exit(0 if sys.argv[1] not in ("", "null") and abs(float(sys.argv[1]) - float(sys.argv[2])) < 1e-15 else 1)' "$1" "$2"; }
ID=model-prices-price-source-unreadable

# yesterday <run-dir> — seed yesterday's live table (grok-4.7 at a rate nothing
# in today's fixtures produces, so any re-price shows).
yesterday() {
  printf '%s\n' '{"updated_at":"2026-09-22T04:30:00Z","source":"openrouter/api/v1/models","per_token":{"grok-4.7":{"prompt":2.5e-06,"completion":7.5e-06,"slug":"x-ai/grok-4.7"}}}' \
    > "$1/state/model-prices.json"
  cp "$1/state/model-prices.json" "$1/yesterday.json"
}

# failed_read_asserts <case> <run-dir>
failed_read_asserts() {
  local c="$1" d="$2" n
  [ "$RC" = 0 ] && ok || bad "$c: refresh must exit 0, got $RC: $(cat "$d/run.err")"
  cmp -s "$d/state/model-prices.json" "$d/yesterday.json" && ok \
    || bad "$c: yesterday's table must be left byte-identical, got $(cat "$d/state/model-prices.json")"
  [ ! -e "$d/put.json" ] && ok || bad "$c: nothing may be pushed to the DB, got $(head -c 200 "$d/put.json")"
  [ ! -e "$d/state/openrouter-models.json" ] && ok || bad "$c: openrouter-models.json must not be written"
  n=$(grep -c -- "--id $ID" "$d/lane-alert.calls")
  [ "$(wc -l < "$d/lane-alert.calls")" = 1 ] && [ "$n" = 1 ] && ok \
    || bad "$c: exactly one lane-alert call, with --id $ID, got: $(cat "$d/lane-alert.calls")"
  grep -q -- '--resolve' "$d/lane-alert.calls" && bad "$c: a failed read must not resolve the alert" || ok
  grep -q -E 'overrides unreadable|priced from OpenRouter this run' "$d/logs/agent-rules.log" \
    && bad "$c: the failure must not be a mere agent-rules line: $(cat "$d/logs/agent-rules.log")" || ok
}

# ============================================================================
# C1. the marks GET fails: one alert, yesterday's table kept, nothing pushed.
# ============================================================================
D="$T/c1"; fixtures "$D"; getbody "$D" '{"grok-4.7":{"price_source":"vendor-direct"}}'
mkdir -p "$D/state"; yesterday "$D"
run "$D" GET_RC=1
failed_read_asserts C1 "$D"

# ============================================================================
# C2. the GET answers, but with a body that has no per_token: same as a failure.
# ============================================================================
D="$T/c2"; fixtures "$D"; printf '%s\n' '{"error":"x"}' > "$D/get.json"
mkdir -p "$D/state"; yesterday "$D"
run "$D"
failed_read_asserts C2 "$D"

# ============================================================================
# C3. two failed runs in a row call lane-alert once each (lane-alert's state
#     machine is the dedup); the next good read resolves the id.
# ============================================================================
D="$T/c3"; fixtures "$D"; getbody "$D" '{}'
mkdir -p "$D/state"; yesterday "$D"
run "$D" GET_RC=1; A1=$(grep -c -- "--id $ID" "$D/lane-alert.calls")
run "$D" GET_RC=1; A2=$(grep -c -- "--id $ID" "$D/lane-alert.calls")
[ "$A1" = 1 ] && [ "$A2" = 1 ] && ok || bad "C3: each failed run alerts exactly once, got $A1 and $A2"
cmp -s "$D/state/model-prices.json" "$D/yesterday.json" && ok || bad "C3: two failed runs still leave yesterday's table"
run "$D"
grep -q -- "--resolve --id $ID" "$D/lane-alert.calls" && ok \
  || bad "C3: a good read must resolve $ID, got: $(cat "$D/lane-alert.calls")"
grep -q -- "--id $ID" <<<"$(grep -v -- '--resolve' "$D/lane-alert.calls")" \
  && bad "C3: a good read must not raise $ID again: $(cat "$D/lane-alert.calls")" || ok
[ -s "$D/put.json" ] && ok || bad "C3: a good read refreshes and pushes the table"

# ============================================================================
# C4. grok-4.7 marked with a D1 vendor price: the D1 price wins over the
#     catalog's, in the file and in the push.
# ============================================================================
D="$T/c4"; fixtures "$D"
getbody "$D" '{"grok-4.7":{"price_source":"vendor-direct","vendor_direct":{"prompt":3e-6,"completion":9e-6,"cache_read":7.5e-7,"cache_write":null,"cliff_tokens":256000}}}'
run "$D"
[ "$RC" = 0 ] && ok || bad "C4: refresh must exit 0, got $RC: $(cat "$D/run.err")"
feq "$(field "$D" grok-4.7 prompt)" 3e-6         && ok || bad "C4: grok-4.7 prompt must be the D1 3e-6, got $(row "$D" grok-4.7)"
feq "$(field "$D" grok-4.7 completion)" 9e-6     && ok || bad "C4: grok-4.7 completion must be 9e-6, got $(row "$D" grok-4.7)"
feq "$(field "$D" grok-4.7 cache_read)" 7.5e-7   && ok || bad "C4: grok-4.7 cache_read must be 7.5e-7, got $(row "$D" grok-4.7)"
[ "$(field "$D" grok-4.7 cliff_tokens)" = 256000 ] && ok || bad "C4: grok-4.7 cliff must be the D1 256000, got $(row "$D" grok-4.7)"
[ "$(field "$D" grok-4.7 slug)" = x-ai/grok-4.7 ] && ok || bad "C4: grok-4.7 keeps its slug, got $(row "$D" grok-4.7)"
[ "$(jq -r '.per_token["grok-4.7"] | has("vendor_direct") or has("price_source")' "$D/state/model-prices.json")" = false ] && ok \
  || bad "C4: the live row is plain rates, no D1 bookkeeping keys, got $(row "$D" grok-4.7)"
P=$(jq -c '.per_token["grok-4.7"]' "$D/put.json" 2>/dev/null)
[ -n "$P" ] && [ "$P" = "$(row "$D" grok-4.7)" ] && ok || bad "C4: the DB push carries the same row, got '$P'"
feq "$(field "$D" x-ai/grok-4.7 prompt)" 1.6e-6 && ok || bad "C4: unmarked x-ai/grok-4.7 stays OpenRouter, got $(row "$D" x-ai/grok-4.7)"
grep -q -- "--resolve --id $ID" "$D/lane-alert.calls" && ok || bad "C4: a good read resolves $ID"

# ============================================================================
# C5. the D1 price is edited (4e-6) and the lane runs again, script unchanged.
# ============================================================================
getbody "$D" '{"grok-4.7":{"price_source":"vendor-direct","vendor_direct":{"prompt":4e-6,"completion":9e-6,"cache_read":7.5e-7,"cache_write":null}}}'
run "$D"
feq "$(field "$D" grok-4.7 prompt)" 4e-6 && ok || bad "C5: the edited D1 price is picked up, got $(row "$D" grok-4.7)"
[ "$(field "$D" grok-4.7 cliff_tokens)" = 200000 ] && ok || bad "C5: no D1 cliff keeps the catalog cliff 200000, got $(row "$D" grok-4.7)"

# ============================================================================
# C5b. the documented minimal form (prompt and completion only): the cliff and
#      cache rate the operator did not set come from the catalog row, not none.
# ============================================================================
getbody "$D" '{"grok-4.7":{"price_source":"vendor-direct","vendor_direct":{"prompt":3e-6,"completion":9e-6,"cache_read":null,"cache_write":null,"cliff_tokens":null}}}'
run "$D"
feq "$(field "$D" grok-4.7 prompt)" 3e-6 && ok || bad "C5b: the D1 prompt 3e-6 wins, got $(row "$D" grok-4.7)"
feq "$(field "$D" grok-4.7 completion)" 9e-6 && ok || bad "C5b: the D1 completion 9e-6 wins, got $(row "$D" grok-4.7)"
feq "$(field "$D" grok-4.7 cache_read)" 5e-7 && ok || bad "C5b: an unset D1 cache_read falls back to the catalog 5e-7, got $(row "$D" grok-4.7)"
[ "$(field "$D" grok-4.7 cache_write)" = null ] && ok || bad "C5b: no cache_write in D1 or catalog stays null, got $(row "$D" grok-4.7)"
[ "$(field "$D" grok-4.7 cliff_tokens)" = 200000 ] && ok || bad "C5b: an unset D1 cliff falls back to the catalog 200000, got $(row "$D" grok-4.7)"
P=$(jq -c '.per_token["grok-4.7"]' "$D/put.json" 2>/dev/null)
[ -n "$P" ] && [ "$P" = "$(row "$D" grok-4.7)" ] && ok || bad "C5b: the DB push carries the same row, got '$P'"

# ============================================================================
# C6. marked, no vendor_direct in D1: the catalog row verbatim (the fallback).
# ============================================================================
D="$T/c6"; fixtures "$D"; getbody "$D" '{"grok-4.7":{"price_source":"vendor-direct"}}'
run "$D"
[ "$(row "$D" grok-4.7)" = "$(jq -c '.per_token["grok-4.7"]' "$D/checkout/catalog/model-prices.json")" ] && ok \
  || bad "C6: no D1 price falls back to the catalog row verbatim, got $(row "$D" grok-4.7)"

# ============================================================================
# C7. marked with an unusable D1 prompt: the catalog row, never 0 or a string.
# ============================================================================
for v in 0 -1 '"2e-6"' true null; do
  D="$T/c7-$(printf '%s' "$v" | tr -dc 'a-z0-9')x"; fixtures "$D"
  getbody "$D" "{\"grok-4.7\":{\"price_source\":\"vendor-direct\",\"vendor_direct\":{\"prompt\":$v,\"completion\":9e-6}}}"
  run "$D"
  feq "$(field "$D" grok-4.7 prompt)" 2e-6 && ok || bad "C7: D1 prompt=$v must fall back to the catalog 2e-6, got $(row "$D" grok-4.7)"
done

# ============================================================================
# C8. vendor_direct on an UNMARKED row is ignored; an empty per_token is a
#     successful read (no alert raised).
# ============================================================================
D="$T/c8"; fixtures "$D"; getbody "$D" '{"grok-4.7":{"vendor_direct":{"prompt":3e-6,"completion":9e-6}}}'
run "$D"
feq "$(field "$D" grok-4.7 prompt)" 1.6e-6 && ok || bad "C8: unmarked grok-4.7 is OpenRouter's rate, got $(row "$D" grok-4.7)"
D="$T/c8b"; fixtures "$D"; printf '%s\n' '{"per_token":{}}' > "$D/get.json"
run "$D"
[ -s "$D/put.json" ] && ok || bad "C8: an empty per_token is a good read and the table refreshes"
grep -q -- "--id $ID" <<<"$(grep -v -- '--resolve' "$D/lane-alert.calls")" \
  && bad "C8: an empty per_token must not alert: $(cat "$D/lane-alert.calls")" || ok

# ============================================================================
# C9. a table with fewer rows than model_prices_get's default floor of 5 (a
#     fresh or wiped D1 this lane has not seeded yet) is a good read too: the
#     lane refreshes and seeds it, and the one marked row is honoured.
# ============================================================================
D="$T/c9"; fixtures "$D"
printf '%s\n' '{"per_token":{"grok-4.7":{"prompt":1e-6,"completion":1e-6,"price_source":"vendor-direct","vendor_direct":{"prompt":3e-6,"completion":9e-6}}}}' > "$D/get.json"
run "$D"
[ -s "$D/put.json" ] && ok || bad "C9: a 1-row table is a good read and the table is pushed"
feq "$(field "$D" grok-4.7 prompt)" 3e-6 && ok || bad "C9: the marked row's D1 price is used, got $(row "$D" grok-4.7)"
grep -q -- "--id $ID" <<<"$(grep -v -- '--resolve' "$D/lane-alert.calls")" \
  && bad "C9: a short table must not alert: $(cat "$D/lane-alert.calls")" || ok

# ============================================================================
# E1. the operator verb writes the D1 price.
# ============================================================================
(
  # shellcheck source=/dev/null
  . "$DIR/bin/lib/jobs/cost.sh"
  _jobs_req() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$T/e.req"; printf '{}'; return 0; }
  : > "$T/e.req"
  model_price_source_set grok-4.7 vendor-direct 3e-6 9e-6 >/dev/null; echo "rc=$?" > "$T/e.rc1"
  model_price_source_set grok-4.7 openrouter 3e-6 9e-6 >/dev/null 2>&1; echo "rc=$?" > "$T/e.rc2"
  model_price_source_set grok-4.7 vendor-direct abc 9e-6 >/dev/null 2>&1; echo "rc=$?" > "$T/e.rc3"
  model_price_source_set grok-4.7 vendor-direct 3e-6 >/dev/null 2>&1; echo "rc=$?" > "$T/e.rc4"
  model_price_source_set grok-4.7 vendor-direct 3e-6 9e-6 7.5e-7 "" 256000 >/dev/null; echo "rc=$?" > "$T/e.rc5"
  model_price_source_set grok-4.7 vendor-direct >/dev/null; echo "rc=$?" > "$T/e.rc6"
) 2>"$T/e.err"
[ "$(cat "$T/e.rc1" 2>/dev/null)" = rc=0 ] && ok || bad "E1: a priced set must answer rc 0, got $(cat "$T/e.rc1" 2>/dev/null) $(cat "$T/e.err")"
body() { sed -n "${1}p" "$T/e.req" | sed 's#^PUT /api/model-prices/source ##' | jq -cS . 2>/dev/null; }
# beq <line> <expected-json> — equal as JSON values (jq prints 9e-06 as 0.000009).
beq() { [ -n "$(body "$1")" ] && jq -e --argjson want "$2" '. == $want' <<<"$(body "$1")" >/dev/null 2>&1; }
beq 1 '{"model":"grok-4.7","price_source":"vendor-direct","vendor":{"prompt":3e-6,"completion":9e-6}}' && ok \
  || bad "E1: body must carry vendor.prompt/completion, got '$(body 1)'"
for r in 2 3 4; do
  [ "$(cat "$T/e.rc$r" 2>/dev/null)" = rc=2 ] && ok || bad "E1: bad call $r must answer rc 2, got $(cat "$T/e.rc$r" 2>/dev/null)"
done
[ "$(cat "$T/e.rc5" 2>/dev/null)" = rc=0 ] && ok || bad "E1: a full set must answer rc 0, got $(cat "$T/e.rc5" 2>/dev/null)"
beq 2 '{"model":"grok-4.7","price_source":"vendor-direct","vendor":{"prompt":3e-6,"completion":9e-6,"cache_read":7.5e-7,"cache_write":null,"cliff_tokens":256000}}' && ok \
  || bad "E1: full body wrong, got '$(body 2)'"
beq 3 '{"model":"grok-4.7","price_source":"vendor-direct"}' && ok \
  || bad "E1: no rates means no vendor key, got '$(body 3)'"
[ "$(wc -l < "$T/e.req")" = 3 ] && ok || bad "E1: refused calls send no request, got: $(cat "$T/e.req")"

echo "update-model-prices.bh-1754: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
