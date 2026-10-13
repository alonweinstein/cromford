#!/bin/bash
# tests/dequeue-watch-act.bh-3719-test.sh — BH-3729 (slice 4 of BH-3719): the
# dequeue-watch action picker, its claim, the fix-round bound, the hold, the
# main-red recheck and the unowned watchdog.
#
# Sources the REAL bin/lib/dequeue-watch/act.sh and stubs only what it calls:
# the dqw_* ledger verbs, the conductor helpers, fix_round_enqueue and friends
# as shell functions, and lead-verdict.sh / needs-human-hold.sh / lane-alert.sh
# / box-for.sh as scripts under a scratch $HARNESS/bin. Every stub appends one
# line to $CALLS; the cases count those lines and check their order.
# Run from anywhere: tests/dequeue-watch-act.bh-3719-test.sh   (exit 0 = all pass)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T/h"
mkdir -p "$HARNESS/bin" "$HARNESS/logs"
CALLS="$T/calls.txt"; export CALLS
LOG="$HARNESS/logs/dequeue-watch.log"

# ── script stubs ──────────────────────────────────────────────────────────────
cat > "$HARNESS/bin/lead-verdict.sh" <<'EOF'
#!/bin/bash
echo "lead-verdict $*" >> "$CALLS"
[ -n "${STUB_LEAD_ERR:-}" ] && echo "$STUB_LEAD_ERR" >&2
exit "${STUB_LEAD_RC:-0}"
EOF
cat > "$HARNESS/bin/needs-human-hold.sh" <<'EOF'
#!/bin/bash
echo "needs-human-hold $*" >> "$CALLS"
exit "${STUB_HOLD_RC:-0}"
EOF
cat > "$HARNESS/bin/lane-alert.sh" <<'EOF'
#!/bin/bash
echo "lane-alert $*" >> "$CALLS"
exit 0
EOF
cat > "$HARNESS/bin/box-for.sh" <<'EOF'
#!/bin/bash
echo "box-for $*" >> "$CALLS"
echo "${STUB_BOX-box-2}"
EOF
chmod +x "$HARNESS/bin/"*.sh

# shellcheck source=../bin/lib/dequeue-watch/act.sh
. "$DIR/bin/lib/dequeue-watch/act.sh" || { echo "FAIL: bin/lib/dequeue-watch/act.sh could not be sourced"; exit 1; }

# ── function stubs (defined after the lib so they win) ───────────────────────
dqw_action_claim() {
  echo "dqw_action_claim $*" >> "$CALLS"
  [ "${STUB_CLAIM_RC:-0}" = 0 ] || return "$STUB_CLAIM_RC"
  if [ -n "${STUB_CLAIM_RAW:-}" ]; then printf '%s\n' "$STUB_CLAIM_RAW"; return 0; fi
  jq -nc --argjson c "${STUB_CLAIMED:-true}" --arg a "${STUB_ROW_ACTION:-$5}" \
    '{claimed:$c, row:{action:$a, status:"claimed"}}'
}
dqw_action_set() { echo "dqw_action_set $*" >> "$CALLS"; return "${STUB_SET_RC:-0}"; }
dqw_rounds_count() {
  echo "dqw_rounds_count $*" >> "$CALLS"
  [ "${STUB_COUNT_RC:-0}" = 0 ] || return "$STUB_COUNT_RC"
  echo "${STUB_COUNT:-0}"
}
dqw_actions_list() {
  echo "dqw_actions_list $*" >> "$CALLS"
  [ "${STUB_LIST_RC:-0}" = 0 ] || return "$STUB_LIST_RC"
  local empty='{"rows":[],"truncated":false}'
  printf '%s\n' "${STUB_LIST:-$empty}"
}
mc_requeued_mark() { echo "mc_requeued_mark $*" >> "$CALLS"; printf '%s' "${STUB_MARK:-}"; }
mc_requeued_record() { echo "mc_requeued_record $*" >> "$CALLS"; }
mc_requeue_mergify() {
  echo "mc_requeue_mergify $*" >> "$CALLS"
  [ "${STUB_MERGIFY_RC:-0}" = 1 ] && printf 'the dequeued label could not be removed (HTTP 500)'
  return "${STUB_MERGIFY_RC:-0}"
}
mc_attempt_put() { echo "mc_attempt_put $*" >> "$CALLS"; }
fix_round_enqueue() {
  echo "fix_round_enqueue $*" >> "$CALLS"
  [ "${STUB_ENQ_RC:-0}" = 0 ] || return "$STUB_ENQ_RC"
  echo '{"id":"job-77","status":"queued"}'
}
metric_flake() { echo "metric_flake $*" >> "$CALLS"; }
main_red_flag() { echo "main_red_flag $*" >> "$CALLS"; [ "${STUB_RED:-0}" = 1 ] && { echo main-red-flag; return 0; }; return 1; }
nh_fingerprint() { echo "nh_fingerprint $*" >> "$CALLS"; echo abcdef0123456789; }

HEAD=0123456789abcdef0123456789abcdef01234567
H12=${HEAD:0:12}
SLUG=example-org/cromford
URL=https://github.com/$SLUG/pull/42
ctx() {  # ctx [verdict] [head_ref] [suite]
  jq -nc --arg v "${1-MERGE}" --arg r "${2-ticket/bh-3729}" --arg s "${3-tests/a-test.sh}" \
    '{rule_id:"D43", suite:$s, fail_lines:"FAIL: a broke\nFAIL: b broke", hint:"h", brief:"b",
      run_id:"991", run_url:"https://github.com/example-org/cromford/actions/runs/991",
      draft:false, head_ref:$r, verdict_word:$v}'
}
reset() {
  : > "$CALLS"; : > "$LOG"
  unset STUB_CLAIM_RC STUB_CLAIMED STUB_ROW_ACTION STUB_CLAIM_RAW STUB_SET_RC STUB_COUNT STUB_COUNT_RC \
        STUB_LIST STUB_LIST_RC STUB_MARK STUB_MERGIFY_RC STUB_ENQ_RC STUB_RED STUB_BOX \
        STUB_LEAD_RC STUB_LEAD_ERR STUB_HOLD_RC DEQUEUE_WATCH_ACT DEQUEUE_WATCH_FIX_ROUNDS \
        DEQUEUE_WATCH_HOLD_CLASSES DEQUEUE_WATCH_UNOWNED_MIN
}
n() { grep -c -- "$1" "$CALLS"; }           # lines in $CALLS matching a pattern
alert_has() { awk -v p="$1" '/lane-alert/ && index($0, p) { f = 1 } END { exit !f }' "$CALLS"; }  # a lane-alert line in $CALLS containing a fixed string
first() { grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
# The lane ships observe-only (BH-3859); these cases act unless one sets 0.
act() { DEQUEUE_WATCH_ACT="${DEQUEUE_WATCH_ACT:-1}" dqw_act proj "$SLUG" 42 "$URL" "$HEAD" "$@"; }

# ── A-claim ───────────────────────────────────────────────────────────────────
reset; STUB_CLAIMED=false STUB_ROW_ACTION=requeue act bystander "$(ctx)"
[ "$(n dqw_action_claim)" = 1 ] && [ "$(wc -l < "$CALLS")" = 1 ] && ok \
  || bad "A-claim: claimed:false must stop after the claim, calls: $(tr '\n' '|' < "$CALLS")"
grep -q already-owned "$LOG" && ok || bad "A-claim: no already-owned log line"

# ── A-claimfail ───────────────────────────────────────────────────────────────
reset; STUB_CLAIM_RC=1 act bystander "$(ctx)"
[ "$(wc -l < "$CALLS")" = 1 ] && grep -q claim-unreadable "$LOG" && ok \
  || bad "A-claimfail: claim rc 1 must do nothing else, calls: $(tr '\n' '|' < "$CALLS")"
reset; STUB_CLAIM_RAW='not json' act bystander "$(ctx)"
[ "$(wc -l < "$CALLS")" = 1 ] && grep -q claim-unreadable "$LOG" && ok \
  || bad "A-claimfail: an unparseable claim answer must read as unreadable"

# ── A-observe ─────────────────────────────────────────────────────────────────
reset; DEQUEUE_WATCH_ACT=0 act bystander "$(ctx)"
grep -q "dqw_action_claim $SLUG 42 $HEAD bystander observe proj" "$CALLS" && ok || bad "A-observe: ACT=0 must claim action observe"
[ "$(wc -l < "$CALLS")" = 1 ] && ok || bad "A-observe: ACT=0 made side effects: $(tr '\n' '|' < "$CALLS")"
[ "$(grep -c WOULD_REQUEUE "$LOG")" = 1 ] && ok || bad "A-observe: want exactly one WOULD_REQUEUE line"
reset; STUB_CLAIMED=false STUB_ROW_ACTION=observe act bystander "$(ctx)"
[ "$(n dqw_action_claim)" = 1 ] && ok || bad "A-observe: ACT=1 over observe made $(n dqw_action_claim) claims"
[ "$(n "dqw_action_set $SLUG 42 $HEAD bystander claimed   requeue")" = 1 ] && ok \
  || bad "A-observe: want one take-over set to action requeue, calls: $(tr '\n' '|' < "$CALLS")"
[ "$(n mc_requeue_mergify)" = 1 ] && ok || bad "A-observe: want exactly one requeue after the take-over"
reset; STUB_CLAIMED=false STUB_ROW_ACTION=observe STUB_SET_RC=1 act bystander "$(ctx)"
[ "$(n mc_requeue_mergify)" = 0 ] && ok || bad "A-observe: a failed take-over must not requeue"

# ── A-bystander ───────────────────────────────────────────────────────────────
reset; act bystander "$(ctx)"
r1=$(first mc_requeued_record); r2=$(first mc_requeue_mergify)
[ "$(n mc_requeued_record)" = 1 ] && [ "$(n mc_requeue_mergify)" = 1 ] && [ "$r1" -lt "$r2" ] && ok \
  || bad "A-bystander: want record then mergify, calls: $(tr '\n' '|' < "$CALLS")"
[ "$(first dqw_action_claim)" -lt "$r1" ] && ok || bad "A-bystander: the claim must come before the mark"
grep -q "mc_requeued_record $SLUG#42 $HEAD" "$CALLS" && ok || bad "A-bystander: mark key must be slug#num head"
grep -q "mc_requeue_mergify $SLUG $URL $HEAD" "$CALLS" && ok || bad "A-bystander: mergify argv"
grep -q "dqw_action_set $SLUG 42 $HEAD bystander done" "$CALLS" && ok || bad "A-bystander: want status done"
[ "$(n fix_round_enqueue)" = 0 ] && [ "$(n lead-verdict)" = 0 ] && ok || bad "A-bystander(-nofix): no fix round, no lead request"
reset; act bystander "$(ctx MERGE-WITH-NOTES)"
[ "$(n mc_requeue_mergify)" = 1 ] && ok || bad "A-bystander: MERGE-WITH-NOTES is a standing verdict"

# ── A-noverdict ───────────────────────────────────────────────────────────────
reset; act bystander "$(ctx '')"
[ "$(n mc_requeue_mergify)" = 0 ] && [ "$(n mc_requeued_record)" = 0 ] && ok || bad "A-noverdict: requeued with no verdict"
[ "$(n lead-verdict)" = 1 ] && ok || bad "A-noverdict: want 1 lead request"
grep -q "lead-verdict request $SLUG 42 $HEAD --notes dequeue-watch: stale-status on $H12" "$CALLS" && ok || bad "A-noverdict: lead argv"
grep -q "dqw_action_claim $SLUG 42 $HEAD stale-status lead-request proj" "$CALLS" && ok || bad "A-noverdict: claim must be stale-status/lead-request"
[ "$(n dqw_action_claim)" = 1 ] && ok || bad "A-noverdict: one claim only"
reset; act flake "$(ctx BLOCK)"
[ "$(n mc_requeue_mergify)" = 0 ] && [ "$(n metric_flake)" = 0 ] && [ "$(n lead-verdict)" = 1 ] && ok || bad "A-noverdict: flake with BLOCK must lead-request"

# ── A-marked ──────────────────────────────────────────────────────────────────
reset; STUB_MARK=1790000000 act bystander "$(ctx)"
[ "$(n mc_requeue_mergify)" = 0 ] && [ "$(n mc_requeued_record)" = 0 ] && ok || bad "A-marked: posted over a conductor mark"
grep -q "dqw_action_set $SLUG 42 $HEAD bystander done  already requeued by the conductor" "$CALLS" && ok || bad "A-marked: want done + note"

# ── A-flake ───────────────────────────────────────────────────────────────────
reset; act flake "$(ctx MERGE ticket/bh-1 'tests/a-test.sh tests/b-test.sh')"
[ "$(n metric_flake)" = 2 ] && [ "$(n mc_requeue_mergify)" = 1 ] && ok || bad "A-flake: want 2 metric_flake + 1 requeue"
[ "$(grep -n metric_flake "$CALLS" | tail -1 | cut -d: -f1)" -lt "$(first mc_requeue_mergify)" ] && ok || bad "A-flake: metrics must precede the requeue"
grep -q "metric_flake $SLUG unknown tests/b-test.sh $HEAD  flake" "$CALLS" && ok || bad "A-flake: metric_flake argv"

# ── A-409 ─────────────────────────────────────────────────────────────────────
reset; STUB_LEAD_RC=1 STUB_LEAD_ERR='lead-verdict: request refused: HTTP 409' act stale-status "$(ctx)"
grep -q "dqw_action_set $SLUG 42 $HEAD stale-status done" "$CALLS" && ok || bad "A-409: want done"
reset; STUB_LEAD_RC=1 STUB_LEAD_ERR='HTTP 500' act stale-status "$(ctx)"
grep -q "dqw_action_set $SLUG 42 $HEAD stale-status failed" "$CALLS" && ok || bad "A-409: a 500 must be failed"

# ── A-requeue-fail ────────────────────────────────────────────────────────────
reset; STUB_MERGIFY_RC=1 act bystander "$(ctx)"
grep -q "dqw_action_set $SLUG 42 $HEAD bystander failed  the dequeued label" "$CALLS" && ok || bad "A-requeue-fail: want failed + reason"
reset; STUB_CLAIMED=false STUB_ROW_ACTION=requeue act bystander "$(ctx)"
[ "$(n mc_requeue_mergify)" = 0 ] && ok || bad "A-requeue-fail: a second tick posted again"
reset; STUB_MERGIFY_RC=3 act bystander "$(ctx)"
grep -q "dqw_action_set $SLUG 42 $HEAD bystander waiting" "$CALLS" && ok || bad "A-requeue: rc 3 must be waiting"
reset; STUB_MERGIFY_RC=2 act bystander "$(ctx)"
grep -q "dqw_action_set $SLUG 42 $HEAD bystander done" "$CALLS" && ok || bad "A-requeue: rc 2 (merged) must be done"

# ── A-mainred ─────────────────────────────────────────────────────────────────
reset; act main-red "$(ctx)"
grep -q "dqw_action_claim $SLUG 42 $HEAD main-red main-red-wait proj" "$CALLS" && ok || bad "A-mainred: claim"
grep -q "dqw_action_set $SLUG 42 $HEAD main-red waiting  verdict=MERGE" "$CALLS" && ok || bad "A-mainred: want waiting + verdict note"
[ "$(n mc_requeue_mergify)" = 0 ] && [ "$(n lead-verdict)" = 0 ] && ok || bad "A-mainred: requeued while main is red"
reset; act main-red "$(ctx '')"
grep -q "dqw_action_set $SLUG 42 $HEAD main-red waiting  verdict=none" "$CALLS" && ok || bad "A-mainred: no verdict must note verdict=none"

# ── A-mainred-clear (dqw_mainred_recheck) ────────────────────────────────────
ROW() { jq -nc --arg h "$HEAD" --arg n "$1" '{rows:[{repo:"x",pr:42,head:$h,class:"main-red",action:"main-red-wait",status:"waiting",note:$n}],truncated:false}'; }
reset; STUB_RED=1 STUB_LIST=$(ROW verdict=MERGE) dqw_mainred_recheck proj "$SLUG"
[ "$(n mc_requeue_mergify)" = 0 ] && [ "$(n dqw_action_set)" = 0 ] && ok || bad "A-mainred-clear: acted while the flag is still on"
grep -q "dqw_actions_list $SLUG   main-red main-red-wait waiting" "$CALLS" && ok || bad "A-mainred-clear: list argv"
reset; STUB_LIST=$(ROW verdict=MERGE) dqw_mainred_recheck proj "$SLUG"
[ "$(n mc_requeue_mergify)" = 1 ] && [ "$(n dqw_action_claim)" = 0 ] && ok || bad "A-mainred-clear: want 1 requeue and no claim, calls: $(tr '\n' '|' < "$CALLS")"
grep -q "mc_requeue_mergify $SLUG $URL $HEAD" "$CALLS" && ok || bad "A-mainred-clear: url must be rebuilt from slug/pr"
grep -Eq "dqw_action_set $SLUG 42 $HEAD main-red done .* requeue$" "$CALLS" && ok || bad "A-mainred-clear: set on the main-red key with action requeue"
reset; STUB_LIST=$(ROW verdict=none) dqw_mainred_recheck proj "$SLUG"
[ "$(n lead-verdict)" = 1 ] && [ "$(n mc_requeue_mergify)" = 0 ] && ok || bad "A-mainred-clear: verdict=none must lead-request"
grep -Eq "dqw_action_set $SLUG 42 $HEAD main-red done .* lead-request$" "$CALLS" && ok || bad "A-mainred-clear: action must become lead-request"
reset; STUB_LIST_RC=1 dqw_mainred_recheck proj "$SLUG"
[ "$(wc -l < "$CALLS")" = 1 ] && ok || bad "A-mainred-clear: unreadable list must do nothing"

# ── A-rulebreak ───────────────────────────────────────────────────────────────
reset; act rule-break "$(ctx)"
[ "$(n fix_round_enqueue)" = 1 ] && ok || bad "A-rulebreak: want 1 enqueue, calls: $(tr '\n' '|' < "$CALLS")"
[ "$(first dqw_rounds_count)" -lt "$(first dqw_action_claim)" ] && ok || bad "A-rulebreak: the bound must be read before the claim"
[ "$(first "mc_attempt_put dqwculprit $SLUG#42 $HEAD")" -lt "$(first fix_round_enqueue)" ] 2>/dev/null && ok \
  || bad "A-rulebreak: the dqwculprit mark must precede the enqueue"
enq=$(grep fix_round_enqueue "$CALLS")
case "$enq" in "fix_round_enqueue proj dqw-42-$H12-rule-break box-2 0 "*) ok ;; *) bad "A-rulebreak: head of argv: $enq" ;; esac
case "$enq" in *" proj dqw-42-$H12 queue-dequeued $URL - BH-3729") ok ;; *) bad "A-rulebreak: tail of argv: $enq" ;; esac
[[ "$enq" == *'"rule_id":"D43"'* && "$enq" == *'FAIL: a broke'* && "$enq" == *'"class":"rule-break"'* ]] && ok || bad "A-rulebreak: record must carry rule_id, class and the FAIL lines"
grep -q "dqw_action_set $SLUG 42 $HEAD rule-break done job-77" "$CALLS" && ok || bad "A-rulebreak: want done with the job id"
reset; STUB_CLAIMED=false STUB_ROW_ACTION=fix-round act rule-break "$(ctx)"
[ "$(n fix_round_enqueue)" = 0 ] && ok || bad "A-rulebreak-2nd: a second tick enqueued"

# ── A-trip ────────────────────────────────────────────────────────────────────
reset; STUB_COUNT=2 act rule-break "$(ctx)"
[ "$(n fix_round_enqueue)" = 0 ] && ok || bad "A-trip: enqueued past the bound"
grep -q "dqw_action_claim $SLUG 42 $HEAD rule-break hold proj" "$CALLS" && ok || bad "A-trip: want a hold claim"
grep -q "needs-human-hold proj 3729 abcdef0123456789 " "$CALLS" && [ "$(n needs-human-hold)" = 1 ] && ok || bad "A-trip: want one placer call on issue 3729"
[ "$(n "lane-alert --severity critical --id dqw-hold:proj:42:rule-break dequeue-watch")" = 1 ] && [ "$(n lane-alert)" = 1 ] && ok \
  || bad "A-trip: want exactly one critical dqw-hold line, calls: $(tr '\n' '|' < "$CALLS")"
line=$(grep 'lane-alert' "$CALLS")
[[ "$line" == *"$URL"* && "$line" == *tests/a-test.sh* && "$line" == *"FAIL: a broke"* && "$line" == *"2 fix rounds spent"* ]] && ok \
  || bad "A-trip: the line must name url, suite, first FAIL and reason: $line"
grep -q "dqw_action_set $SLUG 42 $HEAD rule-break done" "$CALLS" && ok || bad "A-trip: placer 0 must be done"
reset; STUB_COUNT=2 STUB_CLAIMED=false STUB_ROW_ACTION=hold act rule-break "$(ctx)"
[ "$(n lane-alert)" = 0 ] && [ "$(n needs-human-hold)" = 0 ] && ok || bad "A-trip: a second tick paged again"

# ── A-knob ────────────────────────────────────────────────────────────────────
reset; DEQUEUE_WATCH_FIX_ROUNDS=abc STUB_COUNT=1 act rule-break "$(ctx)"
[ "$(n "lane-alert --severity warn --id dqw-knob:DEQUEUE_WATCH_FIX_ROUNDS dequeue-watch")" = 1 ] && [ "$(n fix_round_enqueue)" = 1 ] && ok \
  || bad "A-knob: want 1 warn + 1 enqueue, calls: $(tr '\n' '|' < "$CALLS")"
reset; DEQUEUE_WATCH_FIX_ROUNDS=abc STUB_COUNT=2 act rule-break "$(ctx)"
[ "$(n fix_round_enqueue)" = 0 ] && [ "$(n needs-human-hold)" = 1 ] && ok || bad "A-knob: junk knob must default to 2 and hold"
reset; DEQUEUE_WATCH_HOLD_CLASSES="semantic-test, scanner-fp" act scanner-fp "$(ctx)"
[ "$(n fix_round_enqueue)" = 0 ] && grep -q 'class held by DEQUEUE_WATCH_HOLD_CLASSES' "$CALLS" && ok || bad "A-knob: a held class must hold"
reset; DEQUEUE_WATCH_HOLD_CLASSES="semantic-test, scanner-fp" act rule-break "$(ctx)"
[ "$(n fix_round_enqueue)" = 1 ] && ok || bad "A-knob: an unheld class must still get its fix round"

# ── A-countfail ───────────────────────────────────────────────────────────────
reset; STUB_COUNT_RC=1 act rule-break "$(ctx)"
[ "$(n dqw_action_claim)" = 0 ] && [ "$(n fix_round_enqueue)" = 0 ] && grep -q rounds-unreadable "$LOG" && ok || bad "A-countfail: acted on an unreadable count"
reset; STUB_COUNT=' ' act rule-break "$(ctx)"
[ "$(n dqw_action_claim)" = 0 ] && ok || bad "A-countfail: a non-integer count must read as unreadable"

# ── A-nobox ───────────────────────────────────────────────────────────────────
reset; STUB_BOX=local act rule-break "$(ctx)"
[ "$(n fix_round_enqueue)" = 0 ] && [ "$(n mc_attempt_put)" = 0 ] && ok || bad "A-nobox: enqueued with no box"
grep -q "dqw_action_set $SLUG 42 $HEAD rule-break failed" "$CALLS" && [ "$(n "lane-alert --severity warn --id dqw-nobox:proj")" = 1 ] && ok || bad "A-nobox: want failed + one nobox warn"
reset; STUB_BOX='' act rule-break "$(ctx)"
[ "$(n fix_round_enqueue)" = 0 ] && ok || bad "A-nobox: an empty box must not enqueue"

# ── A-enqfail ─────────────────────────────────────────────────────────────────
reset; STUB_ENQ_RC=1 act rule-break "$(ctx)"
grep -q "dqw_action_set $SLUG 42 $HEAD rule-break failed" "$CALLS" && [ "$(n "lane-alert --severity warn --id dqw-enqueue-failed:proj:42")" = 1 ] && ok || bad "A-enqfail: want failed + one warn"
reset; STUB_CLAIMED=false STUB_ROW_ACTION=fix-round act rule-break "$(ctx)"
[ "$(n fix_round_enqueue)" = 0 ] && ok || bad "A-enqfail: re-enqueued on the next tick"

# ── A-holdfail ────────────────────────────────────────────────────────────────
reset; STUB_HOLD_RC=75 STUB_COUNT=2 act rule-break "$(ctx)"
alert_has 'hold NOT placed (rc 75)' && ok || bad "A-holdfail: the line must say the hold was not placed"
grep -q "dqw_action_set $SLUG 42 $HEAD rule-break failed" "$CALLS" && ok || bad "A-holdfail: want failed"

# ── A-noissue ─────────────────────────────────────────────────────────────────
reset; STUB_COUNT=2 act rule-break "$(ctx MERGE feature/x)"
[ "$(n needs-human-hold)" = 0 ] && alert_has 'no ticket issue' && ok || bad "A-noissue: want no placer call and 'no ticket issue'"
reset; act unclassified "$(ctx)"
[ "$(n fix_round_enqueue)" = 0 ] && [ "$(n needs-human-hold)" = 1 ] && alert_has 'unclassified' && ok || bad "A-unclassified: want a hold"

# ── edge: bad input ───────────────────────────────────────────────────────────
reset; act bystander 'not json'; rc=$?
[ "$rc" = 1 ] && [ ! -s "$CALLS" ] && ok || bad "edge: invalid ctx must be rc 1 with no claim"
reset; dqw_act proj "$SLUG" 42 "$URL" abc123 bystander "$(ctx)"; rc=$?
[ "$rc" = 1 ] && [ ! -s "$CALLS" ] && ok || bad "edge: a non-40-hex head must be rc 1 with no claim"
reset; ( unset HARNESS H; dqw_act proj "$SLUG" 42 "$URL" "$HEAD" bystander "$(ctx)" ); rc=$?
[ "$rc" = 1 ] && [ ! -s "$CALLS" ] && ok || bad "edge: no root must be rc 1 with no claim"

# ── W-* (dqw_watchdog) ────────────────────────────────────────────────────────
wd() { dqw_watchdog proj "$SLUG" 42 "$HEAD" "$1" "$URL"; }
rows() { jq -nc --arg s "$1" '{rows:[{status:$s}],truncated:false}'; }
reset; wd 2700
[ "$(n "lane-alert --severity critical --id dqw-unowned:proj:42:$H12 dequeue-watch")" = 1 ] && alert_has "no dequeue-watch action owns it" && ok || bad "W-45m: want one critical unowned page"
alert_has "$URL" && ok || bad "W-45m: the page must name the url"
reset; wd 1200
[ "$(n lane-alert)" = 0 ] && ok || bad "W-20m: paged under the window"
reset; STUB_LIST=$(rows failed) wd 2700
[ "$(n "lane-alert --severity critical --id dqw-unowned:")" = 1 ] && ok || bad "W-failed-only: a failed row does not own the PR"
reset; STUB_LIST=$(rows "done") wd 2700
[ "$(n "lane-alert --resolve --id dqw-unowned:proj:42:$H12 dequeue-watch")" = 1 ] && [ "$(grep -c -- '--severity' "$CALLS")" = 0 ] && ok || bad "W-owned: want one resolve and no page"
reset; STUB_LIST_RC=1 wd 2700
[ "$(n lane-alert)" = 0 ] && grep -q watchdog-unreadable "$LOG" && ok || bad "W-unreadable: paged or resolved on an unreadable list"
reset; STUB_LIST='garbage' wd 2700
[ "$(n lane-alert)" = 0 ] && ok || bad "W-unreadable: an unparseable list must page nothing"
reset; DEQUEUE_WATCH_UNOWNED_MIN=junk wd 1900
[ "$(n lane-alert)" = 1 ] && grep -q DEQUEUE_WATCH_UNOWNED_MIN "$LOG" && ok || bad "W-knob: junk minutes must fall back to 30 and be logged"

echo "dequeue-watch-act: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
