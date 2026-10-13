#!/bin/bash
# tests/dequeue-watch-llm.bh-3719-test.sh — BH-3729 (slice 4 of BH-3719): the
# dequeue-watch LLM fallback classifier, dqw_llm_classify.
#
# Sources the REAL bin/lib/dequeue-watch/llm.sh, stubs the dqw_* ledger verbs
# and lane_model / lane_model_ladder as shell functions and bin/agent-call.sh as
# a script under a scratch $HARNESS. Pins dedup-before-spend: the fp reuse, the
# stamp BEFORE the call, junk and failure as terminal `none`, and no call when
# the route, the stamp or the ledger read is missing.
# Run from anywhere: tests/dequeue-watch-llm.bh-3719-test.sh   (exit 0 = all pass)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T/h"
mkdir -p "$HARNESS/bin" "$HARNESS/logs" "$HARNESS/catalog/prompts"
cp "$DIR/catalog/prompts/dequeue-classify.md" "$HARNESS/catalog/prompts/" 2>/dev/null \
  || bad "catalog/prompts/dequeue-classify.md is missing"
CALLS="$T/calls.txt"; export CALLS
LOG="$HARNESS/logs/dequeue-watch.log"

# agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt>
cat > "$HARNESS/bin/agent-call.sh" <<'EOF'
#!/bin/bash
echo "agent-call $1 $2 $3 $4 budget=${AGENT_CALL_BUDGET_USD:-} runners=${AGENT_CALL_RUNNERS:-} lane=${AGENT_CALL_LANE:-}" >> "$CALLS"
printf '%s' "$6" > "$(dirname "$CALLS")/prompt.txt"
printf '%b' "${STUB_ANSWER:-rule-break\n}" > "$5"
exit "${STUB_AC_RC:-0}"
EOF
chmod +x "$HARNESS/bin/agent-call.sh"

# shellcheck source=../bin/lib/dequeue-watch/llm.sh
. "$DIR/bin/lib/dequeue-watch/llm.sh" || { echo "FAIL: bin/lib/dequeue-watch/llm.sh could not be sourced"; exit 1; }

dqw_events_list() {
  echo "dqw_events_list $*" >> "$CALLS"
  [ "${STUB_EV_RC:-0}" = 0 ] || return "$STUB_EV_RC"
  local empty='{"rows":[],"truncated":false}'
  printf '%s\n' "${STUB_EV:-$empty}"
}
dqw_event_state() { echo "dqw_event_state $*" >> "$CALLS"; return "${STUB_STATE_RC:-0}"; }
lane_model() { echo "lane_model $*" >> "$CALLS"; [ "${STUB_LM_RC:-0}" = 0 ] || return "$STUB_LM_RC"; echo stub-model-x; }
lane_model_ladder() { echo "lane_model_ladder $*" >> "$CALLS"; printf '0\tdequeue.classify\tclaude\tstub-model-x\n'; }

HEAD=0123456789abcdef0123456789abcdef01234567
FL="$T/fail.txt"
printf 'FAIL: tests/a-test.sh case 12 at deadbeef01\nFAIL: tests/a-test.sh case 12 at deadbeef01\n  FAIL: b broke in 3s\n' > "$FL"
reset() {
  : > "$CALLS"; : > "$LOG"
  unset STUB_ANSWER STUB_AC_RC STUB_EV STUB_EV_RC STUB_STATE_RC STUB_LM_RC DEQUEUE_WATCH_LLM_USD
}
n() { grep -c -- "$1" "$CALLS"; }
first() { grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
cls() { dqw_llm_classify proj example-org/cromford 42 "$HEAD" 991 "tests/a-test.sh" "$FL"; }

# ── A5 ────────────────────────────────────────────────────────────────────────
reset; out=$(cls); rc=$?
[ "$rc" = 0 ] && [ "$out" = rule-break ] && ok || bad "A5: want rc 0 and rule-break, got rc $rc '$out'"
[ "$(n agent-call)" = 1 ] && ok || bad "A5: want 1 agent call"
s=$(first 'dqw_event_state .*llm_attempted_at'); c=$(first agent-call)
[ -n "$s" ] && [ -n "$c" ] && [ "$s" -lt "$c" ] && ok || bad "A5: the attempted stamp must precede the call, calls: $(tr '\n' '|' < "$CALLS")"
grep -q 'agent-call dequeue-classify proj stub-model-x 120 budget=0.05 runners=claude lane=dequeue-watch' "$CALLS" && ok \
  || bad "A5: agent-call argv/env: $(grep agent-call "$CALLS")"
grep -q 'dqw_event_state example-org/cromford 42 '"$HEAD"' 991 .*"llm_class":"rule-break"' "$CALLS" && ok || bad "A5: llm_class not recorded"
[ "$(grep -n 'llm_class' "$CALLS" | head -1 | cut -d: -f1)" -gt "$c" ] && ok || bad "A5: llm_class must be recorded after the call"
grep -q 'lane_model DEQUEUE_WATCH_MODEL dequeue.classify' "$CALLS" && ok || bad "A5: model must come from the dequeue.classify route"
FP=$(grep -o '"llm_fp":"[0-9a-f]*"' "$CALLS" | head -1 | cut -d'"' -f4)
[ "${#FP}" = 40 ] && grep -q "dqw_events_list example-org/cromford   $FP" "$CALLS" && ok || bad "A5: the reuse read must filter on the 40-hex fp ($FP)"
grep -q 'FAIL: b broke' "$T/prompt.txt" && grep -q 'tests/a-test.sh' "$T/prompt.txt" && grep -qi 'exactly one word' "$T/prompt.txt" && ok \
  || bad "A5: the prompt must carry the prompt file, the suites and the FAIL lines"
# the fp ignores hex/digit noise and duplicate lines
printf 'FAIL: tests/a-test.sh case 99 at cafef00d77\n  FAIL: b broke in 8s\n' > "$T/fail2.txt"
reset; dqw_llm_classify proj example-org/cromford 42 "$HEAD" 991 "tests/a-test.sh" "$T/fail2.txt" >/dev/null
grep -q "\"llm_fp\":\"$FP\"" "$CALLS" && ok || bad "A5: the fingerprint must normalise hex/digit runs and duplicates"
reset; DEQUEUE_WATCH_LLM_USD=0.02 cls >/dev/null
grep -q 'budget=0.02' "$CALLS" && ok || bad "A5: DEQUEUE_WATCH_LLM_USD must set the call budget"

# ── A5-rerun ──────────────────────────────────────────────────────────────────
reset; STUB_EV=$(jq -nc --arg fp "$FP" '{rows:[{llm_fp:$fp, llm_attempted_at:"2026-09-30T00:00:00Z", llm_class:"rule-break"}],truncated:false}')
out=$(cls)
[ "$(n agent-call)" = 0 ] && [ "$out" = rule-break ] && [ "$(n dqw_event_state)" = 0 ] && ok || bad "A5-rerun: want 0 calls and rule-break, got '$out'"

# ── A5b ───────────────────────────────────────────────────────────────────────
reset; out=$(STUB_ANSWER='banana\n' cls)
[ -z "$out" ] && grep -q '"llm_class":"none"' "$CALLS" && ok || bad "A5b: junk must record none and print nothing, got '$out'"
reset; out=$(STUB_ANSWER='Rule-Break\n' cls)
[ -z "$out" ] && grep -q '"llm_class":"none"' "$CALLS" && ok || bad "A5b: the enum is strict (no lowercasing)"
reset; out=$(STUB_AC_RC=1 cls)
[ -z "$out" ] && grep -q '"llm_class":"none"' "$CALLS" && ok || bad "A5b: a failed call is billed and terminal none"
reset; out=$(STUB_ANSWER='  flake  \nbecause it is\n' cls)
[ "$out" = flake ] && ok || bad "A5b: the first line, trimmed, is the answer, got '$out'"
reset; STUB_EV=$(jq -nc --arg fp "$FP" '{rows:[{llm_fp:$fp, llm_attempted_at:"x", llm_class:"none"}],truncated:false}')
out=$(cls)
[ "$(n agent-call)" = 0 ] && [ -z "$out" ] && ok || bad "A5b: re-run over none must make 0 calls and print nothing"
reset; STUB_EV=$(jq -nc --arg fp "$FP" '{rows:[{llm_fp:$fp, llm_attempted_at:"x"}],truncated:false}')
out=$(cls)
[ "$(n agent-call)" = 0 ] && [ -z "$out" ] && grep -q llm-attempted-no-answer "$LOG" && ok || bad "A5b: attempted-with-no-answer is terminal"

# ── A5c ───────────────────────────────────────────────────────────────────────
reset; out=$(STUB_LM_RC=75 cls)
[ "$(n agent-call)" = 0 ] && [ "$(n dqw_event_state)" = 0 ] && grep -q no-route "$LOG" && ok || bad "A5c: no route must make 0 calls and 0 stamps"

# ── A5d ───────────────────────────────────────────────────────────────────────
reset; out=$(STUB_STATE_RC=1 cls)
[ "$(n agent-call)" = 0 ] && [ -z "$out" ] && ok || bad "A5d: a failed stamp must make 0 calls"

# ── A5e ───────────────────────────────────────────────────────────────────────
reset; out=$(STUB_EV_RC=1 cls)
[ "$(n agent-call)" = 0 ] && [ "$(n dqw_event_state)" = 0 ] && grep -q llm-ledger-unreadable "$LOG" && ok || bad "A5e: an unreadable ledger must make 0 calls"
reset; out=$(STUB_EV='garbage' cls)
[ "$(n agent-call)" = 0 ] && ok || bad "A5e: an unparseable ledger answer must make 0 calls"

# ── bad input ─────────────────────────────────────────────────────────────────
reset; dqw_llm_classify proj r 42 "$HEAD" 991 s "$T/nope.txt" >/dev/null; rc=$?
[ "$rc" = 1 ] && [ ! -s "$CALLS" ] && ok || bad "edge: an unreadable FAIL-lines file is rc 1 with no reads"
reset; ( unset HARNESS H; cls >/dev/null ); rc=$?
[ "$rc" = 1 ] && [ ! -s "$CALLS" ] && ok || bad "edge: no root is rc 1 with no reads"

echo "dequeue-watch-llm: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
