#!/bin/bash
# tests/lead-review-throughput.bh-4956-test.sh — BH-4956: one bin/lead-review.sh
# tick starts every eligible worklist item as soon as a slot is free, with no
# per-tick start cap, under the fleet-wide settings row lead_review.concurrency.
# The agent stub blocks until the suite releases it, so the in-flight count is
# read while the SAME tick runs (tests/lib/lead-worklist-fixture.bh-4956.sh).
#   T1-1 row lead_review.concurrency=4, 10 items: exactly 4 calls in flight.
#   T1-2 one released: a 5th starts while the same tick PID is alive.
#   T1-3 all released: 10 calls in one tick, `started=10`, no start cap.
#   T1-4 3 lead_review jobs running on another box: exactly 1 in flight here.
#        The running count unreadable (500): nothing starts, and a log line.
#   T1-5 no row: the box cap governs (LEAD_REVIEW_CONCURRENCY=3 = 3 in flight).
#   T1-6 LEAD_REVIEW_DEADLINE_S passes with 2 running: no new start after it,
#        the 2 finish and record, and the tick exits only after them.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-throughput.bh-4956-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
TEN="101 102 103 104 105 106 107 108 109 110"
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os" LEAD_REVIEW_CONCURRENCY=10
live_is() { [ "$(lwf_live)" = "$1" ]; }
agents_ge() { [ "$(lwf_agents)" -ge "$1" ]; }
tick_gone() { ! kill -0 "$TICK_PID" 2>/dev/null; }
finish() { : > "$FX/release.all"; lwf_wait 60 tick_gone || { bad "$1: the tick did not end"; kill "$TICK_PID" 2>/dev/null; }; wait "$TICK_PID" 2>/dev/null; }

# ── T1-1 .. T1-3: the row is 4, ten items ──
lwf_reset; : > "$FX/block"
lwf_needs example-org/demo-os $TEN
echo 4 > "$FX/settings/lead_review.concurrency"
lwf_tick_bg
lwf_wait 30 live_is 4 || bad "T1-1 never reached 4 in flight (live=$(lwf_live)): $(cat "$L" 2>/dev/null)"
sleep 1
[ "$(lwf_live)" = 4 ] && ok || bad "T1-1 live=$(lwf_live) (want 4)"
[ "$(lwf_agents)" = 4 ] && ok || bad "T1-1 agent calls=$(lwf_agents) (want 4)"
: > "$FX/release.101"
lwf_wait 30 agents_ge 5 || bad "T1-2 no 5th start after one release"
kill -0 "$TICK_PID" 2>/dev/null && ok || bad "T1-2 the 5th did not start inside the same tick"
[ "$(lwf_agents)" = 5 ] && ok || bad "T1-2 agent calls=$(lwf_agents) (want 5)"
finish T1-3
[ "$(lwf_agents)" = 10 ] && ok || bad "T1-3 agent calls=$(lwf_agents) (want 10): $(cat "$L")"
[ "$(lwf_peak)" = 4 ] && ok || bad "T1-3 peak in flight=$(lwf_peak) (want 4)"
[ "$(grep -c ' tick seen=' "$L")" = 1 ] && ok || bad "T1-3 want one tick: $(grep ' tick seen=' "$L")"
S=$(lwf_summary)
[[ "$S" == *" started=10 "* && "$S" == *" done=10 "* && "$S" == *" deferred=0 "* && "$S" == *" worklist=10 "* ]] && ok || bad "T1-3 summary: $S"
[ "$(lwf_cnt '"outcome":"done"' "$T/log/worker")" = 10 ] && ok || bad "T1-3 done results=$(lwf_cnt '"outcome":"done"' "$T/log/worker")"

# ── T1-4: three running elsewhere, the row is 4 ──
lwf_reset; : > "$FX/block"
lwf_needs example-org/demo-os $TEN
echo 4 > "$FX/settings/lead_review.concurrency"
echo '[{"box":"box-other"},{"box":"box-other"},{"box":"box-third"}]' > "$FX/jobsrun.json"
lwf_tick_bg
lwf_wait 30 live_is 1 || bad "T1-4 nothing started: $(cat "$L" 2>/dev/null)"
sleep 1.5
[ "$(lwf_live)" = 1 ] && ok || bad "T1-4 live=$(lwf_live) (want 1)"
[ "$(lwf_agents)" = 1 ] && ok || bad "T1-4 agent calls=$(lwf_agents) (want 1)"
grep -q '^GET /api/jobs?kind=lead_review&status=running&limit=500' "$T/log/worker" && ok || bad "T1-4 no running-count read"
finish T1-4
[ "$(lwf_peak)" = 1 ] && ok || bad "T1-4 peak=$(lwf_peak) (want 1)"
# the running count unreadable with a row present: nothing starts
lwf_reset
lwf_needs example-org/demo-os 101 102
echo 4 > "$FX/settings/lead_review.concurrency"
: > "$FX/jobsrun.fail"
lwf_tick
[ "$(lwf_agents)" = 0 ] && ok || bad "T1-4b agent calls=$(lwf_agents) with the count unreadable"
grep -q '^POST /api/lead-reviews/start' "$T/log/worker" && bad "T1-4b a /start with the count unreadable" || ok
grep -q 'running count unreadable; no start this pass' "$L" && ok || bad "T1-4b no log line: $(cat "$L")"
S=$(lwf_summary)
[[ "$S" == *" started=0 "* && "$S" == *" deferred=2 "* ]] && ok || bad "T1-4b summary: $S"

# ── T1-5: no row, the box cap governs ──
lwf_reset; : > "$FX/block"
lwf_needs example-org/demo-os $TEN
LEAD_REVIEW_CONCURRENCY=3 lwf_tick_bg
lwf_wait 30 live_is 3 || bad "T1-5 never reached 3 in flight (live=$(lwf_live))"
sleep 1
[ "$(lwf_live)" = 3 ] && ok || bad "T1-5 live=$(lwf_live) (want 3)"
finish T1-5
[ "$(lwf_peak)" = 3 ] && ok || bad "T1-5 peak=$(lwf_peak) (want 3)"
[ "$(lwf_agents)" = 10 ] && ok || bad "T1-5 agent calls=$(lwf_agents) (want 10)"
grep -q 'no lead_review.concurrency row; the box cap governs' "$L" && ok || bad "T1-5 no fallback line"
grep -q '^GET /api/jobs?kind=lead_review' "$T/log/worker" && bad "T1-5 a running-count read with no row" || ok

# ── T1-6: the deadline closes starts, the running ones finish ──
lwf_reset; : > "$FX/block"
lwf_needs example-org/demo-os 101 102 103 104 105
T0=$(date +%s)
LEAD_REVIEW_CONCURRENCY=2 LEAD_REVIEW_DEADLINE_S=5 lwf_tick_bg
lwf_wait 30 live_is 2 || bad "T1-6 never reached 2 in flight"
while [ $(( $(date +%s) - T0 )) -lt 7 ]; do sleep 0.2; done
kill -0 "$TICK_PID" 2>/dev/null && ok || bad "T1-6 the tick ended while 2 reviews were running"
[ "$(lwf_agents)" = 2 ] && ok || bad "T1-6 agent calls=$(lwf_agents) before release (want 2)"
finish T1-6
[ "$(lwf_agents)" = 2 ] && ok || bad "T1-6 a start after the deadline: agent calls=$(lwf_agents)"
[ "$(lwf_cnt '"outcome":"done"' "$T/log/worker")" = 2 ] && ok || bad "T1-6 the running reviews did not record"
S=$(lwf_summary)
[[ "$S" == *" done=2 "* && "$S" == *" deferred=3 "* && "$S" == *" started=2 "* ]] && ok || bad "T1-6 summary: $S"

echo "lead-review-throughput.bh-4956: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
