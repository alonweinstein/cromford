#!/bin/bash
# tests/utilization-pauses-prs.bh-4010-test.sh — BH-4010 (BH-3988 slice 3): the
# pauses and prs sections of a utilization snapshot,
# bin/lib/utilization/section-pauses.sh and bin/lib/utilization/section-prs.sh.
#
# Runs the REAL collector bin/utilization-push.sh from a scratch $HARNESS (a
# symlink copy of bin/ and catalog/) with the real jobs-client.sh, and asserts
# on the captured PUT payload. Stubbed: fleet-conf.sh (fx-a → example-org/fx-a,
# fx-b → example-org/fx-b, or `-` under FAKE_NO_REPO=fx-b), concurrency-plan.sh,
# and curl, which serves fixture files from $FX and logs every request as
# `<METHOD> <path>` in $H/calls.txt:
#   /api/pauses          $FX/pauses.json   (FAKE_PAUSES_CODE)
#   /api/conductor/held  $FX/held.json     (FAKE_HELD_CODE)
#   /api/merge-queue     $FX/mq-<project>.json, {"merge_queue":[]} without one (FAKE_MQ_CODE)
#   /api/pr-state        $FX/prs-<repo>-<before|first>.json, 404 without one (FAKE_PRS_CODE)
#   a fixture file holding just `@500` answers 500
#   /api/jobs            one running build; PUT /api/utilization is recorded
#   anything else        404 (so flag_sync leaves flags/ alone)
#
#   P0 both section sources exist
#   A1 flags/paused-fx-a: fx-a pauses[0], since = mtime, stops_builds true; not in fx-b
#   A2 flags/automerge-disabled: both projects, stops_builds false
#   A3 flags/all-off: stops_builds true
#   A4 fleet/builds pause in both; fx-b/triage only in fx-b, true; a pauses
#      body over the 128 KiB argv cap is still read, measured
#   A5 fleet/merges and fx-a/reviews pauses: stops_builds false
#   A6 a conductor hold on example-org/fx-a: only in fx-a, kind hold, false
#   A7 /api/pauses 500 (and 404, and truncated, and held truncated or 500):
#      basis.pauses unmeasured, flag pauses still listed, the row still PUT
#   A8 every non-PUT request is a GET
#   B1 merge_queue counts the queued rows, and the read asks for status=queued
#   B2 review/ci through the state-to-bucket table, measured
#   B3 /api/pr-state 404 / 500: review and ci null (not 0), unmeasured
#   B4 pr-state-rows off: null, unmeasured, no /api/pr-state request
#   B5 a merge queue answer of exactly 500 rows: null, unmeasured; 500 error: null
#   B6 a full production-width first page (over the 128 KiB argv cap) then
#      404: counted from page 1, measured, page 2 asked
#      with before=<min id>; every page full: null after 5 pages
#   B7 a project with no repo: review/ci null, pauses still measured
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/utilization-pauses-prs.bh-4010-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2', wanted '$3'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# ── P0 ──────────────────────────────────────────────────────────────────────
PAUSES_SRC="$DIR/bin/lib/utilization/section-pauses.sh"
PRS_SRC="$DIR/bin/lib/utilization/section-prs.sh"
[ -r "$DIR/bin/utilization-push.sh" ] || { echo "FAIL: the collector is missing"; exit 1; }
for f in "$PAUSES_SRC" "$PRS_SRC"; do
  [ -r "$f" ] && ok || bad "P0 $f is missing"
done

# ── the scratch harness ─────────────────────────────────────────────────────
H="$T/h"; FX="$T/fx"
mkdir -p "$H/flags" "$H/logs" "$T/stub" "$T/env" "$FX"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/catalog" "$H/catalog"
rm -f "$H/catalog/lanes.json"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" > "$H/catalog/lanes.json" 2> "$T/build.err" \
  || bad "setup: bin/lanes-build.sh failed: $(cat "$T/build.err")"
rm -f "$H/bin/fleet-conf.sh" "$H/bin/concurrency-plan.sh"
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${1:-}" in
  --projects) printf 'fx-a\nfx-b\n' ;;
  fx-a|fx-b)
    [ "${2:-}" = repo ] || exit 1
    if [ "${FAKE_NO_REPO:-}" = "$1" ]; then echo -; else echo "example-org/$1"; fi ;;
  *) exit 1 ;;
esac
SH
cat > "$H/bin/concurrency-plan.sh" <<'SH'
#!/bin/bash
printf '[{"project":"%s","effective":"5","bound_by":"fixture"}]\n' "$1"
SH
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
M=GET; D=""; U=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) M="$2"; shift 2 ;;
    --data-binary) D="$2"; shift 2 ;;
    -m|--connect-timeout|-w|-H) shift 2 ;;
    -*) shift ;;
    *) U="$1"; shift ;;
  esac
done
P="${U#http://jobs.test}"
echo "$M $P" >> "$HARNESS/calls.txt"
serve() { # serve <file> <code>: the file (or a 404) with the code
  if [ "$2" != 200 ]; then printf '{"error":"fixture"}\n%s' "$2"
  elif [ "$(cat "$1" 2>/dev/null)" = "@500" ]; then printf '{"error":"fixture"}\n500'
  elif [ -f "$1" ]; then cat "$1"; printf '\n200'
  else printf '{"error":"no rows"}\n404'; fi
}
qv() { printf '%s' "$P" | tr '?&' '\n\n' | sed -n "s/^$1=//p" | head -1; }
case "$M $P" in
  "GET /api/pauses?"*) serve "$FX/pauses.json" "${FAKE_PAUSES_CODE:-200}" ;;
  "GET /api/conductor/held?"*) serve "$FX/held.json" "${FAKE_HELD_CODE:-200}" ;;
  "GET /api/merge-queue?"*)
    f="$FX/mq-$(qv project).json"
    [ -f "$f" ] || { f="$FX/mq-empty.json"; echo '{"merge_queue":[]}' > "$f"; }
    serve "$f" "${FAKE_MQ_CODE:-200}" ;;
  "GET /api/pr-state?"*)
    b=$(qv before); r=$(qv repo)
    serve "$FX/prs-${r//%2F/_}-${b:-first}.json" "${FAKE_PRS_CODE:-200}" ;;
  "GET /api/jobs?"*) printf '{"jobs":[{"id":"j1","status":"running","kind":"build"}]}\n200' ;;
  "PUT /api/utilization")
    case "$D" in @*) D=$(cat "${D#@}") ;; esac
    printf '%s\n' "$D" >> "$HARNESS/puts.jsonl"
    printf '{"ok":true}\n200' ;;
  *) printf '{"error":"unknown endpoint"}\n404' ;;
esac
SH
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/concurrency-plan.sh" "$T/stub/curl"

run_lane() {
  rm -f "$H/puts.jsonl" "$H/calls.txt"
  env -i PATH="$T/stub:$PATH" HOME="$T" HARNESS="$H" FX="$FX" HARNESS_ENV_DIR="$T/env" HARNESS_TEST_SANDBOX=1 \
    JOBS_URL=http://jobs.test HARNESS_SECRET=s3cret JOBS_BOX=hub-fixture JOBS_RETRY_SLEEP=0 "$@" \
    bash "$H/bin/utilization-push.sh" > "$T/lane.out" 2> "$T/lane.err"
}
pl() { jq -c --arg p "$1" "select(.project==\$p) | .payload | $2" "$H/puts.jsonl" 2>/dev/null; }
nputs() { if [ -f "$H/puts.jsonl" ]; then awk 'NF' "$H/puts.jsonl" | wc -l | tr -d ' '; else echo 0; fi; }

# The baseline fixtures: nothing paused, nothing held, nothing queued, and a
# small pr_state page per repo.
reset_fx() {
  rm -f "$FX"/*.json "$H/flags"/*
  echo '{"pauses":[],"truncated":false}' > "$FX/pauses.json"
  echo '{"rows":[],"n_total":0}' > "$FX/held.json"
  for r in fx-a fx-b; do
    jq -nc --arg r "example-org/$r" '{rows:[{id:5,repo:$r,number:1,state:"MERGED"}]}' > "$FX/prs-example-org_$r-first.json"
  done
  touch "$H/flags/pr-state-rows"
}

# ── A1 / A2 / A3 ────────────────────────────────────────────────────────────
reset_fx
touch -d '2026-10-01T05:06:07Z' "$H/flags/paused-fx-a"
touch -d '2026-10-02T01:02:03Z' "$H/flags/automerge-disabled"
run_lane; rc=$?
eq "A1 rc" "$rc" 0
eq "A1 PUT count" "$(nputs)" 2
eq "A1 paused-fx-a is pauses[0]" "$(pl fx-a '.pauses[0]')" \
  '{"kind":"flag","name":"paused-fx-a","since":"2026-10-01T05:06:07Z","stops_builds":true}'
eq "A1 fx-b has no paused-fx-a" "$(pl fx-b '[.pauses[]|select(.name=="paused-fx-a")]|length')" 0
eq "A1 basis measured" "$(pl fx-a '.basis.pauses')" '"measured"'
for p in fx-a fx-b; do
  eq "A2 $p automerge-disabled" "$(pl "$p" '[.pauses[]|select(.name=="automerge-disabled")]')" \
    '[{"kind":"flag","name":"automerge-disabled","since":"2026-10-02T01:02:03Z","stops_builds":false}]'
done
# all-off stops the lane at the shared gate, so the gate is disabled here, the
# way P8 of the BH-4008 suite reaches the lane's own checks.
touch -d '2026-10-03T00:00:00Z' "$H/flags/all-off"
run_lane LANE_GATE_DISABLE=1
for p in fx-a fx-b; do
  eq "A3 $p all-off" "$(pl "$p" '[.pauses[]|select(.name=="all-off")|.stops_builds]')" '[true]'
done

# ── A4 / A5 ─────────────────────────────────────────────────────────────────
reset_fx
jq -nc '{truncated:false, pauses:[
  {id:4,scope:"fleet",what:"builds",created_at:"2026-10-03T01:00:00Z",expires_at:"2099-01-01T00:00:00Z"},
  {id:3,scope:"fx-b",what:"triage",created_at:"2026-10-03T02:00:00Z",expires_at:"2099-01-01T00:00:00Z"},
  {id:2,scope:"fleet",what:"merges",created_at:"2026-10-03T03:00:00Z",expires_at:"2099-01-01T00:00:00Z"},
  {id:1,scope:"fx-a",what:"reviews",created_at:"2026-10-03T04:00:00Z",expires_at:"2099-01-01T00:00:00Z"}]}' > "$FX/pauses.json"
run_lane
for p in fx-a fx-b; do
  eq "A4 $p fleet/builds" "$(pl "$p" '[.pauses[]|select(.name=="fleet/builds")]')" \
    '[{"kind":"pause","name":"fleet/builds","since":"2026-10-03T01:00:00Z","stops_builds":true}]'
  eq "A5 $p fleet/merges" "$(pl "$p" '[.pauses[]|select(.name=="fleet/merges")|.stops_builds]')" '[false]'
done
eq "A4 fx-b/triage in fx-b" "$(pl fx-b '[.pauses[]|select(.name=="fx-b/triage")|[.kind,.since,.stops_builds]]')" \
  '[["pause","2026-10-03T02:00:00Z",true]]'
eq "A4 fx-b/triage not in fx-a" "$(pl fx-a '[.pauses[]|select(.name=="fx-b/triage")]|length')" 0
# A production-width active list (reason runs to 512 chars) is over the 128 KiB
# argv cap; the section still reads it and stays measured.
jq -nc '{truncated:false, pauses:[range(0;400) as $i | {id:(1000+$i), scope:"fx-b", what:"reviews",
  reason:("r" * 500), actor:"operator", created_at:"2026-10-03T05:00:00Z", expires_at:"2099-01-01T00:00:00Z",
  ended_at:null, end_reason:null}]}' > "$FX/pauses-wide.json"
jq -c '.pauses += input.pauses' "$FX/pauses.json" "$FX/pauses-wide.json" > "$FX/pauses-all.json"
mv "$FX/pauses-all.json" "$FX/pauses.json"
eq "A4 the wide pauses body is over the argv cap" "$([ "$(wc -c < "$FX/pauses.json")" -gt 131072 ] && echo yes)" yes
run_lane
eq "A4 wide pauses: fx-b lists all of them" "$(pl fx-b '[([.pauses[]|select(.name=="fx-b/reviews")]|length),.basis.pauses]')" '[400,"measured"]'
eq "A4 wide pauses: fx-a still measured" "$(pl fx-a '[([.pauses[]|select(.kind=="pause")]|length),.basis.pauses]')" '[3,"measured"]'
eq "A5 fx-a/reviews false" "$(pl fx-a '[.pauses[]|select(.name=="fx-a/reviews")|.stops_builds]')" '[false]'
eq "A5 fx-a/reviews not in fx-b" "$(pl fx-b '[.pauses[]|select(.name=="fx-a/reviews")]|length')" 0
eq "A4 only live pauses are asked for" "$(grep -c '^GET /api/pauses?active=1$' "$H/calls.txt")" 2

# ── A6 ──────────────────────────────────────────────────────────────────────
reset_fx
jq -nc '{n_total:2, rows:[
  {repo:"example-org/fx-a",number:7,state:"BLOCKED_HUMAN",head:"abc",kind:"x",text:"t",mark:"",mode:"m",first_held_at:"2026-10-02T09:00:00Z",last_seen_at:"2026-10-03T09:00:00Z"},
  {repo:"example-org/other",number:8,state:"BLOCKED_HUMAN",head:"def",kind:"y",text:"",mark:"",mode:"m",first_held_at:"2026-10-02T10:00:00Z",last_seen_at:"2026-10-03T09:00:00Z"}]}' > "$FX/held.json"
run_lane
eq "A6 fx-a hold" "$(pl fx-a '[.pauses[]|select(.kind=="hold")]')" \
  '[{"kind":"hold","name":"example-org/fx-a#7 x","since":"2026-10-02T09:00:00Z","stops_builds":false}]'
eq "A6 fx-b has no hold" "$(pl fx-b '[.pauses[]|select(.kind=="hold")]|length')" 0
eq "A6 basis measured" "$(pl fx-a '.basis.pauses')" '"measured"'

# ── A7 ──────────────────────────────────────────────────────────────────────
reset_fx
touch -d '2026-10-01T05:06:07Z' "$H/flags/paused-fx-a"
for code in 500 404; do
  run_lane FAKE_PAUSES_CODE=$code
  eq "A7 pauses $code still PUT" "$(nputs)" 2
  eq "A7 pauses $code unmeasured" "$(pl fx-a '.basis.pauses')" '"unmeasured"'
  eq "A7 pauses $code flag still pauses[0]" "$(pl fx-a '.pauses[0].name')" '"paused-fx-a"'
done
echo '{"pauses":[],"truncated":true}' > "$FX/pauses.json"
run_lane
eq "A7 truncated pauses unmeasured" "$(pl fx-a '.basis.pauses')" '"unmeasured"'
echo '{"truncated":false}' > "$FX/pauses.json"
run_lane
eq "A7 no pauses array unmeasured" "$(pl fx-a '.basis.pauses')" '"unmeasured"'
echo '{"pauses":[],"truncated":false}' > "$FX/pauses.json"
echo '{"rows":[],"n_total":3}' > "$FX/held.json"
run_lane
eq "A7 held truncated unmeasured" "$(pl fx-a '[.basis.pauses,.pauses[0].name]')" '["unmeasured","paused-fx-a"]'
echo '{"rows":[],"n_total":0}' > "$FX/held.json"
run_lane FAKE_HELD_CODE=500
eq "A7 held 500 unmeasured" "$(pl fx-a '.basis.pauses')" '"unmeasured"'
run_lane
eq "A7 control: everything read is measured" "$(pl fx-a '.basis.pauses')" '"measured"'

# ── A8 ──────────────────────────────────────────────────────────────────────
# The collector's own writes are its PUT and the lane gate's liveness POST;
# everything the sections asked is a GET.
eq "A8 every other request is a GET" \
  "$(grep -v -e '^PUT /api/utilization$' -e '^POST /api/lanes/liveness$' "$H/calls.txt" | grep -vc '^GET ')" 0
eq "A8 the sections were asked" "$(grep -cE '^GET /api/(pauses|conductor/held|merge-queue|pr-state)\?' "$H/calls.txt")" 8

# ── B1 / B2 ─────────────────────────────────────────────────────────────────
reset_fx
jq -nc '{merge_queue:[range(0;3)|{project:"fx-a",pr:.,status:"queued"}]}' > "$FX/mq-fx-a.json"
jq -nc '{rows:([
  ("WAIT_REVIEW","WAIT_REVIEW","NEEDS_HUMAN_VERDICT","WAIT_CI","RED_TWICE","MERGED","MERGED","MERGED","MERGED","READY")]
  | to_entries | map({id:(100-.key), repo:"example-org/fx-a", number:.key, state:.value}))}' > "$FX/prs-example-org_fx-a-first.json"
run_lane
eq "B1 merge_queue" "$(pl fx-a '.prs.merge_queue')" 3
eq "B1 fx-b merge_queue" "$(pl fx-b '.prs.merge_queue')" 0
eq "B1 the read asks for queued rows" "$(grep -c '^GET /api/merge-queue?project=fx-a&status=queued&limit=500$' "$H/calls.txt")" 1
eq "B2 fx-a prs" "$(pl fx-a '[.prs.review,.prs.ci,.basis.prs]')" '[3,2,"measured"]'
eq "B2 fx-b prs" "$(pl fx-b '[.prs.review,.prs.ci,.basis.prs]')" '[0,0,"measured"]'
eq "B2 the pr-state read is per repo" "$(grep -c '^GET /api/pr-state?limit=1000&repo=example-org%2Ffx-a$' "$H/calls.txt")" 1

# ── B3 ──────────────────────────────────────────────────────────────────────
for code in 404 500; do
  run_lane FAKE_PRS_CODE=$code
  out=$(jq -c 'select(.project=="fx-a")' "$H/puts.jsonl")
  jq -e '.payload.prs.review == null and .payload.prs.ci == null' <<<"$out" >/dev/null \
    && ok || bad "B3 pr-state $code: review/ci not null: $(jq -c '.payload.prs' <<<"$out")"
  eq "B3 pr-state $code basis" "$(jq -c '.payload.basis.prs' <<<"$out")" '"unmeasured"'
  eq "B3 pr-state $code merge_queue still counted" "$(jq -c '.payload.prs.merge_queue' <<<"$out")" 3
done

# ── B4 ──────────────────────────────────────────────────────────────────────
rm -f "$H/flags/pr-state-rows"
run_lane
eq "B4 flag off" "$(pl fx-a '[.prs.review,.prs.ci,.basis.prs]')" '[null,null,"unmeasured"]'
eq "B4 no pr-state request" "$(grep -c '^GET /api/pr-state' "$H/calls.txt")" 0
touch "$H/flags/pr-state-rows"

# ── B5 ──────────────────────────────────────────────────────────────────────
jq -nc '{merge_queue:[range(0;500)|{project:"fx-a",pr:.,status:"queued"}]}' > "$FX/mq-fx-a.json"
run_lane
eq "B5 capped merge queue" "$(pl fx-a '[.prs.merge_queue,.basis.prs]')" '[null,"unmeasured"]'
jq -nc '{merge_queue:[range(0;499)|{project:"fx-a",pr:.,status:"queued"}]}' > "$FX/mq-fx-a.json"
run_lane
eq "B5 499 is a count" "$(pl fx-a '[.prs.merge_queue,.basis.prs]')" '[499,"measured"]'
run_lane FAKE_MQ_CODE=500
eq "B5 merge-queue 500" "$(pl fx-a '[.prs.merge_queue,.basis.prs]')" '[null,"unmeasured"]'
echo '{"merge_queue":{}}' > "$FX/mq-fx-a.json"
run_lane
eq "B5 a non-array merge queue" "$(pl fx-a '[.prs.merge_queue,.basis.prs]')" '[null,"unmeasured"]'

# ── B6 ──────────────────────────────────────────────────────────────────────
reset_fx
# Page 1: ids 2000..1001, two WAIT_REVIEW and one WAIT_CI, the rest MERGED.
# Rows carry every column the production view returns (SELECT * FROM pr_state),
# so the page is well over the kernel's 128 KiB cap on one argv string: a
# section that passes the page as an argument fails here, as it would in prod.
jq -nc '{rows:[range(0;1000) as $i | {id:(2000-$i), repo:"example-org/fx-a", number:$i,
  state:(if $i < 2 then "WAIT_REVIEW" elif $i == 2 then "WAIT_CI" else "MERGED" end),
  since:"2026-10-03T01:02:03.456Z", head:"0123456789abcdef0123456789abcdef01234567",
  reviewed:"89abcdef0123456789abcdef0123456789abcdef",
  reason:"conductor: reviewed head matches, CI green on every required check, waiting on the merge sweep",
  url:"https://github.com/example-org/fx-a/pull/\($i)", alerted:"2026-10-03T01:02:03.456Z",
  actor:"hub-fixture", at:"2026-10-03T01:02:03.456Z"}]}' \
  > "$FX/prs-example-org_fx-a-first.json"
eq "B6 the page is over the argv cap" "$([ "$(wc -c < "$FX/prs-example-org_fx-a-first.json")" -gt 131072 ] && echo yes)" yes
run_lane
eq "B6 full page then 404" "$(pl fx-a '[.prs.review,.prs.ci,.basis.prs]')" '[2,1,"measured"]'
eq "B6 page 2 asked before the min id" "$(grep -c '^GET /api/pr-state?limit=1000&before=1001&repo=example-org%2Ffx-a$' "$H/calls.txt")" 1
# A second page with more PRs in it is counted too.
jq -nc '{rows:[{id:900,repo:"example-org/fx-a",number:5000,state:"RED_TWICE"}]}' > "$FX/prs-example-org_fx-a-1001.json"
run_lane
eq "B6 two pages counted" "$(pl fx-a '[.prs.review,.prs.ci,.basis.prs]')" '[2,2,"measured"]'
# A later page that is an outage (a 500) makes the result null.
echo '@500' > "$FX/prs-example-org_fx-a-1001.json"
run_lane
eq "B6 later page 500" "$(pl fx-a '[.prs.review,.prs.ci,.basis.prs]')" '[null,null,"unmeasured"]'
# Every page full: five pages read, still full, null.
rm -f "$FX"/prs-example-org_fx-a-*.json
for b in first 9001 8001 7001 6001; do
  top=$([ "$b" = first ] && echo 10000 || echo $((b - 1)))
  jq -nc --argjson top "$top" '{rows:[range(0;1000) as $i | {id:($top-$i), repo:"example-org/fx-a", number:$i, state:"WAIT_CI"}]}' \
    > "$FX/prs-example-org_fx-a-$b.json"
done
run_lane
eq "B6 every page full is null" "$(pl fx-a '[.prs.review,.prs.ci,.basis.prs]')" '[null,null,"unmeasured"]'
eq "B6 the walk stops at 5 pages" "$(grep -c '^GET /api/pr-state?limit=1000&.*repo=example-org%2Ffx-a$' "$H/calls.txt")" 5

# ── B7 ──────────────────────────────────────────────────────────────────────
reset_fx
jq -nc '{n_total:1, rows:[{repo:"example-org/fx-b",number:9,state:"BLOCKED_HUMAN",head:"a",kind:"k",text:"",mark:"",mode:"m",first_held_at:"2026-10-02T09:00:00Z",last_seen_at:"2026-10-03T09:00:00Z"}]}' > "$FX/held.json"
run_lane FAKE_NO_REPO=fx-b
eq "B7 no repo: prs null" "$(pl fx-b '[.prs.review,.prs.ci,.basis.prs]')" '[null,null,"unmeasured"]'
eq "B7 no repo: no hold, pauses measured" "$(pl fx-b '[([.pauses[]|select(.kind=="hold")]|length),.basis.pauses]')" '[0,"measured"]'
eq "B7 fx-a unaffected" "$(pl fx-a '.basis.prs')" '"measured"'

echo "utilization-pauses-prs: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
