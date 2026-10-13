#!/bin/bash
# bin/price-seed.sh — import the three committed price files into the jobs
# worker's price tables, once per file content (BH-5652).
#
# The price tables are DB rows: model_prices (BH-1032), price_fly and
# model_slugs (BH-5652), each with a version and a price_audit row per change.
# The committed files stay the documented fallback and the place a human edits
# a Fly price or a slug in a PR. This script is what moves such an edit into
# the tables:
#   catalog/model-prices.json -> POST /api/model-prices source=catalog
#                                (insert-only on the worker, BH-1890: a catalog
#                                row never replaces a live OpenRouter rate)
#   catalog/fly-prices.json   -> POST /api/fly-prices
#   catalog/model-slugs.json  -> POST /api/model-slugs
#
# ONCE PER CONTENT. The key is the sha256 of the three files' bytes, in that
# order. $HARNESS/state/prices/seeded holds the key of the last good seed; a
# match exits 0 with no request. The marker is written ONLY when all three
# POSTs return rc 0. Every POST is idempotent (the same value bumps no version),
# so a lost marker costs three requests, not a wrong row.
#
# FAILURE. No marker, one `price-seed-failed` warn lane-alert naming the POST
# that failed, rc 1. The next run retries. A good seed resolves the alert.
# JOBS_URL empty (coordination off on purpose, and every test sandbox) -> rc 0
# with no request and no marker: there is no table to seed.
#
# Files resolve per file: $HARNESS_CHECKOUT/catalog/<f>, then $HARNESS/catalog/<f>
# (the order bin/update-model-prices.sh uses). A missing file is a failure.
#
# Called at the END of bin/update-model-prices.sh (hub, 04:30Z), after the live
# OpenRouter rows have landed. Run by hand: bin/price-seed.sh
set -uo pipefail
H="${HARNESS:-/root/harness}"
CK="${HARNESS_CHECKOUT:-/root/harness-checkout}"
MARK="$H/state/prices/seeded"

NAMES=(model-prices.json fly-prices.json model-slugs.json)
FILES=()
for f in "${NAMES[@]}"; do
  p=""
  for c in "$CK/catalog/$f" "$H/catalog/$f"; do
    [ -r "$c" ] && { p="$c"; break; }
  done
  FILES+=("$p")
done

fail() {
  local msg="$1; no seed marker written, the next 04:30Z refresh retries"
  if [ -x "$H/bin/lane-alert.sh" ]; then
    "$H/bin/lane-alert.sh" --severity warn --id price-seed-failed model-prices "$msg" >/dev/null 2>&1 || true
  else
    HARNESS="$H" "$H/bin/alert-line.sh" "model-prices: price-seed-failed: $msg" 2>/dev/null || true
  fi
  echo "price-seed: $msg" >&2
  exit 1
}

for i in 0 1 2; do
  [ -n "${FILES[$i]}" ] || fail "catalog/${NAMES[$i]} not found in $CK/catalog or $H/catalog"
done
KEY=$(cat "${FILES[@]}" | sha256sum | cut -c1-64)
[ "$(cat "$MARK" 2>/dev/null)" = "$KEY" ] && exit 0

[ -f "$H/bin/jobs-client.sh" ] || fail "no $H/bin/jobs-client.sh"
# shellcheck source=/dev/null
. "$H/bin/jobs-client.sh" || fail "$H/bin/jobs-client.sh did not load"
jobs_configured || exit 0

model_prices_put "${FILES[0]}" catalog || fail "POST /api/model-prices (${FILES[0]}) failed"
price_fly_put    "${FILES[1]}" catalog || fail "POST /api/fly-prices (${FILES[1]}) failed"
model_slugs_put  "${FILES[2]}" catalog || fail "POST /api/model-slugs (${FILES[2]}) failed"

mkdir -p "$H/state/prices" || fail "cannot create $H/state/prices"
printf '%s\n' "$KEY" > "$MARK.tmp.$$" && mv -f "$MARK.tmp.$$" "$MARK" || { rm -f "$MARK.tmp.$$"; fail "cannot write $MARK"; }
[ -x "$H/bin/lane-alert.sh" ] && "$H/bin/lane-alert.sh" --resolve --id price-seed-failed \
  model-prices "the three price files are seeded (key ${KEY:0:12})" >/dev/null 2>&1
exit 0
