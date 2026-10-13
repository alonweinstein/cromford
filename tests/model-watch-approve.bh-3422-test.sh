#!/bin/bash
# tests/model-watch-approve.bh-3422-test.sh — BH-3428 (BH-3422.3): the approval
# command bin/model-watch-approve.sh, driven for real in a scratch harness.
#
# The script runs as shipped against a fake curl first in PATH. The fake records
# every request as one line `METHOD PATH BODY` in $REQLOG and answers from a
# per-case fixture dir: <key>.body / <key>.code, the key being "METHOD PATH" with
# every non-alphanumeric turned into `_`. A PUT may be overridden per role with
# <key>.<role>.code. With no fixture a GET answers 404 and a POST/PUT 200.
#   P1   live suggested row, two hub roles: price POST (catalog) before the route
#        PUTs; PUT bodies carry actor/reason/expected_version and the new id at the
#        suggested position with the runner kept; last request adopts; rc 0;
#        catalog lines printed; the checkout's catalog files untouched
#   P1b  model-prices 500 -> rc 1, 0 route PUTs, 0 state PUTs
#   P1c  --actor ops -> every PUT carries actor ops
#   P2   probe fallback / not-run / failed -> rc 2, one line, 0 writes
#   P2b  status new / ignored -> rc 2, 0 writes
#   P2c  GET /api/model-watch answers 501 -> rc 1, 0 writes
#   P2d  bad invocation -> rc 2, usage, no request at all
#   P2e  empty suggestion / null prompt price -> rc 2, 0 writes
#   P3   second role's PUT answers 409 -> rc 1, state PUT without status, reason names it
#   P4   one role already on the new id -> exactly 1 route PUT; an adopted row -> rc 2, 0 PUTs
#   P5   --dry-run -> 0 POST, 0 PUT, the would-PUT ladders printed
#   P6   the suggested rung moved to a third model -> no PUT for it, `moved since suggestion, skipped`
#   P7   a project suggestion on an inherited route -> no override created
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin/lib/jobs" "$T/fakebin" "$T/logs" "$T/state" "$T/env" "$T/checkout/catalog"
cp "$DIR/bin/model-watch-approve.sh" "$T/bin/model-watch-approve.sh" || { echo "FAIL: no bin/model-watch-approve.sh"; exit 1; }
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/lib/model-watch.sh" "$DIR/bin/lib/env-path.sh" "$T/bin/" || exit 1
mv "$T/bin/model-watch.sh" "$T/bin/env-path.sh" "$T/bin/lib/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/" || exit 1
cp "$DIR/catalog/model-prices.json" "$DIR/catalog/model-slugs.json" "$T/checkout/catalog/" || exit 1
chmod +x "$T/bin/model-watch-approve.sh"

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
m=GET; body=""; prev=""
for a in "$@"; do
  case "$prev" in -X) m="$a" ;; --data-binary) body="$a" ;; esac
  prev="$a"
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
url="${!#}"; path="${url#"$JOBS_URL"}"
printf '%s %s %s\n' "$m" "$path" "$body" >> "$REQLOG"
k=$(printf '%s %s' "$m" "$path" | tr -c 'A-Za-z0-9' '_')
code=""
if [ -n "$body" ]; then
  role=$(printf '%s' "$body" | jq -r '.role // empty' 2>/dev/null)
  [ -n "$role" ] && [ -f "$FX/$k.$role.code" ] && code=$(cat "$FX/$k.$role.code")
fi
[ -z "$code" ] && [ -f "$FX/$k.code" ] && code=$(cat "$FX/$k.code")
if [ -z "$code" ]; then [ "$m" = GET ] && [ ! -f "$FX/$k.body" ] && code=404 || code=200; fi
if [ -f "$FX/$k.body" ]; then cat "$FX/$k.body"; else printf '{"ok":true}'; fi
printf '\n%s' "$code"
EOF
chmod +x "$T/fakebin/curl"

NEW=claude-sonnet-5-6
OLD=claude-sonnet-5-5
OTHER=claude-haiku-4-5
REQLOG="$T/reqlog"; FX="$T/fx"; OUT="$T/out"
WATCH_PATH='/api/model-watch?status=&vendor=anthropic'

key() { printf '%s %s' "$1" "$2" | tr -c 'A-Za-z0-9' '_'; }
fx() { # fx <method> <path> <code> [body]
  local k; k=$(key "$1" "$2")
  printf '%s' "$3" > "$FX/$k.code"
  [ $# -ge 4 ] && printf '%s' "$4" > "$FX/$k.body"
  return 0
}
fx_role_code() { printf '%s' "$2" > "$FX/$(key PUT /api/model-routes).$1.code"; }
# row [status] [verdict] [suggestion-json] [prompt] — probe and suggestion stored as JSON TEXT
row() {
  local st="${1:-suggested}" v="${2:-live}" sug="${3:-}" pr="${4:-0.000003}"
  [ -n "$sug" ] || sug=$(jq -nc --arg o "$OLD" '[{project:null,role:"stage.plan",position:0,runner:"claude",from:$o},{project:null,role:"stage.review",position:1,runner:"claude",from:$o}]')
  jq -nc --arg id "$NEW" --arg st "$st" --arg v "$v" --arg sug "$sug" --argjson pr "$pr" \
    '{rows:[{vendor:"anthropic",model_id:"claude-opus-5-5",status:"adopted"},
            {vendor:"anthropic",model_id:$id,status:$st,slug:"anthropic/claude-sonnet-5.6",
             prompt:$pr,completion:0.000015,cache_read:3e-7,cache_write:0.00000375,
             probe:({verdict:$v,served:$id,rc:0,cost_usd:0.001}|tojson),suggestion:$sug}]}'
}
ladder() { # ladder <scope_version> <source> <model0> <model1>
  jq -nc --argjson v "$1" --arg s "$2" --arg a "$3" --arg b "$4" \
    '{ladder:[{position:0,model:$a,runner:"claude"},{position:1,model:$b,runner:"codex"}],source:$s,scope_version:$v,hub_scope_version:$v}'
}
reset() {
  scratch_rm "$FX" || exit 1; mkdir -p "$FX"; : > "$REQLOG"
  fx GET "$WATCH_PATH" 200 "$(row)"
  fx GET /api/model-routes/stage.plan 200 "$(ladder 7 hub "$OLD" "$OTHER")"
  fx GET /api/model-routes/stage.review 200 "$(ladder 11 hub "$OTHER" "$OLD")"
}
run() {
  ( cd "$T/checkout" && env PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" HARNESS_SECRET=test \
      JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 REQLOG="$REQLOG" FX="$FX" \
      bash "$T/bin/model-watch-approve.sh" "$@" ) > "$OUT" 2>&1
  echo $?
}
count() { local n; n=$(grep -c "^$1 $2 " "$REQLOG" 2>/dev/null); echo "${n:-0}"; }
writes() { local n; n=$(grep -c '^\(POST\|PUT\) ' "$REQLOG" 2>/dev/null); echo "${n:-0}"; }
bodies() { grep "^$1 $2 " "$REQLOG" | sed "s|^$1 $2 ||"; }
lines() { wc -l < "$OUT" | tr -d ' '; }

# ---- P1: the happy path
reset
cp "$T/checkout/catalog/model-prices.json" "$T/prices.before"; cp "$T/checkout/catalog/model-slugs.json" "$T/slugs.before"
rc=$(run anthropic "anthropic/claude-sonnet-5.6")
[ "$rc" = 0 ] && ok || bad "P1 rc=$rc want 0: $(cat "$OUT")"
pl=$(grep -n '^POST /api/model-prices ' "$REQLOG" | head -1 | cut -d: -f1)
ul=$(grep -n '^PUT /api/model-routes ' "$REQLOG" | head -1 | cut -d: -f1)
[ -n "$pl" ] && [ -n "$ul" ] && [ "$pl" -lt "$ul" ] && ok || bad "P1 price POST (line ${pl:-none}) not before first route PUT (line ${ul:-none})"
bodies POST /api/model-prices | jq -e --arg id "$NEW" '.source=="catalog" and .rows[0].model==$id and .rows[0].prompt==0.000003 and .rows[0].slug=="anthropic/claude-sonnet-5.6"' >/dev/null && ok || bad "P1 price body: $(bodies POST /api/model-prices)"
[ "$(count PUT /api/model-routes)" = 2 ] && ok || bad "P1 want 2 route PUTs, got $(count PUT /api/model-routes)"
bodies PUT /api/model-routes | jq -se --arg id "$NEW" --arg o "$OLD" --arg x "$OTHER" '
  length==2 and all(.[]; .actor=="operator" and (.reason|test("^model-watch: " + $o + " -> " + $id + " approved$")) and (.expected_version|type)=="number" and has("project")==false and has("expected_hub_version")==false)
  and (map(select(.role=="stage.plan"))[0] | .expected_version==7 and .ladder==[{model:$id,runner:"claude"},{model:$x,runner:"codex"}])
  and (map(select(.role=="stage.review"))[0] | .expected_version==11 and .ladder==[{model:$x,runner:"claude"},{model:$id,runner:"codex"}])' >/dev/null \
  && ok || bad "P1 route PUT bodies: $(bodies PUT /api/model-routes)"
last=$(tail -1 "$REQLOG")
case "$last" in "PUT /api/model-watch/state "*) ok ;; *) bad "P1 last request is not the state PUT: $last" ;; esac
printf '%s' "${last#PUT /api/model-watch/state }" | jq -e --arg id "$NEW" '.status=="adopted" and .vendor=="anthropic" and .model_id==$id and .actor=="operator"' >/dev/null && ok || bad "P1 state body: $last"
grep -q 'catalog/model-prices.json' "$OUT" && grep -q 'catalog/model-slugs.json' "$OUT" && ok || bad "P1 stdout names no catalog files: $(cat "$OUT")"
grep -qF "\"$NEW\": {\"prompt\":0.000003," "$OUT" && grep -qF "\"$NEW\": \"anthropic/claude-sonnet-5.6\"" "$OUT" && ok || bad "P1 catalog lines missing: $(cat "$OUT")"
cmp -s "$T/prices.before" "$T/checkout/catalog/model-prices.json" && cmp -s "$T/slugs.before" "$T/checkout/catalog/model-slugs.json" && ok || bad "P1 catalog files changed"
grep -qE '(^|[;&|[:space:]])git ' "$DIR/bin/model-watch-approve.sh" && bad "P1 the script runs git" || ok

# ---- P1b: price POST fails -> nothing else is written
reset; fx POST /api/model-prices 500 '{"error":"boom"}'
rc=$(run anthropic "$NEW")
[ "$rc" = 1 ] && ok || bad "P1b rc=$rc want 1"
[ "$(count PUT /api/model-routes)" = 0 ] && [ "$(count PUT /api/model-watch/state)" = 0 ] && ok || bad "P1b writes after a failed price POST: $(cat "$REQLOG")"
grep -q '500' "$OUT" && ok || bad "P1b output does not name the 500: $(cat "$OUT")"

# ---- P1c: --actor
reset
rc=$(run anthropic "$NEW" --actor ops)
[ "$rc" = 0 ] && ok || bad "P1c rc=$rc"
[ "$(bodies PUT /api/model-routes | jq -s 'map(select(.actor=="ops"))|length')" = 2 ] && bodies PUT /api/model-watch/state | jq -e '.actor=="ops"' >/dev/null && ok || bad "P1c actor not carried: $(cat "$REQLOG")"

# ---- P2: probe verdict not live
for v in fallback not-run failed; do
  reset; fx GET "$WATCH_PATH" 200 "$(row suggested "$v")"
  rc=$(run anthropic "$NEW")
  [ "$rc" = 2 ] && ok || bad "P2 $v rc=$rc want 2"
  [ "$(lines)" = 1 ] && ok || bad "P2 $v want one line, got: $(cat "$OUT")"
  [ "$(writes)" = 0 ] && ok || bad "P2 $v wrote: $(cat "$REQLOG")"
done

# ---- P2b: status not suggested
for st in new ignored; do
  reset; fx GET "$WATCH_PATH" 200 "$(row "$st")"
  rc=$(run anthropic "$NEW")
  [ "$rc" = 2 ] && [ "$(writes)" = 0 ] && [ "$(lines)" = 1 ] && ok || bad "P2b $st rc=$rc writes=$(writes): $(cat "$OUT")"
done

# ---- P2c: the contract stub answers 501
reset; fx GET "$WATCH_PATH" 501 '{"error":"not implemented"}'
rc=$(run anthropic "$NEW")
[ "$rc" = 1 ] && [ "$(writes)" = 0 ] && ok || bad "P2c rc=$rc writes=$(writes)"
grep -q 'row read failed' "$OUT" && ok || bad "P2c output: $(cat "$OUT")"

# ---- P2d: bad invocations
for args in "anthropic" "" "anthropic $NEW --actor" "anthropic $NEW --bogus" "anthropic $NEW extra"; do
  reset
  # shellcheck disable=SC2086
  rc=$(run $args)
  [ "$rc" = 2 ] && [ ! -s "$REQLOG" ] && grep -q '^usage:' "$OUT" && ok || bad "P2d '$args' rc=$rc requests=$(wc -l < "$REQLOG"): $(cat "$OUT")"
done
reset; rc=$(run anthropic "$NEW" --actor "")
[ "$rc" = 2 ] && [ ! -s "$REQLOG" ] && ok || bad "P2d empty actor rc=$rc"

# ---- P2e: nothing to switch to / no price
reset; fx GET "$WATCH_PATH" 200 "$(row suggested live '[]')"
rc=$(run anthropic "$NEW")
[ "$rc" = 2 ] && [ "$(writes)" = 0 ] && ok || bad "P2e empty suggestion rc=$rc writes=$(writes)"
reset; fx GET "$WATCH_PATH" 200 "$(row suggested live "" null)"
rc=$(run anthropic "$NEW")
[ "$rc" = 2 ] && [ "$(writes)" = 0 ] && ok || bad "P2e null prompt rc=$rc writes=$(writes)"
reset; rc=$(run anthropic claude-sonnet-9-9)
[ "$rc" = 2 ] && [ "$(writes)" = 0 ] && ok || bad "P2e no such row rc=$rc writes=$(writes)"

# ---- P3: one role's PUT is stale
reset; fx_role_code stage.review 409
rc=$(run anthropic "$NEW")
[ "$rc" = 1 ] && ok || bad "P3 rc=$rc want 1"
[ "$(count PUT /api/model-routes)" = 2 ] && ok || bad "P3 want both roles attempted"
st=$(bodies PUT /api/model-watch/state)
printf '%s' "$st" | jq -e 'has("status")==false and (.reason|test("stage.review")) and (.reason|test("409"))' >/dev/null && ok || bad "P3 state body: $st"
grep -q 'stage.review.*409' "$OUT" && ok || bad "P3 output: $(cat "$OUT")"

# ---- P4: a re-run after that partial, and a re-run after adoption
reset; fx GET /api/model-routes/stage.plan 200 "$(ladder 8 hub "$NEW" "$OTHER")"
rc=$(run anthropic "$NEW")
[ "$rc" = 0 ] && ok || bad "P4 rc=$rc: $(cat "$OUT")"
[ "$(count PUT /api/model-routes)" = 1 ] && bodies PUT /api/model-routes | jq -e '.role=="stage.review"' >/dev/null && ok || bad "P4 want exactly the stage.review PUT: $(bodies PUT /api/model-routes)"
bodies PUT /api/model-watch/state | jq -e '.status=="adopted"' >/dev/null && ok || bad "P4 not adopted"
grep -q "stage.plan.*already on $NEW" "$OUT" && ok || bad "P4 output: $(cat "$OUT")"
reset; fx GET "$WATCH_PATH" 200 "$(row adopted)"
rc=$(run anthropic "$NEW")
[ "$rc" = 2 ] && [ "$(writes)" = 0 ] && grep -q 'already adopted' "$OUT" && ok || bad "P4 adopted re-run rc=$rc writes=$(writes): $(cat "$OUT")"

# ---- P5: dry run
reset
rc=$(run anthropic "$NEW" --dry-run)
[ "$rc" = 0 ] && [ "$(writes)" = 0 ] && ok || bad "P5 rc=$rc writes=$(writes)"
[ "$(count GET /api/model-routes/stage.plan)" = 1 ] && ok || bad "P5 did not read the ladders"
grep -q "would PUT /api/model-routes .*\"$NEW\"" "$OUT" && grep -q 'would POST /api/model-prices' "$OUT" && ok || bad "P5 output: $(cat "$OUT")"

# ---- P6: the suggested rung moved to a third model
reset; fx GET /api/model-routes/stage.plan 200 "$(ladder 9 hub "$OTHER" "$OTHER")"
rc=$(run anthropic "$NEW")
[ "$(count PUT /api/model-routes)" = 1 ] && bodies PUT /api/model-routes | jq -e '.role=="stage.review"' >/dev/null && ok || bad "P6 want only stage.review PUT: $(bodies PUT /api/model-routes)"
grep -q 'stage.plan.*moved since suggestion, skipped' "$OUT" && ok || bad "P6 output: $(cat "$OUT")"
# ... and every group moved: nothing routes to the model, so the row is not adopted
reset
fx GET /api/model-routes/stage.plan 200 "$(ladder 9 hub "$OTHER" "$OTHER")"
fx GET /api/model-routes/stage.review 200 "$(ladder 9 hub "$OTHER" "$OTHER")"
rc=$(run anthropic "$NEW")
[ "$rc" = 1 ] && [ "$(count PUT /api/model-routes)" = 0 ] && ok || bad "P6 all-moved rc=$rc puts=$(count PUT /api/model-routes)"
bodies PUT /api/model-watch/state | jq -e 'has("status")==false' >/dev/null && ok || bad "P6 all-moved adopted the row"

# ---- P7: project suggestions — an own override is rewritten under both guards, an inherited one is skipped
SUG=$(jq -nc --arg o "$OLD" '[{project:"project-3",role:"stage.plan",position:0,runner:"claude",from:$o},{project:"project-4",role:"stage.plan",position:0,runner:"claude",from:$o}]')
reset; fx GET "$WATCH_PATH" 200 "$(row suggested live "$SUG")"
fx GET '/api/model-routes/stage.plan?project=project-3' 200 "$(ladder 3 project "$OLD" "$OTHER" | jq -c '.hub_scope_version=7')"
fx GET '/api/model-routes/stage.plan?project=project-4' 200 "$(ladder 0 hub "$OLD" "$OTHER" | jq -c '.hub_scope_version=7')"
rc=$(run anthropic "$NEW")
[ "$rc" = 0 ] && ok || bad "P7 rc=$rc: $(cat "$OUT")"
[ "$(count PUT /api/model-routes)" = 1 ] && bodies PUT /api/model-routes | jq -e '.project=="project-3" and .expected_version==3 and .expected_hub_version==7' >/dev/null && ok || bad "P7 PUTs: $(bodies PUT /api/model-routes)"
grep -q 'project-4.*inherited from hub, skipped' "$OUT" && ok || bad "P7 output: $(cat "$OUT")"

echo "model-watch-approve.bh-3422-test: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
