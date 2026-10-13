#!/bin/bash
# tests/update-model-prices.bh-1613-test.sh — the per-model price source (BH-1613).
#
# A model marked `price_source = vendor-direct` in the model_prices table is
# billed at the vendor's own rate (xAI bills grok-4.7 at $2 / $0.50 / $6 with a
# 200k cliff), not at OpenRouter's resale list. The daily refresh must keep the
# committed catalog row for it instead of overwriting it with OpenRouter's
# number, and — because that row then equals the catalog — the catalog-behind
# notice must stop firing for it.
#
# The real bin/update-model-prices.sh runs whole against a scratch $HARNESS: a
# fixture `curl` serves OpenRouter's list, a fake bin/jobs-client.sh serves the
# model_prices GET (the override set) and records the POST, and a fake
# lane-alert.sh records the notice. Every run supplies its own slug map and its
# own catalog, so nothing here depends on which models main's catalog carries.
# Section B drives the operator verb's client function with _jobs_req stubbed.
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
cp "$DIR/bin/update-model-prices.sh" "$T/update-model-prices.sh"
mkdir -p "$T/lib"; cp "$DIR/bin/lib/endpoints.sh" "$T/lib/"   # BH-1941: beside the script copy

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
cat "$CURL_BODY"
SH
chmod +x "$T/fakebin/curl"

# The slug map: five anthropic/openai keys plus both grok-4.7 spellings.
cat > "$T/slugs.json" <<'JSON'
{"claude-fable-5-1":"anthropic/claude-fable-5.1","claude-opus-5":"anthropic/claude-opus-5",
 "claude-sonnet-5":"anthropic/claude-sonnet-5","claude-haiku-4-5":"anthropic/claude-haiku-4.5",
 "gpt-6-astra":"openai/gpt-6-astra","grok-4.7":"x-ai/grok-4.7","x-ai/grok-4.7":"x-ai/grok-4.7"}
JSON

# fixtures <run-dir> [opts...] — writes openrouter.json and checkout/catalog/model-prices.json.
# The catalog is built from the SAME OpenRouter rates, so a row the refresh
# prices from OpenRouter compares equal to it, except:
#   grok-4.7 in the catalog is the vendor rate 2e-6 / 6e-6 / 5e-7, cliff 200000
# opts: no-grok-slug   OpenRouter omits x-ai/grok-4.7
#       no-grok-row    the catalog has no grok-4.7 row
#       sonnet-moved   OpenRouter's sonnet completion differs from the catalog
#       all-moved      every non-grok-4.7 catalog row differs from OpenRouter, and
#                      the catalog carries a row for a key the slug map lacks
fixtures() {
  local d="$1"; shift
  mkdir -p "$d/checkout/catalog"
  python3 - "$T/slugs.json" "$d" "$@" <<'PY'
import json, sys
slugs = json.load(open(sys.argv[1])); d = sys.argv[2]; opts = set(sys.argv[3:])
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
    if s == "x-ai/grok-4.7" and "no-grok-slug" in opts: continue
    pr = {"prompt": p, "completion": c, "input_cache_read": cr}
    if cw is not None: pr["input_cache_write"] = cw
    if s == "anthropic/claude-sonnet-5" and "sonnet-moved" in opts: pr["completion"] = "0.000018"
    data.append({"id": s, "pricing": pr})
json.dump({"data": data}, open(d + "/openrouter.json", "w"))
num = lambda x: None if x is None else float(x)
per = {}
for k, s in slugs.items():
    p, c, cr, cw = rates[s]
    row = {"prompt": num(p), "completion": num(c), "cache_read": num(cr), "cache_write": num(cw), "slug": s}
    if "all-moved" in opts: row["prompt"] = row["prompt"] * 3
    per[k] = row
per["grok-4.7"] = {"prompt": 2e-6, "completion": 6e-6, "cache_read": 5e-7, "cache_write": None,
                   "slug": "x-ai/grok-4.7", "cliff_tokens": 200000}
if "no-grok-row" in opts: del per["grok-4.7"]
# A catalog row for a key the slug map does not carry: marking it must not
# smuggle it into the live table.
if "all-moved" in opts: per["not-a-mapped-model"] = {"prompt": 9e-6, "completion": 9e-6, "slug": "x/unmapped"}
json.dump({"updated_at": "2026-09-01T00:00:00Z", "source": "catalog", "per_token": per},
          open(d + "/checkout/catalog/model-prices.json", "w"))
PY
}

# getbody <run-dir> <json-object model->price_source (null = no key)> — the GET answer.
getbody() {
  python3 - "$2" > "$1/get.json" <<'PY'
import json, sys
marks = json.loads(sys.argv[1])
per = {m: {"prompt": 1e-6, "completion": 1e-6} for m in
       ["claude-fable-5-1", "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5", "gpt-6-astra", "x-ai/grok-4.7"]}
for m, ps in marks.items():
    per.setdefault(m, {"prompt": 1e-6, "completion": 1e-6})
    if ps is not None: per[m]["price_source"] = ps
print(json.dumps({"updated_at": "2026-09-22T04:30:00Z", "source": "openrouter", "per_token": per}))
PY
}

# run <run-dir> [env...] — one refresh against its own scratch $HARNESS.
run() {
  local d="$1"; shift
  mkdir -p "$d/bin" "$d/logs" "$d/state"
  : > "$d/logs/agent-rules.log"; : > "$d/lane-alert.calls"
  cat > "$d/bin/jobs-client.sh" <<'SH'
model_prices_get() { [ -n "${GET_RC:-}" ] && return "$GET_RC"; cp "$GET_BODY" "$1"; }
model_prices_put() { cp "$1" "$PUT_OUT"; }
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

# ============================================================================
# A1. grok-4.7 marked vendor-direct, OpenRouter at $1.60: the row stays at the
#     vendor's $2 / $0.50 / $6 with its 200k cliff, in the file AND the DB push.
# ============================================================================
D="$T/a1"; fixtures "$D"; getbody "$D" '{"grok-4.7":"vendor-direct"}'
run "$D"
[ "$RC" = 0 ] && ok || bad "A1: refresh must exit 0, got $RC: $(cat "$D/run.err")"
feq "$(field "$D" grok-4.7 prompt)" 2e-6       && ok || bad "A1: grok-4.7 prompt must be the vendor 2e-6, got $(row "$D" grok-4.7)"
feq "$(field "$D" grok-4.7 completion)" 6e-6   && ok || bad "A1: grok-4.7 completion must be 6e-6, got $(row "$D" grok-4.7)"
feq "$(field "$D" grok-4.7 cache_read)" 5e-7   && ok || bad "A1: grok-4.7 cache_read must be 5e-7, got $(row "$D" grok-4.7)"
[ "$(field "$D" grok-4.7 cliff_tokens)" = 200000 ] && ok || bad "A1: grok-4.7 must keep cliff 200000, got $(row "$D" grok-4.7)"
P=$(jq -c '.per_token["grok-4.7"]' "$D/put.json" 2>/dev/null)
[ -n "$P" ] && [ "$P" = "$(row "$D" grok-4.7)" ] && ok || bad "A1: the DB push must carry the same grok-4.7 row, got '$P'"
# x-ai/grok-4.7 is NOT marked, so it is OpenRouter's $1.60.
feq "$(field "$D" x-ai/grok-4.7 prompt)" 1.6e-6 && ok || bad "A1: unmarked x-ai/grok-4.7 must stay at OpenRouter 1.6e-6, got $(row "$D" x-ai/grok-4.7)"

# A2. same run: no catalog-behind notice for it.
# (BH-1754: the good marks read now also sends a --resolve for its own alert
# id, so the sink must hold exactly that one call and nothing else.)
[ "$(wc -l < "$D/lane-alert.calls")" = 1 ] \
  && grep -q -- '^--resolve --id model-prices-price-source-unreadable ' "$D/lane-alert.calls" && ok \
  || bad "A2: the only lane-alert call is the price-source resolve, got: $(cat "$D/lane-alert.calls")"
grep -q 'drifted from the committed fallback' "$D/logs/agent-rules.log" \
  && bad "A2: no drift line may be logged: $(cat "$D/logs/agent-rules.log")" || ok

# ============================================================================
# A3. mutation / red proof: nothing marked -> grok-4.7 is OpenRouter's rate and
#     the notice fires counting exactly it. A1/A2 are therefore not vacuous.
# ============================================================================
D="$T/a3"; fixtures "$D"; getbody "$D" '{}'
run "$D"
feq "$(field "$D" grok-4.7 prompt)" 1.6e-6 && ok || bad "A3: unmarked grok-4.7 must be OpenRouter's 1.6e-6, got $(row "$D" grok-4.7)"
grep -q '1 model rate(s)' "$D/lane-alert.calls" && ok || bad "A3: the notice must fire for 1 model, got: $(cat "$D/lane-alert.calls")"

# ============================================================================
# A4. grok-4.7 marked and sonnet moved: the notice counts sonnet, not grok.
# ============================================================================
D="$T/a4"; fixtures "$D" sonnet-moved; getbody "$D" '{"grok-4.7":"vendor-direct"}'
run "$D"
grep -q '1 model rate(s)' "$D/lane-alert.calls" && ok || bad "A4: the notice must count only sonnet (1), got: $(cat "$D/lane-alert.calls")"
feq "$(field "$D" claude-sonnet-5 completion)" 1.8e-5 && ok || bad "A4: sonnet must take OpenRouter's moved rate, got $(row "$D" claude-sonnet-5)"
feq "$(field "$D" grok-4.7 prompt)" 2e-6 && ok || bad "A4: grok-4.7 stays vendor-direct, got $(row "$D" grok-4.7)"

# ============================================================================
# A5. grok-4.7 marked and OpenRouter no longer lists the slug: still priced.
# ============================================================================
D="$T/a5"; fixtures "$D" no-grok-slug; getbody "$D" '{"grok-4.7":"vendor-direct"}'
run "$D"
feq "$(field "$D" grok-4.7 prompt)" 2e-6 && ok || bad "A5: grok-4.7 must be priced from the catalog when OpenRouter drops it, got '$(row "$D" grok-4.7)'"
[ "$(field "$D" grok-4.7 cliff_tokens)" = 200000 ] && ok || bad "A5: and keep its cliff, got '$(row "$D" grok-4.7)'"

# ============================================================================
# A6. grok-4.7 marked but the catalog has no row: OpenRouter's rate (never 0,
#     never dropped) and exactly one agent-rules line naming it.
# ============================================================================
D="$T/a6"; fixtures "$D" no-grok-row; getbody "$D" '{"grok-4.7":"vendor-direct"}'
run "$D"
feq "$(field "$D" grok-4.7 prompt)" 1.6e-6 && ok || bad "A6: grok-4.7 with no catalog row keeps OpenRouter's 1.6e-6, got '$(row "$D" grok-4.7)'"
N=$(grep -c 'grok-4.7 is marked vendor-direct' "$D/logs/agent-rules.log")
[ "$N" = 1 ] && ok || bad "A6: exactly one 'marked vendor-direct' line, got $N: $(cat "$D/logs/agent-rules.log")"

# ============================================================================
# A7. adversarial negatives: none of these values is vendor-direct, a marked
#     key the slug map does not carry adds no row, and marking grok-4.7 does not
#     mark x-ai/grok-4.7. Every catalog row differs from OpenRouter here, so a
#     key wrongly treated as direct would show the catalog's tripled prompt.
# ============================================================================
D="$T/a7"; fixtures "$D" all-moved
getbody "$D" '{"claude-fable-5-1":"openrouter","claude-opus-5":"","claude-sonnet-5":"Vendor-Direct","claude-haiku-4-5":"vendor_direct","gpt-6-astra":null,"grok-4.7":"vendor-direct","not-a-mapped-model":"vendor-direct"}'
run "$D"
for kv in claude-fable-5-1:1.5e-5 claude-opus-5:5e-6 claude-sonnet-5:3e-6 claude-haiku-4-5:1e-6 gpt-6-astra:2.5e-6 x-ai/grok-4.7:1.6e-6; do
  k=${kv%%:*}; v=${kv#*:}
  feq "$(field "$D" "$k" prompt)" "$v" && ok || bad "A7: $k must be priced from OpenRouter ($v), got $(row "$D" "$k")"
done
feq "$(field "$D" grok-4.7 prompt)" 2e-6 && ok || bad "A7: grok-4.7 is exactly 'vendor-direct' and stays at 2e-6, got $(row "$D" grok-4.7)"
[ "$(row "$D" not-a-mapped-model)" = null ] && ok || bad "A7: a marked key outside the slug map must add no row, got $(row "$D" not-a-mapped-model)"
grep -q 'not-a-mapped-model' "$D/logs/agent-rules.log" \
  && bad "A7: a marked key outside the slug map is not this lane's to log: $(cat "$D/logs/agent-rules.log")" || ok

# ============================================================================
# A8. the GET fails. Amended by BH-1754, which reversed this case: it used to
#     re-price every model from OpenRouter and log one agent-rules line. Now
#     the refresh stops, yesterday's table stays byte-identical, nothing is
#     pushed, and one lane-alert names the unreadable marks.
# ============================================================================
D="$T/a8"; fixtures "$D"; getbody "$D" '{"grok-4.7":"vendor-direct"}'
mkdir -p "$D/state"; printf '%s\n' '{"per_token":{"grok-4.7":{"prompt":2e-06,"completion":6e-06}}}' > "$D/state/model-prices.json"
cp "$D/state/model-prices.json" "$D/yesterday.json"
run "$D" GET_RC=1
[ "$RC" = 0 ] && ok || bad "A8: refresh must exit 0, got $RC"
cmp -s "$D/state/model-prices.json" "$D/yesterday.json" && ok || bad "A8: yesterday's table must be kept, got $(cat "$D/state/model-prices.json")"
[ ! -e "$D/put.json" ] && ok || bad "A8: nothing may be pushed to the DB"
N=$(grep -c 'overrides unreadable' "$D/logs/agent-rules.log")
[ "$N" = 0 ] && ok || bad "A8: no 'overrides unreadable' agent-rules line any more, got $N: $(cat "$D/logs/agent-rules.log")"
N=$(grep -c -- '--id model-prices-price-source-unreadable' "$D/lane-alert.calls")
[ "$N" = 1 ] && ok || bad "A8: exactly one price-source-unreadable lane-alert, got $N: $(cat "$D/lane-alert.calls")"

# ============================================================================
# B. the operator verb's client: model_price_source_set
# ============================================================================
(
  # shellcheck source=/dev/null
  . "$DIR/bin/lib/jobs/cost.sh"
  _jobs_req() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$T/b.req"; printf '{}'; return 0; }
  : > "$T/b.req"
  model_price_source_set grok-4.7 vendor-direct >/dev/null; echo "rc=$?" > "$T/b.rc1"
  model_price_source_set grok-4.7 bogus >/dev/null 2>&1; echo "rc=$?" > "$T/b.rc2"
  model_price_source_set "" openrouter >/dev/null 2>&1; echo "rc=$?" > "$T/b.rc3"
) 2>"$T/b.err"
[ "$(cat "$T/b.rc1" 2>/dev/null)" = rc=0 ] && ok || bad "B: a valid set must answer rc 0, got $(cat "$T/b.rc1" 2>/dev/null) $(cat "$T/b.err")"
L=$(head -1 "$T/b.req" 2>/dev/null)
case "$L" in "PUT /api/model-prices/source "*) ok ;; *) bad "B: must PUT /api/model-prices/source, got '$L'" ;; esac
B=$(printf '%s' "${L#PUT /api/model-prices/source }" | jq -cS . 2>/dev/null)
[ "$B" = '{"model":"grok-4.7","price_source":"vendor-direct"}' ] && ok || bad "B: body must be {model,price_source}, got '$B'"
[ "$(cat "$T/b.rc2" 2>/dev/null)" = rc=2 ] && ok || bad "B: a bad value must answer rc 2, got $(cat "$T/b.rc2" 2>/dev/null)"
[ "$(cat "$T/b.rc3" 2>/dev/null)" = rc=2 ] && ok || bad "B: a missing model must answer rc 2, got $(cat "$T/b.rc3" 2>/dev/null)"
[ "$(wc -l < "$T/b.req" 2>/dev/null)" = 1 ] && ok || bad "B: a refused call must send no request, got: $(cat "$T/b.req" 2>/dev/null)"

echo "update-model-prices.bh-1613: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
