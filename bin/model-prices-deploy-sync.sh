#!/bin/bash
# bin/model-prices-deploy-sync.sh — put a newly priced model into the
# model_prices table on the deploy that brings it, not at the next 04:30Z
# refresh (BH-1566). Run by bin/harness-sync.sh's deploy path on every box,
# after its success stamp; never run by cron. harness-sync starts it DETACHED
# (BH-1890): its own session, `timeout 600`, output to
# logs/model-prices-deploy-sync.log, so it never counts against the deploy's
# own timeout.
#
# WHY. #1523 priced Opus 5.5 in catalog/model-prices.json and in the refresh's
# slug map, and model_prices still had no row for the Opus 5.5 id until the 04:30Z
# refresh (bin/update-model-prices.sh is the table's only writer), with the
# boxes' 05:05Z pull behind it. For up to a day:
#   - every box costed Opus 5.5 calls from a state/model-prices.json with no row
#     for it. The reader chain (bin/lib/cost-row.sh) takes the FIRST readable
#     table, so the catalog row the deploy had just put on the box never
#     counted, and billed calls landed as unpriced cost rows;
#   - the model_routes PUT refused the model ("not in model_prices"), so the
#     Models console could not route to it.
#
# WHAT IT DOES, once per change. The key is the last commit that touched a price
# input: catalog/model-prices.json, catalog/model-slugs.json, or
# bin/update-model-prices.sh (the refresh itself). A key equal to
# state/model-prices-deploy-synced exits before any network call, so a deploy
# that touches no price input costs one `git rev-list`.
#   1. THE HUB (the configured hub holding the lease, with the update-model-prices
#      lane not switched off) runs the refresh once per key, then makes sure
#      every committed catalog model is in the table. A model the table lacks is
#      POSTed from the committed catalog row as source=catalog; the refresh
#      replaces it with the live rate at 04:30. It only ever ADDS a missing
#      model: a row the table already has (a live rate, a vendor-direct price,
#      a mark) is never overwritten by the catalog. So a new model is priced
#      even when OpenRouter is down or does not list it yet.
#   2. EVERY BOX (hub included) pulls the table into state/model-prices.json
#      through bin/model-prices-sync.sh when that file lacks a catalog model,
#      and stamps the key only once the file covers every catalog model. A box
#      that deploys before the hub has pushed stays unstamped and catches up on
#      its next deploy.
#
# FAILURE. A GET or POST that fails on the hub raises one lane-alert under
# `model-prices-deploy-sync` and leaves the key unstamped, so the next deploy
# retries; the next good run resolves it. So does a table read with NO models
# while this hub's state/model-prices.json has some (or does not parse): that
# read is taken as wrong, not as an empty table, and no POST is sent, because
# every catalog model would look missing and go in as source=catalog (BH-1890).
# Nothing here fails, delays or vetoes a deploy: harness-sync starts it detached
# after its stamp and never waits for it.
set -uo pipefail
H="${HARNESS:-/root/harness}"
CK="${HARNESS_CHECKOUT:-/root/harness-checkout}"
LOG="$H/logs/update-runners.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
DONE="$H/state/model-prices-deploy-synced"
REFRESHED="$H/state/model-prices-deploy-refreshed"
NOTED="$H/state/model-prices-deploy-pending"
LIVE="$H/state/model-prices.json"
ALERT_ID=model-prices-deploy-sync

[ -d "$CK/.git" ] || exit 0
KEY=$(git -C "$CK" rev-list -1 HEAD -- catalog/model-prices.json catalog/model-slugs.json bin/update-model-prices.sh 2>/dev/null)
[ -n "$KEY" ] || exit 0
[ "$(cat "$DONE" 2>/dev/null)" = "$KEY" ] && exit 0

mkdir -p "$H/state" "$H/logs" "$H/locks" 2>/dev/null
exec 9>"$H/locks/model-prices-deploy-sync.lock"
flock -n 9 || exit 0

# No client, no table to sync: this box prices from the catalog harness-sync
# just deployed.
[ -f "$H/bin/jobs-client.sh" ] || exit 0
# shellcheck source=/dev/null
. "$H/bin/jobs-client.sh" 2>/dev/null || exit 0
# shellcheck source=/dev/null
. "$H/bin/lib/hub-box.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/model-prices-deploy.XXXXXX") || exit 0
trap 'rm -rf "$TMPD"' EXIT

# The catalog AT THE KEY, not the working tree: the checkout can move under this
# run (it runs outside harness-sync's deploy lock), and a key paired with a
# later commit's catalog would stamp coverage nobody measured. A key with no
# catalog file (a slug-only history) measures nothing and stamps.
CAT="$TMPD/catalog.json"
git -C "$CK" show "$KEY:catalog/model-prices.json" > "$CAT" 2>/dev/null || printf '{}' > "$CAT"

# missing_from <table-file> — the catalog models (those with a numeric rate; a
# rate-less row is neither pushable nor priceable) the table has no row for,
# one per line. An absent table is missing nothing: the readers then fall back
# to the catalog itself.
missing_from() {
  [ -f "$1" ] || return 0
  jq -r --slurpfile t "$1" '
    (($t[0] // {}) | (.per_token // .)) as $have
    | (.per_token // {}) | to_entries[]
    | select(.value | type == "object")
    | select([.value.prompt, .value.completion, .value.cache_read, .value.cache_write] | any(type == "number"))
    | .key as $k | select($have | has($k) | not) | $k' "$CAT" 2>/dev/null
}

alert() {
  if [ -x "$H/bin/lane-alert.sh" ]; then
    "$H/bin/lane-alert.sh" --severity warn --id "$ALERT_ID" model-prices "$1" >/dev/null 2>&1 || true
  else
    echo "$(STAMP) model-prices: $1" >> "$H/logs/ALERTS.log"
  fi
}

# ── 1. the hub ───────────────────────────────────────────────────────────────
HUB=0
if command -v is_hub_box >/dev/null 2>&1 && is_hub_box "$(local_box_name)" \
   && [ -x "$H/bin/hub-lease.sh" ] && "$H/bin/hub-lease.sh" check >/dev/null 2>&1; then
  HUB=1
  # The price lane's off-switch stops its deploy-time writes as well.
  command -v lane_paused >/dev/null 2>&1 && lane_paused update-model-prices && HUB=0
fi
if [ "$HUB" = 1 ]; then
  # The refresh, once per key whatever it did: it is fail-soft with its own
  # alerts, and the 04:30 cron is its retry.
  if [ "$(cat "$REFRESHED" 2>/dev/null)" != "$KEY" ]; then
    [ -x "$H/bin/update-model-prices.sh" ] \
      && HARNESS="$H" HARNESS_CHECKOUT="$CK" timeout 150 "$H/bin/update-model-prices.sh" >/dev/null 2>&1
    printf '%s\n' "$KEY" > "$REFRESHED"
    echo "$(STAMP) model-prices: price inputs changed at ${KEY:0:7}, ran the price refresh" >> "$LOG"
  fi
  # MODEL_PRICES_MIN=0: a fresh or short table is a good read here, and this
  # push is what fills it.
  if ! MODEL_PRICES_MIN=0 model_prices_get "$TMPD/table.json" >/dev/null 2>&1; then
    alert "the model_prices table could not be read after the deploy at ${KEY:0:7}, so a model priced in that commit may still be unpriced in the table. The next deploy retries; the 04:30Z refresh also fills it."
    exit 0
  fi
  # BH-1890: an empty read is only believed on a hub with nothing to lose. A
  # state file that holds models (or does not parse: fail closed) says the
  # table had rows, so the read is wrong and the POST would put every catalog
  # rate in the table. An absent or empty state file is a fresh hub: go on.
  TN=$(jq -r '(.per_token // {}) | length' "$TMPD/table.json" 2>/dev/null)
  if [ "${TN:-0}" = 0 ] && [ -f "$LIVE" ]; then
    LN=$(jq -r '(.per_token // .) | length' "$LIVE" 2>/dev/null)
    if ! [[ "$LN" =~ ^[0-9]+$ ]] || [ "$LN" -gt 0 ]; then
      [[ "$LN" =~ ^[0-9]+$ ]] && LD="$LN models" || LD="a file that does not parse"
      alert "the model_prices table read back with no models after the deploy at ${KEY:0:7}, while this hub's state/model-prices.json holds $LD. The catalog POST was skipped so live rates are not overwritten with catalog rates. The next deploy retries."
      echo "$(STAMP) model-prices: table read empty but $LIVE is not; refused the catalog POST at ${KEY:0:7}" >> "$LOG"
      exit 0
    fi
  fi
  mapfile -t ADD < <(missing_from "$TMPD/table.json")
  if [ "${#ADD[@]}" -gt 0 ]; then
    jq --args '{source: "catalog", per_token: (.per_token | with_entries(select(.key | IN($ARGS.positional[]))))}' \
      "${ADD[@]}" < "$CAT" > "$TMPD/add.json" 2>/dev/null
    if ! model_prices_put "$TMPD/add.json" catalog >/dev/null 2>&1; then
      alert "could not add ${ADD[*]} to the model_prices table from the committed catalog after the deploy at ${KEY:0:7}, so those models are unpriced in the table until the next deploy or the 04:30Z refresh."
      exit 0
    fi
    echo "$(STAMP) model-prices: added ${ADD[*]} to model_prices from the committed catalog at ${KEY:0:7} (source catalog, until the 04:30Z refresh)" >> "$LOG"
  fi
  [ -x "$H/bin/lane-alert.sh" ] && "$H/bin/lane-alert.sh" --resolve --id "$ALERT_ID" \
    model-prices "the model_prices table covers the committed catalog again" >/dev/null 2>&1
fi

# ── 2. every box ─────────────────────────────────────────────────────────────
if [ -n "$(missing_from "$LIVE")" ] && [ -x "$H/bin/model-prices-sync.sh" ]; then
  HARNESS="$H" "$H/bin/model-prices-sync.sh" >/dev/null 2>&1
fi
LEFT=$(missing_from "$LIVE" | tr '\n' ' ')
if [ -z "${LEFT// /}" ]; then
  printf '%s\n' "$KEY" > "$DONE"
  rm -f "$NOTED"
  exit 0
fi
# Once per key: a box that deployed before the hub pushed retries on every
# deploy until it catches up, and that is not news every five minutes.
if [ "$(cat "$NOTED" 2>/dev/null)" != "$KEY" ]; then
  echo "$(STAMP) model-prices: $LIVE still has no row for ${LEFT% } after the deploy at ${KEY:0:7}; retrying on each deploy until the table has them" >> "$LOG"
  printf '%s\n' "$KEY" > "$NOTED"
fi
exit 0
