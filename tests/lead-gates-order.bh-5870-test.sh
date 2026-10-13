#!/bin/bash
# tests/lead-gates-order.bh-5870-test.sh — BH-5875 (BH-5870.2): the silence
# gate runs BEFORE the risk tier on the lead review worklist, so a low-tier
# head never skips it. Every case drives bin/lead-review.sh tick WHOLE over the
# worklist fixture (tests/lib/lead-worklist-fixture.bh-4956.sh plus
# tests/lib/lead-gates-fixture.bh-5875.sh), with the shipped gate files
# bin/lib/lead-gates.d/30-silence.sh and bin/lib/lead-gates.d/60-risk.sh.
#   O1  PR 101 is low (one new tests/*-test.sh) and adds a gitleaks marker:
#       one needs-human label, one comment, one `[skip silence]` line, NO
#       risk-tier sign-off, NO lead_review job.
#   O2  PR 102 is low with no marker (same tick): one sign-off, no job, one
#       POST /api/risk-tiers with tier low and action sign-off.
#   O3  30-silence.sh removed (D1): PR 101 is signed off.
#   O4  30-silence.sh renamed 65-silence.sh (after the risk tier): PR 101 is
#       signed off, so the filename order is what stops the sign-off.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-order.bh-5870-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5875.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
lgf_setup
GD="$H/bin/lib/lead-gates.d"
DIR="$LWF_SRC"
for f in "$DIR/bin/lib/lead-gates.d/30-silence.sh" "$DIR/bin/lib/lead-gates.d/60-risk.sh" "$DIR/bin/lib/lead-gates-compare.sh"; do
  [ -r "$H/${f#"$DIR"/}" ] && ok || bad "setup: the closure did not install ${f#"$DIR"/}"
done
HA=$(printf '%040d' 101); HB=$(printf '%040d' 102)
# The marker is built from two halves, so this file adds no marker itself.
MARK="gitleaks:allo""w"
LOWF='[["tests/x.bh-1-test.sh","added",3,0,"@@ -0,0 +1,3 @@\n+#!/bin/bash\n+echo ok\n+exit 0"]]'
LOWM=$(jq -nc --arg m "$MARK" '[["tests/x.bh-1-test.sh","added",3,0,("@@ -0,0 +1,3 @@\n+#!/bin/bash\n+TOKEN=tok-fixture-1 # " + $m + "\n+exit 0")]]')
summ() { lwf_summary; }
restore() {
  [ -e "$T/30.off" ] && mv "$T/30.off" "$GD/30-silence.sh"
  [ -e "$GD/65-silence.sh" ] && mv "$GD/65-silence.sh" "$GD/30-silence.sh"
  return 0
}
scenario() { # the O1/O2 heads: 101 low with a marker, 102 low clean
  lgf_reset enforce
  lgf_needs "101:$HA" "102:$HB"
  lgf_cmp "$HA" "$LOWM"; lgf_cmp "$HB" "$LOWF"
}

# ── O1 + O2: both heads in one tick ──
scenario
lwf_tick
[ "$(lwf_cnt '^api -i -X POST repos/example-org/cromford/issues/101/labels' "$T/log/gh")" = 1 ] && ok || bad "O1 label POSTs: $(grep labels "$T/log/gh")"
[ "$(lwf_cnt '^api -i -X POST repos/example-org/cromford/issues/101/comments' "$T/log/gh")" = 1 ] && ok || bad "O1 comment POSTs: $(grep comments "$T/log/gh")"
[ "$(lgf_signed 101)" = 0 ] && ok || bad "O1 PR 101 was signed off: $(cat "$T/log/lv")"
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "O1 PR 101 got a lead_review job"
[ "$(lwf_cnt '\[skip silence\] example-org/cromford#101' "$L")" = 1 ] && ok || bad "O1 skip lines: $(cat "$L")"
[ "$(lgf_signed 102)" = 1 ] && ok || bad "O2 PR 102 sign-offs=$(lgf_signed 102): $(cat "$L")"
grep -q "^post example-org/cromford 102 $HB MERGE --source risk-tier --reviewer risk-tier:box-demo --note low risk: " "$T/log/lv" \
  && ok || bad "O2 lead-verdict argv: $(cat "$T/log/lv" 2>/dev/null)"
[ "$(lgf_jobs 102)" = 0 ] && ok || bad "O2 PR 102 got a lead_review job"
RB=$(grep '^POST /api/risk-tiers .*"pr":102' "$T/log/worker" | sed 's/^POST \/api\/risk-tiers //')
[ "$(jq -r '[.tier,.action] | join(" ")' <<<"$RB" 2>/dev/null)" = "low sign-off" ] && ok || bad "O2 risk-tiers body: $RB"
[[ "$(summ)" == *" skipped=2 "* && "$(summ)" == *" started=0 "* ]] && ok || bad "O1/O2 summary: $(summ)"

# ── O3: no silence gate: PR 101 is signed off (the D1 mutation) ──
mv "$GD/30-silence.sh" "$T/30.off"
scenario
lwf_tick
[ "$(lgf_signed 101)" = 1 ] && ok || bad "O3 PR 101 not signed off with 30-silence.sh gone: $(cat "$L")"
[ "$(lwf_cnt 'labels' "$T/log/gh")" = 0 ] && ok || bad "O3 a label POST without the silence gate"
restore

# ── O4: the silence gate after the risk tier: PR 101 is signed off ──
mv "$GD/30-silence.sh" "$GD/65-silence.sh"
scenario
lwf_tick
[ "$(lgf_signed 101)" = 1 ] && ok || bad "O4 PR 101 not signed off with the silence gate at 65: $(cat "$L")"
[ "$(lwf_cnt '\[skip silence\]' "$L")" = 0 ] && ok || bad "O4 a skip line"
restore

echo "lead-gates-order.bh-5870: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
