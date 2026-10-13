#!/bin/bash
# tests/queue-rows-flip-preflight-merge.bh-2313-test.sh — BH-2340 (BH-2313.2):
# the merge gate of bin/queue-rows-flip-preflight.sh (bin/lib/qrf/merge.sh),
# driven as shipped (bash $HARNESS/bin/queue-rows-flip-preflight.sh merge) with
# the real _jobs_req behind the fake curl of tests/lib/qrf-fixture.sh. Asserts
# printed verdict lines and exit codes only.
# Run from anywhere: tests/queue-rows-flip-preflight-merge.bh-2313-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/qrf-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# The file under test, named for bin/test-impact.sh.
[ -f "$DIR/bin/lib/qrf/merge.sh" ] || { echo "bin/lib/qrf/merge.sh missing"; exit 1; }
bash -n "$DIR/bin/lib/qrf/merge.sh" || exit 1
check() { if eval "$2"; then ok; else bad "$1"; echo "--- out:"; cat "$OUT"; echo "--- err:"; cat "$ERR"; fi; }

case_init() {
  qrf_fixture_init "$T/$1" "$DIR" || { echo "fixture init failed"; exit 1; }
  OUT="$T/$1/out"; ERR="$T/$1/err"
  qrf_fixture_route GET /api/settings/merge_queue_rows_only 200 '{"setting":{"value":"0"}}'
}
qfile() { mkdir -p "$HARNESS/state/merge-queue/$1" && : > "$HARNESS/state/merge-queue/$1/$2"; }
# rows <project> <pr:status> ... → the two live-status routes for that project
# (status=queued / status=blocked, limit=500, BH-3221) each answer 200 with
# their own subset. landed/dropped rows are served by neither, as the filtered
# worker route would not; both routes answer even when empty.
rows() {
  local p="$1" r s body; shift
  for s in queued blocked; do
    body='[]'
    for r in "$@"; do
      [ "${r#*:}" = "$s" ] || continue
      body=$(jq -c --arg p "$p" --argjson n "${r%%:*}" --arg s "$s" '. + [{project:$p,pr:$n,status:$s}]' <<<"$body")
    done
    qrf_fixture_route GET "/api/merge-queue?project=$p&status=$s&limit=500" 200 "{\"merge_queue\":$body}"
  done
}
run() { bash "$HARNESS/bin/queue-rows-flip-preflight.sh" merge > "$OUT" 2> "$ERR"; RC=$?; }
ready()    { grep -q '^RESULT: READY merge$' "$OUT" && [ "$RC" = 0 ]; }
notready() { grep -q '^RESULT: NOT READY merge' "$OUT" && [ "$RC" = 1 ]; }
fails()    { grep -c '^\[FAIL\] merge:' "$OUT"; }

# --- M1: healthy — plain/queued, .blocked/blocked; .absent and non-numeric skipped ---
case_init m1
qfile alpha 12; qfile alpha 13.blocked; qfile alpha 14.absent; qfile alpha README
rows alpha 12:queued 13:blocked 99:queued 7:landed; run
check "M1 READY, rc 0" "ready"
check "M1 no FAIL" "[ \"\$(fails)\" = 0 ]"
check "M1 parity PASS for alpha" "grep -qx '\[PASS\] row parity alpha: 2 file(s) matched' '$OUT'"
check "M1 one row with no file, info" "grep -q '^  alpha: 1 queued/blocked row(s) with no file' '$OUT'"

# --- M2: plain file, no row → FAIL naming the file and merge_queue_put ---
case_init m2; qfile alpha 15; rows alpha; run
check "M2 FAIL names file and put fix" "grep '^\[FAIL\] merge:' '$OUT' | grep 'state/merge-queue/alpha/15' | grep -q 'merge_queue_put alpha 15'"
check "M2 NOT READY, rc 1" "notready"
check "M2 no parity PASS" "! grep -q '^\[PASS\] row parity' '$OUT'"

# --- M3: .blocked file whose row is queued ---
case_init m3; qfile alpha 13.blocked; rows alpha 13:queued; run
check "M3 FAIL names .blocked file and set fix" "grep '^\[FAIL\] merge:' '$OUT' | grep 'state/merge-queue/alpha/13.blocked' | grep -q 'merge_queue_set alpha 13 blocked'"
check "M3 NOT READY, rc 1" "notready"

# --- M3b: plain file whose row is blocked ---
case_init m3b; qfile alpha 12; rows alpha 12:blocked; run
check "M3b FAIL names plain file" "grep '^\[FAIL\] merge:' '$OUT' | grep -q 'state/merge-queue/alpha/12 '"
check "M3b NOT READY" "notready"

# --- M3c: .blocked file with no row → put then set ---
case_init m3c; qfile alpha 17.blocked; rows alpha 12:queued; run
check "M3c FAIL names file, put then set" "grep '^\[FAIL\] merge:' '$OUT' | grep 'state/merge-queue/alpha/17.blocked' | grep -q 'merge_queue_put alpha 17.*merge_queue_set alpha 17 blocked'"
check "M3c NOT READY" "notready"

# --- M3d: plain file whose row landed is still a FAIL ---
case_init m3d; qfile alpha 18; rows alpha 18:landed; run
check "M3d landed row for a plain file → FAIL" "grep '^\[FAIL\] merge:' '$OUT' | grep -q 'state/merge-queue/alpha/18 has no row' && notready"

# --- M4: empty project dir, empty list → READY ---
case_init m4; mkdir -p "$HARNESS/state/merge-queue/alpha"; rows alpha; run
check "M4 READY, rc 0" "ready"
check "M4 probe PASS rows=0" "grep -q '^\[PASS\] live probe /api/merge-queue?project=alpha&status=queued&limit=500 http=200 rows=0' '$OUT'"

# --- M4b: no state/merge-queue at all → one liveness probe, READY ---
case_init m4b
qrf_fixture_route GET '/api/merge-queue?status=queued' 200 '{"merge_queue":[]}'; run
check "M4b READY, rc 0" "ready"
check "M4b liveness probe sent" "qrf_fixture_reqs | grep -qx 'GET /api/merge-queue?status=queued'"
# ...and a dead route there is still NOT READY.
case_init m4c; run
check "M4c no dirs + 404 list → NOT READY" "grep -q '^\[FAIL\] merge: live probe /api/merge-queue?status=queued http=404' '$OUT' && notready"

# --- M5: list route 503 → FAIL with http=, no parity PASS ---
case_init m5; qfile alpha 12
qrf_fixture_route GET '/api/merge-queue?project=alpha&status=queued&limit=500' 503 'unavailable'; run
check "M5 FAIL http=503" "grep -q '^\[FAIL\] merge: live probe /api/merge-queue?project=alpha&status=queued&limit=500 http=503' '$OUT'"
check "M5 no parity PASS" "! grep -q '^\[PASS\] row parity' '$OUT'"
check "M5 parity not checked, said so" "grep -q 'row parity for alpha not checked: live probe failed' '$OUT'"
check "M5 NOT READY, rc 1" "notready"
check "M5 only the probe FAILs, no parity verdict on an unread list" "[ \"\$(fails)\" = 1 ]"
# An empty dir behind a dead route never earns a parity PASS either.
case_init m5c; mkdir -p "$HARNESS/state/merge-queue/alpha"
qrf_fixture_route GET '/api/merge-queue?project=alpha&status=queued&limit=500' 503 'unavailable'; run
check "M5c empty dir + 503 → no parity PASS, NOT READY" "! grep -q '^\[PASS\] row parity' '$OUT' && notready"

# --- M5b: 200 with an HTML/1101 body → FAIL ---
case_init m5b; qfile alpha 12
qrf_fixture_route GET '/api/merge-queue?project=alpha&status=queued&limit=500' 200 '<html>error code: 1101</html>'; run
check "M5b FAIL on non-JSON body" "grep -q '^\[FAIL\] merge: live probe /api/merge-queue?project=alpha&status=queued&limit=500 http=200' '$OUT' && notready"
check "M5b no parity PASS" "! grep -q '^\[PASS\] row parity' '$OUT'"

# --- M6: a live status at its clamp (500) → incomplete FAIL ---
case_init m6; qfile alpha 12
qrf_fixture_route GET '/api/merge-queue?project=alpha&status=queued&limit=500' 200 \
  "$(jq -nc '{merge_queue:[range(500)|{project:"alpha",pr:(.+1000),status:"queued"}]}')"; run
check "M6 incomplete at limit 500" "grep -q 'incomplete: rows=500 = limit 500' '$OUT'"
check "M6 NOT READY" "notready"

# --- M7: two projects, only beta is broken ---
case_init m7; qfile alpha 12; qfile beta 21
rows alpha 12:queued; rows beta; run
check "M7 exactly one FAIL" "[ \"\$(fails)\" = 1 ]"
check "M7 FAIL names beta/21" "grep '^\[FAIL\] merge:' '$OUT' | grep -q 'state/merge-queue/beta/21'"
check "M7 no FAIL names alpha" "! grep '^\[FAIL\] merge:' '$OUT' | grep -q alpha"
check "M7 alpha parity PASS" "grep -qx '\[PASS\] row parity alpha: 1 file(s) matched' '$OUT'"
check "M7 NOT READY" "notready"

# --- M8: plain and .blocked for the same PR, row blocked → .blocked governs ---
case_init m8; qfile alpha 16; qfile alpha 16.blocked; rows alpha 16:blocked; run
check "M8 READY" "ready"
check "M8 shadowed plain file is info" "grep -q '^  .*state/merge-queue/alpha/16 .*shadowed' '$OUT'"

# --- M9: read-only — GETs only, nothing under HARNESS, TMPDIR clean ---
case_init m9; qfile alpha 15; rows alpha
touch "$QRF_FX/marker"; sleep 0.05; run
check "M9 only GET sent" "[ \"\$(qrf_fixture_methods)\" = GET ]"
check "M9 no EXEC" "! qrf_fixture_reqs | grep -q '^EXEC'"
check "M9 nothing written under HARNESS" "[ -z \"\$(find '$HARNESS' -newer '$QRF_FX/marker')\" ]"
check "M9 TMPDIR empty after the run" "[ -z \"\$(ls -A '$TMPDIR')\" ]"
check "M9 per-project queued read" "qrf_fixture_reqs | grep -qx 'GET /api/merge-queue?project=alpha&status=queued&limit=500'"
check "M9 per-project blocked read" "qrf_fixture_reqs | grep -qx 'GET /api/merge-queue?project=alpha&status=blocked&limit=500'"

# --- M10: rows with no file never fail ---
case_init m10; qfile alpha 12; rows alpha 12:queued 50:queued 51:blocked; run
check "M10 READY" "ready"
check "M10 two rows with no file, info" "grep -q '^  alpha: 2 queued/blocked row(s) with no file' '$OUT'"

echo "queue-rows-flip-preflight-merge.bh-2313: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
