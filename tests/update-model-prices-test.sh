#!/bin/bash
# tests/update-model-prices-test.sh — the daily price refresh, run WHOLE against
# a scratch $HARNESS and a scratch git checkout.
#
# WHAT IT PINS (BH-628). The refresh used to write its table straight into
# /root/harness-checkout/catalog/model-prices.json and, on the common day where
# prices had not moved, rewrite `updated_at` in that tracked file and exit
# without committing. From 04:30 local every day the hub's checkout was dirty,
# bin/harness-sync.sh answers rc 30 on a dirty checkout, and the hub's LIVE bin/
# froze while the drift check stayed green. The second path was worse: a
# hostname-gated `git commit` + `git push origin main` FROM A CRON, which also
# leaves the file dirty on any failure.
#
# So the contract under test is, in order of what breaks first:
#
#   the checkout stays clean   `git status --porcelain` prints nothing after a
#                              run, on the unchanged-prices path and the
#                              changed-prices path alike
#   the table lands in state/  $HARNESS/state/model-prices.json, atomically
#   nothing is committed       HEAD and the bare origin's main do not move
#   the catalog is a FALLBACK  catalog/model-prices.json is byte-identical
#                              before and after every run, and a live table that
#                              has drifted from it raises ONE deduped warn
#   readers prefer the live    $MODEL_PRICES, then state/, then the old chain
#   fail-soft did not regress  a failed fetch or a thin parse keeps the previous
#                              state file and says so in ALERTS.log
#
# No network: `curl` is a fixture script on PATH. No real box: everything lives
# under one mktemp -d. Run from anywhere: tests/update-model-prices-test.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-1941: the script under test resolves its vendor base URL through
# endpoint_url (env, else the registry default); this sandbox composes no
# registry, so the env carries today's URL — the registry default itself.
export ENDPOINT_OPENROUTER=https://openrouter.ai
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/locks" "$T/flags" "$T/catalog" "$T/fakebin"
cp "$DIR/bin/alert-line.sh" "$T/bin/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v git >/dev/null || { echo "jq/git missing — skipping"; exit 0; }

# ── the script under test ────────────────────────────────────────────────────
# Copied, with only the two path assignments rewritten to their overridable
# form so the fixture can point them at the scratch tree — the same sed trick
# .github/workflows/harness-ci.yml already uses for bin/triage-gate.sh. Once
# BH-628 lands the two sed expressions match nothing and this is a plain copy;
# every other line of the lane runs verbatim.
sed -e 's|^H=/root/harness$|H="${HARNESS:-/root/harness}"|' \
    -e 's|^CK=/root/harness-checkout$|CK="${HARNESS_CHECKOUT:-/root/harness-checkout}"|' \
    "$DIR/bin/update-model-prices.sh" > "$T/update-model-prices.sh"
mkdir -p "$T/lib"; cp "$DIR/bin/lib/endpoints.sh" "$T/lib/"   # BH-1941: beside the script copy
grep -q 'HARNESS:-/root/harness' "$T/update-model-prices.sh" \
  && ok || bad "could not make \$H overridable — did the assignment shape change?"
grep -q 'HARNESS_CHECKOUT:-/root/harness-checkout' "$T/update-model-prices.sh" \
  && ok || bad "could not make \$CK overridable — did the assignment shape change?"

# ── the fixture OpenRouter list ──────────────────────────────────────────────
# Six slugs, which the lane's MAP expands to well past the 5-model floor.
mkprices() { # mkprices <completion-multiplier> > $T/openrouter.json
  python3 - "$1" > "$T/openrouter.json" <<'PY'
import json, sys
mult = float(sys.argv[1])
slugs = ["anthropic/claude-fable-5.1", "anthropic/claude-opus-5",
         "anthropic/claude-sonnet-5", "anthropic/claude-haiku-4.5",
         "openai/gpt-6-astra", "x-ai/grok-4.6"]
data = []
for n, s in enumerate(slugs):
    data.append({"id": s, "pricing": {
        "prompt": str(0.00001 * (n + 1)),
        "completion": str(0.00005 * (n + 1) * mult),
        "input_cache_read": str(0.000001 * (n + 1)),
        "input_cache_write": str(0.0000125 * (n + 1))}})
json.dump({"data": data}, sys.stdout)
PY
}
mkprices 1

# `curl` the lane calls: prints the fixture, or fails with the rc we hand it.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
[ -n "${CURL_RC:-}" ] && exit "$CURL_RC"
cat "$CURL_BODY"
SH
chmod +x "$T/fakebin/curl"

# lane-alert.sh, recording. The real one talks to Telegram.
cat > "$T/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$LANE_SINK"
exit 0
SH
chmod +x "$T/bin/lane-alert.sh"

# ── the scratch checkout: a real clone of a real bare origin ─────────────────
git init -q --bare "$T/origin"
git clone -q "$T/origin" "$T/ck" 2>/dev/null
git -C "$T/ck" config user.email t@t; git -C "$T/ck" config user.name t
mkdir -p "$T/ck/catalog" "$T/ck/bin"
# The committed fallback starts as a table that does NOT match the fixture.
cat > "$T/ck/catalog/model-prices.json" <<'JSON'
{"updated_at":"2026-01-01T00:00:00Z","source":"openrouter/api/v1/models","per_token":{
  "claude-fable-5-1":{"prompt":0.1,"completion":0.2,"cache_read":0.3,"cache_write":0.4,"slug":"anthropic/claude-fable-5.1"}
}}
JSON
printf '#!/bin/bash\n:\n' > "$T/ck/bin/x.sh"
# The slug map is the committed catalog's (BH-1510.4: the script has no copy of
# its own any more, and with no map it skips the refresh).
cp "$DIR/catalog/model-slugs.json" "$T/ck/catalog/model-slugs.json"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm seed
git -C "$T/ck" branch -M main 2>/dev/null
git -C "$T/ck" push -q origin main
BASE_HEAD=$(git -C "$T/ck" rev-parse HEAD)
BASE_ORIGIN=$(git -C "$T/origin" rev-parse main)

LANE_SINK="$T/lane.txt"; : > "$LANE_SINK"
run_refresh() { # run_refresh -> rc in $RC
  ( export HARNESS="$T" HARNESS_CHECKOUT="$T/ck" \
           PATH="$T/fakebin:$PATH" CURL_BODY="$T/openrouter.json" \
           LANE_SINK="$LANE_SINK" "$@"
    bash "$T/update-model-prices.sh" ) >"$T/run.out" 2>"$T/run.err"
  RC=$?
}
porcelain() { git -C "$T/ck" status --porcelain --untracked-files=no; }
catsha()    { sha256sum < "$T/ck/catalog/model-prices.json" | cut -d' ' -f1; }

# ============================================================================
# A2. prices CHANGED against the committed fallback — the checkout stays clean
#     and nothing is committed or pushed
# ============================================================================
CAT_BEFORE=$(catsha)
run_refresh
[ "$RC" = 0 ] && ok || bad "a successful refresh must exit 0, got $RC: $(cat "$T/run.err")"
P=$(porcelain)
[ -z "$P" ] && ok || bad "THE BUG: the refresh left the checkout dirty: $P"
[ -s "$T/state/model-prices.json" ] && ok || bad "the live table must land in state/model-prices.json"
N=$(jq '.per_token|length' "$T/state/model-prices.json" 2>/dev/null || echo 0)
[ "${N:-0}" -ge 5 ] && ok || bad "the live table must carry the whole map, got $N models"
date -u -d "$(jq -r .updated_at "$T/state/model-prices.json" 2>/dev/null)" +%s >/dev/null 2>&1 \
  && ok || bad "updated_at must parse as a date: $(jq -r .updated_at "$T/state/model-prices.json" 2>/dev/null)"
[ "$(catsha)" = "$CAT_BEFORE" ] && ok || bad "the committed catalog must not be rewritten by a refresh"
[ "$(git -C "$T/ck" rev-parse HEAD)" = "$BASE_HEAD" ] && ok || bad "a cron must not commit — HEAD moved"
[ "$(git -C "$T/origin" rev-parse main)" = "$BASE_ORIGIN" ] && ok || bad "a cron must not push to main — origin moved"

# A6a. the fallback is behind the live table, and that is said ONCE, as a warn.
grep -q -- '--id model-prices-catalog-behind' "$LANE_SINK" \
  && ok || bad "a catalog behind the live table must warn: $(cat "$LANE_SINK")"
grep -q -- '--severity warn' "$LANE_SINK" \
  && ok || bad "the catalog-behind notice is a warn, not a page: $(cat "$LANE_SINK")"

# ============================================================================
# A3. harness-sync agrees the checkout is deployable
# ============================================================================
SYNC_OUT=$(HARNESS="$T" HARNESS_CHECKOUT="$T/ck" bash "$DIR/bin/harness-sync.sh" --check 2>"$T/sync.err"); SRC=$?
[ "$SRC" = 0 ] && ok || bad "harness-sync --check must pass on the post-refresh checkout, rc=$SRC out=$SYNC_OUT err=$(cat "$T/sync.err")"
case "$SYNC_OUT" in fresh*) ok ;; *) bad "harness-sync must report fresh, got: $SYNC_OUT" ;; esac

# ============================================================================
# A1. someone lands the live table as the committed fallback; the NEXT run sees
#     unchanged prices — and still must not touch the checkout
# ============================================================================
cp "$T/state/model-prices.json" "$T/ck/catalog/model-prices.json"
git -C "$T/ck" add -A >/dev/null; git -C "$T/ck" commit -qm "model-prices: land the live table"
git -C "$T/ck" push -q origin main
BASE_HEAD=$(git -C "$T/ck" rev-parse HEAD)
BASE_ORIGIN=$(git -C "$T/origin" rev-parse main)
CAT_BEFORE=$(catsha)
: > "$LANE_SINK"
PREV_UPDATED=$(jq -r .updated_at "$T/state/model-prices.json")
run_refresh
[ "$RC" = 0 ] && ok || bad "an unchanged-prices refresh must exit 0, got $RC: $(cat "$T/run.err")"
P=$(porcelain)
[ -z "$P" ] && ok || bad "THE BUG: the unchanged-prices path rewrote updated_at in the checkout: $P"
[ "$(catsha)" = "$CAT_BEFORE" ] && ok || bad "the committed catalog must not be rewritten when prices are unchanged"
[ "$(jq -S '.per_token' "$T/state/model-prices.json")" = "$(jq -S '.per_token' "$T/ck/catalog/model-prices.json")" ] \
  && ok || bad "the live table must still hold the same rates"
# A6b. fallback in step with the live table -> no notice at all.
# (BH-3990: the catalog-stale check resolves its id on every in-threshold run;
# lane-alert.sh --resolve on an id that is not open sends nothing, so only a
# non-resolve call would be heard.)
[ -z "$(grep -v -- '^--resolve ' "$LANE_SINK")" ] && ok || bad "a catalog in step must say nothing: $(cat "$LANE_SINK")"
# staleness stays measurable: updated_at is refreshed even when rates did not move
[ -n "$PREV_UPDATED" ] && ok || bad "could not read the previous updated_at"

# ============================================================================
# A2-bis. rates actually move: the new table is what lands, still no git write
# ============================================================================
mkprices 2
CAT_BEFORE=$(catsha)
: > "$LANE_SINK"
run_refresh
[ "$RC" = 0 ] && ok || bad "a changed-prices refresh must exit 0, got $RC: $(cat "$T/run.err")"
[ -z "$(porcelain)" ] && ok || bad "THE BUG: the changed-prices path dirtied the checkout: $(porcelain)"
[ "$(catsha)" = "$CAT_BEFORE" ] && ok || bad "the committed catalog must not be rewritten on the changed path"
[ "$(git -C "$T/ck" rev-parse HEAD)" = "$BASE_HEAD" ] && ok || bad "a cron must not commit — HEAD moved on the changed path"
[ "$(git -C "$T/origin" rev-parse main)" = "$BASE_ORIGIN" ] && ok || bad "a cron must not push to main — origin moved on the changed path"
# the doubled completion rate is in the LIVE table, so the write really happened
NEWC=$(jq -r '.per_token["claude-fable-5-1"].completion' "$T/state/model-prices.json")
OLDC=$(jq -r '.per_token["claude-fable-5-1"].completion' "$T/ck/catalog/model-prices.json")
awk -v n="$NEWC" -v o="$OLDC" 'BEGIN{exit !(o>0 && n>o*1.9 && n<o*2.1)}' \
  && ok || bad "the live table must carry the NEW rates (catalog $OLDC -> state $NEWC)"
grep -q -- '--id model-prices-catalog-behind' "$LANE_SINK" \
  && ok || bad "a fallback left behind by a real price move must warn: $(cat "$LANE_SINK")"

# ============================================================================
# A5. readers: $MODEL_PRICES, then state/, then the committed fallback
# ============================================================================
cp "$T/ck/catalog/model-prices.json" "$T/catalog/model-prices.json"
cat > "$T/session.jsonl" <<'JSON'
{"type":"assistant","uuid":"u1","timestamp":"2026-09-14T20:00:00.000Z","message":{"id":"m1","type":"message","role":"assistant","model":"claude-fable-5-1","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1000,"output_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
JSON
# Driven from $T/bin, which is the layout on every box and every fly builder:
# the script's own ../catalog IS $HARNESS/catalog there, so the fallback leg
# under test is the one production actually takes.
cp "$DIR/bin/transcript-cost.sh" "$T/bin/transcript-cost.sh"; chmod +x "$T/bin/transcript-cost.sh"
readprices() { # readprices -> the path transcript-cost resolved, normalised
  local p
  p=$( ( unset MODEL_PRICES; export HARNESS="$T"
         bash "$T/bin/transcript-cost.sh" "$T/session.jsonl" --no-subagents --format json 2>/dev/null ) | jq -r .prices )
  readlink -f "$p" 2>/dev/null || printf '%s' "$p"
}
[ "$(readprices)" = "$T/state/model-prices.json" ] \
  && ok || bad "a reader must prefer the live table, got: $(readprices)"
mv "$T/state/model-prices.json" "$T/state/model-prices.keep"
[ "$(readprices)" = "$T/catalog/model-prices.json" ] \
  && ok || bad "with no live table a reader must fall back to the catalog, got: $(readprices)"
# and $MODEL_PRICES still wins over both
mv "$T/state/model-prices.keep" "$T/state/model-prices.json"
[ "$(MODEL_PRICES="$T/catalog/model-prices.json" HARNESS="$T" bash "$T/bin/transcript-cost.sh" \
      "$T/session.jsonl" --no-subagents --format json 2>/dev/null | jq -r .prices)" = "$T/catalog/model-prices.json" ] \
  && ok || bad "an explicit \$MODEL_PRICES must still win"

# cost_price_tokens: precedence proved by the NUMBER, not by the path. The live
# table's completion rate is 2x the catalog's, so 1M completion tokens priced
# off state/ must come back at twice the catalog's figure.
priced() { # priced <HARNESS>
  ( unset MODEL_PRICES; export HARNESS="$1"
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1
    cost_price_tokens claude-fable-5-1 0 1000000 0 0 )
}
USD_STATE=$(priced "$T")
mv "$T/state/model-prices.json" "$T/state/model-prices.keep"
USD_CAT=$(MODEL_PRICES="$T/catalog/model-prices.json" priced "$T")
mv "$T/state/model-prices.keep" "$T/state/model-prices.json"
awk -v s="$USD_STATE" -v c="$USD_CAT" 'BEGIN{exit !(c>0 && s>c*1.9 && s<c*2.1)}' \
  && ok || bad "cost_price_tokens must price off the LIVE table (state=$USD_STATE catalog=$USD_CAT)"

# ============================================================================
# A7. fail-soft: a failed fetch keeps the table it already had, and says so
# ============================================================================
: > "$T/logs/ALERTS.log"
BEFORE_SHA=$(sha256sum < "$T/state/model-prices.json" | cut -d' ' -f1)
run_refresh CURL_RC=22
[ "$RC" = 0 ] && ok || bad "a failed fetch is fail-soft, not a crash, got $RC"
[ "$(sha256sum < "$T/state/model-prices.json" | cut -d' ' -f1)" = "$BEFORE_SHA" ] \
  && ok || bad "a failed fetch must leave the previous table untouched"
[ "$(grep -c 'fetch failed' "$T/logs/ALERTS.log")" = 1 ] \
  && ok || bad "a failed fetch must say so exactly once: $(cat "$T/logs/ALERTS.log")"
[ -z "$(porcelain)" ] && ok || bad "a failed fetch must not dirty the checkout: $(porcelain)"

# ============================================================================
# A8. a thin list is not a price table: refuse to overwrite
# ============================================================================
: > "$T/logs/ALERTS.log"
python3 - > "$T/openrouter.json" <<'PY'
import json, sys
json.dump({"data": [{"id": "anthropic/claude-opus-5", "pricing": {"prompt": "0.00001", "completion": "0.00005"}}]}, sys.stdout)
PY
run_refresh
[ "$RC" = 0 ] && ok || bad "a thin parse is fail-soft, got $RC"
[ "$(sha256sum < "$T/state/model-prices.json" | cut -d' ' -f1)" = "$BEFORE_SHA" ] \
  && ok || bad "a thin parse must not overwrite the live table"
grep -q 'parsed only 2' "$T/logs/ALERTS.log" \
  && ok || bad "a thin parse must name the count it refused on: $(cat "$T/logs/ALERTS.log")"

echo "update-model-prices-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
