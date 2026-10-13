#!/bin/bash
# tests/qrf-merge-live.bh-3221-test.sh — BH-3221: the merge gate of
# bin/queue-rows-flip-preflight.sh (bin/lib/qrf/merge.sh) lists only the live
# merge statuses (queued, blocked) at the route's clamp (limit=500), never the
# unfiltered ?project=<p> list, which keeps landed/dropped rows and so sits at
# its default limit of 200 for any project with a history. Driven as shipped
# (bash $HARNESS/bin/queue-rows-flip-preflight.sh merge) with the real
# _jobs_req behind the fake curl of tests/lib/qrf-fixture.sh.
# Run from anywhere: tests/qrf-merge-live.bh-3221-test.sh (exit 0 = all pass)
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
# body <project> <status> <pr...> → a {"merge_queue":[...]} body, every row at <status>
body() {
  local p="$1" s="$2"; shift 2
  jq -nc --arg p "$p" --arg s "$s" '{merge_queue:[$ARGS.positional[]|{project:$p,pr:tonumber,status:$s}]}' --args "$@"
}
# live <project> <status> <pr...> → the filtered live-status route answers those rows
live() {
  local p="$1" s="$2"; shift 2
  qrf_fixture_route GET "/api/merge-queue?project=$p&status=$s&limit=500" 200 "$(body "$p" "$s" "$@")"
}
# unfiltered <project> <pr:status>... → the old ?project=<p> route answers 250
# terminal rows plus the live ones given, as the worker does for a project with
# a history. Only a gate that still sends the unfiltered read ever reads it.
unfiltered() {
  local p="$1"; shift
  qrf_fixture_route GET "/api/merge-queue?project=$p" 200 "$(jq -nc --arg p "$p" '
    {merge_queue:([range(250)|{project:$p,pr:(.+1000),status:(if . % 2 == 0 then "landed" else "dropped" end)}]
      + [$ARGS.positional[]|split(":")|{project:$p,pr:(.[0]|tonumber),status:.[1]}])}' --args "$@")"
}
run() { bash "$HARNESS/bin/queue-rows-flip-preflight.sh" merge > "$OUT" 2> "$ERR"; RC=$?; }
ready()    { grep -q '^RESULT: READY merge$' "$OUT" && [ "$RC" = 0 ]; }
notready() { grep -q '^RESULT: NOT READY merge' "$OUT" && [ "$RC" = 1 ]; }
fails()    { grep -c '^\[FAIL\] merge:' "$OUT"; }

# --- L1 (AT1): 250 terminal rows + 3 live rows matching 3 files → READY ---
case_init l1
qfile alpha 12; qfile alpha 13; qfile alpha 14.blocked
unfiltered alpha 12:queued 13:queued 14:blocked
live alpha queued 12 13; live alpha blocked 14; run
check "L1 parity PASS, 3 matched" "grep -qx '\[PASS\] row parity alpha: 3 file(s) matched' '$OUT'"
check "L1 no FAIL" "[ \"\$(fails)\" = 0 ]"
check "L1 READY, rc 0" "ready"

# --- L2 (AT2): one row missing → FAIL naming the file ---
case_init l2
qfile alpha 12; qfile alpha 13; qfile alpha 14.blocked
unfiltered alpha 12:queued 14:blocked
live alpha queued 12; live alpha blocked 14; run
check "L2 FAIL names alpha/13 and the put fix" "grep '^\[FAIL\] merge:' '$OUT' | grep 'state/merge-queue/alpha/13 ' | grep -q 'merge_queue_put alpha 13'"
check "L2 exactly one FAIL" "[ \"\$(fails)\" = 1 ]"
check "L2 NOT READY, rc 1" "notready"

# --- L3 (AT3): a live status at the clamp → incomplete, parity not checked ---
case_init l3; qfile alpha 12
qrf_fixture_route GET '/api/merge-queue?project=alpha&status=queued&limit=500' 200 \
  "$(jq -nc '{merge_queue:[range(500)|{project:"alpha",pr:(.+1),status:"queued"}]}')"
live alpha blocked; run
check "L3 incomplete at the clamp" "grep -q '^\[FAIL\] merge: live probe /api/merge-queue?project=alpha&status=queued&limit=500 incomplete: rows=500 = limit 500' '$OUT'"
check "L3 parity not checked" "grep -q 'row parity for alpha not checked: live probe failed' '$OUT'"
check "L3 no parity PASS" "! grep -q '^\[PASS\] row parity' '$OUT'"
check "L3 NOT READY, rc 1" "notready"

# --- L4 (R4): queued read good, blocked read 503 → parity not checked ---
case_init l4; qfile alpha 12; qfile alpha 14.blocked
live alpha queued 12
qrf_fixture_route GET '/api/merge-queue?project=alpha&status=blocked&limit=500' 503 'unavailable'; run
check "L4 FAIL http=503 on the blocked read" "grep -q '^\[FAIL\] merge: live probe /api/merge-queue?project=alpha&status=blocked&limit=500 http=503' '$OUT'"
check "L4 parity not checked" "grep -q 'row parity for alpha not checked: live probe failed' '$OUT'"
check "L4 no parity PASS" "! grep -q '^\[PASS\] row parity' '$OUT'"
check "L4 only the probe FAILs, no parity verdict on a partial list" "[ \"\$(fails)\" = 1 ]"
check "L4 NOT READY, rc 1" "notready"

# --- L5 (R1/R2): both live-status reads sent, never the unfiltered list ---
case_init l5; qfile alpha 12; qfile alpha 14.blocked
unfiltered alpha 12:queued 14:blocked
live alpha queued 12; live alpha blocked 14; run
check "L5 queued read sent" "qrf_fixture_reqs | grep -qx 'GET /api/merge-queue?project=alpha&status=queued&limit=500'"
check "L5 blocked read sent" "qrf_fixture_reqs | grep -qx 'GET /api/merge-queue?project=alpha&status=blocked&limit=500'"
check "L5 no unfiltered read" "! qrf_fixture_reqs | grep '^GET /api/merge-queue?project=alpha' | grep -qv '&status='"
check "L5 READY" "ready"

# --- L6: read-only — GETs only, nothing under HARNESS, TMPDIR clean ---
case_init l6; qfile alpha 12; qfile alpha 14.blocked
live alpha queued 12; live alpha blocked 14
touch "$QRF_FX/marker"; sleep 0.05; run
check "L6 only GET sent" "[ \"\$(qrf_fixture_methods)\" = GET ]"
check "L6 no EXEC" "! qrf_fixture_reqs | grep -q '^EXEC'"
check "L6 nothing written under HARNESS" "[ -z \"\$(find '$HARNESS' -newer '$QRF_FX/marker')\" ]"
check "L6 TMPDIR empty after the run" "[ -z \"\$(ls -A '$TMPDIR')\" ]"

echo "qrf-merge-live.bh-3221: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
