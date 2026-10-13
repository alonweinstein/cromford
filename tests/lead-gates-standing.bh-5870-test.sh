#!/bin/bash
# tests/lead-gates-standing.bh-5870-test.sh — BH-5874 (BH-5870.1): gate 2,
# bin/lib/lead-gates.d/20-standing.sh, on the lead review worklist. Every case
# drives bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh, LEAD_REVIEW_WORKLIST=1). The
# standing verdict is the `.standing` key of the fixture's GET /api/verdicts.
#   S0  nothing stands on the head: one lead_review job.
#   S1  a lead MERGE stands: no job, one `[skip verdict]` line.
#   S2  a human verdict stands, then a risk-tier one: no job each time.
#   S3  risk-tier standing plus the enqueue's risk-pub marker: exactly one
#       statuses/<head> POST, the marker is gone, `published on retry`.
#   S3b a second tick after S3: no further statuses POST.
#   S3c the status POST answers 500: the marker stays, `still not published`;
#       the next tick publishes it once.
#   S3d a lead verdict stands and a marker exists: no statuses POST.
#   S4  the standing read answers 500: no job, held=1.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-standing.bh-5870-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
S12="${SHA:0:12}"
[ -r "$H/bin/lib/lead-gates.d/20-standing.sh" ] && ok || bad "setup: the closure of bin/lead-review.sh did not install bin/lib/lead-gates.d/20-standing.sh"
MARK="$H/state/lead-review-enqueue/risk-pub-example-org_demo-os-101-$S12"
jobs101() { lwf_cnt '^POST /api/jobs .*"ticket_id":"lr-101-' "$T/log/worker"; }
skips() { lwf_cnt "\[skip verdict\] example-org/demo-os#101 @$S12 " "$L"; }
statuses() { lwf_cnt "POST repos/example-org/demo-os/statuses/$SHA" "$T/log/gh"; }
# standing <source> <verdict> — the verdict standing on $SHA
standing() {
  jq -nc --arg s "$1" --arg v "$2" --arg h "$SHA" \
    '{rows:[], truncated:false, standing:{verdict:$v, source:$s, id:31, created_at:"2026-10-10T03:00:00Z", head_sha:$h}}' > "$FX/verdicts.json"
}
reset() { lwf_reset; scratch_rm "$H/state/lead-review-enqueue"; lwf_needs example-org/demo-os 101; }

# ── S0: nothing stands ──
reset
lwf_tick
[ "$(jobs101)" = 1 ] && ok || bad "S0 jobs=$(jobs101) (want 1): $(cat "$L")"
[ "$(skips)" = 0 ] && ok || bad "S0 a [skip verdict] line with nothing standing"

# ── S1: a lead verdict stands ──
reset; standing lead MERGE
lwf_tick
[ "$(jobs101)" = 0 ] && ok || bad "S1 jobs=$(jobs101) (want 0): $(cat "$L")"
[ "$(lwf_agents)" = 0 ] && ok || bad "S1 agent calls=$(lwf_agents)"
[ "$(skips)" = 1 ] && ok || bad "S1 [skip verdict] lines=$(skips): $(cat "$L")"
grep -q "\[skip verdict\] example-org/demo-os#101 @$S12 a lead verdict stands on this head" "$L" && ok || bad "S1 skip text: $(grep skip "$L")"
[[ "$(lwf_summary)" == *" skipped=1 "* ]] && ok || bad "S1 summary: $(lwf_summary)"

# ── S2: human, then risk-tier ──
for src in human risk-tier; do
  reset; standing "$src" MERGE
  lwf_tick
  [ "$(jobs101)" = 0 ] && ok || bad "S2 $src: jobs=$(jobs101) (want 0)"
  grep -q "a $src verdict stands on this head" "$L" && ok || bad "S2 $src: no skip line: $(cat "$L")"
  [ "$(statuses)" = 0 ] && ok || bad "S2 $src with no marker: statuses POSTs=$(statuses)"
done

# ── S3 / S3b: an unpublished risk-tier status is published once ──
reset; standing risk-tier MERGE
mkdir -p "${MARK%/*}"; printf 'risk tier low: rules-text change, signed off' > "$MARK"
lwf_tick
[ "$(statuses)" = 1 ] && ok || bad "S3 statuses POSTs=$(statuses) (want 1): $(cat "$T/log/gh")"
grep -q "statuses/$SHA .*description=risk tier low: rules-text change, signed off" "$T/log/gh" && ok || bad "S3 the status does not carry the marker text: $(grep statuses "$T/log/gh")"
[ ! -e "$MARK" ] && ok || bad "S3 the marker is still there"
grep -q "example-org/demo-os#101 @$S12: risk-tier lead-verdict status published on retry" "$L" && ok || bad "S3 no published line: $(cat "$L")"
[ "$(jobs101)" = 0 ] && ok || bad "S3 jobs=$(jobs101)"
lwf_tick
[ "$(statuses)" = 1 ] && ok || bad "S3b statuses POSTs after a second tick=$(statuses) (want 1)"

# ── S3c: the publish fails, the marker stays, the next tick publishes ──
reset; standing risk-tier MERGE
mkdir -p "${MARK%/*}"; printf 'risk tier low' > "$MARK"; : > "$FX/statusfail"
lwf_tick
[ -e "$MARK" ] && ok || bad "S3c the marker went on a failed publish"
grep -q "example-org/demo-os#101 @$S12: risk-tier lead-verdict status still not published; next tick retries" "$L" && ok || bad "S3c no retry line: $(cat "$L")"
rm -f "$FX/statusfail"; n0=$(statuses)
lwf_tick
[ "$(( $(statuses) - n0 ))" = 1 ] && ok || bad "S3c the retry tick posted $(( $(statuses) - n0 )) statuses (want 1)"
[ ! -e "$MARK" ] && ok || bad "S3c the marker is still there after the retry"

# ── S3d: a lead verdict with a marker: never republished ──
reset; standing lead MERGE
mkdir -p "${MARK%/*}"; printf 'risk tier low' > "$MARK"
lwf_tick
[ "$(statuses)" = 0 ] && ok || bad "S3d statuses POSTs=$(statuses) for a lead verdict (want 0)"
[ -e "$MARK" ] && ok || bad "S3d the marker went"

# ── S4: the standing read fails: held, never 'nothing stands' ──
reset; : > "$FX/standing.fail"
lwf_tick
[ "$(jobs101)" = 0 ] && ok || bad "S4 jobs=$(jobs101) (want 0)"
[[ "$(lwf_summary)" == *" held=1"* ]] && ok || bad "S4 summary: $(lwf_summary)"
grep -q "example-org/demo-os#101 @$S12: standing verdict unreadable (rc 2); held" "$L" && ok || bad "S4 no unreadable line: $(cat "$L")"

echo "lead-gates-standing.bh-5870: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
