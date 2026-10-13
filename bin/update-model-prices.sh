#!/bin/bash
# bin/update-model-prices.sh — daily model price refresh (hub cron 04:30Z).
#
# Cost rows are CLI-reported where the runner reports them (claude CLI stamps
# total_cost_usd itself); this table exists for everything else — filling rows
# whose runner reports tokens but no dollars, and keeping reports honest as
# vendors reprice. Source: OpenRouter's public models API (live list prices per
# token, covers every lane we run including the anthropic/ slugs). DB-driven
# iron law: prices are data in a JSON table, never constants in code.
# Fail-soft: any fetch/parse problem keeps yesterday's file.
# One read fails CLOSED instead (BH-1754): when the model_prices price-source
# marks cannot be read, the lane raises one alert and stops with yesterday's
# table (file and DB) untouched, rather than pricing vendor-direct models at
# OpenRouter's resale rate.
#
# THE MAP IS DATA TOO (BH-1361). Which model key prices from which OpenRouter
# slug lives in catalog/model-slugs.json, so adding a model to the price table
# is a data edit, not a code deploy. Since BH-1510.4 it is the ONLY map: there
# is no script copy to fall back to, so a missing or unusable catalog file skips
# the refresh with one ALERTS line and leaves yesterday's table in place.
#
# WHERE THE TABLE GOES, AND WHY IT IS NOT THE GIT CHECKOUT (BH-628). This wrote
# into /root/harness-checkout/catalog/model-prices.json and, on the common day
# where rates had not moved, rewrote `updated_at` in that tracked file and
# exited without committing. From 04:30 local every day the hub's checkout was
# dirty; bin/harness-sync.sh answers rc 30 on a dirty checkout, so the hub's
# LIVE bin/ froze while the drift check stayed green (it compares the
# CHECKOUT's HEAD to origin, which the ff-only pull keeps current). The other
# path was worse: a hostname-gated `git commit` + `git push origin main` from a
# cron, which also left the file dirty on any failure, and which the iron
# guardrails forbid outright.
#
# So the live table is RUNTIME STATE — $HARNESS/state/model-prices.json, a path
# harness-sync neither inspects nor rsyncs — written whole, temp+mv, so a reader
# mid-refresh keeps its inode. catalog/model-prices.json stays the COMMITTED
# FALLBACK: it is what boxes, fly builders and the pool archive price from, and
# it moves only when a human lands a PR. When the live table drifts from it this
# lane says so once (see the catalog-behind notice at the bottom); it never
# commits, and it never pushes.
set -uo pipefail
H="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-update-model-prices
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off update-model-prices.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit update-model-prices
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    update-model-prices
CK="${HARNESS_CHECKOUT:-/root/harness-checkout}"
OUT="$H/state/model-prices.json"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

# ── the map the refresh actually prices from (BH-1361) ───────────────────────
# catalog/model-slugs.json, resolved the same way the price table is: an
# explicit $MODEL_SLUGS is used AS GIVEN and never fallen back FROM to a
# different file (an override that silently reads another path is worse than no
# override), otherwise the checkout's copy, then the box's synced $H/catalog.
# It is the ONLY map (BH-1510.4 deleted the script's own copy): keyed by the
# name in cost.csv's model column -> the OpenRouter slug that prices it.
# Absent or unusable file -> no refresh at all: ONE ALERTS line saying which
# and why, exit 0 BEFORE the OpenRouter fetch, and yesterday's table stands
# untouched. A valid but EMPTY object is data, not damage — it maps nothing,
# the >=5 floor below refuses the write and yesterday's table stands.
if [ -n "${MODEL_SLUGS:-}" ]; then
  SLUG_PATHS=("$MODEL_SLUGS")
else
  SLUG_PATHS=("$CK/catalog/model-slugs.json" "$H/catalog/model-slugs.json")
fi
SLUG_FILE=""
for f in "${SLUG_PATHS[@]}"; do
  [ -e "$f" ] && { SLUG_FILE="$f"; break; }
done
if [ -z "$SLUG_FILE" ]; then
  HARNESS="$H" "$H/bin/alert-line.sh" "model-prices: slug map absent at ${SLUG_PATHS[*]} — no refresh, keeping existing table (catalog/model-slugs.json is the only map since BH-1510)"
  exit 0
elif SLUG_JSON=$(jq -e 'if type == "object" and all(.[]; type == "string") then . else empty end' "$SLUG_FILE" 2>/dev/null); then
  SLUG_MAP="$SLUG_JSON"
else
  HARNESS="$H" "$H/bin/alert-line.sh" "model-prices: slug map invalid at $SLUG_FILE (not an object of strings) — no refresh, keeping existing table (catalog/model-slugs.json is the only map since BH-1510)"
  exit 0
fi

# The committed fallback, resolved BEFORE the fetch because it is now an INPUT
# as well as the thing the notice at the bottom compares against: OpenRouter
# publishes rates, not price cliffs, so `cliff_tokens` (BH-656) is authored in
# catalog/model-prices.json by hand and CARRIED through this refresh. Without
# that carry the hub loses the cliff at 04:30 every morning — every reader
# prefers the live table — and the cliff warn, the cliff route and the 2x
# pricing all silently stop on the one box that runs the lane they are for.
FALLBACK=""
for f in "$CK/catalog/model-prices.json" "$H/catalog/model-prices.json"; do
  [ -r "$f" ] && { FALLBACK="$f"; break; }
done

# ── the catalog-stale alert (BH-3990) ────────────────────────────────────────
# The DB table is canonical; the committed catalog is the seed a box prices from
# when its sync never landed. Its own `updated_at` is the age that matters, read
# HERE, before the fetch, so a failed refresh cannot hide it. Over
# MODEL_PRICES_CATALOG_MAX_AGE_DAYS (default 14, 0 = off) or unreadable -> one
# warn lane-alert; within it -> resolved. Never writes a table.
CAT_MAX="${MODEL_PRICES_CATALOG_MAX_AGE_DAYS:-14}"
case "$CAT_MAX" in ''|*[!0-9]*) CAT_MAX=14 ;; esac
CAT_MAX=$((10#$CAT_MAX))
if [ -n "$FALLBACK" ] && [ "$CAT_MAX" -gt 0 ]; then
  CAT_UA=$(jq -r '.updated_at // empty' "$FALLBACK" 2>/dev/null)
  CAT_MSG=""
  if [ -n "$CAT_UA" ] && CAT_EP=$(date -u -d "$CAT_UA" +%s 2>/dev/null); then
    CAT_AGE=$(( ( $(date -u +%s) - CAT_EP ) / 86400 ))
    [ "$CAT_AGE" -gt "$CAT_MAX" ] \
      && CAT_MSG="$FALLBACK (catalog/model-prices.json) is $CAT_AGE days old (updated_at $CAT_UA, threshold $CAT_MAX days). It is the seeded fallback a box prices from when its DB sync has not landed; land state/model-prices.json over catalog/model-prices.json in a PR."
  else
    CAT_MSG="$FALLBACK (catalog/model-prices.json) has no readable updated_at ('${CAT_UA:-absent}'), so its age is unknown (threshold $CAT_MAX days). Land state/model-prices.json over catalog/model-prices.json in a PR."
  fi
  CAT_LA="$H/bin/lane-alert.sh"
  if [ -x "$CAT_LA" ]; then
    if [ -n "$CAT_MSG" ]; then CAT_ARGS=(--severity warn)
    else CAT_ARGS=(--resolve); CAT_MSG="catalog/model-prices.json is within $CAT_MAX days of its refresh"; fi
    "$CAT_LA" "${CAT_ARGS[@]}" --id "model-prices-catalog-stale" model-prices "$CAT_MSG" >/dev/null 2>&1 || true
  elif [ -n "$CAT_MSG" ]; then
    HARNESS="$H" "$H/bin/alert-line.sh" "model-prices: model-prices-catalog-stale: $CAT_MSG"
  fi
fi

# The base URL is the endpoint-openrouter knob (BH-1941), resolved before the
# call; an unresolvable endpoint is an ALERTS line and a nonzero exit.
. "${HARNESS:-/root/harness}/bin/lib/endpoints.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/endpoints.sh" 2>/dev/null
OR_BASE=$(endpoint_url openrouter 2>/dev/null) || { HARNESS="$H" "$H/bin/alert-line.sh" "model-prices: no OpenRouter endpoint (ENDPOINT_OPENROUTER: no env, no registry default) — no refresh"; exit 1; }
RAW=$(curl -sf -m 30 "$OR_BASE/api/v1/models") || { HARNESS="$H" "$H/bin/alert-line.sh" "model-prices: fetch failed, keeping existing table"; exit 0; }

# jobs-client is sourced here, above the pricing, because the override set below
# is read through it. The DB push further down keeps its own guard.
if [ -f "$H/bin/jobs-client.sh" ]; then
  # shellcheck source=/dev/null
  . "$H/bin/jobs-client.sh" 2>/dev/null || true
fi

# ── the per-model price source (BH-1613, BH-1754) ─────────────────────────────
# Some models are billed at the vendor's own rate, not OpenRouter's resale list
# (xAI bills grok direct, with its own cliff). An operator marks those rows
# `price_source = vendor-direct` in the model_prices table, with the vendor's
# rates in the same row (jobs-client.sh model-price-source <model> vendor-direct
# <prompt> <completion> ...). GET emits those rates as `vendor_direct` on a
# marked row. For each marked key the pricing below uses the D1 rates, then the
# committed catalog row when D1 has none, instead of OpenRouter's. The match is
# the exact stored string: any other value is OpenRouter.
# A GET that fails, or answers without a per_token object, is NOT "no marks":
# the lane raises ONE lane-alert and exits here, before anything is written, so
# state/model-prices.json, openrouter-models.json and the DB copy all keep
# yesterday's rates. A good read resolves that alert. A box with no jobs-client
# has no marks to read and prices from OpenRouter as it always has.
# The read runs with MODEL_PRICES_MIN=0: model_prices_get's >=5-rows floor is
# for a box syncing the table as its price source, not for reading marks. A
# fresh or wiped table holds fewer than 5 rows, and this lane's push below is
# its only writer, so that floor here would stop the refresh for good and page
# daily about a healthy worker.
DIRECT='{}'
PS_ALERT_ID=model-prices-price-source-unreadable
if command -v model_prices_get >/dev/null 2>&1; then
  PS_TMP=$(mktemp "${TMPDIR:-/tmp}/model-prices-source.XXXXXX")
  if MODEL_PRICES_MIN=0 model_prices_get "$PS_TMP" >/dev/null 2>&1 \
     && D=$(jq -ce '[.per_token | to_entries[] | select(.value.price_source == "vendor-direct") | {key, value: (.value.vendor_direct // null)}] | from_entries' "$PS_TMP" 2>/dev/null); then
    DIRECT="$D"
    rm -f "$PS_TMP"
    [ -x "$H/bin/lane-alert.sh" ] && "$H/bin/lane-alert.sh" --resolve --id "$PS_ALERT_ID" \
      model-prices "price-source marks readable again" >/dev/null 2>&1 || true
  else
    rm -f "$PS_TMP"
    MSG="the price_source marks could not be read from model_prices (GET failed), so today's refresh stopped and kept yesterday's table. Vendor-direct models would otherwise have been priced at OpenRouter's resale rate. Check the jobs worker; the next 04:30Z run retries."
    if [ -x "$H/bin/lane-alert.sh" ]; then
      "$H/bin/lane-alert.sh" --severity warn --id "$PS_ALERT_ID" model-prices "$MSG" >/dev/null 2>&1 || true
    else
      HARNESS="$H" "$H/bin/alert-line.sh" "model-prices: $MSG"
    fi
    exit 0
  fi
fi

PY_ERR=$(mktemp "${TMPDIR:-/tmp}/model-prices-err.XXXXXX")
NEW=$(printf '%s' "$RAW" | python3 -c '
import json, sys, datetime
raw = json.load(sys.stdin)["data"]
mapping = json.loads(sys.argv[1])
by_id = {m["id"]: m.get("pricing", {}) for m in raw}
def num(x):
    try: return float(x)
    except (TypeError, ValueError): return None
per = {}
for name, slug in mapping.items():
    p = by_id.get(slug)
    if not p: continue
    per[name] = {"prompt": num(p.get("prompt")), "completion": num(p.get("completion")),
                 "cache_read": num(p.get("input_cache_read")), "cache_write": num(p.get("input_cache_write")),
                 "slug": slug}
# CARRY THE CLIFF (BH-656). OpenRouter prices per token and says nothing about
# the per-request cliff xAI bills on, so `cliff_tokens` is authored once in the
# committed catalog and copied onto the matching model here. Apart from the
# vendor-direct rows below, nothing else on a row is taken from the fallback, so
# the catalog-behind compare still reads equal on a day rates did not move. A
# missing or unreadable fallback carries nothing and is not an error: the lane
# must never fail on a file it only reads for optional keys.
fb = {}
try:
    fb = json.load(open(sys.argv[2]))["per_token"]
except Exception:
    fb = {}
for name, row in per.items():
    c = (fb.get(name) or {}).get("cliff_tokens")
    if isinstance(c, (int, float)) and not isinstance(c, bool) and c > 0:
        row["cliff_tokens"] = c
# VENDOR-DIRECT (BH-1613, BH-1754): a marked key takes its D1 vendor price
# (argv[3] maps each marked key to its GET `vendor_direct`, or null) when that
# carries a prompt and completion > 0; otherwise its committed catalog row
# verbatim (rates, slug, cliff). A D1 price overlays the catalog row per field:
# a cache rate or cliff the operator did not set in D1 comes from the catalog
# row, never "none" (a dropped cliff prices every request past it at half).
# Either way it is priced even when OpenRouter no longer lists the slug. A marked key with neither keeps its OpenRouter
# price, never none, and is named on stderr for the shell to log. Only keys in
# the slug map count.
def rate(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and x > 0
for name, v in json.loads(sys.argv[3]).items():
    if name not in mapping: continue
    r = fb.get(name)
    if isinstance(v, dict) and rate(v.get("prompt")) and rate(v.get("completion")):
        r = r if isinstance(r, dict) else {}
        def pick(k):
            if rate(v.get(k)): return v[k]
            return r[k] if rate(r.get(k)) else None
        row = {"prompt": v["prompt"], "completion": v["completion"],
               "cache_read": pick("cache_read"), "cache_write": pick("cache_write"),
               "slug": r.get("slug") or mapping[name]}
        c = v.get("cliff_tokens")
        if not (isinstance(c, int) and not isinstance(c, bool) and c > 0):
            c = r.get("cliff_tokens")
        if rate(c):
            row["cliff_tokens"] = c
        per[name] = row
    elif isinstance(r, dict):
        per[name] = dict(r)
    else:
        print("VENDOR_DIRECT_NO_ROW " + name, file=sys.stderr)
print(json.dumps({"updated_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                  "source": "openrouter/api/v1/models", "per_token": per}))
' "$SLUG_MAP" "$FALLBACK" "$DIRECT" 2>"$PY_ERR")
sed -n 's/^VENDOR_DIRECT_NO_ROW //p' "$PY_ERR" | while IFS= read -r k; do
  echo "$(STAMP) model-prices: $k is marked vendor-direct but has no D1 vendor price and no catalog row in catalog/model-prices.json; priced from OpenRouter this run" >> "$H/logs/agent-rules.log"
done
rm -f "$PY_ERR"

N=$(jq '.per_token | length' <<<"$NEW" 2>/dev/null || echo 0)
[ "${N:-0}" -ge 5 ] || { HARNESS="$H" "$H/bin/alert-line.sh" "model-prices: parsed only ${N:-0} models — refusing to overwrite (empty is not pass)"; exit 0; }

# One unconditional write. NEW already carries a fresh `updated_at`, so the
# "rates did not move" day still refreshes the stamp and staleness stays
# measurable — it just does it in state/, where nothing is tracked and there is
# no commit to churn.
mkdir -p "$H/state"

# ── the OpenRouter id list, kept for the UNPRICED alert (BH-1361) ────────────
# cost-rollup names the catalog line to add for a model it could not price, and
# the slug half of that line has to come from somewhere. This lane already holds
# the full list, once a day, so it writes it down instead of making the hourly
# rollup fetch it again. It is a HINT SOURCE, not a contract: temp+mv, and a
# failure here changes nothing and stops nothing — the alert then says <slug?>.
printf '%s' "$RAW" | python3 -c '
import json, sys, datetime
raw = json.load(sys.stdin)["data"]
print(json.dumps({"fetched_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                  "ids": [m["id"] for m in raw if isinstance(m.get("id"), str)]}))
' > "$H/state/openrouter-models.json.tmp" 2>/dev/null \
  && mv "$H/state/openrouter-models.json.tmp" "$H/state/openrouter-models.json" \
  || rm -f "$H/state/openrouter-models.json.tmp"

printf '%s\n' "$NEW" | jq . > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

# ── and into the model_prices table (BH-1032) ────────────────────────────────
# WHY. Until now this file was the live table and it is HUB-ONLY runtime state
# — harness-sync neither inspects nor rsyncs state/ — so every other box, and in
# particular every Fly pool machine (the fleet's largest execute lane), priced
# its rows from catalog/model-prices.json, the committed fallback that moves
# only when a human lands a PR. One call could be priced two ways depending on
# which machine ran it, and the cheaper reading was the one nobody chose.
#
# So the rates go to the DB, and bin/model-prices-sync.sh pulls them down into
# each box's own state/model-prices.json — the same path every reader already
# prefers, so no consumer changes. FAIL-OPEN AND AFTER THE FILE: the write above
# is the contract, this is a mirror, and a worker outage leaves this lane
# behaving exactly as it did before it existed.
# (jobs-client.sh is sourced above the pricing, for the price-source read.)
PUSHED=0
if command -v model_prices_put >/dev/null 2>&1; then
  model_prices_put "$OUT" openrouter >/dev/null 2>&1 \
    && PUSHED=1 \
    || echo "$(STAMP) model-prices: the table push failed — $OUT is current, the DB copy is stale until the next run" >> "$H/logs/agent-rules.log"
fi
# BH-5652: the hub has no model-prices-sync line (it would read back its own
# push), so this is how the hub's table gets each row's D1 `version` and a hub
# cost row records `price_v:`. Only after a good push. A failed read leaves $OUT
# unversioned: rows then carry no token, never a guessed one.
if [ "$PUSHED" = 1 ] && command -v model_prices_versions_merge >/dev/null 2>&1; then
  model_prices_versions_merge "$OUT" >/dev/null 2>&1 \
    || echo "$(STAMP) model-prices: could not read the price versions back — hub cost rows carry no price_v until the next run" >> "$H/logs/agent-rules.log"
fi

# ── the catalog-behind notice ────────────────────────────────────────────────
# The committed fallback is what every box, every fly builder and the pool
# archive price from, and nothing refreshes it but a human opening a PR. Its
# staleness therefore has to be VISIBLE, or "the catalog is the fallback" is
# just a nicer way of saying the fleet quietly prices off an old table.
# lane-alert.sh holds the state, so the repeat is counted, not re-sent.
# ($FALLBACK is resolved above the fetch — it is an input to the table now.)
# RATES_ONLY: a catalog landed from a versioned state file carries the BH-5652
# `version`/`effective_at` keys (and a vendor-direct row copies them into NEW).
# A version is not a rate, so both sides drop them before the compare.
RATES_ONLY='map_values(if type == "object" then del(.version, .effective_at) else . end)'
if [ -n "$FALLBACK" ] && [ "$(jq -S ".per_token | $RATES_ONLY" "$FALLBACK" 2>/dev/null)" != "$(jq -S ".per_token | $RATES_ONLY" <<<"$NEW")" ]; then
  DIFFN=$(jq -n --slurpfile old "$FALLBACK" --argjson new "$(jq -c ".per_token | $RATES_ONLY" <<<"$NEW")" \
    "((((\$old[0] // {}).per_token) // {}) | $RATES_ONLY) as \$o"'
     | [ ((($o|keys) + ($new|keys)) | unique)[] | select($o[.] != $new[.]) ] | length' 2>/dev/null)
  MSG="the live price table has drifted from the committed fallback: ${DIFFN:-some} model rate(s) differ between $OUT and $FALLBACK. Boxes, fly builders and the pool archive all price from the fallback, so until someone lands state/model-prices.json over catalog/model-prices.json in a PR they are costing runs at the older rates."
  echo "$(STAMP) model-prices: $MSG" >> "$H/logs/agent-rules.log"
  if [ -x "$H/bin/lane-alert.sh" ]; then
    "$H/bin/lane-alert.sh" --severity warn --id model-prices-catalog-behind \
      model-prices "$MSG" >/dev/null 2>&1 || true
  else
    HARNESS="$H" "$H/bin/alert-line.sh" "model-prices: $MSG"
  fi
fi

# ── the price seed (BH-5652) ─────────────────────────────────────────────────
# bin/price-seed.sh mirrors the three committed price files (model prices,
# Fly prices, slugs) into their DB tables, once per file content. LAST, so the
# live OpenRouter rows above land first and a catalog row (insert-only on the
# worker) can never stand in for one. Its own failure is its own lane-alert
# (price-seed-failed) and changes nothing above it, so its rc is ignored here.
[ -x "$H/bin/price-seed.sh" ] && "$H/bin/price-seed.sh" >/dev/null 2>&1 || true
