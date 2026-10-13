#!/bin/bash
# tests/queue-rows-flip-preflight-build.bh-2313-test.sh — BH-2339 (BH-2313.1):
# the build gate of bin/queue-rows-flip-preflight.sh (bin/lib/qrf/build.sh),
# driven as shipped (bash $HARNESS/bin/queue-rows-flip-preflight.sh build) with
# the real _jobs_req behind the fake curl of tests/lib/qrf-fixture.sh. It
# asserts printed lines and exit codes only.
# Run from anywhere: tests/queue-rows-flip-preflight-build.bh-2313-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/qrf-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# The files under test, named for bin/test-impact.sh.
for f in "$DIR/bin/queue-rows-flip-preflight.sh" "$DIR/bin/lib/qrf/build.sh"; do
  [ -f "$f" ] || { bad "$f missing"; continue; }
  bash -n "$f" || exit 1
done
check() { if eval "$2"; then ok; else bad "$1"; echo "--- out:"; cat "$OUT"; echo "--- err:"; cat "$ERR"; fi; }

CLAIMED='/api/queue?status=claimed&limit=500'
QUEUED='/api/queue?status=queued&limit=500'
row() { printf '{"project":"%s","ticket_key":"%s","status":"%s","target":"fly"}' "$1" "$2" "$3"; }
case_init() {
  qrf_fixture_init "$T/$1" "$DIR" || { echo "fixture init failed"; exit 1; }
  OUT="$T/$1/out"; ERR="$T/$1/err"
  qrf_fixture_route GET /api/settings/build_queue_rows_only 200 \
    '{"key":"build_queue_rows_only","setting":{"key":"build_queue_rows_only","value":"0"}}'
}
active_file() { mkdir -p "$HARNESS/state/fly"; printf '%s' "$2" > "$HARNESS/state/fly/$1-active.json"; }
queue_file() { mkdir -p "$HARNESS/state/build-queue/$1"; printf '{"key":"%s"}' "$2" > "$HARNESS/state/build-queue/$1/$2.json"; }
run() { touch "$QRF_FX/marker"; sleep 0.05; bash "$HARNESS/bin/queue-rows-flip-preflight.sh" "$@" > "$OUT" 2> "$ERR"; RC=$?; }
readonly_checks() { # readonly_checks <case>
  check "$1 only GET sent" "[ \"\$(qrf_fixture_methods)\" = GET ]"
  check "$1 nothing written under HARNESS" "[ -z \"\$(find '$HARNESS' -newer '$QRF_FX/marker')\" ]"
  check "$1 TMPDIR empty after the run" "[ -z \"\$(ls -A '$TMPDIR')\" ]"
}

# --- B1: healthy — active key claimed, queue file queued → READY ---
case_init b1
active_file demo '{"key":"BH-1","machine":"m1"}'; queue_file demo BH-2
# Scratch the globs must not match: the app file and a dot-prefixed pull temp.
printf '{}' > "$HARNESS/state/fly/demo.json"; printf '{}' > "$HARNESS/state/build-queue/demo/.BH-3.json.pull"
qrf_fixture_route GET "$CLAIMED" 200 "{\"queue\":[$(row demo BH-1 claimed)]}"
qrf_fixture_route GET "$QUEUED" 200 "{\"queue\":[$(row demo BH-2 queued)]}"
run build
check "B1 claimed probe PASS rows=1" "grep -qx '\[PASS\] live probe /api/queue?status=claimed&limit=500 http=200 rows=1' '$OUT'"
check "B1 queued probe PASS rows=1" "grep -qx '\[PASS\] live probe /api/queue?status=queued&limit=500 http=200 rows=1' '$OUT'"
check "B1 parity PASS, 2 file entries" "grep -q '^\[PASS\] row parity: 2 file entries' '$OUT'"
check "B1 no FAIL line" "! grep -q '^\[FAIL\]' '$OUT'"
check "B1 READY build, rc 0" "grep -q '^RESULT: READY build' '$OUT' && [ $RC = 0 ]"
readonly_checks B8/b1

# --- B2: active key with no claimed row → FAIL naming the file and queue_put ---
case_init b2
active_file demo '{"key":"BH-1"}'
qrf_fixture_route GET "$CLAIMED" 200 '{"queue":[]}'
qrf_fixture_route GET "$QUEUED" 200 "{\"queue\":[$(row demo BH-1 queued)]}"
run build
check "B2 FAIL names file, key and queue_put" "grep '^\[FAIL\] build: ' '$OUT' | grep 'state/fly/demo-active.json' | grep 'BH-1' | grep -q 'queue_put demo BH-1'"
check "B2 no parity PASS" "! grep -q '^\[PASS\] row parity' '$OUT'"
check "B2 NOT READY build, rc 1" "grep -q '^RESULT: NOT READY build' '$OUT' && [ $RC = 1 ]"
readonly_checks B8/b2
# A claimed row for the same key under ANOTHER project does not count.
case_init b2p
active_file demo '{"key":"BH-1"}'
qrf_fixture_route GET "$CLAIMED" 200 "{\"queue\":[$(row other BH-1 claimed)]}"
qrf_fixture_route GET "$QUEUED" 200 '{"queue":[]}'
run build
check "B2 other project's row → FAIL" "grep '^\[FAIL\] build: ' '$OUT' | grep -q 'state/fly/demo-active.json' && [ $RC = 1 ]"
# An active file with no .key is a FAIL, never skipped.
case_init b2k
active_file demo 'not json'
qrf_fixture_route GET "$CLAIMED" 200 '{"queue":[]}'
qrf_fixture_route GET "$QUEUED" 200 '{"queue":[]}'
run build
check "B2 unreadable active file → FAIL no .key" "grep '^\[FAIL\] build: ' '$OUT' | grep 'state/fly/demo-active.json' | grep -q 'no .key' && [ $RC = 1 ]"

# --- B3: queue file with no row → FAIL naming the file and queue_put ---
case_init b3
queue_file demo BH-2
qrf_fixture_route GET "$CLAIMED" 200 '{"queue":[]}'
qrf_fixture_route GET "$QUEUED" 200 '{"queue":[]}'
qrf_fixture_route GET '/api/queue?project=demo&key=BH-2&limit=1' 200 '{"queue":[]}'
run build
check "B3 FAIL names file and queue_put" "grep '^\[FAIL\] build: ' '$OUT' | grep 'state/build-queue/demo/BH-2.json' | grep 'has no row' | grep -q 'queue_put demo BH-2'"
check "B3 NOT READY build, rc 1" "grep -q '^RESULT: NOT READY build' '$OUT' && [ $RC = 1 ]"
# B3d: the row is done → FAIL names the status.
case_init b3d
queue_file demo BH-2
qrf_fixture_route GET "$CLAIMED" 200 '{"queue":[]}'
qrf_fixture_route GET "$QUEUED" 200 '{"queue":[]}'
qrf_fixture_route GET '/api/queue?project=demo&key=BH-2&limit=1' 200 "{\"queue\":[$(row demo BH-2 done)]}"
run build
check "B3d FAIL names done" "grep '^\[FAIL\] build: ' '$OUT' | grep 'state/build-queue/demo/BH-2.json' | grep -q 'row is done'"
check "B3d NOT READY build, rc 1" "grep -q '^RESULT: NOT READY build' '$OUT' && [ $RC = 1 ]"
# B3u: the per-key read fails → FAIL http=<code>, never "no row".
case_init b3u
queue_file demo BH-2
qrf_fixture_route GET "$CLAIMED" 200 '{"queue":[]}'
qrf_fixture_route GET "$QUEUED" 200 '{"queue":[]}'
qrf_fixture_route GET '/api/queue?project=demo&key=BH-2&limit=1' 503 'down'
run build
check "B3u unreadable row → FAIL http=503" "grep '^\[FAIL\] build: ' '$OUT' | grep 'state/build-queue/demo/BH-2.json' | grep -q 'unreadable http=503'"
check "B3u never says no row" "! grep -q 'has no row' '$OUT' && [ $RC = 1 ]"

# --- B4: a row with no file on this box → info, READY ---
case_init b4
qrf_fixture_route GET "$CLAIMED" 200 "{\"queue\":[$(row other BH-9 claimed)]}"
qrf_fixture_route GET "$QUEUED" 200 '{"queue":[]}'
run build
check "B4 info names other/BH-9" "grep -q '^  row with no file on this box: other/BH-9 (claimed)' '$OUT'"
check "B4 not a FAIL" "! grep -q '^\[FAIL\]' '$OUT'"
check "B4 READY build, rc 0" "grep -q '^RESULT: READY build' '$OUT' && [ $RC = 0 ]"

# --- B5: /api/queue answers 503 → FAIL http=503, parity never judged ---
case_init b5
active_file demo '{"key":"BH-1"}'
qrf_fixture_route GET "$CLAIMED" 503 'down'
qrf_fixture_route GET "$QUEUED" 200 '{"queue":[]}'
run build
check "B5 FAIL http=503" "grep -qx '\[FAIL\] build: live probe /api/queue?status=claimed&limit=500 http=503' '$OUT'"
check "B5 no parity line at all" "! grep -q 'row parity' '$OUT'"
check "B5 NOT READY build, rc 1" "grep -q '^RESULT: NOT READY build' '$OUT' && [ $RC = 1 ]"
# The queued list failing after a good claimed list is a FAIL too.
case_init b5q
qrf_fixture_route GET "$CLAIMED" 200 '{"queue":[]}'
run build
check "B5 queued 404 → FAIL http=404, no parity" "grep -qx '\[FAIL\] build: live probe /api/queue?status=queued&limit=500 http=404' '$OUT' && ! grep -q 'row parity' '$OUT' && [ $RC = 1 ]"

# --- B6: a list at its limit is incomplete ---
case_init b6
BIG=$(jq -nc '{queue: [range(500) | {project:"demo", ticket_key:("K-\(.)"), status:"claimed"}]}')
qrf_fixture_route GET "$CLAIMED" 200 "$BIG"
qrf_fixture_route GET "$QUEUED" 200 '{"queue":[]}'
run build
check "B6 incomplete FAIL" "grep -q '^\[FAIL\] build: live probe /api/queue?status=claimed&limit=500 incomplete: rows=500 = limit 500' '$OUT'"
check "B6 no parity line" "! grep -q 'row parity' '$OUT'"
check "B6 NOT READY build, rc 1" "grep -q '^RESULT: NOT READY build' '$OUT' && [ $RC = 1 ]"

# --- B7: no files, empty lists → READY ---
case_init b7
qrf_fixture_route GET "$CLAIMED" 200 '{"queue":[]}'
qrf_fixture_route GET "$QUEUED" 200 '{"queue":[]}'
run build
check "B7 parity PASS, 0 file entries" "grep -q '^\[PASS\] row parity: 0 file entries' '$OUT'"
check "B7 READY build, rc 0" "grep -q '^RESULT: READY build' '$OUT' && [ $RC = 0 ]"

# --- B9: no seed mode ---
case_init b9
run build --seed
check "B9 build --seed → rc 2 usage" "[ $RC = 2 ] && grep -q '^usage:' '$ERR'"
check "B9 no request sent" "[ ! -s '$QRF_FX/req.log' ]"

echo "queue-rows-flip-preflight-build.bh-2313: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
