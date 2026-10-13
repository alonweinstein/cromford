#!/bin/bash
# tests/model-watch.bh-3422-test.sh — BH-3429 (BH-3422.4): the daily
# model-watch lane, driven through the SHIPPED bin/model-watch.sh.
#
# WHAT IS STUBBED. The lane runs from a scratch harness ($H: a symlink tree of
# the repo's bin/, a copy of catalog/) with two shims swapped in:
# bin/lane-alert.sh records every call, and bin/agent-call.sh writes a
# .modelUsage envelope for the id it was asked for and counts calls. Everything
# else is real: the gate, the switch, endpoint_url, jobs-client, the
# model-watch libs. A fake `curl` first in PATH is the network:
#   - $JOBS_URL is a fake worker. /api/model-watch keeps its rows in $T/db.json
#     across runs (POST insert-or-nothing on (vendor, model_id), GET list, PUT
#     state), so a second run sees what the first one wrote. /api/settings
#     answers $T/settings.json. Gate traffic (/api/settings, /api/flags,
#     /api/lanes) is logged to $GATELOG; every other request to $REQLOG.
#   - $ENDPOINT_OPENROUTER answers $FX/openrouter.json (code $FX/openrouter.code).
#   - $ENDPOINT_ANTHROPIC answers $FX/anthropic.json, and only when the -H @file
#     it was handed carries the test key (else 401).
# Vendor requests are logged with their whole argv, so a key on the command
# line would show up in $REQLOG.
#
# Cases: A1 A2 A2b A2c A5 A6 A9 A10 A11, the known-set failure, a record 500,
# and the D1 mutation (a lane copy with mw_record stubbed turns A1 red).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/model-watch.bh-3422-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "model-watch: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

# The four product paths this slice ships (D41).
for f in "$DIR/bin/model-watch.sh" "$DIR/catalog/lanes.d/model-watch.json" \
         "$DIR/cron/lanes/720-model-watch.cron" "$DIR/catalog/switches.d/model-watch-off.json"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
[ -f "$DIR/bin/model-watch.sh" ] || { echo "model-watch: $PASS passed, $FAIL failed"; exit 1; }

LFX="$DIR/tests/fixtures/model-watch/lane"
H="$T/h"
mkdir -p "$H/catalog" "$H/env" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog/lanes.d" "$DIR/catalog/switches.d" "$H/catalog/"
cp "$DIR/catalog/model-prices.json" "$DIR/catalog/model-slugs.json" "$H/catalog/"
: > "$H/env/global.env"
rm -f "$H/bin/lane-alert.sh" "$H/bin/agent-call.sh"
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
n=$(find "$FXT/alerts" -name '*.args' 2>/dev/null | wc -l)
printf '%s\n' "$@" > "$FXT/alerts/$((n + 1)).args"
printf '%s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" >> "$FXT/alerts.log"
exit 0
SH
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
# agent-call.sh <stage> <project> <model> <timeout> <out-prefix> <prompt>
echo "agent-call $1 $2 $3" >> "$FXT/agentcalls"
jq -nc --arg m "$3" '{modelUsage: {($m): {inputTokens: 5}}, total_cost_usd: 0.0012}' > "$5.json"
exit 0
SH
printf '#!/bin/bash\necho "2.1.285 (Claude Code)"\n' > "$T/fakebin/claude"
chmod +x "$H/bin/lane-alert.sh" "$H/bin/agent-call.sh" "$T/fakebin/claude"
LANE="$H/bin/model-watch.sh"

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
m=GET; body=""; prev=""; wfmt=0; fail=0; hfile=""
for a in "$@"; do
  case "$prev" in
    -X) m="$a" ;;
    --data-binary) body="$a" ;;
    -w) wfmt=1 ;;
    -H) case "$a" in @*) hfile="${a#@}" ;; esac ;;
  esac
  case "$a" in -f|-sf|-fs|-sfS|-sSf) fail=1 ;; esac
  prev="$a"
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
url="${!#}"
# vendor_answer <file> <code-file>: a vendor list, curl -f semantics.
vendor_answer() {
  local code=200
  [ -f "$2" ] && code=$(cat "$2")
  [ -f "$1" ] || code=404
  if [ "$code" -ge 400 ]; then [ "$fail" = 1 ] && exit 22; printf '{"error":"x"}'; exit 0; fi
  cat "$1"; exit 0
}
case "$url" in
  "$ENDPOINT_OPENROUTER"*)
    printf 'VENDOR %s ARGS %s\n' "$url" "$*" >> "$REQLOG"
    vendor_answer "$FX/openrouter.json" "$FX/openrouter.code" ;;
  "$ENDPOINT_ANTHROPIC"*)
    printf 'VENDOR %s ARGS %s\n' "$url" "$*" >> "$REQLOG"
    if [ -z "$hfile" ] || ! grep -qx "x-api-key: $EXPECT_KEY" "$hfile" 2>/dev/null; then
      echo 401 > "$FX/anthropic.code"
    fi
    vendor_answer "$FX/anthropic.json" "$FX/anthropic.code" ;;
  "$JOBS_URL"*) ;;
  *) exit 7 ;;
esac
path="${url#"$JOBS_URL"}"
case "$path" in
  /api/settings*|/api/flags*|/api/lanes*) printf '%s %s %s\n' "$m" "$path" "$body" >> "$GATELOG" ;;
  *) printf '%s %s %s\n' "$m" "$path" "$body" >> "$REQLOG" ;;
esac
code=200; out='{"ok":true}'
now() { n=$(( $(cat "$FXT/clock" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FXT/clock"; printf '2026-09-29T05:%02d:%02dZ' $((n / 60)) $((n % 60)); }
case "$m $path" in
  "GET /api/settings"*)
    out=$(jq -c '{settings: .}' "$FXT/settings.json" 2>/dev/null || echo '{"settings":[]}') ;;
  "GET /api/model-prices"*)
    code=$(cat "$FX/prices.code" 2>/dev/null || echo 200); out=$(cat "$FX/prices.json") ;;
  "GET /api/model-routes/"*)
    role=${path#/api/model-routes/}
    out=$(jq -c --arg r "$role" '[.roles[] | select(.role == $r)][0] | {ladder, source: "hub", scope_version: 3, hub_scope_version: 3}' "$FX/routes.json") ;;
  "GET /api/model-routes"*) out=$(cat "$FX/routes.json") ;;
  "GET /api/metrics/cli-versions"*) out=$(cat "$FX/cli-versions.json") ;;
  "GET /api/model-watch/usage"*) out=$(cat "$FX/usage.json") ;;
  "POST /api/model-watch")
    mid=$(printf '%s' "$body" | jq -r '.model_id | ascii_downcase')
    if [ -f "$FX/record-500-$mid" ]; then code=500; out='{"error":"boom"}'
    else
      ts=$(now)
      first=$(jq --argjson b "$body" '[.[] | select(.vendor == ($b.vendor|ascii_downcase) and .model_id == ($b.model_id|ascii_downcase))] | length == 0' "$FXT/db.json")
      if [ "$first" = true ]; then
        jq --argjson b "$body" --arg t "$ts" '. + [$b + {vendor: ($b.vendor|ascii_downcase), model_id: ($b.model_id|ascii_downcase),
          status: "new", suggestion: null, probe: null, probe_attempted_at: null, announced_at: null, first_seen: $t, updated_at: $t}]' \
          "$FXT/db.json" > "$FXT/db.tmp" && mv "$FXT/db.tmp" "$FXT/db.json"
      fi
      out=$(jq -nc --argjson f "$first" '{recorded: true, first: $f}')
    fi ;;
  "GET /api/model-watch?"*)
    code=$(cat "$FX/list.code" 2>/dev/null || echo 200)
    v=$(printf '%s' "$path" | sed -n 's/.*vendor=\([^&]*\).*/\1/p')
    out=$(jq -c --arg v "$v" '{rows: ([.[] | select($v == "" or .vendor == $v)] | sort_by(.first_seen) | reverse), truncated: false}' "$FXT/db.json") ;;
  "PUT /api/model-watch/state")
    ts=$(now)
    hit=$(jq --argjson b "$body" '[.[] | select(.vendor == $b.vendor and .model_id == $b.model_id)] | length' "$FXT/db.json")
    if [ "$hit" = 0 ]; then code=404; out='{"error":"no such model_watch row"}'
    else
      jq --argjson b "$body" --arg t "$ts" 'map(if .vendor == $b.vendor and .model_id == $b.model_id then
          . + ($b | del(.vendor, .model_id) | with_entries(if (.key == "suggestion" or .key == "probe") and (.value | type) == "object"
            then .value |= tojson elif (.key == "suggestion" and (.value | type) == "array") then .value |= tojson else . end)) + {updated_at: $t} else . end)' \
        "$FXT/db.json" > "$FXT/db.tmp" && mv "$FXT/db.tmp" "$FXT/db.json"
      out='{"updated":true}'
    fi ;;
  "GET "*) code=404; out='{"error":"not found"}' ;;
esac
printf '%s' "$out"
[ "$wfmt" = 1 ] && printf '\n%s' "$code"
exit 0
SH
chmod +x "$T/fakebin/curl"

KEY="sk-ant-test-$$-secret"
REQLOG="$T/reqlog"; GATELOG="$T/gatelog"; FX="$T/fx"
export HARNESS="$H" FXT="$T" FX REQLOG GATELOG EXPECT_KEY="$KEY" \
  JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 HARNESS_SECRET=test \
  ENDPOINT_OPENROUTER=https://or.invalid ENDPOINT_ANTHROPIC=https://anth.invalid \
  PATH="$T/fakebin:$PATH"
unset ANTHROPIC_API_KEY MODEL_WATCH_ENABLED MODEL_WATCH_VENDORS MODEL_WATCH_PROBE_USD_CAP \
  MODEL_WATCH_MAX_NEW MODEL_WATCH_MIN_LIST MODEL_WATCH_FIXTURE LANE_GATE_DISABLE 2>/dev/null || true

# reset [openrouter-fixture]: a fresh world — an empty model_watch table, no
# switches, no settings rows.
reset() {
  local p
  for p in "$FX" "$T/alerts" "$T/alerts.log" "$T/agentcalls" "$T/db.json" "$T/clock" "$T/settings.json" \
    "$H/state" "$H/logs" "$H/locks" "$H/flags"; do
    scratch_rm "$p" || exit 1
  done
  mkdir -p "$FX" "$T/alerts"
  : > "$REQLOG"; : > "$GATELOG"
  echo '[]' > "$T/db.json"; echo '[]' > "$T/settings.json"
  cp "$LFX/${1:-openrouter-one-new.json}" "$FX/openrouter.json"
  cp "$LFX/anthropic-models.json" "$FX/anthropic.json"
  cp "$LFX/model-routes.json" "$FX/routes.json"
  cp "$LFX/model-prices.json" "$FX/prices.json"
  cp "$LFX/cli-versions.json" "$FX/cli-versions.json"
  cp "$LFX/usage.json" "$FX/usage.json"
}
# run [VAR=value ...]: one tick of the shipped lane.
run() {
  env HARNESS_TEST_SANDBOX=1 "$@" bash "$LANE" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
n_req() { local n; n=$(grep -c -- "$1" "$REQLOG" 2>/dev/null); printf '%s' "${n:-0}"; }
n_crit() { local n; n=$(grep -c -- '^--severity critical' "$T/alerts.log" 2>/dev/null); printf '%s' "${n:-0}"; }
n_alert() { local n; n=$(grep -c -- "$1" "$T/alerts.log" 2>/dev/null); printf '%s' "${n:-0}"; }
n_agent() { local n; n=$(wc -l 2>/dev/null < "$T/agentcalls"); printf '%s' "${n:-0}" | tr -d ' '; }
n_log() { local n; n=$(wc -l 2>/dev/null < "$H/logs/model-watch.log"); printf '%s' "${n:-0}" | tr -d ' '; }
summary() { tail -1 "$H/logs/model-watch.log" 2>/dev/null; }
rows() { jq length "$T/db.json"; }
msg1() { tail -n +6 "$T/alerts/1.args" 2>/dev/null; }
no_route_put() { check "$1: no PUT /api/model-routes" '[ "$(n_req "PUT /api/model-routes")" = 0 ]'; }

# ── A1: one unknown model -> one row, one critical send, one stamp ──────────
reset; run ANTHROPIC_API_KEY=
check "A1 rc 0" '[ "$(cat "$T/rc")" = 0 ]'
check "A1 exactly one POST /api/model-watch ($(n_req 'POST /api/model-watch '))" '[ "$(n_req "POST /api/model-watch ")" = 1 ]'
check "A1 POST body carries the normalized id" \
  'grep "^POST /api/model-watch " "$REQLOG" | sed "s|^POST /api/model-watch ||" | jq -e ".vendor == \"anthropic\" and .model_id == \"claude-lyra-5-7\" and .slug == \"anthropic/claude-lyra-5.7\" and .source == \"openrouter\" and .prompt == 0.000002 and .cache_read == 0.0000002 and (has(\"cache_write\") | not) and .context_window == 400000 and (.released_at | test(\"^2026-09-\"))" >/dev/null'
check "A1 one critical send ($(cat "$T/alerts.log" 2>/dev/null))" '[ "$(n_crit)" = 1 ]'
check "A1 send id is model-watch:anthropic:claude-lyra-5-7" 'sed -n 4p "$T/alerts/1.args" | grep -qx "model-watch:anthropic:claude-lyra-5-7" && sed -n 5p "$T/alerts/1.args" | grep -qx model-watch'
for s in 'New model: anthropic/claude-lyra-5.7 (claude-lyra-5-7)' 'List price per 1M in/out: $2.00 / $10.00' \
         'vs claude-lyra-5-5: $3.00 / $15.00' 'Routes: hub stage.plan#0' 'Cost delta: -$' '/day' 'Probe: live (served by claude-lyra-5-7' \
         'CLI behind on: hub (2.1.284)' "Approve: $H/bin/model-watch-approve.sh anthropic claude-lyra-5-7"; do
  check "A1 message carries '$s': $(msg1)" 'msg1 | grep -qF -- "$s"'
done
check "A1 one agent-call" '[ "$(n_agent)" = 1 ]'
check "A1 row stamped announced + suggested" \
  'jq -e ".[0] | .announced_at != null and .status == \"suggested\" and (.suggestion | fromjson | .[0].from == \"claude-lyra-5-5\" and .[0].role == \"stage.plan\" and .[0].position == 0) and (.probe | fromjson | .verdict == \"live\")" "$T/db.json" >/dev/null'
# The handoff: the shipped approve script accepts the row this lane wrote.
( cd "$T" && env HARNESS_TEST_SANDBOX=1 ANTHROPIC_API_KEY= bash "$H/bin/model-watch-approve.sh" anthropic claude-lyra-5-7 --dry-run ) > "$T/approve.out" 2>&1
arc=$?
check "A1 model-watch-approve.sh --dry-run accepts the row (rc $arc): $(cat "$T/approve.out")" \
  '[ "$arc" = 0 ] && grep -q "stage.plan" "$T/approve.out" && ! grep -qi "refus\|no route suggestion" "$T/approve.out"'
check "A1 the dry run wrote nothing" '[ "$(n_req "PUT /api/model-routes")" = 0 ] && [ "$(n_req "POST /api/model-prices")" = 0 ]'

check "A1 the stamp PUT comes after the send" '[ "$(grep -c "announced_at" "$REQLOG")" = 1 ]'
no_route_put A1
check "A1 one summary line ($(summary))" '[ "$(n_log)" = 1 ] && summary | grep -q " fetched=[0-9]* known=[0-9]* recorded=1 record-failed=0 announced=1 deferred=0 stamp-failed=0 probed=1 anthropic=skipped$"'

# ── A5: the second run the same day sends nothing and probes nothing ────────
: > "$T/alerts.log"; rm -f "$T/agentcalls"
run ANTHROPIC_API_KEY=
check "A5 rc 0" '[ "$(cat "$T/rc")" = 0 ]'
check "A5 0 critical sends" '[ "$(n_crit)" = 0 ]'
check "A5 0 agent-calls" '[ "$(n_agent)" = 0 ]'
check "A5 no second POST" '[ "$(n_req "POST /api/model-watch ")" = 1 ]'
check "A5 still one row" '[ "$(rows)" = 1 ]'
no_route_put A5
check "A5 log grew by one" '[ "$(n_log)" = 2 ] && summary | grep -q " announced=0 "'

# ── D1 mutation: a lane that never records turns A1 red ─────────────────────
rm -f "$LANE"; sed 's/mw_record "/: mw_record "/' "$DIR/bin/model-watch.sh" > "$LANE"
check "D1 the mutation changed the lane" '! cmp -s "$LANE" "$DIR/bin/model-watch.sh"'
reset; run ANTHROPIC_API_KEY=
check "D1 mutated lane: no POST and no send" '[ "$(n_req "POST /api/model-watch ")" = 0 ] && [ "$(n_crit)" = 0 ]'
rm -f "$LANE"; ln -s "$DIR/bin/model-watch.sh" "$LANE"

# ── A2: known ids only (dotted slug, :free, :beta, mixed case, other vendor) ─
reset openrouter-known.json; run ANTHROPIC_API_KEY=
check "A2 rc 0" '[ "$(cat "$T/rc")" = 0 ]'
check "A2 0 POST" '[ "$(n_req "POST /api/model-watch ")" = 0 ]'
check "A2 0 sends ($(cat "$T/alerts.log" 2>/dev/null))" '[ ! -s "$T/alerts.log" ]'
check "A2 summary ($(summary))" 'summary | grep -q " recorded=0 .* announced=0 "'
no_route_put A2

# ── A2b: the Anthropic dated id of the same model -> still one row ──────────
reset; run ANTHROPIC_API_KEY="$KEY"
check "A2b rc 0" '[ "$(cat "$T/rc")" = 0 ]'
check "A2b the anthropic list was read" '[ "$(n_req "VENDOR https://anth.invalid/v1/models")" = 1 ]'
check "A2b one row ($(jq -c 'map(.model_id)' "$T/db.json"))" '[ "$(rows)" = 1 ] && [ "$(n_req "POST /api/model-watch ")" = 1 ]'
check "A2b the OpenRouter entry won" 'jq -e ".[0].source == \"openrouter\"" "$T/db.json" >/dev/null'
check "A2b the key is in no request line and no log" '! grep -qF "$KEY" "$REQLOG" "$GATELOG" "$H/logs/"* "$T/out"'
check "A2b no anthropic= suffix ($(summary))" '! summary | grep -q "anthropic="'
no_route_put A2b

# A bad key: Anthropic skipped with a warn line, the run goes on over OpenRouter.
reset; run ANTHROPIC_API_KEY=wrong-key
check "A2b bad key still records from OpenRouter" '[ "$(rows)" = 1 ] && summary | grep -q "anthropic=down$"'
check "A2b bad key is not logged" '! grep -qF "wrong-key" "$REQLOG" "$H/logs/"* "$T/out"'

# ── A2c: no key -> no anthropic request ─────────────────────────────────────
reset; run ANTHROPIC_API_KEY=
check "A2c no /v1/models request" '[ "$(n_req "anth.invalid")" = 0 ]'
check "A2c summary says anthropic=skipped" 'summary | grep -q "anthropic=skipped$"'

# ── A6: an OpenRouter outage is not "nothing new" ───────────────────────────
reset; echo 500 > "$FX/openrouter.code"; run ANTHROPIC_API_KEY=
check "A6 500: rc 0" '[ "$(cat "$T/rc")" = 0 ]'
check "A6 500: 0 POST" '[ "$(n_req "POST /api/model-watch")" = 0 ]'
check "A6 500: one warn model-watch-fetch ($(cat "$T/alerts.log" 2>/dev/null))" \
  '[ "$(wc -l < "$T/alerts.log")" = 1 ] && [ "$(n_alert "^--severity warn --id model-watch-fetch model-watch")" = 1 ]'
check "A6 500: summary fetch-failed" 'summary | grep -q " fetch-failed$"'
reset; echo '{"data":[]}' > "$FX/openrouter.json"; run ANTHROPIC_API_KEY=
check "A6 data:[]: 0 POST, one warn" '[ "$(n_req "POST /api/model-watch")" = 0 ] && [ "$(wc -l < "$T/alerts.log")" = 1 ] && [ "$(n_alert "model-watch-fetch")" = 1 ]'
reset openrouter-four.json; run ANTHROPIC_API_KEY=
check "A6 four entries (< MIN_LIST 5): 0 POST, one warn" '[ "$(n_req "POST /api/model-watch")" = 0 ] && [ "$(n_alert "model-watch-fetch")" = 1 ]'
reset; echo 'not json' > "$FX/openrouter.json"; run ANTHROPIC_API_KEY=
check "A6 junk: 0 POST, one warn" '[ "$(n_req "POST /api/model-watch")" = 0 ] && [ "$(n_alert "model-watch-fetch")" = 1 ]'
# OpenRouter down, Anthropic up: continue on Anthropic alone.
reset; echo 500 > "$FX/openrouter.code"; run ANTHROPIC_API_KEY="$KEY"
check "A6 openrouter down + anthropic up: the anthropic model is recorded" \
  '[ "$(rows)" = 1 ] && jq -e ".[0].source == \"anthropic\" and .[0].model_id == \"claude-lyra-5-7\"" "$T/db.json" >/dev/null && summary | grep -q "openrouter=down"'
check "A6 openrouter down + anthropic up: no fetch warn" '[ "$(n_alert "model-watch-fetch")" = 0 ]'

# ── Known-set failure: fail closed ──────────────────────────────────────────
reset; echo 500 > "$FX/prices.code"; run ANTHROPIC_API_KEY=
check "known-set 500: 0 POST, 0 critical" '[ "$(n_req "POST /api/model-watch")" = 0 ] && [ "$(n_crit)" = 0 ]'
check "known-set 500: one warn model-watch-known ($(cat "$T/alerts.log" 2>/dev/null))" \
  '[ "$(wc -l < "$T/alerts.log")" = 1 ] && [ "$(n_alert "^--severity warn --id model-watch-known model-watch")" = 1 ]'
reset; echo 500 > "$FX/list.code"; run ANTHROPIC_API_KEY=
check "ledger 500: 0 POST, 0 critical, one warn model-watch-known" \
  '[ "$(n_req "POST /api/model-watch ")" = 0 ] && [ "$(n_crit)" = 0 ] && [ "$(n_alert "model-watch-known")" = 1 ]'

# ── Record 500: that model is skipped and counted ───────────────────────────
reset; touch "$FX/record-500-claude-lyra-5-7"; run ANTHROPIC_API_KEY=
check "record 500: no send" '[ "$(n_crit)" = 0 ]'
check "record 500: summary record-failed=1 ($(summary))" 'summary | grep -q " recorded=0 record-failed=1 "'

# ── A9: seven unknown, MAX_NEW=5 -> 5 now, 2 next run ───────────────────────
reset openrouter-seven-new.json; run ANTHROPIC_API_KEY= MODEL_WATCH_MAX_NEW=5
check "A9 run 1: 7 rows" '[ "$(rows)" = 7 ]'
check "A9 run 1: 5 critical sends ($(n_crit))" '[ "$(n_crit)" = 5 ]'
check "A9 run 1: summary announced=5 deferred=2 ($(summary))" 'summary | grep -q " announced=5 deferred=2 "'
check "A9 run 1: the oldest five went first" \
  '[ "$(jq -r "[.[] | select(.announced_at == null) | .model_id] | sort | join(\",\")" "$T/db.json")" = "claude-lyra-5-12,claude-lyra-5-13" ]'
: > "$T/alerts.log"
run ANTHROPIC_API_KEY= MODEL_WATCH_MAX_NEW=5
check "A9 run 2: 2 critical sends ($(n_crit))" '[ "$(n_crit)" = 2 ]'
check "A9 run 2: summary announced=2 deferred=0" 'summary | grep -q " announced=2 deferred=0 "'
check "A9 two runs, two summary lines" '[ "$(n_log)" = 2 ]'
no_route_put A9
# An out-of-range knob is not clamped silently: one warn line, the default.
reset openrouter-seven-new.json; run ANTHROPIC_API_KEY= MODEL_WATCH_MAX_NEW=99
check "A9 MAX_NEW=99: warned and fell back to 5" \
  'grep -q "MODEL_WATCH_MAX_NEW=99" "$H/logs/model-watch.notes.log" && [ "$(n_crit)" = 5 ]'

# ── A10: the switch and ENABLED=0 stop the lane before any network call ─────
reset; mkdir -p "$H/flags"; touch "$H/flags/model-watch-off"; run ANTHROPIC_API_KEY="$KEY"
check "A10 flag file: rc 0" '[ "$(cat "$T/rc")" = 0 ]'
check "A10 flag file: 0 requests ($(cat "$REQLOG"))" '[ ! -s "$REQLOG" ]'
check "A10 flag file: summary off" '[ "$(n_log)" = 1 ] && summary | grep -q " off$"'
reset; echo '[{"key":"switch.model-watch-off","value":"1","actor":"operator"}]' > "$T/settings.json"; run ANTHROPIC_API_KEY="$KEY"
check "A10 switch row: 0 requests ($(cat "$REQLOG"))" '[ ! -s "$REQLOG" ] && summary | grep -q " off$"'
reset; run ANTHROPIC_API_KEY="$KEY" MODEL_WATCH_ENABLED=0
check "A10 ENABLED=0 env: 0 requests, summary disabled" '[ ! -s "$REQLOG" ] && summary | grep -q " disabled$"'
reset; echo '[{"key":"lane.model-watch.model_watch_enabled","value":"0","actor":"operator"}]' > "$T/settings.json"; run ANTHROPIC_API_KEY="$KEY"
check "A10 ENABLED=0 settings row: 0 requests, summary disabled ($(summary))" '[ ! -s "$REQLOG" ] && summary | grep -q " disabled$"'
reset; mkdir -p "$H/flags"; touch "$H/flags/lane-off-model-watch"; run ANTHROPIC_API_KEY="$KEY"
check "A10 lane-off flag: 0 requests" '[ ! -s "$REQLOG" ]'

# ── A11: a second vendor with no probe runner ───────────────────────────────
reset openrouter-xai.json; run ANTHROPIC_API_KEY= MODEL_WATCH_VENDORS="Anthropic, x-ai"
check "A11 x-ai row recorded" 'jq -e "length == 1 and .[0].vendor == \"x-ai\" and .[0].model_id == \"grok-nova-9\"" "$T/db.json" >/dev/null'
check "A11 one send, id model-watch:x-ai:grok-nova-9" '[ "$(n_crit)" = 1 ] && sed -n 4p "$T/alerts/1.args" | grep -qx "model-watch:x-ai:grok-nova-9"'
check "A11 message says no probe runner: $(msg1)" 'msg1 | grep -qF "Probe: not run (no probe runner for x-ai)"'
check "A11 no Approve line" '! msg1 | grep -q "Approve:"'
check "A11 0 agent-calls" '[ "$(n_agent)" = 0 ]'
check "A11 row stamped status new" 'jq -e ".[0].status == \"new\" and .[0].announced_at != null" "$T/db.json" >/dev/null'
reset openrouter-xai.json; run ANTHROPIC_API_KEY= MODEL_WATCH_VENDORS='anthropic,$(touch /tmp/x),x-ai'
check "A11 a bad vendor name is dropped with a note" 'grep -q "dropped vendor" "$H/logs/model-watch.notes.log" && [ "$(rows)" = 1 ]'

# An anthropic row with no matching route is never probed (no spend).
reset; jq '.roles = []' "$LFX/model-routes.json" > "$FX/routes.json"; run ANTHROPIC_API_KEY=
check "no route: 0 agent-calls, sent with Routes: none match" \
  '[ "$(n_agent)" = 0 ] && [ "$(n_crit)" = 1 ] && msg1 | grep -qF "Routes: none match" && msg1 | grep -qF "Probe: not run (no matching route)" && ! msg1 | grep -q "Approve:"'

# The source never writes a route and never runs the approve script.
check "the lane never PUTs a route" '! grep -q "PUT /api/model-routes\|model-routes.*PUT" "$DIR/bin/model-watch.sh"'
check "the lane never calls the approve script" '! grep -v "^ *#" "$DIR/bin/model-watch.sh" | grep -q "model-watch-approve.sh"'

echo "model-watch: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
