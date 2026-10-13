#!/bin/bash
# tests/lead-review-knobs.bh-3479-test.sh — BH-3479.0 (ticket BH-3544): the lead
# review contract knobs in catalog/lanes.d/lead-review-land.json and
# catalog/lanes.d/lead-review.json, and what lane_env_apply exports for them.
#   R1  LEAD_REVIEW_AUTO_REPOS: string, default example-org/cromford, required;
#   R2  LEAD_REVIEW_SPOTCHECK_PCT: int 10, 0..100 percent, zero_means off, required;
#   R3  LEAD_REVIEW_THREAD_MAX_BYTES: int 60000, 1000..500000 bytes, required;
#   R4  LEAD_REVIEW_AUTO_REPOS is settable:false (a *_REPOS row could re-aim a root lane);
#   E1  lane_env_apply lead-review-land with no settings row exports both defaults;
#   E2  lane_env_apply lead-review with no settings row exports THREAD_MAX 60000;
#   E3  an AUTO_REPOS row is refused (not settable) and a SPOTCHECK row of 150 clamps to 100.
# Rooted sources: "$DIR/bin/lib/lane-gate.sh", and tests/lib/rendered.sh renders
# the registry with "$DIR/bin/lanes-build.sh".
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-knobs.bh-3479-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

LAND="$DIR/catalog/lanes.d/lead-review-land.json"
LANE="$DIR/catalog/lanes.d/lead-review.json"
fields() { # fields <file> <env> -> the knob's contract fields as one compact array
  jq -c --arg e "$2" '.knobs[]? | select(.env==$e) | [.type,.default,.min,.max,.unit,.zero_means,.required]' "$1" 2>/dev/null
}

# R1-R4
G=$(fields "$LAND" LEAD_REVIEW_AUTO_REPOS)
[ "$G" = '["string","example-org/cromford",null,null,null,null,true]' ] && ok || bad "R1 LEAD_REVIEW_AUTO_REPOS is '$G'"
G=$(fields "$LAND" LEAD_REVIEW_SPOTCHECK_PCT)
[ "$G" = '["int",10,0,100,"percent","off",true]' ] && ok || bad "R2 LEAD_REVIEW_SPOTCHECK_PCT is '$G'"
G=$(fields "$LANE" LEAD_REVIEW_THREAD_MAX_BYTES)
[ "$G" = '["int",60000,1000,500000,"bytes",null,true]' ] && ok || bad "R3 LEAD_REVIEW_THREAD_MAX_BYTES is '$G'"
G=$(jq -c '.knobs[]? | select(.env=="LEAD_REVIEW_AUTO_REPOS") | .settable' "$LAND" 2>/dev/null)
[ "$G" = false ] && ok || bad "R4 LEAD_REVIEW_AUTO_REPOS settable is '$G' (want false)"

# E1-E3 — the production path: lane_env_apply against the rendered registry
mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/catalog"
cp "$DIR/bin/lib/lane-gate.sh" "$T/h/bin/lib/"
cp "$(rendered_registry)" "$T/h/catalog/lanes.json"
apply() { # apply <settings json> <lane> -> the three knobs as seen by the lane
  rm -rf "$T/h/state" && mkdir -p "$T/h/state"   # a fresh settings cache per call
  printf '_jobs_req() { printf %%s %q; }\n' "$1" > "$T/h/bin/stub-jobs-client.sh"
  env -u LEAD_REVIEW_AUTO_REPOS -u LEAD_REVIEW_SPOTCHECK_PCT -u LEAD_REVIEW_THREAD_MAX_BYTES \
    HARNESS="$T/h" LANE_GATE_NOW=1758300000 LANE="$2" bash -c '
    set -uo pipefail
    . "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
    lane_env_apply "$LANE"
    printf "%s|%s|%s" "${LEAD_REVIEW_AUTO_REPOS:-UNSET}" "${LEAD_REVIEW_SPOTCHECK_PCT:-UNSET}" "${LEAD_REVIEW_THREAD_MAX_BYTES:-UNSET}"' 2>/dev/null
}
V=$(apply '{"settings":[]}' lead-review-land)
[ "$V" = 'example-org/cromford|10|UNSET' ] && ok || bad "E1 lead-review-land with no row exported '$V'"
V=$(apply '{"settings":[]}' lead-review)
[ "$V" = 'UNSET|UNSET|60000' ] && ok || bad "E2 lead-review with no row exported '$V'"
V=$(apply '{"settings":[{"key":"lane.lead-review-land.lead_review_auto_repos","value":"evil/repo"},{"key":"lane.lead-review-land.lead_review_spotcheck_pct","value":"150"}]}' lead-review-land)
[ "$V" = 'example-org/cromford|100|UNSET' ] && ok || bad "E3 rows evil/repo + 150 reached the lane as '$V'"

echo "lead-review-knobs.bh-3479: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
