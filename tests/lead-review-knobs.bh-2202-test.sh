#!/bin/bash
# tests/lead-review-knobs.bh-2202-test.sh — BH-2202: the registry bound on
# LEAD_REVIEW_DIFF_MAX_BYTES. The lead-review lane's context ceiling is 200K
# tokens (catalog/context-budgets.json), and a 2,000,000-byte diff blows past
# it, so the registry max is 600000.
#   K1  the registry entry: min <= default <= max, and max <= 600000;
#   K2  max / 3 (bytes per token, conservative for diffs) fits the lane's
#       ceiling_tokens, both read from the files, either one absent = red;
#   K3  the production path: a settings row of 2000000 goes through
#       lane_env_apply against the rendered registry and the lane gets 600000,
#       with the CLAMPED line in logs/lane-gate.log.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-knobs.bh-2202-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SRC="$DIR/catalog/lanes.d/lead-review.json"
K=$(jq -c '.knobs[]? | select(.env=="LEAD_REVIEW_DIFF_MAX_BYTES")' "$SRC" 2>/dev/null)
mn=$(jq -r '.min // empty' <<<"$K" 2>/dev/null); def=$(jq -r '.default // empty' <<<"$K" 2>/dev/null)
mx=$(jq -r '.max // empty' <<<"$K" 2>/dev/null)

# K1
if [ -n "$mn" ] && [ -n "$def" ] && [ -n "$mx" ]; then
  [ "$mn" -le "$def" ] && [ "$def" -le "$mx" ] && ok || bad "K1 bounds out of order: min=$mn default=$def max=$mx"
  [ "$mx" -le 600000 ] && ok || bad "K1 max is $mx (want <= 600000)"
else
  bad "K1 no LEAD_REVIEW_DIFF_MAX_BYTES knob with min/default/max in $SRC: '$K'"
fi

# K2
ceil=$(jq -r '.lanes[]? | select(.lane=="lead-review") | .ceiling_tokens // empty' "$DIR/catalog/context-budgets.json" 2>/dev/null | head -1)
if [ -n "$ceil" ] && [ -n "$mx" ]; then
  [ $((mx / 3)) -le "$ceil" ] && ok || bad "K2 max $mx bytes / 3 = $((mx / 3)) tokens, over the lane ceiling $ceil"
else
  bad "K2 missing value: max='$mx' ceiling_tokens='$ceil'"
fi

# K3 — lane_env_apply with a settings row above the max
mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/catalog"
cp "$DIR/bin/lib/lane-gate.sh" "$T/h/bin/lib/"
cp "$(rendered_registry)" "$T/h/catalog/lanes.json"
cat > "$T/h/bin/stub-jobs-client.sh" <<'SH'
_jobs_req() { printf '{"settings":[{"key":"lane.lead-review.lead_review_diff_max_bytes","value":"2000000"}]}'; }
SH
V=$(env -u LEAD_REVIEW_DIFF_MAX_BYTES HARNESS="$T/h" LANE_GATE_NOW=1758300000 bash -c '
  set -uo pipefail
  . "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
  lane_env_apply lead-review
  printf "%s" "${LEAD_REVIEW_DIFF_MAX_BYTES:-UNSET}"' 2>/dev/null)
[ "$V" = 600000 ] && ok || bad "K3 a 2000000 settings row reached the lane as '$V' (want 600000)"
grep -q 'LEAD_REVIEW_DIFF_MAX_BYTES CLAMPED 2000000 -> 600000' "$T/h/logs/lane-gate.log" 2>/dev/null && ok \
  || bad "K3 no CLAMPED 2000000 -> 600000 line: $(cat "$T/h/logs/lane-gate.log" 2>/dev/null)"

echo "lead-review-knobs: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
