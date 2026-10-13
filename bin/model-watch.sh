#!/bin/bash
# bin/model-watch.sh — BH-3429 (BH-3422.4): the daily model-watch lane. A hub
# cron lane: it notices a vendor model the fleet has never priced, records it,
# and announces it once on Telegram with a suggestion. It never switches a
# route: the only route writer is bin/model-watch-approve.sh, run by a human.
# It calls the BH-3422 contract only:
#   mw_norm_id / mw_record / mw_get / mw_set_state / mw_usage  (bin/lib/model-watch.sh)
#   mw_match_routes / mw_delta_per_day / mw_probe_run / mw_cli_lag / mw_message
#                                                              (bin/lib/model-watch-suggest.sh)
#
# THE RUN, in this order. Steps 1-4 happen before any network call.
#   1. lane_gate_or_exit model-watch, then lane_env_apply model-watch;
#   2. the model-watch-off switch: ON writes the summary with ` off`, exit 0;
#   3. MODEL_WATCH_ENABLED=0: the summary with ` disabled`, exit 0;
#   4. flock -n on locks/model-watch.lock: a held lock skips the run (dedupe);
#   5. fetch OpenRouter /api/v1/models, and Anthropic /v1/models when
#      `anthropic` is watched and ANTHROPIC_API_KEY is set (the key rides a
#      600 header file, never argv). A list is valid only with at least
#      MODEL_WATCH_MIN_LIST entries (Anthropic: a .data array). No valid list
#      at all is an outage, not "nothing new": one warn `model-watch-fetch`,
#      nothing recorded;
#   6. the known set: GET /api/model-prices, catalog/model-prices.json and
#      catalog/model-slugs.json, every id through mw_norm_id. Any of the three
#      unreadable, or the model_watch list unreadable: one warn
#      `model-watch-known`, nothing recorded or sent;
#   7. every watched-vendor model whose (vendor, mw_norm_id) is not known and
#      has no model_watch row yet is recorded (mw_record). A failed POST skips
#      that model; it is still unknown next run;
#   8. the unannounced `new` rows, oldest first_seen first, at most
#      MODEL_WATCH_MAX_NEW; the rest drain next run (`deferred`). Per row:
#      routes, $/day delta, a probe (an anthropic row only with a matching
#      route; mw_probe_run stamps before it spends), CLI lag, the message;
#   9. send `lane-alert --severity critical --id model-watch:<vendor>:<id>`,
#      THEN stamp announced_at/status/suggestion. A failed stamp re-sends next
#      run and lane-alert's open id absorbs it;
#  10. one summary line in logs/model-watch.log:
#      <ts> fetched=<n> known=<n> recorded=<n> record-failed=<n> announced=<n> deferred=<n> stamp-failed=<n> probed=<n>[ openrouter=down| anthropic=skipped| anthropic=down| fetch-failed| known-failed| off| disabled]
#      Detail lines (warnings, dropped vendors) go to logs/model-watch.notes.log.
#
# OFF: settings row / flags/model-watch-off (lane_switch), flags/lane-off-model-watch
# (bin/harness-ctl.sh off model-watch), or MODEL_WATCH_ENABLED=0.
# Registry: catalog/lanes.d/model-watch.json. Note:
# docs/notes/2026-09-29-BH-3422-model-watch.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
# Bounded (D21): the whole run, probes included, inside 15 minutes.
if [ "${MW_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  MW_TIMED=1 exec timeout 900 bash "$0" "$@"
fi
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/lib/lane-switch.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/endpoints.sh" 2>/dev/null || true
  . "$SELF/lib/model-watch.sh" 2>/dev/null || true
  . "$SELF/lib/model-watch-suggest.sh" 2>/dev/null || true
}
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${MODEL_WATCH_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$MODEL_WATCH_FIXTURE"
fi

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit model-watch
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply model-watch
command -v mw_record >/dev/null 2>&1 && command -v mw_message >/dev/null 2>&1 \
  && command -v endpoint_url >/dev/null 2>&1 && command -v model_prices_get >/dev/null 2>&1 || {
  echo "model-watch: contract libs missing (bin/lib/model-watch.sh, bin/lib/model-watch-suggest.sh, jobs-client, endpoints)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "model-watch: jq is required" >&2; exit 1; }
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$H/flags/$1" ]; }

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/model-watch.log"
NOTES="$H/logs/model-watch.notes.log"
declare -A C=()
for k in fetched known recorded record-failed announced deferred stamp-failed probed; do C[$k]=0; done
inc() { C[$1]=$(( ${C[$1]} + ${2:-1} )); }
SUFFIX=""
summary() { # summary [suffix]
  local s="" k
  for k in fetched known recorded record-failed announced deferred stamp-failed probed; do s="$s $k=${C[$k]}"; done
  printf '%s%s%s%s\n' "$(date -u +%FT%TZ)" "$s" "$SUFFIX" "${1:+ $1}" >> "$LOG"
}
note() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$NOTES"; }
alert() { "$H/bin/lane-alert.sh" --severity warn --id "$1" model-watch "$2" >/dev/null 2>&1 || true; }

if lane_switch model-watch-off file; then summary off; exit 0; fi
case "${MODEL_WATCH_ENABLED:-1}" in
  0) summary disabled; exit 0 ;;
  1) ;;
  *) note "warn: MODEL_WATCH_ENABLED=${MODEL_WATCH_ENABLED} is not 0 or 1; using the default 1" ;;
esac

exec 9>"$H/locks/model-watch.lock" || exit 0
flock -n 9 || exit 0

# knob_int <name> <value> <default> <min> [max]: an out-of-range value is one
# warn line and the default, never a silent clamp (D11).
knob_int() {
  local v=$2
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$4" ] && { [ -z "${5:-}" ] || [ "$((10#$v))" -le "$5" ]; }; then
    printf '%s' "$((10#$v))"
  else
    note "warn: $1=$v is outside $4..${5:-} ; using the default $3"
    printf '%s' "$3"
  fi
}
MAX_NEW=$(knob_int MODEL_WATCH_MAX_NEW "${MODEL_WATCH_MAX_NEW:-5}" 5 1 20)
MIN_LIST=$(knob_int MODEL_WATCH_MIN_LIST "${MODEL_WATCH_MIN_LIST:-5}" 5 1)

# The watched vendors: lowercased, trimmed, [a-z0-9-] only (they reach jq as
# data, never as code). Each name is its own OpenRouter id prefix.
VENDORS=()
IFS=, read -ra _raw <<<"${MODEL_WATCH_VENDORS:-anthropic}"
for v in "${_raw[@]}"; do
  v=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  [ -n "$v" ] || continue
  if ! [[ $v =~ ^[a-z0-9][a-z0-9-]*$ ]]; then note "dropped vendor '$v' (want [a-z0-9-])"; continue; fi
  [[ " ${VENDORS[*]} " == *" $v "* ]] || VENDORS+=("$v")
done
if [ "${#VENDORS[@]}" = 0 ]; then note "no valid vendor in MODEL_WATCH_VENDORS"; summary no-vendors; exit 0; fi
VJSON=$(printf '%s\n' "${VENDORS[@]}" | jq -R . | jq -sc .)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/model-watch.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# ── 5. Fetch ──────────────────────────────────────────────────────────────────
OR_BASE=""; or_ok=0; or_why=""
if OR_BASE=$(endpoint_url openrouter 2>/dev/null); then
  OR_BASE=${OR_BASE%/}
  if curl -sf -m 30 "$OR_BASE/api/v1/models" > "$TMP/or.json" 2>/dev/null; then
    n=$(jq -r 'if type == "object" and (.data | type) == "array" then (.data | length) else "junk" end' "$TMP/or.json" 2>/dev/null)
    if [[ ${n:-} =~ ^[0-9]+$ ]] && [ "$n" -ge "$MIN_LIST" ]; then or_ok=1
    else or_why="OpenRouter list unusable (${n:-junk} entries, need $MIN_LIST)"; fi
  else
    or_why="OpenRouter /api/v1/models fetch failed"
  fi
else
  OR_BASE=""; or_why="OpenRouter endpoint not configured"
fi

an_state=off
if [[ " ${VENDORS[*]} " == *" anthropic "* ]]; then
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    an_state=skipped
  elif AN_BASE=$(endpoint_url anthropic 2>/dev/null); then
    # printf is a builtin: the key reaches the 600 file without touching argv.
    ( umask 077; printf 'x-api-key: %s\nanthropic-version: 2023-06-01\n' "$ANTHROPIC_API_KEY" > "$TMP/an.h" )
    if curl -sf -m 30 -H "@$TMP/an.h" "${AN_BASE%/}/v1/models?limit=1000" > "$TMP/an.json" 2>/dev/null \
      && jq -e '(.data | type) == "array"' "$TMP/an.json" >/dev/null 2>&1; then
      an_state=ok
    else
      an_state=down; note "warn: Anthropic /v1/models fetch failed or unreadable; skipped this run"
    fi
    rm -f "$TMP/an.h"
  else
    an_state=down; note "warn: Anthropic endpoint not configured; skipped this run"
  fi
fi

if [ "$or_ok" != 1 ] && [ "$an_state" != ok ]; then
  alert model-watch-fetch "model-watch: no vendor list this run: $or_why; Anthropic ${an_state}. Nothing recorded."
  summary fetch-failed; exit 0
fi
[ "$or_ok" = 1 ] || { SUFFIX="$SUFFIX openrouter=down"; note "warn: $or_why; running on Anthropic only"; }
case "$an_state" in skipped|down) SUFFIX="$SUFFIX anthropic=$an_state" ;; esac

# The watched entries of both lists, OpenRouter first and un-suffixed ids
# before `:free` variants, so the priced entry wins a shared key. An absent or
# unparseable price is left out of the body, never 0 (D11).
[ "$or_ok" = 1 ] || echo '{"data":[]}' > "$TMP/or.json"
[ "$an_state" = ok ] || echo '{"data":[]}' > "$TMP/an.json"
jq -c --argjson vs "$VJSON" --arg or "$OR_BASE" --arg an "${AN_BASE:-}" --slurpfile a "$TMP/an.json" '
  def num: (tonumber? // null) | if type == "number" and . >= 0 then . else null end;
  def clean: with_entries(select(.value != null));
  ([.data[] | select(type == "object" and (.id | type) == "string" and (.id | contains("/")))
     | (.id | split("/")[0] | ascii_downcase) as $v | select($vs | index($v))
     | {vendor: $v, slug: .id, source: "openrouter", source_url: ($or + "/" + .id),
        released_at: (.created | if type == "number" then todate else null end),
        prompt: (.pricing.prompt | num), completion: (.pricing.completion | num),
        cache_read: (.pricing.input_cache_read | num), cache_write: (.pricing.input_cache_write | num),
        context_window: (.context_length | if type == "number" then . else null end)} | clean]
   | sort_by(.slug | contains(":"))),
  ([$a[0].data[]? | select(type == "object" and (.id | type) == "string")
     | {vendor: "anthropic", slug: .id, source: "anthropic", source_url: ($an + "/v1/models"),
        released_at: (.created_at | if type == "string" then . else null end)} | clean])
  | .[]' "$TMP/or.json" > "$TMP/entries.jsonl" 2>/dev/null || : > "$TMP/entries.jsonl"
inc fetched "$(wc -l < "$TMP/entries.jsonl" | tr -d ' ')"

# ── 6. Known set ─────────────────────────────────────────────────────────────
known_ok=1
if model_prices_get "$TMP/prices.json" 2>/dev/null; then
  jq -r '.per_token | keys[]' "$TMP/prices.json" > "$TMP/known.raw" 2>/dev/null || known_ok=0
else
  known_ok=0; note "warn: GET /api/model-prices unreadable"
fi
jq -r '.per_token | keys[]' "$H/catalog/model-prices.json" >> "$TMP/known.raw" 2>/dev/null \
  || { known_ok=0; note "warn: catalog/model-prices.json unreadable"; }
jq -r 'to_entries[] | .key, .value' "$H/catalog/model-slugs.json" >> "$TMP/known.raw" 2>/dev/null \
  || { known_ok=0; note "warn: catalog/model-slugs.json unreadable"; }
LEDGER=""
if [ "$known_ok" = 1 ]; then
  LEDGER=$(mw_get "" "") && jq -e '(.rows | type) == "array"' <<<"$LEDGER" >/dev/null 2>&1 \
    || { known_ok=0; LEDGER=""; note "warn: GET /api/model-watch unreadable"; }
fi
if [ "$known_ok" != 1 ]; then
  alert model-watch-known "model-watch: the known-model set or the model_watch list is unreadable (logs/model-watch.notes.log). Nothing recorded or sent."
  summary known-failed; exit 0
fi
[ "$(jq -r '.truncated // false' <<<"$LEDGER")" = true ] && note "model_watch list truncated at the worker cap; unannounced rows drain oldest first"
declare -A KNOWN=() HAVE=() SEEN=()
while IFS= read -r id; do
  id=$(mw_norm_id "$id") && KNOWN[$id]=1
done < "$TMP/known.raw"
while IFS=$'\t' read -r v m; do HAVE["$v/$m"]=1; done < <(jq -r '.rows[] | [.vendor, .model_id] | @tsv' <<<"$LEDGER")

# ── 7. Record the unknown ────────────────────────────────────────────────────
while IFS= read -r e; do
  IFS=$'\t' read -r vendor slug < <(jq -r '[.vendor, .slug] | @tsv' <<<"$e")
  nid=$(mw_norm_id "$slug") || continue
  [ -z "${SEEN[$vendor/$nid]:-}" ] || continue
  SEEN[$vendor/$nid]=1
  if [ -n "${KNOWN[$nid]:-}" ]; then inc known; continue; fi
  [ -z "${HAVE[$vendor/$nid]:-}" ] || continue
  if out=$(mw_record "$(jq -c --arg m "$nid" '. + {model_id: $m}' <<<"$e")"); then
    [ "$(jq -r '.first // false' <<<"$out" 2>/dev/null)" = true ] && inc recorded
  else
    inc record-failed; note "record-failed $vendor/$nid"
  fi
done < "$TMP/entries.jsonl"

# ── 8. The unannounced rows, oldest first ────────────────────────────────────
LIST=$(mw_get "" "") && jq -e '(.rows | type) == "array"' <<<"$LIST" >/dev/null 2>&1 || {
  alert model-watch-known "model-watch: the model_watch list became unreadable after recording. Nothing sent."
  summary known-failed; exit 0; }
jq -c --argjson vs "$VJSON" '[.rows[] | select(.announced_at == null and .status == "new" and ((.vendor // "") as $v | $vs | index($v)))]
  | sort_by(.first_seen) | .[]' <<<"$LIST" > "$TMP/pending.jsonl"
: > "$TMP/todo.jsonl"
while IFS= read -r r; do
  # A model that reached the catalog since it was recorded is not news any more.
  [ -z "${KNOWN[$(jq -r '.model_id' <<<"$r")]:-}" ] && printf '%s\n' "$r" >> "$TMP/todo.jsonl"
done < "$TMP/pending.jsonl"
total=$(wc -l < "$TMP/todo.jsonl" | tr -d ' ')
[ "$total" -gt "$MAX_NEW" ] && inc deferred "$((total - MAX_NEW))"

# Read once per run: the hub ladders, flattened to the rungs mw_match_routes takes.
LADDERS=$(_jobs_req GET /api/model-routes 2>/dev/null \
  | jq -c '[.roles[] | .role as $r | .ladder[] | {project: null, role: $r, position, model, runner}]' 2>/dev/null) || LADDERS=""
jq -e 'type == "array"' <<<"$LADDERS" >/dev/null 2>&1 || { LADDERS=""; note "warn: GET /api/model-routes unreadable"; }
CLIV=$(_jobs_req GET '/api/metrics/cli-versions?limit=200' 2>/dev/null) || CLIV=""
SINCE=$(date -u -d '7 days ago' +%FT%TZ 2>/dev/null)

while IFS= read -r row; do
  vendor=$(jq -r '.vendor' <<<"$row"); mid=$(jq -r '.model_id' <<<"$row")
  nroutes=0; delta=""
  if [ -n "$LADDERS" ] && routes=$(mw_match_routes "$vendor" "$mid" "$LADDERS"); then
    nroutes=$(jq 'length' <<<"$routes")
    from=$(jq -r '.[0].from // ""' <<<"$routes")
    prices=$(jq -c --argjson r "$routes" '.per_token as $p | reduce ($r[].from) as $f ({}; if $p[$f] then .[$f] = $p[$f] else . end)' "$TMP/prices.json")
    sug=$(jq -nc --argjson r "$routes" --argjson p "$prices" '{routes: $r, prices: $p}')
    if [ "$nroutes" -gt 0 ]; then
      newp=$(jq -c '{prompt, completion, cache_read, cache_write} | with_entries(select(.value != null))' <<<"$row")
      oldp=$(jq -c --arg f "$from" '.per_token[$f] // null' "$TMP/prices.json")
      usage=$(mw_usage "$from" "$SINCE" 2>/dev/null) || usage=""
      delta=$(mw_delta_per_day "$from" "$newp" "$oldp" "$usage" "$mid")
    else
      delta="n/a (no matching route)"
    fi
  else
    sug='{"routes":"unreadable"}'; delta="unknown (routes unreadable)"
  fi
  # The probe: a stored verdict is reused, a lost one stays lost, and an
  # anthropic row is probed only when a route could take it.
  probe=$(jq -r '.probe // ""' <<<"$row")
  if [ -z "$probe" ] && [ "$(jq -r '.probe_attempted_at // ""' <<<"$row")" = "" ]; then
    if [ "$vendor" = anthropic ] && [ "$nroutes" = 0 ]; then
      probe='{"verdict":"not-run","reason":"no matching route"}'
    else
      [ "$vendor" = anthropic ] && inc probed
      probe=$(mw_probe_run "$vendor" "$mid" "$H/state/model-watch/probe/$vendor-$mid" 2>>"$NOTES")
      [ -n "$probe" ] || probe='{"verdict":"not-run","reason":"probe could not run"}'
    fi
  fi
  lag=""
  [ "$vendor" = anthropic ] && lag=$(mw_cli_lag "$(jq -r '.cli // ""' <<<"$probe" 2>/dev/null)" "$CLIV")
  msg=$(mw_message "$row" "$sug" "$delta" "$probe" "$lag") || { note "message-failed $vendor/$mid"; continue; }
  "$H/bin/lane-alert.sh" --severity critical --id "model-watch:$vendor:$mid" model-watch "$msg" >/dev/null 2>&1 || true
  inc announced
  verdict=$(jq -r '.verdict // ""' <<<"$probe" 2>/dev/null)
  status=new
  [ "$nroutes" -gt 0 ] && [ "$verdict" = live ] && status=suggested
  # `suggestion` is the mw_match_routes array: what bin/model-watch-approve.sh
  # reads back (it refuses anything but a non-empty array). Unreadable routes
  # store none.
  if ! mw_set_state "$(jq -nc --arg v "$vendor" --arg m "$mid" --arg t "$(date -u +%FT%TZ)" --arg s "$status" \
      --argjson g "$sug" \
      '{vendor: $v, model_id: $m, announced_at: $t, status: $s}
        + (if ($g.routes | type) == "array" then {suggestion: $g.routes} else {} end)')" >/dev/null; then
    inc stamp-failed; note "warn: stamp-failed $vendor/$mid (sent; the next run re-sends into the open alert id)"
  fi
done < <(head -n "$MAX_NEW" "$TMP/todo.jsonl")

summary
exit 0
