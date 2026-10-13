#!/bin/bash
# tests/queue-rows-flip-preflight.bh-2338-test.sh — BH-2338 (BH-2313.0): the
# read-only preflight frame for the five queue-row knobs, driven as shipped
# (bash $HARNESS/bin/queue-rows-flip-preflight.sh) with the real _jobs_req
# behind the fake curl of tests/lib/qrf-fixture.sh.
# Run from anywhere: tests/queue-rows-flip-preflight.bh-2338-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/qrf-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# The files under test, named for bin/test-impact.sh.
for f in "$DIR/bin/queue-rows-flip-preflight.sh" "$DIR/bin/lib/qrf/build.sh" "$DIR/bin/lib/qrf/merge.sh" \
         "$DIR/bin/lib/qrf/deploy.sh" "$DIR/bin/lib/qrf/ready.sh" "$DIR/bin/lib/qrf/closeout.sh"; do
  [ -f "$f" ] || { bad "$f missing"; continue; }
  bash -n "$f" || exit 1
done
check() { if eval "$2"; then ok; else bad "$1"; echo "--- out:"; cat "$OUT"; echo "--- err:"; cat "$ERR"; fi; }

GATES="build merge deploy ready closeout"
knob_of() { case "$1" in build) echo build_queue_rows_only;; merge) echo merge_queue_rows_only;;
  deploy) echo deploy_queue_rows;; ready) echo ready_queue_rows;; closeout) echo closeout_aged_table;; esac; }
knob_row() { qrf_fixture_route GET "/api/settings/$1" 200 "{\"key\":\"$1\",\"setting\":{\"key\":\"$1\",\"value\":\"$2\"}}"; }
all_knobs() { local g; for g in $GATES; do knob_row "$(knob_of "$g")" "${1:-0}"; done; }
# Each case reinstalls the five FAIL stubs, so this suite tests the frame alone
# and not whichever real gate modules have landed since (BH-2313 slices).
case_init() { qrf_fixture_init "$T/$1" "$DIR" || { echo "fixture init failed"; exit 1; }; OUT="$T/$1/out"; ERR="$T/$1/err"
  local g; for g in $GATES; do printf 'qrf_gate_%s() { qrf_fail %s "row parity: check not implemented yet"; }\n' "$g" "$g" > "$HARNESS/bin/lib/qrf/$g.sh"; done; }
run() { bash "$HARNESS/bin/queue-rows-flip-preflight.sh" "$@" > "$OUT" 2> "$ERR"; RC=$?; }

# --- A1: every knob row answers 200 → one knob line per gate ---
case_init a1; all_knobs 0; run
for g in $GATES; do k=$(knob_of "$g"); check "A1 knob: $k=0 printed" "grep -q 'knob: $k=0\$' '$OUT'"; done

# --- A2 (T2): one gate asked → nothing about the others, one GET, no /api/queue ---
case_init a2; all_knobs 0; run merge
check "A2 no other gate or knob named" "! grep -Eq 'build|deploy|ready|closeout' '$OUT' '$ERR'"
check "A2 merge gate reported" "grep -q 'RESULT: NOT READY merge' '$OUT'"
check "A2 no /api/queue request" "! qrf_fixture_reqs | grep -q '/api/queue'"
check "A2 exactly one request, the merge knob" "[ \"\$(qrf_fixture_reqs)\" = 'GET /api/settings/merge_queue_rows_only' ]"

# --- A3 (T5): exactly the five rollback lines, real verb ---
case_init a3; all_knobs 0; run
check "A3 five rollback lines" "[ \"\$(grep -c '^rollback: ' '$OUT')\" = 5 ]"
for g in $GATES; do k=$(knob_of "$g")
  check "A3 rollback for $k" "grep -qx 'rollback: bin/jobs-client.sh setting-set $k 0' '$OUT'"; done

# --- A4 (T6): GETs only, nothing written under \$HARNESS, TMPDIR clean ---
# deploy's knob answers 500, so the client's _jobs_log fires on this run.
case_init a4; all_knobs 0; qrf_fixture_route GET /api/settings/deploy_queue_rows 500 'boom'
touch "$QRF_FX/marker"; sleep 0.05; run
check "A4 only GET sent" "[ \"\$(qrf_fixture_methods)\" = GET ]"
# One knob GET per gate; a real module adds its own probe GETs after it.
check "A4 five knob requests sent" "[ \"\$(qrf_fixture_reqs | grep -c '^GET /api/settings/')\" = 5 ]"
check "A4 nothing written under HARNESS" "[ -z \"\$(find '$HARNESS' -newer '$QRF_FX/marker')\" ]"
check "A4 TMPDIR empty after the run" "[ -z \"\$(ls -A '$TMPDIR')\" ]"
check "A4 500 knob is unreadable, not 0" "grep -q '^\[FAIL\] deploy: knob deploy_queue_rows: unreadable http=500' '$OUT'"
check "A4 client log line went to stderr" "grep -q 'http=500' '$ERR'"

# --- A5 (T7): no client / unknown gate / no coordination DB → rc 2 ---
case_init a5a; all_knobs 0; rm -f "$HARNESS/bin/jobs-client.sh"; run
check "A5a no client → rc 2" "[ $RC = 2 ]"
check "A5a says why" "grep -q 'no jobs client under' '$ERR'"
for w in bogus fly_machines; do
  case_init "a5b-$w"; all_knobs 0; run merge "$w"
  check "A5b '$w' → rc 2" "[ $RC = 2 ]"
  check "A5b '$w' → usage" "grep -q '^usage:' '$ERR'"
  check "A5b '$w' → no request sent" "[ ! -s '$QRF_FX/req.log' ]"
done
case_init a5c; all_knobs 0; printf 'HARNESS_SECRET=test-secret\nJOBS_URL=\n' > "$HARNESS/env/global.env"
touch "$QRF_FX/marker"; sleep 0.05; run
check "A5c empty JOBS_URL → rc 2" "[ $RC = 2 ]"
check "A5c says not configured" "grep -q 'not configured' '$ERR'"
check "A5c nothing written under HARNESS" "[ -z \"\$(find '$HARNESS' -newer '$QRF_FX/marker')\" ]"
check "A5c no request sent" "[ ! -s '$QRF_FX/req.log' ]"

# --- A6: with no rows registered every gate is NOT READY, in the default order ---
case_init a6; all_knobs 0; run
check "A6 rc 1" "[ $RC = 1 ]"
check "A6 NOT READY for all five, in order" "[ \"\$(grep -o '^RESULT: NOT READY [a-z]*' '$OUT' | awk '{print \$4}' | tr '\n' ' ')\" = 'build merge deploy ready closeout ' ]"
# A stub FAILs outright; a real module FAILs its live probe (no route → 404).
for g in $GATES; do check "A6 FAIL for $g" "grep -q '^\[FAIL\] $g:' '$OUT'"; done
check "A6 no READY line" "! grep -q '^RESULT: READY' '$OUT'"
# A duplicate gate runs once.
case_init a6d; all_knobs 0; run merge merge
check "A6 duplicate gate runs once" "[ \"\$(grep -c '^RESULT: ' '$OUT')\" = 1 ] && [ \"\$(qrf_fixture_reqs | wc -l)\" = 1 ]"
# A deleted module is a FAIL, never READY.
case_init a6m; all_knobs 0; rm -f "$HARNESS/bin/lib/qrf/ready.sh"; run ready
check "A6 missing module → FAIL" "grep -q '^\[FAIL\] ready: gate module bin/lib/qrf/ready.sh missing' '$OUT' && grep -q '^RESULT: NOT READY ready' '$OUT' && [ $RC = 1 ]"

# --- A7: a 404 knob row is a FAIL, never 0 ---
case_init a7; run merge
check "A7 [FAIL] names the knob" "grep -q '^\[FAIL\] merge: knob merge_queue_rows_only: no settings row' '$OUT'"
check "A7 no knob value printed" "! grep -q 'knob: merge_queue_rows_only=' '$OUT'"
check "A7 NOT READY, rc 1" "grep -q '^RESULT: NOT READY merge' '$OUT' && [ $RC = 1 ]"
# A 200 without a value is a FAIL too.
case_init a7v; qrf_fixture_route GET /api/settings/merge_queue_rows_only 200 '{"setting":{}}'; run merge
check "A7 row without value → FAIL" "grep -q '^\[FAIL\] merge: knob merge_queue_rows_only: row has no value' '$OUT' && [ $RC = 1 ]"

# --- A8: READY is reachable when the module passes ---
case_init a8; all_knobs 0
printf 'qrf_gate_merge() { qrf_pass "merge override"; }\n' > "$HARNESS/bin/lib/qrf/merge.sh"; run merge
check "A8 READY merge, rc 0" "grep -q '^RESULT: READY merge' '$OUT' && [ $RC = 0 ]"
check "A8 pass line printed" "grep -qx '\[PASS\] merge override' '$OUT'"

# --- A9: qrf_list — below limit PASS; at limit, 500, non-array FAIL ---
a9() { # a9 <case> <http> <body>
  case_init "a9-$1"; knob_row merge_queue_rows_only 0
  printf 'qrf_gate_merge() { qrf_info "H=$QRF_H S=$QRF_STATE"; qrf_list merge /api/x .rows 3 "$QRF_TMP"; }\n' > "$HARNESS/bin/lib/qrf/merge.sh"
  qrf_fixture_route GET /api/x "$2" "$3"; run merge
}
a9 two 200 '{"rows":[1,2]}'
check "A9 2 rows → PASS" "grep -qx '\[PASS\] live probe /api/x http=200 rows=2' '$OUT' && grep -q '^RESULT: READY merge' '$OUT' && [ $RC = 0 ]"
check "A9 QRF_H / QRF_STATE exported to the module" "grep -qx '  H=$HARNESS S=$HARNESS/state' '$OUT'"
a9 three 200 '{"rows":[1,2,3]}'
check "A9 3 rows = limit → incomplete" "grep -q '^\[FAIL\] merge: live probe /api/x incomplete: rows=3 = limit 3' '$OUT' && grep -q '^RESULT: NOT READY merge' '$OUT'"
a9 err 500 'error code: 1101'
check "A9 500 → FAIL http=500" "grep -q '^\[FAIL\] merge: live probe /api/x http=500' '$OUT' && grep -q '^RESULT: NOT READY merge' '$OUT'"
a9 obj 200 '{"rows":{"a":1}}'
check "A9 non-array → FAIL" "grep -q '^\[FAIL\] merge: live probe /api/x http=200' '$OUT' && grep -q '^RESULT: NOT READY merge' '$OUT'"
# A non-numeric limit is a FAIL, not a silent default.
case_init a9-lim; knob_row merge_queue_rows_only 0
printf 'qrf_gate_merge() { qrf_list merge /api/x .rows many "$QRF_TMP"; }\n' > "$HARNESS/bin/lib/qrf/merge.sh"
qrf_fixture_route GET /api/x 200 '{"rows":[]}'; run merge
check "A9 non-numeric limit → FAIL" "grep -q '^\[FAIL\] merge: .*limit' '$OUT' && [ $RC = 1 ]"

# --- NEGATIVE: the slice never says it flipped anything ---
check "no 'flipped' in the new files" "! grep -il flipped '$DIR/bin/queue-rows-flip-preflight.sh' '$DIR'/bin/lib/qrf/*.sh"

echo "queue-rows-flip-preflight.bh-2338: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
