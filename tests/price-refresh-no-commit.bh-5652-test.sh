#!/bin/bash
# tests/price-refresh-no-commit.bh-5652-test.sh — the daily price refresh writes
# DB rows and creates no git commit, and the seeder imports the three committed
# price files once per file content (BH-5652).
#
# BH-628 already took the commit out of bin/update-model-prices.sh. BH-5652
# pins that absence, and adds bin/price-seed.sh at the end of the refresh: it
# POSTs catalog/model-prices.json (source=catalog, insert-only on the worker),
# catalog/fly-prices.json and catalog/model-slugs.json, then writes the sha256
# of the three files to state/prices/seeded so the next run posts nothing.
#
#   R1  the real refresh POSTs a /api/model-prices body with >= 5 rows
#   R2  the checkout's commit count is the same before and after
#   R3  the checkout's `git status --porcelain` is empty
#   R4  the seeder POSTed /api/fly-prices (5 keys) and /api/model-slugs (every
#       key of the file), and state/prices/seeded holds the sha256 key
#   R5  a second run posts 0 seed requests; with the fly POST failing there is
#       no marker, one price-seed-failed lane-alert, and the refresh exits 0
#   R6  the seeder with JOBS_URL empty (coordination off) posts nothing and
#       writes no marker
#
# The real bin/update-model-prices.sh, bin/price-seed.sh and jobs client run
# against a scratch $HARNESS; only `curl` (OpenRouter and the jobs worker) and
# lane-alert.sh are fixtures.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1 \
  || { echo "jq/python3/git missing — skipping"; exit 0; }

[ -x "$DIR/bin/price-seed.sh" ] && ok || bad "bin/price-seed.sh is missing or not executable"

H="$T/h"; CK="$T/checkout"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$T/fakebin" "$T/req" "$CK/catalog"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=http://jobs.fixture.invalid\n' > "$H/env/global.env"
printf 'lane_gate_or_exit() { :; }\nlane_env_apply() { :; }\n' > "$H/bin/lib/lane-gate.sh"
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$LANE_SINK"
SH
chmod +x "$H/bin/lane-alert.sh"
for s in bin/update-model-prices.sh bin/price-seed.sh bin/jobs-client.sh bin/alert-line.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "could not install the closure of $s"
done

# The checkout: a real git repo holding today's three committed price files.
for f in model-prices.json fly-prices.json model-slugs.json; do cp "$DIR/catalog/$f" "$CK/catalog/$f"; done
git -C "$CK" init -q && git -C "$CK" add -A \
  && git -C "$CK" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm seed \
  || bad "could not build the scratch checkout"

# OpenRouter: one priced entry per slug the real slug map names.
jq '{data: [ [.[]] | unique | .[] | {id: ., pricing: {prompt: "0.000002", completion: "0.00001", input_cache_read: "0.0000002"}} ]}' \
  "$DIR/catalog/model-slugs.json" > "$T/openrouter.json"

# The fixture transport. A jobs request is logged as "<n> <METHOD> <path>" in
# $T/req/log and its body is kept as $T/req/<n>.json.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
method=GET data="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data-binary|-d) data="$2"; shift 2 ;;
    -m|-w|-H|--connect-timeout) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */api/v1/models) cat "$OR_BODY"; exit 0 ;;
esac
path="/${url#*://*/}"
n=$(( $(wc -l < "$REQ_DIR/log" 2>/dev/null || echo 0) + 1 ))
echo "$n $method $path" >> "$REQ_DIR/log"
case "$data" in @*) cp "${data#@}" "$REQ_DIR/$n.json" ;; ?*) printf '%s' "$data" > "$REQ_DIR/$n.json" ;; esac
case "$method $path" in
  "GET /api/model-prices")  printf '{"updated_at":"2026-10-09T04:30:00Z","per_token":{}}\n200' ;;
  "POST /api/model-prices") printf '{"accepted":1}\n200' ;;
  "POST /api/fly-prices")   [ "${FLY_FAIL:-0}" = 1 ] && printf '{"error":"fixture"}\n500' || printf '{"accepted":5}\n200' ;;
  "POST /api/model-slugs")  printf '{"accepted":1}\n200' ;;
  *) printf '{}\n404' ;;
esac
SH
chmod +x "$T/fakebin/curl"

refresh() { # refresh [env...] — one run of the real refresh; prints its rc
  : > "$T/req/log"; rm -f "$T/req/"*.json
  ( export HARNESS="$H" HARNESS_CHECKOUT="$CK" PATH="$T/fakebin:$PATH" OR_BODY="$T/openrouter.json" \
           REQ_DIR="$T/req" LANE_SINK="$T/lane-alert.calls" ENDPOINT_OPENROUTER=http://openrouter.fixture.invalid \
           MODEL_PRICES_CATALOG_MAX_AGE_DAYS=0 JOBS_RETRIES=0 "$@"
    bash "$H/bin/update-model-prices.sh" ) >"$T/run.out" 2>&1
  echo $?
}
# reqs <METHOD> <path> [source] — the request numbers that match
reqs() {
  local n m p
  while read -r n m p; do
    [ "$m $p" = "$1 $2" ] || continue
    if [ -n "${3:-}" ]; then [ "$(jq -r '.source // empty' "$T/req/$n.json" 2>/dev/null)" = "$3" ] || continue; fi
    echo "$n"
  done < "$T/req/log"
}
KEY=$(cat "$CK/catalog/model-prices.json" "$CK/catalog/fly-prices.json" "$CK/catalog/model-slugs.json" | sha256sum | cut -c1-64)
COMMITS0=$(git -C "$CK" rev-list --count HEAD)

# ── R1 ───────────────────────────────────────────────────────────────────────
RC=$(refresh)
[ "$RC" = 0 ] && ok || bad "R1 the refresh exited $RC: $(tail -5 "$T/run.out")"
N=$(reqs POST /api/model-prices openrouter | head -1)
if [ -n "$N" ]; then
  ROWS=$(jq '.rows | length' "$T/req/$N.json")
  [ "$ROWS" -ge 5 ] && ok || bad "R1 the refresh's model_prices POST carried $ROWS rows, expected >= 5"
else
  bad "R1 the refresh POSTed no openrouter /api/model-prices body: $(cat "$T/req/log")"
fi

# ── R2 / R3 ──────────────────────────────────────────────────────────────────
[ "$(git -C "$CK" rev-list --count HEAD)" = "$COMMITS0" ] && ok \
  || bad "R2 the refresh created a commit: $COMMITS0 -> $(git -C "$CK" rev-list --count HEAD)"
PORC=$(git -C "$CK" status --porcelain)
[ -z "$PORC" ] && ok || bad "R3 the refresh left the checkout dirty: $PORC"

# ── R4 ───────────────────────────────────────────────────────────────────────
N=$(reqs POST /api/fly-prices catalog | head -1)
if [ -n "$N" ]; then
  FK=$(python3 - "$T/req/$N.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))["prices"]
keys = [k for k, v in p.items() if isinstance(v, (int, float)) and not isinstance(v, bool)]
keys += [f"{k}.{j}" for k, v in p.items() if isinstance(v, dict) for j, w in v.items() if isinstance(w, (int, float))]
print(len(keys))
PY
)
  [ "$FK" = 5 ] && ok || bad "R4 the fly-prices body carried $FK numeric keys, expected 5"
else
  bad "R4 the seeder POSTed no /api/fly-prices body (source=catalog): $(cat "$T/req/log")"
fi
N=$(reqs POST /api/model-slugs catalog | head -1)
if [ -n "$N" ]; then
  [ "$(jq -S .slugs "$T/req/$N.json")" = "$(jq -S . "$CK/catalog/model-slugs.json")" ] && ok \
    || bad "R4 the model-slugs body is not the whole slug map"
else
  bad "R4 the seeder POSTed no /api/model-slugs body (source=catalog): $(cat "$T/req/log")"
fi
N=$(reqs POST /api/model-prices catalog | head -1)
if [ -n "$N" ]; then
  [ "$(jq '.rows | length' "$T/req/$N.json")" = "$(jq '[.per_token[] | select(type == "object")] | length' "$CK/catalog/model-prices.json")" ] \
    && ok || bad "R4 the catalog model_prices body does not carry every catalog model"
else
  bad "R4 the seeder POSTed no source=catalog /api/model-prices body: $(cat "$T/req/log")"
fi
[ "$(cat "$H/state/prices/seeded" 2>/dev/null)" = "$KEY" ] && ok \
  || bad "R4 state/prices/seeded must hold the sha256 of the three files ($KEY): '$(cat "$H/state/prices/seeded" 2>/dev/null)'"
grep -q -- '--resolve --id price-seed-failed' "$T/lane-alert.calls" 2>/dev/null \
  && ok || bad "R4 a good seed must resolve price-seed-failed: $(cat "$T/lane-alert.calls" 2>/dev/null)"

# ── R5 ───────────────────────────────────────────────────────────────────────
RC=$(refresh)
[ "$RC" = 0 ] && ok || bad "R5 the second refresh exited $RC"
SEEDS=$(( $(reqs POST /api/fly-prices | wc -l) + $(reqs POST /api/model-slugs | wc -l) + $(reqs POST /api/model-prices catalog | wc -l) ))
[ "$SEEDS" = 0 ] && ok || bad "R5 the marker matched, so the seeder must post 0 requests, posted $SEEDS: $(cat "$T/req/log")"
[ -n "$(reqs POST /api/model-prices openrouter)" ] && ok || bad "R5 the refresh itself must still post its rows"

rm -f "$H/state/prices/seeded"; : > "$T/lane-alert.calls"
RC=$(refresh FLY_FAIL=1)
[ "$RC" = 0 ] && ok || bad "R5 a failed seed must not fail the refresh (rc $RC)"
[ -n "$(reqs POST /api/fly-prices catalog)" ] && ok || bad "R5 the failing run never tried the fly POST"
[ ! -e "$H/state/prices/seeded" ] && ok || bad "R5 a failed seed must write no marker"
[ "$(grep -c -- '--severity warn --id price-seed-failed' "$T/lane-alert.calls" 2>/dev/null)" = 1 ] && ok \
  || bad "R5 a failed seed must raise ONE price-seed-failed lane-alert: $(cat "$T/lane-alert.calls" 2>/dev/null)"
grep -- '--id price-seed-failed' "$T/lane-alert.calls" 2>/dev/null | grep -q 'fly-prices' \
  && ok || bad "R5 the alert must name the POST that failed: $(cat "$T/lane-alert.calls" 2>/dev/null)"
# The next good run seeds and resolves.
: > "$T/lane-alert.calls"
RC=$(refresh)
[ "$RC" = 0 ] && [ "$(cat "$H/state/prices/seeded" 2>/dev/null)" = "$KEY" ] && ok \
  || bad "R5 the retry must seed and write the marker (rc $RC)"

# ── R6: coordination off ─────────────────────────────────────────────────────
rm -f "$H/state/prices/seeded"; : > "$T/req/log"
( export HARNESS="$H" HARNESS_CHECKOUT="$CK" PATH="$T/fakebin:$PATH" REQ_DIR="$T/req" \
         LANE_SINK="$T/lane-alert.calls" JOBS_URL=""
  sed -i 's/^JOBS_URL=.*/JOBS_URL=/' "$H/env/global.env"
  bash "$H/bin/price-seed.sh" ) >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "R6 the seeder with coordination off must exit 0 (rc $RC)"
[ ! -s "$T/req/log" ] && ok || bad "R6 the seeder with coordination off posted: $(cat "$T/req/log")"
[ ! -e "$H/state/prices/seeded" ] && ok || bad "R6 nothing was seeded, so no marker"

echo "price-refresh-no-commit.bh-5652-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
