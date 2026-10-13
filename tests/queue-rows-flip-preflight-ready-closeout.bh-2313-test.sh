#!/bin/bash
# tests/queue-rows-flip-preflight-ready-closeout.bh-2313-test.sh — BH-2342
# (BH-2313.4): the ready and closeout gates of bin/queue-rows-flip-preflight.sh
# (bin/lib/qrf/ready.sh, bin/lib/qrf/closeout.sh), driven as shipped
# (bash $HARNESS/bin/queue-rows-flip-preflight.sh ready closeout) with the real
# _jobs_req behind the fake curl of tests/lib/qrf-fixture.sh. Asserts printed
# verdict lines and exit codes only.
# Run from anywhere: tests/queue-rows-flip-preflight-ready-closeout.bh-2313-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/qrf-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# The files under test, named for bin/test-impact.sh.
for f in "$DIR/bin/lib/qrf/ready.sh" "$DIR/bin/lib/qrf/closeout.sh"; do
  [ -f "$f" ] || { echo "$f missing"; exit 1; }
  bash -n "$f" || exit 1
done
check() { if eval "$2"; then ok; else bad "$1"; echo "--- out:"; cat "$OUT"; echo "--- err:"; cat "$ERR"; fi; }

case_init() {
  qrf_fixture_init "$T/$1" "$DIR" || { echo "fixture init failed"; exit 1; }
  OUT="$T/$1/out"; ERR="$T/$1/err"
  qrf_fixture_route GET /api/settings/ready_queue_rows 200 '{"setting":{"value":"0"}}'
  qrf_fixture_route GET /api/settings/closeout_aged_table 200 '{"setting":{"value":"0"}}'
  mkdir -p "$HARNESS/logs" "$HARNESS/state"
}
qline() { printf '%s\n' "$1" >> "$HARNESS/logs/READY-QUEUE.log"; }
# ready_rows <key> ... → /api/queue?status=ready answers 200 with those rows
ready_rows() {
  local k body='[]'
  for k in "$@"; do body=$(jq -c --arg k "$k" '. + [{project:"cromford",ticket_key:$k,status:"ready"}]' <<<"$body"); done
  qrf_fixture_route GET '/api/queue?status=ready' 200 "{\"queue\":$body}"
}
tsv() { printf '%s\t%s\thead\taged\n' "$1" "$2" >> "$HARNESS/state/closeout-aged-out.tsv"; }
enc() { jq -rn --arg v "$1" '$v|@uri'; }
# dir_row <dir> <http> [aged-json-array] → the per-dir GET closeout_aged_has sends
dir_row() {
  local body="${3:-}"
  [ -n "$body" ] || body=$(jq -nc --arg d "$1" '{aged:[{build_dir:$d}]}')
  qrf_fixture_route GET "/api/closeout-aged?build_dir=$(enc "$1")" "$2" "$body"
}
aged_list() { # aged_list <dir> ... → the list GET answers 200 with those rows
  local d body='[]'
  for d in "$@"; do body=$(jq -c --arg d "$d" '. + [{build_dir:$d}]' <<<"$body"); done
  qrf_fixture_route GET /api/closeout-aged 200 "{\"aged\":$body}"
}
run() { bash "$HARNESS/bin/queue-rows-flip-preflight.sh" "$@" > "$OUT" 2> "$ERR"; RC=$?; }
ready_of()    { grep -q "^RESULT: READY $1\$" "$OUT"; }
notready_of() { grep -q "^RESULT: NOT READY $1" "$OUT"; }
# X2, checked after every run: a gate with any [FAIL] line never prints READY.
x2() {
  local g
  for g in ready closeout; do
    if grep -q "^\[FAIL\] $g:" "$OUT" && ready_of "$g"; then bad "X2 $1: $g READY despite a FAIL"; else ok; fi
  done
}

D1=/root/harness/builds/cromford-BH-1-202609010000
D2=/root/harness/builds/project-3-TK-2-202609010000

# --- H1: healthy — two lines, two rows; two tsv dirs, each with an aged row ---
case_init h1
qline "BH-10 READY 2h project=cromford fix the thing"; qline "BH-11 OWED-STALE 30h [review/operator] other"
ready_rows BH-10 BH-11
tsv cromford "$D1"; tsv project-3 "$D2"; tsv cromford "$D1"
aged_list "$D1" "$D2"; dir_row "$D1" 200; dir_row "$D2" 200
touch "$QRF_FX/marker"; sleep 0.05; run ready closeout
check "H1 READY ready" "ready_of ready"
check "H1 READY closeout" "ready_of closeout"
check "H1 rc 0" "[ $RC = 0 ]"
check "H1 ready live probe PASS" "grep -qx '\[PASS\] live probe /api/queue?status=ready http=200 rows=2' '$OUT'"
check "H1 ready parity PASS" "grep -qx '\[PASS\] row parity: 2 READY-QUEUE.log line(s) matched' '$OUT'"
check "H1 closeout live probe PASS" "grep -qx '\[PASS\] live probe /api/closeout-aged http=200 rows=2' '$OUT'"
check "H1 closeout parity PASS (duplicate dir once)" "grep -qx '\[PASS\] row parity: 2 tsv dir(s) matched' '$OUT'"
check "H1 one GET per unique dir" "[ \"\$(qrf_fixture_reqs | grep -c 'closeout-aged?build_dir=')\" = 2 ]"
check "X1 H1 only GET sent" "[ \"\$(qrf_fixture_methods)\" = GET ]"
check "X1 H1 nothing written under HARNESS" "[ -z \"\$(find '$HARNESS' -newer '$QRF_FX/marker')\" ]"
x2 H1

# --- R2: a line with no row → FAIL naming the line and queue_ready_put ---
case_init r2
qline "BH-10 READY 2h project=cromford ok"; qline "BH-9 READY 1h project=cromford missing one"
qline "project-3-7 READY 1h no project token"; qline "# comment, not a live line"
ready_rows BH-10
touch "$QRF_FX/marker"; sleep 0.05; run ready
check "R2 FAIL names BH-9 and the fix" "grep -q '^\[FAIL\] ready: READY-QUEUE.log line has no ready row: BH-9 READY 1h .*fix: queue_ready_put cromford BH-9 ' '$OUT'"
check "R2 FAIL for a line without project= uses <project>" "grep -q '^\[FAIL\] ready: .*project-3-7.*fix: queue_ready_put <project> project-3-7 ' '$OUT'"
check "R2 comment line not checked" "! grep -q 'comment, not a live line' '$OUT'"
check "R2 exactly two FAILs" "[ \"\$(grep -c '^\[FAIL\] ready:' '$OUT')\" = 2 ]"
check "R2 no parity PASS" "! grep -q '^\[PASS\] row parity' '$OUT'"
check "R2 NOT READY ready, rc 1" "notready_of ready && [ $RC = 1 ]"
check "X1 R2 only GET sent" "[ \"\$(qrf_fixture_methods)\" = GET ]"
check "X1 R2 nothing written under HARNESS" "[ -z \"\$(find '$HARNESS' -newer '$QRF_FX/marker')\" ]"
x2 R2
# A key whose row is claimed is absent from status=ready, so it is missing.
case_init r2c; qline "BH-12 READY 1h project=cromford x"; ready_rows; run ready
check "R2 key with no ready row → FAIL" "grep -q '^\[FAIL\] ready: .*BH-12' '$OUT' && notready_of ready"
x2 R2c

# --- R3: rows are a superset — a row with no line is info; empty and absent log READY ---
case_init r3; qline "BH-10 READY 2h project=cromford ok"; ready_rows BH-10 BH-20 BH-21; run ready
check "R3 row with no line → info" "grep -qx '  2 ready row(s) with no READY-QUEUE.log line (rows are a superset, not a failure)' '$OUT'"
check "R3 READY ready, rc 0" "ready_of ready && [ $RC = 0 ]"
x2 R3
case_init r3e; : > "$HARNESS/logs/READY-QUEUE.log"; ready_rows; run ready
check "R3 empty log + empty rows → READY" "ready_of ready && [ $RC = 0 ] && grep -qx '\[PASS\] row parity: 0 READY-QUEUE.log line(s) matched' '$OUT'"
case_init r3n; ready_rows; run ready
check "R3 no log → info + READY" "grep -qx '  no READY-QUEUE.log on this box' '$OUT' && ready_of ready && [ $RC = 0 ]"

# --- R4: the live probe fails → FAIL http=, parity not checked ---
case_init r4; qline "BH-10 READY 2h project=cromford ok"
qrf_fixture_route GET '/api/queue?status=ready' 503 'upstream down'; run ready
check "R4 503 → FAIL http=503" "grep -q '^\[FAIL\] ready: live probe /api/queue?status=ready http=503' '$OUT'"
check "R4 parity not checked" "grep -q '^\[FAIL\] ready: row parity: not checked (live probe failed)' '$OUT'"
check "R4 NOT READY, rc 1" "notready_of ready && [ $RC = 1 ]"
x2 R4
case_init r4h; qrf_fixture_route GET '/api/queue?status=ready' 200 '<html>oops</html>'; run ready
check "R4 HTML 200 → FAIL" "grep -q '^\[FAIL\] ready: live probe /api/queue?status=ready http=200' '$OUT' && notready_of ready && [ $RC = 1 ]"
x2 R4h

# --- R5: a list at its limit is incomplete ---
case_init r5; qrf_fixture_route GET '/api/queue?status=ready' 200 "$(jq -nc '{queue:[range(200)|{ticket_key:"BH-\(.)"}]}')"; run ready
check "R5 incomplete at 200" "grep -q '^\[FAIL\] ready: live probe /api/queue?status=ready incomplete: rows=200 = limit 200' '$OUT'"
check "R5 parity not checked" "grep -q '^\[FAIL\] ready: row parity: not checked' '$OUT' && ! grep -q '^\[PASS\] row parity' '$OUT'"
check "R5 NOT READY" "notready_of ready && [ $RC = 1 ]"
x2 R5

# --- C2: a tsv dir with no aged row → FAIL naming dir and closeout_aged_put ---
case_init c2; tsv cromford "$D1"; tsv project-3 "$D2"
aged_list "$D1"; dir_row "$D1" 200; dir_row "$D2" 200 '{"aged":[]}'
touch "$QRF_FX/marker"; sleep 0.05; run closeout
check "C2 FAIL names dir and fix" "grep -qx '\[FAIL\] closeout: closeout tsv dir has no aged row: $D2 — fix: closeout_aged_put project-3 $D2' '$OUT'"
check "C2 one FAIL" "[ \"\$(grep -c '^\[FAIL\] closeout:' '$OUT')\" = 1 ]"
check "C2 NOT READY closeout, rc 1" "notready_of closeout && [ $RC = 1 ]"
check "X1 C2 only GET sent" "[ \"\$(qrf_fixture_methods)\" = GET ]"
check "X1 C2 nothing written under HARNESS" "[ -z \"\$(find '$HARNESS' -newer '$QRF_FX/marker')\" ]"
x2 C2

# --- C3: a row with no tsv line is info; empty and absent tsv READY ---
case_init c3; tsv cromford "$D1"; aged_list "$D1" "$D2" /x/other; dir_row "$D1" 200; run closeout
check "C3 row with no tsv line → info" "grep -qx '  2 aged row(s) with no tsv line (rows are a superset, not a failure)' '$OUT'"
check "C3 READY closeout, rc 0" "ready_of closeout && [ $RC = 0 ]"
x2 C3
case_init c3e; : > "$HARNESS/state/closeout-aged-out.tsv"; aged_list; run closeout
check "C3 empty tsv + empty rows → READY" "ready_of closeout && [ $RC = 0 ] && grep -qx '\[PASS\] row parity: 0 tsv dir(s) matched' '$OUT'"
case_init c3n; aged_list; run closeout
check "C3 no tsv → info + READY" "grep -q '^  no closeout-aged-out.tsv' '$OUT' && ready_of closeout && [ $RC = 0 ]"

# --- C4: the list probe answers 503 → FAIL, no per-dir GET ---
case_init c4; tsv cromford "$D1"; dir_row "$D1" 200
qrf_fixture_route GET /api/closeout-aged 503 'down'; run closeout
check "C4 FAIL http=503" "grep -q '^\[FAIL\] closeout: live probe /api/closeout-aged http=503' '$OUT'"
check "C4 parity not checked" "grep -q '^\[FAIL\] closeout: row parity: not checked (live probe failed)' '$OUT'"
check "C4 no per-dir GET" "! qrf_fixture_reqs | grep -q 'build_dir='"
check "C4 NOT READY, rc 1" "notready_of closeout && [ $RC = 1 ]"
x2 C4

# --- C5: 200 with a non-array .aged → FAIL ---
case_init c5; qrf_fixture_route GET /api/closeout-aged 200 '{"aged":{}}'; run closeout
check "C5 non-array → FAIL http=200" "grep -q '^\[FAIL\] closeout: live probe /api/closeout-aged http=200' '$OUT' && notready_of closeout && [ $RC = 1 ]"
check "C5 no live probe PASS" "! grep -q '^\[PASS\] live probe /api/closeout-aged' '$OUT'"
x2 C5

# --- C6: a per-dir GET is an outage → FAIL, loop stops, never a pass ---
D3=/root/harness/builds/project-4-C-3-202609010000
case_init c6; tsv cromford "$D1"; tsv project-3 "$D2"; tsv project-4 "$D3"
aged_list "$D1" "$D2" "$D3"; dir_row "$D1" 200; dir_row "$D2" 503 'down'; dir_row "$D3" 200
run closeout
check "C6 FAIL names the per-dir probe as an outage" "grep -qF '[FAIL] closeout: live probe /api/closeout-aged?build_dir=$D2 failed: closeout_aged_has rc=1 (outage' '$OUT'"
check "C6 no stale http= from the list probe" "! grep -q 'build_dir=.*http=200' '$OUT'"
check "C6 client's http=503 on stderr" "grep -q 'build_dir=.*http=503' '$ERR'"
check "C6 parity not checked past the dir" "grep -qF '[FAIL] closeout: row parity: not checked past $D2 (outage)' '$OUT'"
check "C6 no parity PASS" "! grep -q '^\[PASS\] row parity' '$OUT'"
check "C6 no GET for the later dir" "! qrf_fixture_reqs | grep -qF \"build_dir=\$(enc '$D3')\""
check "C6 NOT READY, rc 1" "notready_of closeout && [ $RC = 1 ]"
x2 C6

# --- NEGATIVE: the modules never say they flipped anything ---
check "X2 no 'flipped' in the modules" "! grep -il flipped '$DIR/bin/lib/qrf/ready.sh' '$DIR/bin/lib/qrf/closeout.sh'"

echo "queue-rows-flip-preflight-ready-closeout.bh-2313: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
