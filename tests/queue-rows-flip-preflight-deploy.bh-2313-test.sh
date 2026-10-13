#!/bin/bash
# tests/queue-rows-flip-preflight-deploy.bh-2313-test.sh — BH-2341 (BH-2313.3):
# the deploy gate of bin/queue-rows-flip-preflight.sh. Every case runs the
# shipped preflight (bash $HARNESS/bin/queue-rows-flip-preflight.sh deploy)
# with the real _jobs_req behind the fake curl of tests/lib/qrf-fixture.sh, and
# asserts the printed verdict lines and the exit code.
# Run from anywhere: tests/queue-rows-flip-preflight-deploy.bh-2313-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/qrf-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# The file under test, named for bin/test-impact.sh.
MOD="$DIR/bin/lib/qrf/deploy.sh"
[ -f "$MOD" ] && bash -n "$MOD" || { echo "FAIL: $MOD missing or does not parse"; exit 1; }
check() { if eval "$2"; then ok; else bad "$1"; echo "--- out:"; cat "$OUT"; echo "--- err:"; cat "$ERR"; fi; }

QR='/api/deploy-queue?status=queued&limit=200'
CR='/api/deploy-queue?status=claimed&limit=200'
SHA_A=abcdef1200112233445566778899aabbccddeeff
SHA_B=12345678ffeeddccbbaa99887766554433221100
case_init() {
  qrf_fixture_init "$T/$1" "$DIR" || { echo "fixture init failed"; exit 1; }
  OUT="$T/$1/out"; ERR="$T/$1/err"
  qrf_fixture_route GET /api/settings/deploy_queue_rows 200 '{"key":"deploy_queue_rows","setting":{"key":"deploy_queue_rows","value":"0"}}'
}
# rows <project>:<sha>:<status> ... → the worker's GET /api/deploy-queue body
rows() { jq -nc '{deploy_queue: ($ARGS.positional | map(split(":") | {project: .[0], sha: .[1], status: .[2], build_dir: "/root/harness/builds/x"})), as_of: "2026-09-27T00:00:00Z"}' --args "$@"; }
queued()  { qrf_fixture_route GET "$QR" 200 "$(rows "$@")"; }
claimed() { qrf_fixture_route GET "$CR" 200 "$(rows "$@")"; }
# qfile <project> <epoch> <sha> [build] — what bin/deploy-request.sh writes
qfile() {
  mkdir -p "$HARNESS/state/deploy-queue/$1"
  printf '%s %s\n' "$3" "${4-/root/harness/builds/$1-x}" > "$HARNESS/state/deploy-queue/$1/$2-${3:0:8}"
}
run() { bash "$HARNESS/bin/queue-rows-flip-preflight.sh" deploy > "$OUT" 2> "$ERR"; RC=$?; }
ready()    { grep -qx 'RESULT: READY deploy' "$OUT" && [ "$RC" = 0 ]; }
notready() { grep -q '^RESULT: NOT READY deploy' "$OUT" && [ "$RC" = 1 ]; }
nfail()    { grep -c '^\[FAIL\] deploy:' "$OUT"; }

# --- D1: a file with a queued row → READY ---
case_init d1; qfile app 1700000000 "$SHA_A"; queued "app:$SHA_A:queued"; claimed; run
check "D1 queued probe PASS" "grep -qx '\[PASS\] live probe $QR http=200 rows=1' '$OUT'"
check "D1 claimed probe PASS" "grep -qx '\[PASS\] live probe $CR http=200 rows=0' '$OUT'"
check "D1 parity PASS" "grep -qx '\[PASS\] row parity: 1 deploy file(s), each with a queued/claimed row' '$OUT'"
check "D1 READY, rc 0" "ready"
check "D1 no FAIL" "[ \"\$(nfail)\" = 0 ]"

# --- D1c: the row is only in the claimed list → READY ---
case_init d1c; qfile app 1700000000 "$SHA_A"; queued; claimed "app:$SHA_A:claimed"; run
check "D1c claimed row satisfies the file" "ready && grep -q '^\[PASS\] row parity: 1 deploy file' '$OUT'"

# --- D2: one file with a row, one without → one FAIL naming the fix ---
case_init d2; qfile app 1700000000 "$SHA_A"; qfile app 1700000100 "$SHA_B"
queued "app:$SHA_A:queued"; claimed; run
check "D2 exactly one FAIL" "[ \"\$(nfail)\" = 1 ]"
check "D2 FAIL names the file and the put" "grep -qxF '[FAIL] deploy: row parity: state/deploy-queue/app/1700000100-12345678 has no queued/claimed deploy_queue row. Fix: deploy_queue_put app $SHA_B /root/harness/builds/app-x' '$OUT'"
check "D2 NOT READY (1 check(s) failed), rc 1" "grep -qx 'RESULT: NOT READY deploy (1 check(s) failed)' '$OUT' && [ $RC = 1 ]"
check "D2 no parity PASS" "! grep -q '^\[PASS\] row parity' '$OUT'"
# A file with an empty build field prints '-' in the fix.
case_init d2b; qfile app 1700000100 "$SHA_B" ""; queued; claimed; run
check "D2 empty build → '-'" "grep -qF 'Fix: deploy_queue_put app $SHA_B -' '$OUT' && notready"

# --- D2p: a row for another project does not satisfy the file ---
case_init d2p; qfile app 1700000000 "$SHA_A"; queued "other:$SHA_A:queued"; claimed; run
check "D2p project mismatch → FAIL" "grep -q '^\[FAIL\] deploy: row parity: state/deploy-queue/app/1700000000-abcdef12 has no' '$OUT' && notready"

# --- D2u: uppercase hex in the row sha and in the file name still match ---
case_init d2u; qfile app 1700000000 "$SHA_A"; queued "app:${SHA_A^^}:queued"; claimed; run
check "D2u uppercase row sha → READY" "ready"
case_init d2U; mkdir -p "$HARNESS/state/deploy-queue/app"
printf '%s x\n' "$SHA_A" > "$HARNESS/state/deploy-queue/app/1700000000-ABCDEF12"
queued "app:$SHA_A:queued"; claimed; run
check "D2u uppercase file name → READY" "ready"

# --- D2n: a name that is not <epoch>-<hex> → FAIL ---
case_init d2n; mkdir -p "$HARNESS/state/deploy-queue/app"; echo x > "$HARNESS/state/deploy-queue/app/junk"
queued; claimed; run
check "D2n unrecognised name → FAIL" "grep -qx '\[FAIL\] deploy: state/deploy-queue/app/junk: unrecognised queue file name' '$OUT' && notready"
# A subdirectory inside a project dir is skipped, as the train skips it.
case_init d2d; mkdir -p "$HARNESS/state/deploy-queue/app/sub"; queued; claimed; run
check "D2d subdirectory skipped → READY" "ready && grep -q '^\[PASS\] row parity: 0 deploy file' '$OUT'"

# --- D3: a row with no file is info, never a FAIL ---
case_init d3; qfile app 1700000000 "$SHA_A"; queued "app:$SHA_A:queued" "app:$SHA_B:queued"; claimed; run
check "D3 info line for the row without a file" "grep -qx '  row app@12345678 (queued) has no file on this box' '$OUT'"
check "D3 no FAIL, READY" "[ \"\$(nfail)\" = 0 ] && ready"

# --- D4: no queue dir at all, or an empty project dir → READY ---
case_init d4; queued; claimed; run
check "D4 no dir → parity PASS 0" "grep -qx '\[PASS\] row parity: 0 deploy file(s), each with a queued/claimed row' '$OUT' && ready"
case_init d4e; mkdir -p "$HARNESS/state/deploy-queue/app"; queued; claimed; run
check "D4 empty project dir → READY" "ready"

# --- D5: a failed list is a FAIL with the http code, never 0 rows ---
case_init d5; qfile app 1700000000 "$SHA_A"; qrf_fixture_route GET "$QR" 503 'unavailable'; claimed "app:$SHA_A:claimed"; run
check "D5 503 → FAIL http=503" "grep -qxF '[FAIL] deploy: live probe $QR http=503' '$OUT'"
check "D5 parity not checked" "grep -qx '  row parity: not checked (the list did not answer in full)' '$OUT' && ! grep -q '^\[PASS\] row parity' '$OUT'"
check "D5 NOT READY, rc 1" "notready"
case_init d5b; queued; qrf_fixture_route GET "$CR" 200 'error code: 1101'; run
check "D5b non-JSON 200 → FAIL http=200" "grep -qxF '[FAIL] deploy: live probe $CR http=200' '$OUT' && ! grep -q '^\[PASS\] row parity' '$OUT' && notready"

# --- D6: a list at the limit is incomplete, never READY ---
case_init d6
qrf_fixture_route GET "$QR" 200 "$(jq -nc '{deploy_queue: [range(200) | {project: "app", sha: ("\(.)" + "0000000"), status: "queued"}]}')"
claimed; run
check "D6 incomplete FAIL" "grep -qxF '[FAIL] deploy: live probe $QR incomplete: rows=200 = limit 200' '$OUT' && ! grep -q '^\[PASS\] row parity' '$OUT' && notready"

# --- D7: read-only — GETs only, nothing written, TMPDIR clean, files intact ---
case_init d7; qfile app 1700000000 "$SHA_A"; qfile app 1700000100 "$SHA_B"; queued "app:$SHA_A:queued"; claimed
SUM0=$(cat "$HARNESS"/state/deploy-queue/app/* | md5sum)
touch "$QRF_FX/marker"; sleep 0.05; run
check "D7 only GET sent" "[ \"\$(qrf_fixture_methods)\" = GET ]"
check "D7 three requests: knob, queued, claimed" "[ \"\$(qrf_fixture_reqs | tr '\n' '|')\" = 'GET /api/settings/deploy_queue_rows|GET $QR|GET $CR|' ]"
check "D7 nothing written under HARNESS" "[ -z \"\$(find '$HARNESS' -newer '$QRF_FX/marker')\" ]"
check "D7 TMPDIR empty after the run" "[ -z \"\$(ls -A '$TMPDIR')\" ]"
check "D7 queue files unchanged" "[ \"\$(cat '$HARNESS'/state/deploy-queue/app/* | md5sum)\" = '$SUM0' ]"

echo "queue-rows-flip-preflight-deploy.bh-2313: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
