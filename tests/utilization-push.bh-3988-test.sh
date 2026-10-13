#!/bin/bash
# tests/utilization-push.bh-3988-test.sh — BH-4008 (BH-3988 tracer): the hourly
# hub collector bin/utilization-push.sh, its builds section and its verdict.
#
# The collector runs AS SHIPPED from a scratch $HARNESS (a symlink copy of the
# real bin/ and catalog/), with the real jobs-client.sh. Stubbed: fleet-conf.sh
# (two fixture projects), concurrency-plan.sh (FAKE_CAP / FAKE_CAP_RC) and curl,
# which answers GET /api/jobs with FAKE_RUNNING rows, answers PUT
# /api/utilization with FAKE_PUT_CODE and records each PUT body, one per line,
# in $H/puts.jsonl. Everything else (settings reads) answers 404.
#
#   V1  util_verdict: {} / both inputs (rule 4, busy) / not-json, and ready 0 with
#       free_slots null is unknown, never starved
#   P1  one PUT per project: the start hour, verdict unknown, the builds
#       numbers, basis measured; log projects=2 written=2 failed=0 deferred=0
#   P2  concurrency-plan rc 1: pool_cap and free_slots null, unmeasured, row
#       still PUT. P2b: a jobs read that hits its 500 cap is running null
#   P3  cap unlimited: free_slots "unlimited". P3b: cap 0 is 0, not unlimited
#   P4  running 3 over cap 2: free_slots 0
#   P5  past the deadline: no PUT, deferred=2
#   P6  PUT 404: written=0 failed=2, rc 0, `put failed` lines
#   P7  a section printing `not json` or `[]`: dropped, basis.<s> unmeasured,
#       the builds data still there. A bad rc with good JSON is dropped too
#   P8  flags/lane-off-utilization-push: no PUT, rc 0; flags/utilization-push-off
#       with the shared lane gate disabled: no PUT, the lane logs ` off` itself;
#       UTIL_PUSH_ENABLED=0
#   P9  the lock held: rc 0, no PUT, ` busy`
#   P10 render-cron and lanes-build --check, and the one hub line at :07
#   P11 fleet.conf unreadable: rc 1, no PUT, one ALERTS line
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/utilization-push.bh-3988-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2', wanted '$3'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
TAB=$'\t'

LANE_SRC="$DIR/bin/utilization-push.sh"
VERDICT_SRC="$DIR/bin/lib/utilization.sh"
SECTION_SRC="$DIR/bin/lib/utilization/section-builds.sh"
CLIENT_SRC="$DIR/bin/lib/jobs/utilization.sh"
ROUTE_SRC="$DIR/worker/jobs/src/routes/utilization.js"
for f in "$LANE_SRC" "$VERDICT_SRC" "$SECTION_SRC" "$CLIENT_SRC" "$ROUTE_SRC"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; echo "utilization-push: 0 passed, 1 failed"; exit 1; }
done

# ── V1: the verdict, sourced alone ──────────────────────────────────────────
# shellcheck disable=SC1090
. "$VERDICT_SRC" || { echo "FAIL: cannot source $VERDICT_SRC"; exit 1; }
eq "V1 {}" "$(util_verdict '{}')" "unknown${TAB}inputs unmeasured: tickets.ready builds.free_slots"
eq "V1 builds only" "$(util_verdict '{"builds":{"free_slots":2}}')" "unknown${TAB}inputs unmeasured: tickets.ready"
# BH-4009 replaced the tracer's placeholder branch with the full precedence
# (tests/utilization-verdict.bh-3988-test.sh pins every rule); this is rule 4.
eq "V1 both measured" "$(util_verdict '{"tickets":{"ready":3},"builds":{"free_slots":2}}')" "busy${TAB}running 0, ready 3"
eq "V1 not-json" "$(util_verdict 'not-json')" "unknown${TAB}snapshot unparseable"
util_verdict 'not-json' >/dev/null; eq "V1 not-json rc" "$?" 0
eq "V1 ready 0, free_slots null is never starved" \
  "$(util_verdict '{"tickets":{"ready":0},"builds":{"free_slots":null}}')" "unknown${TAB}inputs unmeasured: builds.free_slots"
eq "V1 an array is unparseable as a snapshot" "$(util_verdict '[]')" "unknown${TAB}snapshot unparseable"

# ── the scratch harness ─────────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/flags" "$H/logs" "$T/stub" "$T/env"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/catalog" "$H/catalog"
rm -f "$H/catalog/lanes.json"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" > "$H/catalog/lanes.json" 2> "$T/build.err" \
  || bad "setup: bin/lanes-build.sh failed: $(cat "$T/build.err")"
rm -f "$H/bin/fleet-conf.sh" "$H/bin/concurrency-plan.sh"
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ -n "${FAKE_NO_FLEET:-}" ] && exit 1
case "${1:-}" in --projects) printf 'acme\nbeta\n' ;; *) exit 1 ;; esac
SH
cat > "$H/bin/concurrency-plan.sh" <<'SH'
#!/bin/bash
[ "${FAKE_CAP_RC:-0}" = 0 ] || exit "$FAKE_CAP_RC"
printf '[{"project":"%s","effective":"%s","bound_by":"fixture"}]\n' "$1" "${FAKE_CAP:-5}"
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
case "$M $P" in
  "GET /api/jobs?"*)
    n=${FAKE_RUNNING:-1}
    jq -nc --argjson n "$n" '{jobs:[range(0;$n)|{id:("j"+(.|tostring)),status:"running",kind:"build"}]}'
    printf '\n200' ;;
  "PUT /api/utilization")
    case "$D" in @*) D=$(cat "${D#@}") ;; esac
    printf '%s\n' "$D" >> "$HARNESS/puts.jsonl"
    printf '{"ok":true}\n%s' "${FAKE_PUT_CODE:-200}" ;;
  *) printf '{"error":"unknown endpoint"}\n404' ;;
esac
SH
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/concurrency-plan.sh" "$T/stub/curl"
LOG="$H/logs/utilization-push.log"

# run_lane [VAR=val...] — the shipped entry from the scratch harness, clean env.
run_lane() {
  rm -f "$H/puts.jsonl" "$H/calls.txt"
  env -i PATH="$T/stub:$PATH" HOME="$T" HARNESS="$H" HARNESS_ENV_DIR="$T/env" HARNESS_TEST_SANDBOX=1 \
    JOBS_URL=http://jobs.test HARNESS_SECRET=s3cret JOBS_BOX=hub-fixture JOBS_RETRY_SLEEP=0 "$@" \
    bash "$H/bin/utilization-push.sh" > "$T/lane.out" 2> "$T/lane.err"
}
nputs() { if [ -f "$H/puts.jsonl" ]; then awk 'NF' "$H/puts.jsonl" | wc -l | tr -d ' '; else echo 0; fi; }
put_for() { jq -c --arg p "$1" 'select(.project==$p)' "$H/puts.jsonl" 2>/dev/null; }
last() { tail -n 1 "$LOG" 2>/dev/null | cut -d' ' -f2-; }

# ── P1 ──────────────────────────────────────────────────────────────────────
HOUR_BEFORE=$(date -u +%Y-%m-%dT%H:00:00Z)
run_lane FAKE_RUNNING=2 FAKE_CAP=5; rc=$?
HOUR_AFTER=$(date -u +%Y-%m-%dT%H:00:00Z)
eq "P1 rc" "$rc" 0
eq "P1 PUT count" "$(nputs)" 2
for p in acme beta; do
  b=$(put_for "$p")
  h=$(jq -r '.hour' <<<"$b")
  { [ "$h" = "$HOUR_BEFORE" ] || [ "$h" = "$HOUR_AFTER" ]; } && ok || bad "P1 $p hour '$h' is not the run hour"
  eq "P1 $p row" "$(jq -c '[.verdict,.payload.builds,.payload.basis.builds,.box,.retention_days]' <<<"$b")" \
    '["unknown",{"running":2,"pool_cap":5,"free_slots":3},"measured","hub-fixture",35]'
done
eq "P1 tickets section loaded: no board resolvable is null, never 0" \
  "$(put_for acme | jq -c '[.payload.tickets,.payload.basis.ready]')" \
  '[{"ready":null,"blocked":null,"held":null,"parked":null,"held_complete":null},"unmeasured"]'
eq "P1 jobs read is capped and filtered" "$(grep -c '^GET /api/jobs?project=acme&status=running&kind=build&limit=500$' "$H/calls.txt")" 1
eq "P1 log" "$(last)" "projects=2 written=2 failed=0 deferred=0"
[ -s "$T/lane.out" ] && bad "P1 the lane wrote to stdout: $(head -c 300 "$T/lane.out")" || ok

# ── P2 / P2b ────────────────────────────────────────────────────────────────
run_lane FAKE_RUNNING=2 FAKE_CAP_RC=1; rc=$?
eq "P2 rc" "$rc" 0
eq "P2 PUT count (still written)" "$(nputs)" 2
eq "P2 builds" "$(put_for acme | jq -c '[.payload.builds,.payload.basis.builds]')" \
  '[{"running":2,"pool_cap":null,"free_slots":null},"unmeasured"]'
run_lane FAKE_RUNNING=500 FAKE_CAP=5
eq "P2b capped read is null, never 500" "$(put_for acme | jq -c '[.payload.builds,.payload.basis.builds]')" \
  '[{"running":null,"pool_cap":5,"free_slots":null},"unmeasured"]'

# ── P3 / P3b / P4 ───────────────────────────────────────────────────────────
run_lane FAKE_RUNNING=4 FAKE_CAP=unlimited
eq "P3 unlimited" "$(put_for acme | jq -c '[.payload.builds,.payload.basis.builds]')" \
  '[{"running":4,"pool_cap":"unlimited","free_slots":"unlimited"},"measured"]'
run_lane FAKE_RUNNING=0 FAKE_CAP=0
eq "P3b cap 0 is a number" "$(put_for acme | jq -c '.payload.builds')" '{"running":0,"pool_cap":0,"free_slots":0}'
run_lane FAKE_RUNNING=3 FAKE_CAP=2
eq "P4 over cap" "$(put_for acme | jq -c '.payload.builds')" '{"running":3,"pool_cap":2,"free_slots":0}'
run_lane FAKE_RUNNING=1 FAKE_CAP=garbage
eq "P4b a cap that is neither a number nor unlimited" "$(put_for acme | jq -c '[.payload.builds,.payload.basis.builds]')" \
  '[{"running":1,"pool_cap":null,"free_slots":null},"unmeasured"]'

# ── P5 ──────────────────────────────────────────────────────────────────────
run_lane UTIL_PUSH_DEADLINE_S=0; rc=$?
eq "P5 rc" "$rc" 0
eq "P5 PUT count" "$(nputs)" 0
eq "P5 log" "$(last)" "projects=2 written=0 failed=0 deferred=2"
# The seam is a TEST seam: outside the sandbox it is ignored.
rm -f "$H/puts.jsonl"
env -i PATH="$T/stub:$PATH" HOME="$T" HARNESS="$H" HARNESS_ENV_DIR="$T/env" \
  JOBS_URL=http://jobs.test HARNESS_SECRET=s3cret JOBS_RETRY_SLEEP=0 UTIL_PUSH_DEADLINE_S=0 \
  bash "$H/bin/utilization-push.sh" > /dev/null 2>&1
eq "P5 seam ignored outside HARNESS_TEST_SANDBOX" "$(nputs)" 2

# ── P6 ──────────────────────────────────────────────────────────────────────
run_lane FAKE_PUT_CODE=404; rc=$?
eq "P6 rc" "$rc" 0
eq "P6 log" "$(last)" "projects=2 written=0 failed=2 deferred=0"
eq "P6 put failed lines" "$(grep -cE ' put failed project=(acme|beta)$' "$LOG")" 2
run_lane FAKE_PUT_CODE=503
eq "P6 503 log" "$(last)" "projects=2 written=0 failed=2 deferred=0"

# ── P7 ──────────────────────────────────────────────────────────────────────
SEC="$H/bin/lib/utilization"
printf 'util_section_zz() { echo "not json"; }\n' > "$SEC/section-zz.sh"
run_lane FAKE_RUNNING=1 FAKE_CAP=3
# basis is read through {builds, zz}: the other sections in bin/lib/utilization/
# (pauses and prs, BH-4010) add their own keys, pinned by their own suite.
eq "P7 garbage section dropped" "$(put_for acme | jq -c '[.payload.builds,(.payload.basis|{builds,zz})]')" \
  '[{"running":1,"pool_cap":3,"free_slots":2},{"builds":"measured","zz":"unmeasured"}]'
eq "P7 still written" "$(last)" "projects=2 written=2 failed=0 deferred=0"
printf 'util_section_zz() { echo "[]"; }\n' > "$SEC/section-zz.sh"
run_lane FAKE_RUNNING=1 FAKE_CAP=3
eq "P7 [] section dropped" "$(put_for acme | jq -c '.payload.basis|{builds,zz}')" '{"builds":"measured","zz":"unmeasured"}'
printf 'util_section_zz() { echo "{\\"zz\\":{\\"x\\":1}}"; return 1; }\n' > "$SEC/section-zz.sh"
run_lane FAKE_RUNNING=1 FAKE_CAP=3
eq "P7 bad rc with good JSON dropped" "$(put_for acme | jq -c '[.payload.zz,(.payload.basis|{builds,zz})]')" '[null,{"builds":"measured","zz":"unmeasured"}]'
printf 'util_section_zz() { echo "{\\"zz\\":{\\"x\\":1},\\"basis\\":{\\"zz\\":\\"measured\\"}}"; }\n' > "$SEC/section-zz.sh"
run_lane FAKE_RUNNING=1 FAKE_CAP=3
eq "P7 a good section deep-merges" "$(put_for acme | jq -c '[.payload.zz,(.payload.basis|{builds,zz})]')" '[{"x":1},{"builds":"measured","zz":"measured"}]'
rm -f "$SEC/section-zz.sh"

# ── P8 ──────────────────────────────────────────────────────────────────────
touch "$H/flags/lane-off-utilization-push"
run_lane; rc=$?
eq "P8 rc" "$rc" 0
eq "P8 PUT count" "$(nputs)" 0
rm -f "$H/flags/lane-off-utilization-push"
# The lane's own check, for a box running with the shared gate disabled: the
# utilization-push-off switch, read through lane_switch in file mode.
touch "$H/flags/utilization-push-off"
run_lane LANE_GATE_DISABLE=1; rc=$?
eq "P8 gate disabled rc" "$rc" 0
eq "P8 gate disabled PUT count" "$(nputs)" 0
eq "P8 gate disabled log" "$(last)" "off"
rm -f "$H/flags/utilization-push-off"
run_lane UTIL_PUSH_ENABLED=0; rc=$?
eq "P8 disabled rc" "$rc" 0
eq "P8 disabled PUT count" "$(nputs)" 0
eq "P8 disabled log" "$(last)" "disabled"

# ── P9 ──────────────────────────────────────────────────────────────────────
mkdir -p "$H/locks"
# -o: flock itself holds the lock and the sleep does not inherit it, so the
# kill below releases it. Without it the orphaned sleep held the lock for 30 s
# and, on a box where P10 finishes fast, P11 read `busy` and exited 0.
flock -o "$H/locks/utilization-push.lock" sleep 30 &
HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  flock -n "$H/locks/utilization-push.lock" true 2>/dev/null || break
  sleep 0.2
done
run_lane; rc=$?
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
eq "P9 rc" "$rc" 0
eq "P9 PUT count" "$(nputs)" 0
eq "P9 log" "$(last)" "busy"

# ── P10 ─────────────────────────────────────────────────────────────────────
( cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/render-cron.sh --check && HARNESS_TEST_SANDBOX=1 bin/lanes-build.sh --check ) > "$T/p10.out" 2>&1
rc=$?
eq "P10 render-cron and lanes-build --check rc" "$rc" 0
[ "$rc" = 0 ] || cat "$T/p10.out"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-cron.sh" hub > "$T/hub.cron" 2> "$T/hub.err"
eq "P10 hub line" "$(grep 'bin/utilization-push.sh' "$T/hub.cron")" \
  '7 * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/utilization-push.sh >/dev/null 2>&1'
eq "P10 registry entry" "$(jq -c '.lanes[]|select(.id=="utilization-push")|[.scope,.boxes,.switch.name,.script,.cadence,([.knobs[]|select(.settable)|.env]|sort)]' "$H/catalog/lanes.json")" \
  '["hub",["hub"],"lane-off-utilization-push","bin/utilization-push.sh","7 * * * *",["UTIL_PUSH_ENABLED","UTIL_RETENTION_DAYS"]]'

# ── P11 ─────────────────────────────────────────────────────────────────────
run_lane FAKE_NO_FLEET=1; rc=$?
eq "P11 rc" "$rc" 1
eq "P11 PUT count" "$(nputs)" 0
eq "P11 ALERTS line" "$(grep -c '\[utilization-push\] fleet.conf gave an EMPTY project list' "$H/logs/ALERTS.log" 2>/dev/null)" 1

echo "utilization-push: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
