#!/bin/bash
# bin/model-watch-approve.sh — BH-3428 (BH-3422.3): approve a model the
# model-watch lane suggested, and switch the routes it named onto it.
#
# usage: model-watch-approve.sh <vendor> <model-id> [--dry-run] [--actor <name>]
#
# The ONLY writer of model_routes in the model-watch feature: the lane suggests,
# a human runs this. It reads the row through mw_get (bin/lib/model-watch.sh)
# and refuses, rc 2 and one line, unless the row is `suggested` with a `live`
# probe, a non-empty suggestion and a prompt/completion price. Then, in order:
#   1. POST /api/model-prices {source:"catalog"} — insert-only, and it must come
#      first: PUT /api/model-routes answers 400 for a model with no price row.
#   2. per (project, role) in the suggestion: GET the ladder, replace only the
#      suggested rungs still on `from` (a rung already on the new id is done, any
#      other model is `moved since suggestion, skipped`), and PUT the whole ladder
#      under expected_version (and expected_hub_version on a project write). A
#      project whose route is inherited from the hub is skipped: no override is
#      created for it.
#   3. mw_set_state LAST: `adopted` only when no read or PUT failed and at least
#      one route is on the new id; otherwise the per-route results go into
#      `reason`, the row stays `suggested`, rc 1. Re-running converges.
# It then prints the catalog/model-prices.json and catalog/model-slugs.json
# lines for the operator's PR. It never writes or commits the repo.
# --dry-run does the reads and prints every write it would make; zero writes.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"

usage() { echo "usage: model-watch-approve.sh <vendor> <model-id> [--dry-run] [--actor <name>]" >&2; exit 2; }
VENDOR=""; WANT=""; DRY=0; ACTOR=operator; NPOS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --actor) [ $# -ge 2 ] && [ -n "$2" ] || usage; ACTOR="$2"; shift ;;
    -*) usage ;;
    *) NPOS=$((NPOS+1)); case "$NPOS" in 1) VENDOR="$1" ;; 2) WANT="$1" ;; *) usage ;; esac ;;
  esac
  shift
done
[ -n "$VENDOR" ] && [ -n "$WANT" ] || usage
VENDOR=$(printf '%s' "$VENDOR" | tr '[:upper:]' '[:lower:]')

. "$HARNESS/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$HARNESS}/env"; }
HENV=$(harness_env_dir "$HARNESS")
set -a
[ -f "$HENV/global.env" ] && . "$HENV/global.env"
set +a
# shellcheck disable=SC1091
. "$HARNESS/bin/jobs-client.sh" || { echo "model-watch-approve: cannot load $HARNESS/bin/jobs-client.sh" >&2; exit 1; }
# shellcheck disable=SC1091
. "$HARNESS/bin/lib/model-watch.sh" || { echo "model-watch-approve: cannot load $HARNESS/bin/lib/model-watch.sh" >&2; exit 1; }

refuse() { echo "model-watch-approve: $*" >&2; exit 2; }
KEY=$(mw_norm_id "$WANT") || usage
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mw-approve.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# ---- the row, and the gate
# mw_get runs _jobs_req in a subshell, so the HTTP status is not visible here;
# the transport logs it to logs/jobs-client.log.
ROWS=$(mw_get "" "$VENDOR") || { echo "model-watch-approve: row read failed (worker answered non-2xx or was unreachable; see $HARNESS/logs/jobs-client.log)" >&2; exit 1; }
MATCH=()
while IFS= read -r r; do
  [ -n "$r" ] || continue
  [ "$(mw_norm_id "$(printf '%s' "$r" | jq -r '.model_id // empty')")" = "$KEY" ] && MATCH+=("$r")
done < <(printf '%s' "$ROWS" | jq -c --arg v "$VENDOR" \
  '(if type=="array" then . else (.rows // []) end)[] | select(((.vendor // "")|ascii_downcase)==$v)' 2>/dev/null)
[ "${#MATCH[@]}" -gt 0 ] || refuse "no $VENDOR row for $WANT"
[ "${#MATCH[@]}" -eq 1 ] || refuse "${#MATCH[@]} $VENDOR rows normalize to $KEY; refusing to pick one"
ROW=$(printf '%s' "${MATCH[0]}" | jq -c 'def obj: if type=="string" then (fromjson? // null) else . end;
  .probe |= obj | .suggestion |= obj')
MID=$(printf '%s' "$ROW" | jq -r '.model_id')
STATUS=$(printf '%s' "$ROW" | jq -r '.status // "none"')
case "$STATUS" in
  suggested) ;;
  adopted) refuse "$MID is already adopted" ;;
  *) refuse "$MID is $STATUS, not suggested" ;;
esac
VERDICT=$(printf '%s' "$ROW" | jq -r '.probe.verdict? // "none"')
[ "$VERDICT" = live ] || refuse "$MID probe verdict is $VERDICT, not live"
printf '%s' "$ROW" | jq -e '(.suggestion|type)=="array" and (.suggestion|length)>0' >/dev/null || refuse "$MID has no route suggestion"
printf '%s' "$ROW" | jq -e '(.prompt|type)=="number" and (.completion|type)=="number"' >/dev/null || refuse "$MID has no prompt/completion price; it would be priced at \$0"

# ---- 1. the price row, before any route write
PRICE=$(printf '%s' "$ROW" | jq -c '{source:"catalog", rows:[{model:.model_id, slug, prompt, completion, cache_read, cache_write}]}')
if [ "$DRY" = 1 ]; then
  echo "would POST /api/model-prices $PRICE"
else
  _jobs_req POST /api/model-prices "$PRICE" > "$TMP/price"
  prc=$?
  [ "$prc" = 0 ] || { echo "model-watch-approve: POST /api/model-prices failed (HTTP ${JOBS_HTTP:-no answer}); no route touched" >&2; exit 1; }
fi

# ---- 2. the routes, one guarded PUT per (project, role)
RESULTS=(); FAILED=0; DONE=0; FROM=""
while IFS= read -r g; do
  role=$(printf '%s' "$g" | jq -r '.role')
  proj=$(printf '%s' "$g" | jq -r '.project // empty')
  rungs=$(printf '%s' "$g" | jq -c '.rungs')
  gfrom=$(printf '%s' "$rungs" | jq -r '.[0].from // ""')
  [ -n "$FROM" ] || FROM="$gfrom"
  scope="hub"; path="/api/model-routes/$(_mw_uri "$role")"
  [ -n "$proj" ] && { scope="project $proj"; path="$path?project=$(_mw_uri "$proj")"; }
  label="$scope $role"
  _jobs_req GET "$path" > "$TMP/ladder"
  if [ $? -ne 0 ]; then
    RESULTS+=("$label: read failed (HTTP ${JOBS_HTTP:-no answer})"); FAILED=1; continue
  fi
  if [ -n "$proj" ] && [ "$(jq -r '.source // ""' "$TMP/ladder")" != project ]; then
    RESULTS+=("$label: inherited from hub, skipped"); continue
  fi
  plan=$(jq -c --arg id "$MID" --argjson rungs "$rungs" '
    reduce $rungs[] as $r ({ladder: ((.ladder // []) | sort_by(.position)), replaced: 0, already: 0, moved: 0};
      ($r.position | tonumber? // null) as $p
      | ([.ladder[] | select(.position == $p)] | .[0]) as $cur
      | if $cur == null or $p == null then .moved += 1
        elif $cur.model == $id then .already += 1
        elif $cur.model == $r.from then .replaced += 1 | .ladder |= map(if .position == $p then .model = $id else . end)
        else .moved += 1 end)' "$TMP/ladder") || { RESULTS+=("$label: unreadable ladder"); FAILED=1; continue; }
  replaced=$(printf '%s' "$plan" | jq -r '.replaced')
  if [ "$replaced" = 0 ]; then
    if [ "$(printf '%s' "$plan" | jq -r '.already')" != 0 ]; then
      RESULTS+=("$label: already on $MID"); DONE=$((DONE+1))
    else
      RESULTS+=("$label: moved since suggestion, skipped")
    fi
    continue
  fi
  body=$(jq -c --arg role "$role" --arg proj "$proj" --arg actor "$ACTOR" \
      --arg reason "model-watch: $gfrom -> $MID approved" --argjson plan "$plan" '
    {role: $role, ladder: ($plan.ladder | map({model, runner})), expected_version: .scope_version, actor: $actor, reason: $reason}
    + (if $proj == "" then {} else {project: $proj, expected_hub_version: .hub_scope_version} end)' "$TMP/ladder")
  if [ "$DRY" = 1 ]; then
    echo "would PUT /api/model-routes $body"
    RESULTS+=("$label: would switch"); DONE=$((DONE+1)); continue
  fi
  _jobs_req PUT /api/model-routes "$body" > "$TMP/put"
  case $? in
    0) RESULTS+=("$label: switched"); DONE=$((DONE+1)) ;;
    9) RESULTS+=("$label: 409 stale, not switched"); FAILED=1 ;;
    *) RESULTS+=("$label: HTTP ${JOBS_HTTP:-no answer}, not switched"); FAILED=1 ;;
  esac
done < <(printf '%s' "$ROW" | jq -c '.suggestion
  | group_by([(.project // ""), .role])[]
  | {project: (.[0].project // null), role: .[0].role, rungs: map({position, from})}')
printf '%s\n' "${RESULTS[@]}"
SUMMARY=$(IFS=';'; printf '%s' "${RESULTS[*]}" | sed 's/;/; /g')

catalog_lines() {
  echo "for the catalog PR (this script does not write the repo):"
  printf '  catalog/model-prices.json per_token: %s\n' \
    "$(printf '%s' "$ROW" | jq -c '{(.model_id): {prompt, completion, cache_read, cache_write, slug}}' | sed 's/^{//; s/}$//; s/":{/": {/')"
  if [ "$(printf '%s' "$ROW" | jq -r '.slug // empty')" ]; then
    printf '  catalog/model-slugs.json: %s\n' "$(printf '%s' "$ROW" | jq -c '{(.model_id): .slug}' | sed 's/^{//; s/}$//; s/":"/": "/')"
  else
    echo "  catalog/model-slugs.json: no slug recorded; add the model-slugs line by hand"
  fi
}

if [ "$DRY" = 1 ]; then
  echo "dry run: nothing written; would $([ "$FAILED" = 0 ] && [ "$DONE" -gt 0 ] && echo "mark $MID adopted" || echo "leave $MID suggested")"
  catalog_lines
  exit 0
fi

# ---- 3. the row, last
if [ "$FAILED" = 0 ] && [ "$DONE" -gt 0 ]; then
  st=$(jq -nc --arg v "$VENDOR" --arg m "$MID" --arg a "$ACTOR" --arg r "approved ${FROM:+$FROM -> }$MID: $SUMMARY" \
    '{vendor:$v, model_id:$m, status:"adopted", actor:$a, reason:$r}')
  if ! mw_set_state "$st" >/dev/null; then
    echo "routes switched, row NOT marked adopted; re-run to finish"
    exit 1
  fi
  echo "routes switched; $MID adopted"
  catalog_lines
  exit 0
fi
st=$(jq -nc --arg v "$VENDOR" --arg m "$MID" --arg a "$ACTOR" --arg r "approve incomplete: $SUMMARY" \
  '{vendor:$v, model_id:$m, actor:$a, reason:$r}')
mw_set_state "$st" >/dev/null || echo "model-watch-approve: the per-route results were not written to the row either" >&2
echo "not adopted: $MID stays suggested; fix the routes above and re-run"
exit 1
