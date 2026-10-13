#!/bin/bash
# tests/review-prs-parallel-slow.bh-5311-test.sh — BH-5311: the BH-5284 pool
# suite was red on main (run 37691240774, R6 peak 10 of 12) because its peak
# cases raced a fixed agent-call sleep against each PR's SERIAL pre-gate work
# (bin/review-prs.sh waits for a worker's gate before starting the next). On a
# slow runner the first reviews finished before the last ones started. This
# suite reruns that suite with every gh read slowed (RPP_GH_DELAY_S), the
# shape of a loaded CI box, and requires it fully green: the peak cases must
# measure the pool's cap, never the box's speed.
#   S1  RPP_GH_DELAY_S=0.6: review-prs-parallel.bh-5284 exits 0, 0 failed.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-prs-parallel-slow.bh-5311-test.sh
set -uo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# TEST-CHANGE (BH-5544): the default delay was 0.1. 0.6 s is the measured load
# that turns main's 30 s total barrier red (R6 peak 9 or 10 of 12), so this
# suite now pins the load case.
OUT=$(RPP_GH_DELAY_S="${RPP_GH_DELAY_S:-0.6}" bash "$SRC/tests/review-prs-parallel.bh-5284-test.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "S1 the BH-5284 suite went red with slow gh reads (rc=$rc): $(grep '^FAIL' <<<"$OUT" | head -5)"
grep -qE 'review-prs-parallel\.bh-5284: [0-9]+ passed, 0 failed' <<<"$OUT" && ok || bad "S1 no clean summary line: $(tail -3 <<<"$OUT")"
echo "review-prs-parallel-slow.bh-5311: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
