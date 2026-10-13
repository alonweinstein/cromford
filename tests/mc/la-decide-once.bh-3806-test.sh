#!/bin/bash
# tests/mc/la-decide-once.bh-3806-test.sh — BH-3806: a governed READY row asks
# la_decide ONCE per (PR, head) per tick. Before, the BH-3777 gate asked and
# then mc_enqueue_mergify asked again, and every la_decide costs two or more
# REST reads. The answer is memoised in the PR's own worker (mc_la_decide).
#
# WHAT IS DRIVEN. The real bin/merge-conductor.sh, merge mode, over a Mergify
# repo (tests/lib/nhv-conductor-fixture.sh); the stub la_decide logs each call.
#   L1  one READY row, la rc 0, one tick to QUEUED: 1 call for (PR, head)
#   L2  two READY rows in one tick: 1 call each
#   L3  a labelled QUEUED row the BH-3806 unqueue takes off (detector, then the
#       gate on the memo, no enqueue): 1 call
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc/la-decide-once.bh-3806-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# shellcheck source=tests/lib/nhv-conductor-fixture.sh
. "$(dirname "$0")/../lib/nhv-conductor-fixture.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

nhvf_setup || { echo "FAIL: fixture setup"; exit 1; }
H41=aaaaaaaa00aaaaaaaaaaaaaaaaaaaaaaaaaaaa41
H42=bbbbbbbb00bbbbbbbbbbbbbbbbbbbbbbbbbbbb42
calls() { grep -c -- "^example-org/mgfy-os $1 $2 conductor" "$T/la-calls.txt" 2>/dev/null; }

# ── L1 ──────────────────────────────────────────────────────────────────────
nhvf_pr 41 "$H41"
nhvf_reset
nhvf_la 0 "no protected path"; nhvf_tick
[ "$(nhvf_field 41 2)" = QUEUED ] && ok || bad "L1 setup: the row goes READY -> QUEUED (got '$(nhvf_field 41 2)'; log: $(grep -F '#41' "$CLOG" | tail -3))"
[ "$(calls 41 "$H41")" = 1 ] && ok || bad "L1: one la_decide for (41, head) in the tick (calls: $(cat "$T/la-calls.txt"))"

# ── L2 ──────────────────────────────────────────────────────────────────────
nhvf_pr 42 "$H42"
nhvf_reset
nhvf_la 0 "no protected path"; nhvf_tick
[ "$(nhvf_field 41 2)" = QUEUED ] && [ "$(nhvf_field 42 2)" = QUEUED ] && ok || bad "L2 setup: both rows QUEUED (41 '$(nhvf_field 41 2)', 42 '$(nhvf_field 42 2)')"
[ "$(calls 41 "$H41")" = 1 ] && [ "$(calls 42 "$H42")" = 1 ] && ok || bad "L2: one la_decide per row (calls: $(cat "$T/la-calls.txt"))"
[ "$(nhvf_count . la-calls.txt)" = 2 ] && ok || bad "L2: two calls in all (calls: $(cat "$T/la-calls.txt"))"

# ── L3 ──────────────────────────────────────────────────────────────────────
: > "$T/prs"; nhvf_pr 41 "$H41"
nhvf_reset
nhvf_la 0 "no protected path"; nhvf_tick
nhvf_la 1 "touches protected paths: catalog/switches.d/x-off.json"; nhvf_clear; nhvf_tick
[ "$(nhvf_field 41 2)" = NEEDS_HUMAN_VERDICT ] && ok || bad "L3 setup: the labelled row is unqueued to NEEDS_HUMAN_VERDICT (got '$(nhvf_field 41 2)')"
[ "$(calls 41 "$H41")" = 1 ] && ok || bad "L3: the detector and the gate share one la_decide (calls: $(cat "$T/la-calls.txt"))"

echo "la-decide-once.bh-3806-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
