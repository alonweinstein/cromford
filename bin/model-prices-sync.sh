#!/bin/bash
# bin/model-prices-sync.sh — pull the model_prices table into this box's
# $HARNESS/state/model-prices.json (BH-1032, State→DB slice 7).
#
# THE PROBLEM THIS EXISTS FOR. state/model-prices.json was the live price table
# and it was HUB-ONLY: bin/update-model-prices.sh runs on the hub, and
# bin/harness-sync.sh deliberately neither inspects nor rsyncs state/. So every
# other box — and in particular every Fly pool machine, which runs the fleet's
# largest execute lane and whose rootfs is built from the repo — priced its rows
# from catalog/model-prices.json, the COMMITTED fallback that moves only when a
# human lands a PR. The same call could be priced two ways depending on which
# machine ran it, and nothing anywhere said so.
#
# The table is now the source (worker/jobs `model_prices`, pushed by the daily
# refresh) and THIS FILE IS ITS DERIVED CACHE. Every reader is unchanged: the
# chain in bin/lib/cost-row.sh already prefers state/model-prices.json over the
# catalog, so a box that has run this once prices from the hub's own rates.
#
# EMPTY IS NOT PASS. A body that does not parse, or that carries fewer than
# MODEL_PRICES_MIN models, is refused and the existing file is left alone —
# overwriting a good table with an empty one would price every row in the fleet
# at nothing, which on every cost view is indistinguishable from a free fleet.
# Same rule, same reason, as bin/update-model-prices.sh's own `>= 5` guard.
#
# FAIL OPEN. rc 0 whenever the box still has a usable table (refreshed or not);
# the only rc 1 is "there is no table here at all and I could not fetch one",
# which is the one case a caller should react to. One line a day on the failure
# path, never one per tick: the catalog fallback is right there and a stale rate
# is a rounding error, not an outage.
#
#   model-prices-sync.sh              refresh, quiet on the happy path
#   model-prices-sync.sh --print      also print "<models> <updated_at>"
#
# Knobs: HARNESS, MODEL_PRICES_MIN (default 5, read in bin/lib/jobs/cost.sh),
# MODEL_PRICES_SYNC=0 / flags/model-prices-sync-off (or the
# `switch.model-prices-sync-off` settings row) / flags/lane-off-model-prices-sync
# (or flags/all-off) to disarm — the last two are the registered lane switch,
# which bin/harness-ctl.sh off model-prices-sync writes.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
OUT="$H/state/model-prices.json"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
PRINT=0
[ "${1:-}" = --print ] && PRINT=1

mkdir -p "$H/state" "$H/logs" "$H/flags" 2>/dev/null

# global.env is sourced here because cron does not — HARNESS_SECRET and JOBS_URL
# live there. `+u` around it: an unbound reference inside the env file must not
# kill this silently.
set -a +u; . "$HENV/global.env" 2>/dev/null; set +a -u

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-model-prices-sync
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use,
# which is what makes MODEL_PRICES_SYNC settable from the control plane rather
# than only from this box's env file. Both fail OPEN: an unreachable worker
# leaves the lane exactly as it is today. It sits BELOW the env load above, or
# global.env would re-assign the knob the settings row just exported.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off model-prices-sync.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit model-prices-sync
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    model-prices-sync

say_ok() {
  [ "$PRINT" = 1 ] || return 0
  python3 -c '
import json, sys
try:
    b = json.load(open(sys.argv[1]))
except Exception:
    print("0 none"); raise SystemExit(0)
print(len(b.get("per_token") or {}), b.get("updated_at") or "none")' "$OUT" 2>/dev/null || echo "0 none"
}

# shellcheck source=bin/lib/lane-switch.sh
command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }
if [ "${MODEL_PRICES_SYNC:-1}" = 0 ] || lane_switch model-prices-sync-off file; then
  say_ok; exit 0
fi

if [ ! -f "$H/bin/jobs-client.sh" ]; then
  # A box mid-bootstrap. The catalog fallback still prices every row, and the
  # next tick will find the client, so this is not an event.
  say_ok; exit 0
fi
# shellcheck source=/dev/null
. "$H/bin/jobs-client.sh"

# model_prices_get reads the API in a subshell, so $JOBS_HTTP never reaches this
# shell; the client's status file is how the alert below names what the API
# answered (http=500, curl_rc=7, no-url) instead of a constant "none".
JOBS_STATUS_FILE=$(mktemp "${TMPDIR:-/tmp}/model-prices-sync.XXXXXX" 2>/dev/null) || JOBS_STATUS_FILE=""
export JOBS_STATUS_FILE
if command -v model_prices_get >/dev/null 2>&1 && model_prices_get "$OUT"; then
  rm -f "$JOBS_STATUS_FILE"
  say_ok
  exit 0
fi
ST=""
[ -n "$JOBS_STATUS_FILE" ] && ST=$(head -c 64 "$JOBS_STATUS_FILE" 2>/dev/null | tr -d '\n')
rm -f "$JOBS_STATUS_FILE"
ST="${ST:-http=${JOBS_HTTP:-none}}"

# ONE LINE A DAY on the failure path, not one per tick. If alert-line.sh itself
# fails, the flag goes again so the next tick retries the line (BH-5652): a
# flag that outlives a lost alert is a day of silence.
F="$H/flags/alerted-model-prices-sync-$(date -u +%Y%m%d)"
if [ ! -f "$F" ]; then
  touch "$F" 2>/dev/null
  if [ -s "$OUT" ]; then
    echo "$(STAMP) model-prices-sync: could not refresh from the model_prices table ($ST) — this box keeps pricing from its existing $OUT" >> "$H/logs/agent-rules.log"
    # BH-5652: the cache answering is a FALLBACK, and a box can price from a
    # stale cache for weeks while agent-rules.log alone says so. One ALERTS line
    # under the same daily flag. A `{}` or 500 body takes this path too:
    # model_prices_get refuses it, so the cache bytes stay as they were.
    UA=$(jq -r '.updated_at // "unknown"' "$OUT" 2>/dev/null) || UA=unknown
    HARNESS="$H" ALERT_LINE_STAMP="$(STAMP)" "$(dirname "$0")/alert-line.sh" --id model-prices-sync "model-prices-sync: the model_prices API did not answer with a usable table ($ST); this box prices from its cached $OUT (updated_at ${UA:-unknown}). Check the jobs worker." >/dev/null 2>&1 || rm -f "$F"
  else
    HARNESS="$H" ALERT_LINE_STAMP="$(STAMP)" "$(dirname "$0")/alert-line.sh" --id model-prices-sync "model-prices-sync: could not fetch the model_prices table ($ST) and this box has no $OUT — every row it writes will be priced from catalog/model-prices.json, which moves only when a human lands a PR. Check HARNESS_SECRET/JOBS_URL." >/dev/null 2>&1 || rm -f "$F"
  fi
fi
say_ok
[ -s "$OUT" ] && exit 0
exit 1
