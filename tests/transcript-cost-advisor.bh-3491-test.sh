#!/bin/bash
# tests/transcript-cost-advisor.bh-3491-test.sh — BH-3491: `bin/transcript-cost.sh
# --advisor` prices the advisor's sub-inferences (usage.iterations[] entries of
# type advisor_message) at their own model, deduped on the API response like the
# executor sum, and the default mode is untouched by them.
#
#   AT-T1  default mode on an advised transcript = executor-only totals
#   AT-T2  --advisor = the advisor sums, one response repeated on 3 lines counts once
#   AT-T3  --advisor with no advisor iterations -> exit 4, "no advisor iterations"
#   AT-T4  an unpriced advisor model is named in `unpriced`, USD 0 for it
#   AT-7   the fixture's iteration shape is the recorded/API-doc shape
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
TC="$DIR/bin/transcript-cost.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
cat > "$T/prices.json" <<'EOF'
{"per_token":{"claude-fable-5-1":{"prompt":0.00001,"completion":0.0001,"cache_read":0.000001,"cache_write":0.0000125},
 "claude-opus-5-5":{"prompt":0.000001,"completion":0.00001,"cache_read":0.0000001,"cache_write":0.00000125}}}
EOF
# Response m1 (executor only) twice; m2 with an advisor iteration THREE times,
# the way the CLI writes one entry per content block.
M2='{"type":"assistant","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":200,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"iterations":[{"type":"message","input_tokens":200,"output_tokens":20},{"type":"advisor_message","model":"claude-fable-5-1","input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":50,"cache_creation_input_tokens":8}]}}}'
M1='{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'
printf '%s\n%s\n%s\n%s\n%s\n' "$M1" "$M1" "$M2" "$M2" "$M2" > "$T/adv.jsonl"
printf '%s\n%s\n' "$M1" "$M1" > "$T/plain.jsonl"
sed 's/claude-fable-5-1/claude-nova-9/' "$T/adv.jsonl" > "$T/unpriced.jsonl"

run() { COST_TRANSCRIPT_SCAN_MAX=400 COST_CACHE_TTL=auto HARNESS="$T" bash "$TC" "$@" --prices "$T/prices.json" 2>"$T/err"; }

# AT-T1: 300 in / 30 out executor; 300e-6 + 30e-5 = 0.0006
OUT=$(run "$T/adv.jsonl"); RC=$?
[ "$RC" = 0 ] && ok || bad "AT-T1 rc=$RC"
[ "$OUT" = "300|30|0|0|0.000600|claude-opus-5-5|2|1|" ] && ok || bad "AT-T1 default mode must be executor-only: $OUT"

# AT-T2: 1000*1e-5 + 100*1e-4 + 50*1e-6 + 8*1.25e-5 = 0.02015
OUT=$(run "$T/adv.jsonl" --advisor); RC=$?
[ "$RC" = 0 ] && ok || bad "AT-T2 rc=$RC ($(cat "$T/err"))"
[ "$OUT" = "1000|100|50|8|0.020150|claude-fable-5-1|1|1|" ] && ok || bad "AT-T2 --advisor line: $OUT"

# AT-T3
OUT=$(run "$T/plain.jsonl" --advisor); RC=$?
[ "$RC" = 4 ] && ok || bad "AT-T3 want exit 4, got $RC ($OUT)"
grep -q 'no advisor iterations' "$T/err" && ok || bad "AT-T3 stderr: $(cat "$T/err")"
[ -z "$OUT" ] && ok || bad "AT-T3 must print no row line: $OUT"

# AT-T4
OUT=$(run "$T/unpriced.jsonl" --advisor); RC=$?
[ "$RC" = 0 ] && ok || bad "AT-T4 rc=$RC"
[ "$OUT" = "1000|100|50|8|0.000000|claude-nova-9|1|1|claude-nova-9" ] && ok || bad "AT-T4 unpriced line: $OUT"

# AT-7: the fixture iteration carries exactly the fields the API doc names
# (type advisor_message + its own model + the four usage counters). A billed
# advisor session could not be recorded on the build box (no login), so this is
# the API-doc shape, not a captured one.
SHAPE=$(printf '%s' "$M2" | jq -c '.message.usage.iterations[] | select(.type=="advisor_message") | keys')
[ "$SHAPE" = '["cache_creation_input_tokens","cache_read_input_tokens","input_tokens","model","output_tokens","type"]' ] && ok \
  || bad "AT-7 fixture advisor iteration shape: $SHAPE"

echo "transcript-cost-advisor.bh-3491: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
