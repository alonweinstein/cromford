#!/bin/bash
# tests/update-model-prices.bh-1361-test.sh — the model -> openrouter-slug map
# is DATA (catalog/model-slugs.json), and since BH-1510.4 it is the ONLY map:
# the script carries no constant to fall back to.
#
# THE FAILURE (BH-1361, from #1360). The map the daily refresh prices from was a
# constant inside bin/update-model-prices.sh, so adding a model to the price
# table was a CODE DEPLOY. Every new lane or model therefore repeats the
# 2026-08-19 grok and 2026-09-22 claude-opus-4-8 shape: real spend that reads as
# $0.00 on every cost view until somebody edits bin/ and lands a PR.
#
# So the contract under test, in the order it breaks:
#
#   the catalog is read       a key present in catalog/model-slugs.json and
#                             ABSENT from the constant is priced by the refresh
#   no map, no refresh        no file (or an unusable one) is ONE ALERTS line,
#                             rc 0, no OpenRouter fetch, and yesterday's table
#                             byte-identical (BH-1510.4: there is no constant
#                             left to price from, so the lane did NOT do its job)
#   the floor is unchanged    a thin openrouter list still refuses to overwrite,
#                             and neither state file moves
#   the id list is persisted  state/openrouter-models.json carries the ids the
#                             refresh already fetched, so the UNPRICED alert can
#                             name a slug without a second network call
#
# No network: `curl` is a fixture script on PATH. No real box: everything lives
# under one mktemp -d. SCRIPT_UNDER_TEST=<path> runs the sections against another
# copy of the lane (that is the red proof against origin/main).
# Run from anywhere: tests/update-model-prices.bh-1361-test.sh
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
command -v jq >/dev/null && command -v git >/dev/null && command -v python3 >/dev/null \
  || { echo "jq/git/python3 missing — skipping"; exit 0; }

# ── the script under test ────────────────────────────────────────────────────
# Copied whole, with only the two path assignments rewritten to their
# overridable form (a no-op on today's script, kept so an older copy handed in
# through SCRIPT_UNDER_TEST still points at the scratch tree).
UNDER="${SCRIPT_UNDER_TEST:-$DIR/bin/update-model-prices.sh}"
sed -e 's|^H=/root/harness$|H="${HARNESS:-/root/harness}"|' \
    -e 's|^CK=/root/harness-checkout$|CK="${HARNESS_CHECKOUT:-/root/harness-checkout}"|' \
    "$UNDER" > "$T/update-model-prices.sh"
mkdir -p "$T/lib"; cp "$DIR/bin/lib/endpoints.sh" "$T/lib/"   # BH-1941: beside the script copy
grep -q 'HARNESS:-/root/harness' "$T/update-model-prices.sh" \
  && ok || bad "could not make \$H overridable — did the assignment shape change?"

# ============================================================================
# B0. the committed catalog seed
# ============================================================================
CATALOG="$DIR/catalog/model-slugs.json"
[ -s "$CATALOG" ] && ok || bad "catalog/model-slugs.json is missing — the map is still code-only"
jq -e 'type=="object" and (to_entries|length) >= 26 and all(.[]; type=="string")' "$CATALOG" >/dev/null 2>&1 \
  && ok || bad "catalog/model-slugs.json must be an object of >=26 string values"
# A duplicate key parses (last wins) and silently drops the earlier slug, so the
# seed is checked with a parser that refuses one.
python3 - "$CATALOG" <<'PY' && ok || bad "catalog/model-slugs.json has duplicate keys"
import json, sys
def pairs(p):
    k = [x for x, _ in p]
    if len(k) != len(set(k)):
        raise SystemExit(1)
    return dict(p)
json.load(open(sys.argv[1]), object_pairs_hook=pairs)
PY
# BH-1510.4: the bash MAP='{…}' table is gone — the catalog is the only map.
[ "$(grep -c "^MAP='" "$DIR/bin/update-model-prices.sh")" = 0 ] \
  && ok || bad "bin/update-model-prices.sh still carries a MAP='{…}' literal table"
jq -e 'has("claude-opus-4-8") and has("deepseek/deepseek-v4-flash") and has("codex-default")' "$CATALOG" >/dev/null \
  && ok || bad "the catalog must carry the two #1360 models and codex-default"

# ── the fixture OpenRouter list ──────────────────────────────────────────────
mkor() { # mkor <slug> [<slug>...] > $T/openrouter.json
  python3 - "$T/openrouter.json" "$@" <<'PY'
import json, sys
out, slugs = sys.argv[1], sys.argv[2:]
data = [{"id": s, "pricing": {"prompt": str(0.00001 * (n + 1)),
                              "completion": str(0.00005 * (n + 1)),
                              "input_cache_read": str(0.000001 * (n + 1)),
                              "input_cache_write": str(0.0000125 * (n + 1))}}
        for n, s in enumerate(slugs)]
json.dump({"data": data}, open(out, "w"))
PY
}
FULL_IDS=(anthropic/claude-fable-5.1 anthropic/claude-opus-5 anthropic/claude-sonnet-5
          anthropic/claude-haiku-4.5 openai/gpt-6-astra x-ai/grok-4.6 anthropic/claude-opus-4.8)
mkor "${FULL_IDS[@]}"

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
echo "$*" >> "$CURL_SINK"
[ -n "${CURL_RC:-}" ] && exit "$CURL_RC"
cat "$CURL_BODY"
SH
chmod +x "$T/fakebin/curl"
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
cat > "$T/ck/catalog/model-prices.json" <<'JSON'
{"updated_at":"2026-01-01T00:00:00Z","source":"openrouter/api/v1/models","per_token":{
  "claude-fable-5-1":{"prompt":0.1,"completion":0.2,"cache_read":0.3,"cache_write":0.4,"slug":"anthropic/claude-fable-5.1"}
}}
JSON
printf '#!/bin/bash\n:\n' > "$T/ck/bin/x.sh"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm seed
git -C "$T/ck" branch -M main 2>/dev/null
git -C "$T/ck" push -q origin main
BASE_HEAD=$(git -C "$T/ck" rev-parse HEAD)
BASE_ORIGIN=$(git -C "$T/origin" rev-parse main)

# The operator's data edit: six keys the constant also has, plus one the
# constant cannot have (bh-1361-catalog-only — a key no release of the script
# ever shipped, so this section stays red on every earlier copy even after the
# constant gains a model). Left untracked on purpose: it is the file under test,
# not part of the checkout's cleanliness contract.
SLUGS="$T/ck/catalog/model-slugs.json"
write_slugs() { cat > "$SLUGS" <<'JSON'
{
  "bh-1361-catalog-only": "anthropic/claude-opus-4.8",
  "claude-fable-5-1": "anthropic/claude-fable-5.1",
  "claude-haiku-4-5": "anthropic/claude-haiku-4.5",
  "claude-opus-4-8": "anthropic/claude-opus-4.8",
  "claude-opus-5": "anthropic/claude-opus-5",
  "claude-sonnet-5": "anthropic/claude-sonnet-5",
  "gpt-6-astra": "openai/gpt-6-astra",
  "grok-4.6": "x-ai/grok-4.6"
}
JSON
}
write_slugs

LANE_SINK="$T/lane.txt"; : > "$LANE_SINK"
CURL_SINK="$T/curl.calls"
run_refresh() { # run_refresh [VAR=val ...] -> rc in $RC
  : > "$CURL_SINK"
  ( export HARNESS="$T" HARNESS_CHECKOUT="$T/ck" \
           PATH="$T/fakebin:$PATH" CURL_BODY="$T/openrouter.json" CURL_SINK="$CURL_SINK" \
           LANE_SINK="$LANE_SINK" "$@"
    bash "$T/update-model-prices.sh" ) >"$T/run.out" 2>"$T/run.err"
  RC=$?
}
porcelain() { git -C "$T/ck" status --porcelain --untracked-files=no; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# ============================================================================
# B1. a key in the catalog and ABSENT from the constant is priced
# ============================================================================
: > "$T/logs/ALERTS.log"; : > "$T/logs/agent-rules.log"
run_refresh
[ "$RC" = 0 ] && ok || bad "a catalog-driven refresh must exit 0, got $RC: $(cat "$T/run.err")"
[ "$(jq -r '.per_token["bh-1361-catalog-only"].slug' "$T/state/model-prices.json" 2>/dev/null)" = "anthropic/claude-opus-4.8" ] \
  && ok || bad "THE BUG: a model in catalog/model-slugs.json but not in the script constant was not priced: $(jq -c '.per_token|keys' "$T/state/model-prices.json" 2>/dev/null)"
[ "$(jq -r '.per_token["claude-opus-4-8"].slug' "$T/state/model-prices.json" 2>/dev/null)" = "anthropic/claude-opus-4.8" ] \
  && ok || bad "the catalog's own keys must all be priced"
N=$(jq '.per_token|length' "$T/state/model-prices.json" 2>/dev/null || echo 0)
[ "${N:-0}" -ge 8 ] && ok || bad "the catalog map must price all 8 of its keys, got $N"
# The catalog REPLACES the constant: a constant-only key whose slug is in the
# fixture list (anthropic/claude-opus-5) must not appear.
[ "$(jq -r '.per_token|has("anthropic/claude-opus-5")' "$T/state/model-prices.json")" = false ] \
  && ok || bad "the catalog must replace the constant, not merge with it"
[ -z "$(porcelain)" ] && ok || bad "the refresh left the checkout dirty: $(porcelain)"
[ "$(git -C "$T/ck" rev-parse HEAD)" = "$BASE_HEAD" ] && ok || bad "a cron must not commit — HEAD moved"
[ "$(git -C "$T/origin" rev-parse main)" = "$BASE_ORIGIN" ] && ok || bad "a cron must not push to main — origin moved"
[ "$(grep -c 'slug map' "$T/logs/agent-rules.log")" = 0 ] \
  && ok || bad "a good catalog read must log no fallback line: $(grep 'slug map' "$T/logs/agent-rules.log")"

# ============================================================================
# B4. the openrouter id list is persisted for the UNPRICED alert
# ============================================================================
ORM="$T/state/openrouter-models.json"
[ -s "$ORM" ] && ok || bad "the refresh must persist the openrouter id list to state/openrouter-models.json"
[ "$(jq -r '.ids|length' "$ORM" 2>/dev/null)" = 7 ] \
  && ok || bad "the id list must carry every fetched id, got $(jq -r '.ids|length' "$ORM" 2>/dev/null)"
jq -e '.ids|index("anthropic/claude-opus-4.8")' "$ORM" >/dev/null 2>&1 \
  && ok || bad "the id list must contain the ids the fixture served"
[ -n "$(jq -r '.fetched_at // empty' "$ORM" 2>/dev/null)" ] \
  && ok || bad "the id list must stamp when it was fetched"

# ============================================================================
# B5. a thin list is still refused, and neither state file moves
# ============================================================================
PRICES_SHA=$(sha "$T/state/model-prices.json"); ORM_SHA=$(sha "$ORM")
: > "$T/logs/ALERTS.log"
mkor anthropic/claude-opus-5
run_refresh
[ "$RC" = 0 ] && ok || bad "a thin parse is fail-soft, got $RC"
grep -q 'parsed only' "$T/logs/ALERTS.log" \
  && ok || bad "a thin parse must name the count it refused on: $(cat "$T/logs/ALERTS.log")"
[ "$(sha "$T/state/model-prices.json")" = "$PRICES_SHA" ] \
  && ok || bad "a thin parse must not overwrite the live price table"
[ "$(sha "$ORM")" = "$ORM_SHA" ] \
  && ok || bad "a thin parse must not overwrite the persisted id list either"
mkor "${FULL_IDS[@]}"

# ============================================================================
# B2. no catalog file -> no refresh: ONE ALERTS line, no fetch, table untouched
#     (BH-1510.4 — there is no script constant left to fall back to)
# ============================================================================
# no_refresh <label> <grep-phrase>: the run just made must have refused cleanly.
no_refresh() {
  [ "$RC" = 0 ] && ok || bad "$1: a missing map is fail-soft (rc 0), got $RC: $(cat "$T/run.err")"
  [ "$(grep -c "$2" "$T/logs/ALERTS.log")" = 1 ] \
    && ok || bad "$1: must say '$2' exactly once in ALERTS.log: $(cat "$T/logs/ALERTS.log")"
  [ "$(sha "$T/state/model-prices.json")" = "$PRICES_SHA" ] \
    && ok || bad "$1: the live price table must stay byte-identical"
  [ ! -s "$CURL_SINK" ] && ok || bad "$1: no map means no OpenRouter fetch, curl ran: $(cat "$CURL_SINK")"
  [ "$(grep -c 'slug map' "$T/logs/agent-rules.log")" = 0 ] \
    && ok || bad "$1: a skipped refresh is a page, not an agent-rules note: $(cat "$T/logs/agent-rules.log")"
}
rm -f "$SLUGS" "$T/catalog/model-slugs.json"
PRICES_SHA=$(sha "$T/state/model-prices.json")
[ -n "$PRICES_SHA" ] && ok || bad "B2 needs a table from B1 to compare against"
: > "$T/logs/ALERTS.log"; : > "$T/logs/agent-rules.log"
run_refresh
no_refresh B2 'slug map absent'
grep -q 'catalog/model-slugs.json is the only map' "$T/logs/ALERTS.log" \
  && ok || bad "B2 the ALERTS line must name the fix: $(cat "$T/logs/ALERTS.log")"

# ============================================================================
# B3. an unusable catalog -> the same refusal, saying INVALID
# ============================================================================
printf '[1,2]\n' > "$SLUGS"
: > "$T/logs/ALERTS.log"; : > "$T/logs/agent-rules.log"
run_refresh
no_refresh B3 'slug map invalid'
# A catalog whose values are not strings is unusable too.
printf '{"claude-opus-5": 5}\n' > "$SLUGS"
: > "$T/logs/ALERTS.log"; : > "$T/logs/agent-rules.log"
run_refresh
no_refresh B3-nonstring 'slug map invalid'

# ============================================================================
# B3b. an EMPTY catalog is what it says: the >=5 floor answers it. It is
#      valid data, not an absent map, so it is not the B2/B3 refusal.
# ============================================================================
printf '{}\n' > "$SLUGS"
PRICES_SHA=$(sha "$T/state/model-prices.json")
: > "$T/logs/ALERTS.log"; : > "$T/logs/agent-rules.log"
run_refresh
[ "$RC" = 0 ] && ok || bad "an empty catalog must not fail the lane, got $RC"
grep -q 'parsed only 0' "$T/logs/ALERTS.log" \
  && ok || bad "an empty catalog must hit the floor: $(cat "$T/logs/ALERTS.log")"
[ "$(sha "$T/state/model-prices.json")" = "$PRICES_SHA" ] \
  && ok || bad "an empty catalog must leave the previous table in place"
[ "$(grep -c 'slug map' "$T/logs/agent-rules.log")" = 0 ] \
  && ok || bad "an empty catalog is valid data, not a fallback: $(cat "$T/logs/agent-rules.log")"
[ "$(grep -c 'slug map' "$T/logs/ALERTS.log")" = 0 ] \
  && ok || bad "an empty catalog is valid data, not the absent/invalid refusal: $(cat "$T/logs/ALERTS.log")"

# ============================================================================
# B6. $MODEL_SLUGS is used AS GIVEN — an unreadable override never silently
#     falls through to a different file (same contract as $MODEL_PRICES)
# ============================================================================
write_slugs
PRICES_SHA=$(sha "$T/state/model-prices.json")
: > "$T/logs/ALERTS.log"; : > "$T/logs/agent-rules.log"
run_refresh MODEL_SLUGS="$T/nope.json"
no_refresh B6 'slug map absent'
grep -q "slug map absent at $T/nope.json " "$T/logs/ALERTS.log" \
  && ok || bad "an absent \$MODEL_SLUGS must name only that path, never fall through: $(cat "$T/logs/ALERTS.log")"

echo "update-model-prices.bh-1361-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
