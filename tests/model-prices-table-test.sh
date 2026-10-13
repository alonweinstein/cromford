#!/bin/bash
# tests/model-prices-table-test.sh — the price table is a TABLE, and the file on
# each box is its derived cache (BH-1032, State→DB slice 7).
#
# WHY THIS LANE EXISTS. state/model-prices.json was the live table and it was
# hub-only — harness-sync neither inspects nor rsyncs state/ — so every Fly pool
# machine, which runs the fleet's largest execute lane, priced its rows from
# catalog/model-prices.json, the committed fallback that moves only when a human
# lands a PR. One call, two prices, decided by which machine ran it.
#
# DRIVEN, NOT GREPPED:
#   1. model_prices_put turns a catalog-shaped file into rows the POST route
#      accepts — every model key, the slug, and cliff_tokens where it exists.
#   2. model_prices_get writes the body straight to disk in the shape the
#      READERS already prefer, and the real cost_price_tokens then prices from
#      it — including the 2x cliff — so "the pool prices like the hub" is
#      proved by a dollar figure, not by a path.
#   3. EMPTY IS NOT PASS: a thin or unparseable body is REFUSED and the existing
#      file is left byte-identical. Overwriting a good table with an empty one
#      prices every row in the fleet at nothing, which reads as a free fleet.
#   4. bin/model-prices-sync.sh fails open — a box that cannot fetch keeps its
#      table, says so once, and exits 0.
#   5. bin/update-model-prices.sh mirrors to the table AFTER it writes the file,
#      and a failed push is not allowed to fail the refresh.
# Run from anywhere: tests/model-prices-table-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/bin" "$T/h/env"
export HARNESS="$T/h"
echo "HARNESS_SECRET=test-secret" > "$T/h/env/global.env"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/jobs-client.sh"
# The client is a SHIM over bin/lib/jobs/ since BH-1194 and refuses to half-load,
# so a fixture that copies it copies the modules beside it too.
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/bin/model-prices-sync.sh" "$T/h/bin/model-prices-sync.sh"
mkdir -p "$T/h/bin/lib" && cp "$DIR/bin/lib/env-path.sh" "$T/h/bin/lib/env-path.sh" 2>/dev/null

# A catalog-shaped table, with one model carrying a cliff and one without.
cat > "$T/prices.json" <<'JSON'
{
  "updated_at": "2026-09-20T04:30:00Z",
  "source": "openrouter/api/v1/models",
  "per_token": {
    "claude-opus-5":   {"prompt": 0.000015, "completion": 0.000075, "cache_read": 0.0000015, "cache_write": 0.00001875, "slug": "anthropic/claude-opus-5"},
    "claude-sonnet-5": {"prompt": 0.000003, "completion": 0.000015, "cache_read": 0.0000003, "cache_write": 0.00000375, "slug": "anthropic/claude-sonnet-5"},
    "grok-4.6":        {"prompt": 0.000002, "completion": 0.00001,  "cache_read": 0.0000005, "cache_write": null, "slug": "x-ai/grok-4.6", "cliff_tokens": 200000},
    "gpt-6-astra":     {"prompt": 0.00000125, "completion": 0.00001, "cache_read": 0.000000125, "cache_write": 0, "slug": "openai/gpt-6-astra"},
    "claude-haiku-4-5":{"prompt": 0.000001, "completion": 0.000005, "cache_read": 0.0000001, "cache_write": 0.00000125, "slug": "anthropic/claude-haiku-4.5"}
  }
}
JSON

# shellcheck source=/dev/null
( set +u; . "$T/h/bin/jobs-client.sh" >/dev/null 2>&1 ) || true
# shellcheck source=/dev/null
set +u; . "$T/h/bin/jobs-client.sh" >/dev/null 2>&1; set -u
command -v model_prices_put >/dev/null 2>&1 \
  && ok || bad "bin/jobs-client.sh does not define model_prices_put"
command -v model_prices_get >/dev/null 2>&1 \
  && ok || bad "bin/jobs-client.sh does not define model_prices_get"

# ===========================================================================
# 1. PUT — every model becomes a row the POST route would accept
# ===========================================================================
BODY_SINK="$T/put-body.json"
_jobs_req_file() { cp "$3" "$BODY_SINK"; printf '{"accepted":5}\n'; return 0; }
model_prices_put "$T/prices.json" openrouter && ok || bad "model_prices_put failed on a good table"
[ -s "$BODY_SINK" ] && ok || bad "model_prices_put sent no body"
pget() { python3 -c '
import json, sys
b = json.load(open(sys.argv[1]))
rows = {r["model"]: r for r in b["rows"]}
print(rows[sys.argv[2]].get(sys.argv[3]) if sys.argv[2] in rows else "MISSING")' "$BODY_SINK" "$2" "$3"; }
[ "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["rows"]))' "$BODY_SINK")" = 5 ] \
  && ok || bad "model_prices_put dropped model keys"
[ "$(pget x claude-opus-5 slug)" = anthropic/claude-opus-5 ] \
  && ok || bad "the slug did not survive: $(pget x claude-opus-5 slug)"
[ "$(pget x grok-4.6 cliff_tokens)" = 200000 ] \
  && ok || bad "cliff_tokens must reach the table or the 2x cliff silently stops: $(pget x grok-4.6 cliff_tokens)"
[ "$(pget x claude-opus-5 cliff_tokens)" = None ] \
  && ok || bad "a model with no cliff must carry none, got $(pget x claude-opus-5 cliff_tokens)"
[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["source"])' "$BODY_SINK")" = openrouter ] \
  && ok || bad "the source label did not travel"
# An empty table is refused before it is sent — the same rule as the file side.
# `{"per_token":{}}` is the trap: an empty dict is FALSY, so a `or t` fallback
# pushes a row literally called "per_token" and the guard never fires.
echo '{"per_token":{}}' > "$T/empty.json"
model_prices_put "$T/empty.json" openrouter && bad "an empty table must not be pushed" || ok
# A FLAT table (several fixtures and older copies use that shape) still pushes
# its models, and the envelope keys beside them are not models.
cat > "$T/flat.json" <<'FLAT'
{"updated_at":"2026-09-20T04:30:00Z","source":"x",
 "a-model":{"prompt":0.000001,"completion":0.000002,"cache_read":0,"cache_write":0}}
FLAT
model_prices_put "$T/flat.json" manual && ok || bad "a flat-shaped table must still push"
FLATM=$(python3 -c 'import json,sys;print(",".join(sorted(r["model"] for r in json.load(open(sys.argv[1]))["rows"])))' "$BODY_SINK")
[ "$FLATM" = a-model ] \
  && ok || bad "a flat table pushed its envelope keys as models: $FLATM"

# ===========================================================================
# 2. GET — the file it writes IS the file the readers price from
# ===========================================================================
# The fake route answers exactly what worker/jobs/src/index.js builds: the
# catalog shape, cliff_tokens present only where the row has one.
cat > "$T/fakeget.py" <<'PYEOF'
import json, os, sys
t = json.load(open(sys.argv[1]))
per = {}
for m, r in t["per_token"].items():
    e = {"prompt": r["prompt"], "completion": r["completion"],
         "cache_read": r["cache_read"], "cache_write": r["cache_write"], "slug": r["slug"]}
    if r.get("cliff_tokens") is not None:
        e["cliff_tokens"] = r["cliff_tokens"]
    per[m] = e
if os.environ.get("THIN") == "1":
    per = {k: per[k] for k in list(per)[:2]}
print(json.dumps({"updated_at": "2026-09-20T04:30:00Z", "source": "openrouter",
                  "models": len(per), "per_token": per}))
PYEOF
_jobs_req() { [ "${GET_DOWN:-0}" = 1 ] && return 1; python3 "$T/fakeget.py" "$T/prices.json"; }

model_prices_get "$T/h/state/model-prices.json" && ok || bad "model_prices_get failed on a good body"
[ -s "$T/h/state/model-prices.json" ] && ok || bad "model_prices_get wrote nothing"

# THE PROOF IS A DOLLAR FIGURE. The real cost_price_tokens, pointed at the file
# the table produced, must price a row — and apply the cliff.
# shellcheck source=/dev/null
. "$DIR/bin/lib/cost-row.sh"
P=$(MODEL_PRICES="$T/h/state/model-prices.json" cost_price_tokens claude-opus-5 1000000 0 0 0)
[ "$P" = 15.000000 ] \
  && ok || bad "a row priced from the table-derived file came out '$P', expected 15.000000"
# 250k input past grok's 200k cliff: 0.5 flat, doubled.
P=$(MODEL_PRICES="$T/h/state/model-prices.json" cost_price_tokens grok-4.6 250000 0 0 0)
[ "$P" = 1.000000 ] \
  && ok || bad "the cliff did not survive the table round-trip: '$P', expected 1.000000 (0.50 doubled)"
C=$(MODEL_PRICES="$T/h/state/model-prices.json" cost_model_cliff grok-4.6)
[ "$C" = 200000 ] && ok || bad "cost_model_cliff read '$C' from the table-derived file"
MODEL_PRICES="$T/h/state/model-prices.json" cost_model_cliff claude-opus-5 >/dev/null 2>&1 \
  && bad "a model with no cliff must answer nothing" || ok

# ===========================================================================
# 3. EMPTY IS NOT PASS
# ===========================================================================
cp "$T/h/state/model-prices.json" "$T/good.json"
( THIN=1 model_prices_get "$T/h/state/model-prices.json" ) \
  && bad "a 2-model body must be refused (MODEL_PRICES_MIN=5)" || ok
cmp -s "$T/h/state/model-prices.json" "$T/good.json" \
  && ok || bad "a refused fetch overwrote the good table"
_jobs_req() { printf 'not json at all\n'; }
model_prices_get "$T/h/state/model-prices.json" \
  && bad "an unparseable body must be refused" || ok
cmp -s "$T/h/state/model-prices.json" "$T/good.json" \
  && ok || bad "an unparseable body clobbered the good table"
[ -z "$(ls "$T/h/state"/model-prices.json.tmp.* 2>/dev/null)" ] \
  && ok || bad "a refused fetch left a temp file behind"

# ===========================================================================
# 4. bin/model-prices-sync.sh fails open
# ===========================================================================
# Drive the real script with a stubbed curl so nothing talks to a network.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
[ "${CURL_DOWN:-0}" = 1 ] && exit 7
printf 'not json\n200\n'
CURL
chmod +x "$T/fakebin/curl"
OLDPATH="$PATH"; export PATH="$T/fakebin:$PATH"
cp "$T/good.json" "$T/h/state/model-prices.json"
( CURL_DOWN=1 HARNESS="$T/h" bash "$T/h/bin/model-prices-sync.sh" ) ; RC=$?
export PATH="$OLDPATH"
[ "$RC" = 0 ] && ok || bad "a box that still has a table must exit 0 (rc $RC)"
cmp -s "$T/h/state/model-prices.json" "$T/good.json" \
  && ok || bad "a failed sync clobbered the box's table"
grep -q 'model-prices-sync' "$T/h/logs/agent-rules.log" 2>/dev/null \
  && ok || bad "a failed sync must say so once in logs/agent-rules.log"
# Kill switch.
: > "$T/h/logs/agent-rules.log"; touch "$T/h/flags/model-prices-sync-off"
( HARNESS="$T/h" bash "$T/h/bin/model-prices-sync.sh" ) && ok || bad "the kill switch must exit 0"
[ ! -s "$T/h/logs/agent-rules.log" ] && ok || bad "the kill switch should be silent"
rm -f "$T/h/flags/model-prices-sync-off"

# ===========================================================================
# 5. The refresh mirrors AFTER the file, and a failed push does not fail it
# ===========================================================================
SRC="$DIR/bin/update-model-prices.sh"
python3 - "$SRC" <<'PYEOF' && ok || bad "bin/update-model-prices.sh pushes the table BEFORE it writes the file — the file is the contract"
import sys
s = open(sys.argv[1]).read()
w = s.index('mv "$OUT.tmp" "$OUT"')
p = s.index("model_prices_put")
raise SystemExit(0 if w < p else 1)
PYEOF
grep -q 'model_prices_put "$OUT" openrouter >/dev/null 2>&1 \\' "$SRC" \
  && ok || bad "the push is not silent-on-failure in bin/update-model-prices.sh"
grep -q 'command -v model_prices_put' "$SRC" \
  && ok || bad "bin/update-model-prices.sh must not call model_prices_put on a jobs-client that predates it"
# The refresh must still be the one that writes the file: no `exit` between the
# write and the catalog-behind notice that a failed push could reach.
python3 - "$SRC" <<'PYEOF' && ok || bad "a failed table push can abort bin/update-model-prices.sh"
import re, sys
s = open(sys.argv[1]).read()
seg = s[s.index('mv "$OUT.tmp" "$OUT"'):s.index("the catalog-behind notice")]
raise SystemExit(1 if re.search(r"^\s*exit\s+1", seg, re.M) else 0)
PYEOF

# ===========================================================================
# 6. ENROLMENT — a lane nobody calls is a lane that does not exist
# ===========================================================================
# Same set-equality shape bin/cost-rows-push.sh's enrolment test uses: every box
# cron that mirrors cost rows also refreshes its price table, and the two crons
# that must NOT carry the line DECLARE the absence rather than leave it silent.
# BH-1247: cron/<box>.cron is GENERATED and not committed, so a glob over
# "$DIR"/cron is EMPTY in a fresh checkout — the loop would run zero times and
# this whole section would pass having read no crontab at all (it instead
# reported every box un-enrolled: "cron enrolment is half-applied:
# *(no-push-and-no-declaration)"). The box list comes from the COMMITTED
# cron/boxes/<box>.d, and each crontab is rendered into $T.
MISSING=""
for B in $(rendered_boxes); do
  C=$(rendered_cron "$B")
  N=$(grep -c 'bin/model-prices-sync.sh' "$C")
  case "$B" in
    hub)
      # The hub WRITES the table at 04:30; a pull here reads back its own output.
      grep -q '^# NO model-prices-sync line, deliberately' "$C" \
        || MISSING="$MISSING $B(hub-must-declare-the-absence)"
      grep -q '^[0-9].*bin/model-prices-sync.sh' "$C" \
        && MISSING="$MISSING $B(hub-must-not-pull)" ;;
    *)
      if grep -q 'bin/cost-rows-push.sh' "$C"; then
        [ "$N" = 1 ] || MISSING="$MISSING $B($N lines)"
      else
        grep -q '^# NO model-prices-sync line, deliberately' "$C" \
          || MISSING="$MISSING $B(no-push-and-no-declaration)"
      fi ;;
  esac
done
[ -z "$MISSING" ] \
  && ok || bad "cron enrolment is half-applied:$MISSING"
# The pool machine is the whole reason this lane exists: its rootfs is the repo,
# so without a pull it prices from the committed catalog forever.
grep -q 'model_prices_pull' "$DIR/fly/builder-runner.sh" \
  && ok || bad "fly/builder-runner.sh does not pull the price table — the pool keeps pricing from the committed catalog"
grep -q 'model-prices-sync.sh' "$DIR/fly/builder-runner.sh" \
  && ok || bad "fly/builder-runner.sh does not call bin/model-prices-sync.sh"
# It must not be able to fail a build.
sed -n '/^model_prices_pull() {/,/^}/p' "$DIR/fly/builder-runner.sh" | grep -q '|| true' \
  && ok || bad "the pool's price pull can fail a build"
sed -n '/^model_prices_pull() {/,/^}/p' "$DIR/fly/builder-runner.sh" | grep -q 'timeout ' \
  && ok || bad "the pool's price pull has no timeout — a hung worker would block every build"

echo "model-prices-table: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
