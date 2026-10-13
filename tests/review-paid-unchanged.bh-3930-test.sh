#!/bin/bash
# tests/review-paid-unchanged.bh-3930-test.sh — BH-3941 (BH-3930.4): the meter
# for "a review paid twice on one unchanged PR head".
#
#   E1-E5 run the real CLI, "$DIR/bin/review-paid-unchanged.sh", over fixture
#         fleet-cost.csv files with the full 26-column header and a pinned NOW:
#     E1  review-prs then review-autopilot on one head = ONE repeat, under the
#         second lane (the prefixes share a key)
#     E2  refused / unbilled / settled repeats are not paid, so not counted
#     E3  a ~reason fp (and its stored _reason form) is exempt, never counted
#     E4  lead:<key> twice counts under lead-review; legacy -:-:p rows = unkeyed;
#         an empty lane_id reads "null"; top[] shape
#     E5  a note with commas and quotes parses; no guard_fp column = rc 1
#   E6  the cost-rollup blocks, extracted VERBATIM from bin/cost-rollup.sh by
#       their markers and run with stub lane-alert / beat / alert-line:
#     a) yesterday 2, day before 1 -> warn with the top keys
#     b) yesterday 0, day before 3 -> resolve, no warn
#     c) RPU_ERR set -> one ALERTS line, no lane-alert, no beat
#     d) yesterday 1, day before 0 -> resolve, no warn
#     e) the compute block with a metric that fails -> {"error": ...}, never zeros
#     f) a summary with no key for yesterday -> the error path, never a resolve
#     g) the beat's exempt counts are yesterday's (exempt_by_day), not the window's
#   E7  a reason is grouped without its trailing digits (rebuy<epoch> -> rebuy),
#       and the stored _reason form is exempt like ~reason (call_guard_fp
#       rewrites ~ to _ before the row is written)
#   E8  days=7 is exactly 7 UTC days ending on NOW's day, every one zero-filled
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-paid-unchanged.bh-3930-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
RPU="$DIR/bin/review-paid-unchanged.sh"
[ -x "$RPU" ] || { echo "FAIL: bin/review-paid-unchanged.sh is missing or not executable"; exit 1; }

# 2026-10-03T12:00:00Z: yesterday is 2026-10-02, the day before 2026-10-01.
NOW=1791028800
S=$(printf 'a%.0s' {1..40}); S2=$(printf 'b%.0s' {1..40})
HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp"
# row <ts> <row_source> <cost> <lane_id> <guard_fp> [note] — one 26-column line
row() {
  printf '%s,box-1,demo-os,review,claude,m,0,10,1,1,0,0,%s,metered,fp,acct,sid,%s,,BH-1,job-1,,run-1,%s,%s,%s\n' \
    "$1" "$3" "$2" "${6:-}" "$4" "$5"
}
csvf() { { echo "$HDR"; cat; } > "$T/f.csv"; }
run() { "$RPU" "$T/f.csv" 7 "$NOW" > "$T/o.json" 2> "$T/e.txt"; RC=$?; }
j() { jq -cS "$1" "$T/o.json" 2>/dev/null; }

# ── E1: two review lanes on one head share a key; the second one is the repeat ──
csvf <<EOF
$(row 2026-10-01T09:00:00Z ledger 0.40 review-prs "review-prs:o/r#1@$S")
$(row 2026-10-01T09:30:00Z ledger 0.50 review-autopilot "review-autopilot:o/r#1@$S")
EOF
run
[ "$RC" = 0 ] && ok || bad "E1 rc=$RC err=$(cat "$T/e.txt")"
[ "$(j '.days["2026-10-01"]')" = '{"review-autopilot":1}' ] && ok || bad "E1 days: $(j .days)"
[ "$(j '.total_by_day["2026-10-01"]')" = 1 ] && ok || bad "E1 total_by_day: $(j .total_by_day)"
[ "$(j '.top[0].key')" = "\"review:o/r#1@$S\"" ] && ok || bad "E1 top key: $(j .top)"
[ "$(j '.top[0] | [.lane, .calls, .usd]')" = '["review-autopilot",2,0.5]' ] && ok || bad "E1 top entry: $(j .top)"
# a different head is a different key: no repeat
csvf <<EOF
$(row 2026-10-01T09:00:00Z ledger 0.40 review-prs "review-prs:o/r#1@$S")
$(row 2026-10-01T09:30:00Z ledger 0.50 review-prs "review-prs:o/r#1@$S2")
EOF
run
[ "$(j '[.total_by_day[]] | add')" = 0 ] && [ "$(j '.top')" = '[]' ] && ok || bad "E1 two heads counted as a repeat: $(cat "$T/o.json")"

# ── E2: refused / unbilled / settled repeats are not paid ──
csvf <<EOF
$(row 2026-10-02T09:00:00Z ledger 0.40 review-prs "review-prs:o/r#1@$S")
$(row 2026-10-02T09:10:00Z refused 0 review-prs "review-prs:o/r#1@$S")
$(row 2026-10-02T09:20:00Z unbilled 0 review-prs "review-prs:o/r#1@$S")
$(row 2026-10-02T09:30:00Z settled 0 review-prs "review-prs:o/r#1@$S")
EOF
run
[ "$RC" = 0 ] && [ "$(j '[.total_by_day[]] | add')" = 0 ] && [ "$(j '[.days[][]] | length')" = 0 ] && ok || bad "E2 unpaid rows counted: $(cat "$T/o.json")"
# ...and a refused FIRST row does not make the key paid: the next paid one is free
csvf <<EOF
$(row 2026-10-02T09:00:00Z refused 0 review-prs "review-prs:o/r#1@$S")
$(row 2026-10-02T09:10:00Z ledger 0.40 review-prs "review-prs:o/r#1@$S")
EOF
run
[ "$(j '[.total_by_day[]] | add')" = 0 ] && ok || bad "E2 a refused first row made the next paid row a repeat: $(cat "$T/o.json")"

# ── E3: ~reason (and the stored _reason) is exempt, never the metric ──
csvf <<EOF
$(row 2026-10-02T09:00:00Z ledger 0.40 review-prs "review:o/r#1@$S")
$(row 2026-10-02T09:10:00Z ledger 0.40 review-prs "review:o/r#1@$S~rereq")
$(row 2026-10-02T09:20:00Z ledger 0.40 lead-review "lead:o/r#1@${S}_noverdict")
EOF
run
[ "$RC" = 0 ] && ok || bad "E3 rc=$RC err=$(cat "$T/e.txt")"
[ "$(j '.exempt_by_reason')" = '{"noverdict":1,"rereq":1}' ] && ok || bad "E3 exempt_by_reason: $(j .exempt_by_reason)"
[ "$(j '[.total_by_day[]] | add')" = 0 ] && ok || bad "E3 an exempt row was counted: $(j .total_by_day)"

# ── E4: lead keys, legacy unkeyed lead rows, empty lane_id, the window ──
csvf <<EOF
$(row 2026-09-20T08:00:00Z ledger 0.30 review-prs "review-prs:o/r#9@$S2")
$(row 2026-10-02T08:00:00Z ledger 0.30 lead-review "lead:o/r#1@$S")
$(row 2026-10-02T08:09:00Z ledger 0.35 lead-review "lead:o/r#1@$S")
$(row 2026-10-02T08:10:00Z ledger 0.30 lead-review "-:-:pabcdef0123456789")
$(row 2026-10-02T08:20:00Z ledger 0.30 lead-review "-:-:p0123456789abcdef")
$(row 2026-10-02T09:00:00Z ledger 0.20 review-prs "review-prs:o/r#2@$S")
$(row 2026-10-02T09:10:00Z ledger 0.25 "" "review-prs:o/r#2@$S")
$(row 2026-10-02T09:15:00Z ledger 0.25 review-prs "review-prs:o/r#9@$S2")
EOF
run
[ "$RC" = 0 ] && ok || bad "E4 rc=$RC err=$(cat "$T/e.txt")"
[ "$(j '.days["2026-10-02"]')" = '{"lead-review":1,"null":1,"review-prs":1}' ] && ok || bad "E4 days: $(j .days)"
[ "$(j '.unkeyed')" = 2 ] && ok || bad "E4 unkeyed: $(j .unkeyed)"
[ "$(j '.total_by_day["2026-10-02"]')" = 3 ] && ok || bad "E4 total: $(j .total_by_day)"
# the key first paid BEFORE the window still makes its in-window repeat count
[ "$(j '[.top[] | select(.key == "review:o/r#9@'"$S2"'") | .calls]')" = '[1]' ] && ok || bad "E4 pre-window key: $(j .top)"
[ "$(j '[.top[] | select(.key == "lead:o/r#1@'"$S"'") | [.lane,.calls,.usd]]')" = '[["lead-review",2,0.35]]' ] && ok || bad "E4 lead top entry: $(j .top)"
[ "$(j '.top | length')" = 3 ] && ok || bad "E4 top length: $(j .top)"
[ "$(j '.window | [.from,.to]')" = '["2026-09-27","2026-10-03"]' ] && ok || bad "E4 window: $(j .window)"

# ── E5: a note with commas and quotes; a CSV with no guard_fp column ──
csvf <<EOF
$(row 2026-10-02T09:00:00Z ledger 0.40 review-prs "review-prs:o/r#1@$S" '"a, b ""q"" c"')
$(row 2026-10-02T09:10:00Z ledger 0.40 review-prs "review-prs:o/r#1@$S" '"x,y"')
EOF
run
[ "$RC" = 0 ] && [ "$(j '.days["2026-10-02"]')" = '{"review-prs":1}' ] && ok || bad "E5 quoted note: rc=$RC $(cat "$T/o.json" "$T/e.txt")"
printf 'ts,host,lane_id\n2026-10-02T09:00:00Z,b,review-prs\n' > "$T/f.csv"; run
[ "$RC" = 1 ] && ok || bad "E5 a CSV with no guard_fp column: rc=$RC (want 1)"
[ "$(wc -l < "$T/e.txt" | tr -d ' ')" = 1 ] && ok || bad "E5 want one stderr line: $(cat "$T/e.txt")"
[ -s "$T/o.json" ] && bad "E5 printed a result for an unreadable CSV: $(cat "$T/o.json")" || ok
"$RPU" "$T/nope.csv" 7 "$NOW" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "E5 a missing file: rc=$rc (want 2)"
"$RPU" "$T/f.csv" 0 "$NOW" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "E5 days=0: rc=$rc (want 2)"

# ── E6: the cost-rollup blocks, verbatim ──
CR="$DIR/bin/cost-rollup.sh"
blk() { awk -v b="$1" -v e="$2" 'index($0, b) == 1 {f=1} f {print} f && index($0, e) == 1 && !(index($0, b) == 1) {exit}' "$CR"; }
blk '# >>> review paid unchanged beat' '# <<< review paid unchanged beat' > "$T/beat-block.sh"
blk '# >>> review paid unchanged (BH-3930)' '# <<< review paid unchanged' > "$T/compute-block.sh"
[ -s "$T/beat-block.sh" ] && grep -q 'lane-alert' "$T/beat-block.sh" && ok || { bad "E6 the beat block is absent from bin/cost-rollup.sh"; }
[ -s "$T/compute-block.sh" ] && grep -q 'review-paid-unchanged.sh' "$T/compute-block.sh" && ok || { bad "E6 the compute block is absent from bin/cost-rollup.sh"; }

EH="$T/eh"; mkdir -p "$EH/bin" "$EH/flags" "$EH/cd"
for s in lane-alert beat alert-line; do
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/%s.log"\nexit 0\n' "$T" "$s" > "$EH/bin/$s.sh"; chmod +x "$EH/bin/$s.sh"
done
# summ <yesterday> <day-before> — a fixture summary.json carrying the metric
summ() {
  jq -n --argjson y "$1" --argjson b "$2" '{review_paid_unchanged:{
    days: {"2026-10-02": (if $y > 0 then {"review-prs": ($y - 1), "lead-review": 1} else {} end),
           "2026-10-01": (if $b > 0 then {"review-prs": $b} else {} end)},
    total_by_day: {"2026-10-02": $y, "2026-10-01": $b},
    exempt_by_reason: {rereq: 5, noverdict: 4},
    exempt_by_day: {"2026-10-02": {rereq: 2}, "2026-10-01": {rereq: 3, noverdict: 4}},
    unkeyed: 0,
    top: [{key:"review:o/r#1@aaaa", lane:"review-prs", calls:3, usd:0.8}, {key:"lead:o/r#2@bbbb", lane:"lead-review", calls:2, usd:0.4}]}}' > "$EH/cd/summary.json"
}
# beat_case <RPU_ERR> — run the extracted daily block as the daily run would
beat_case() {
  rm -f "$T"/{lane-alert,beat,alert-line}.log
  ( H="$EH"; CD="$EH/cd"; RPU_ERR="$1"; RPU_TODAY=2026-10-03
    # shellcheck disable=SC1090
    . "$T/beat-block.sh" ) > "$T/beat-out" 2>&1
}
lines_of() { [ -f "$T/$1.log" ] && wc -l < "$T/$1.log" | tr -d ' ' || echo 0; }
flags_before=$(ls "$EH/flags" | wc -l)

summ 2 1; beat_case ""
[ "$(lines_of lane-alert)" = 1 ] && grep -q -- '^--id review-paid-unchanged --severity warn cost-rollup ' "$T/lane-alert.log" && ok \
  || bad "E6a want one warn: $(cat "$T/lane-alert.log" "$T/beat-out" 2>/dev/null)"
grep -q 'review:o/r#1@aaaa' "$T/lane-alert.log" && grep -q 'lead:o/r#2@bbbb' "$T/lane-alert.log" && ok || bad "E6a the warn lacks the top keys: $(cat "$T/lane-alert.log")"
grep -q 'yesterday 2, day before 1' "$T/lane-alert.log" && ok || bad "E6a the warn lacks the counts: $(cat "$T/lane-alert.log")"
[ "$(lines_of beat)" = 1 ] && ok || bad "E6a want one beat, got $(lines_of beat)"
jq -r .line < "$T/beat.log" 2>/dev/null | grep -qx 'review_paid_unchanged yesterday: lead-review=1 review-prs=1 (exempt: rereq=2 stepup=0 noverdict=0)' \
  && ok || bad "E6a beat line: $(cat "$T/beat.log")"
[ "$(jq -r .akey < "$T/beat.log" 2>/dev/null)" = "reviewpaid:2026-10-03" ] && ok || bad "E6a beat akey: $(cat "$T/beat.log")"

summ 0 3; beat_case ""
grep -q -- '--severity warn' "$T/lane-alert.log" && bad "E6b warned on a zero yesterday" || ok
[ "$(lines_of lane-alert)" = 1 ] && grep -q -- '^--resolve --id review-paid-unchanged cost-rollup ' "$T/lane-alert.log" && ok || bad "E6b want one resolve: $(cat "$T/lane-alert.log" 2>/dev/null)"
jq -r .line < "$T/beat.log" 2>/dev/null | grep -qx 'review_paid_unchanged yesterday: none (exempt: rereq=2 stepup=0 noverdict=0)' \
  && ok || bad "E6b beat line: $(cat "$T/beat.log" 2>/dev/null)"

summ 2 1; beat_case "the CSV has no guard_fp column"
[ "$(lines_of alert-line)" = 1 ] && grep -q 'review_paid_unchanged did not compute: the CSV has no guard_fp column' "$T/alert-line.log" && ok \
  || bad "E6c want one ALERTS line: $(cat "$T/alert-line.log" 2>/dev/null)"
[ "$(lines_of lane-alert)" = 0 ] && ok || bad "E6c an error reached lane-alert (a resolve on unknown?): $(cat "$T/lane-alert.log")"
[ "$(lines_of beat)" = 0 ] && ok || bad "E6c an error was beaten as a line: $(cat "$T/beat.log")"

summ 1 0; beat_case ""
grep -q -- '--severity warn' "$T/lane-alert.log" && bad "E6d warned on one day" || ok
grep -q -- '^--resolve --id review-paid-unchanged' "$T/lane-alert.log" && ok || bad "E6d want a resolve: $(cat "$T/lane-alert.log" 2>/dev/null)"

# E6f: no key for yesterday is unknown, not zero: one ALERTS line, no resolve
summ 2 1; jq -c '.review_paid_unchanged.total_by_day |= del(.["2026-10-02"])' "$EH/cd/summary.json" > "$T/s2" && mv "$T/s2" "$EH/cd/summary.json"
beat_case ""
[ "$(lines_of lane-alert)" = 0 ] && ok || bad "E6f a missing day reached lane-alert: $(cat "$T/lane-alert.log")"
[ "$(lines_of alert-line)" = 1 ] && ok || bad "E6f want one ALERTS line for a missing day: $(cat "$T/alert-line.log" 2>/dev/null) $(cat "$T/beat-out")"
summ 2 1; jq -c '.review_paid_unchanged.total_by_day |= del(.["2026-10-01"])' "$EH/cd/summary.json" > "$T/s2" && mv "$T/s2" "$EH/cd/summary.json"
beat_case ""
[ "$(lines_of lane-alert)" = 0 ] && [ "$(lines_of alert-line)" = 1 ] && ok || bad "E6f a missing day-before: lane-alert=$(lines_of lane-alert) alert-line=$(lines_of alert-line)"

# E6g: the real metric's output through the beat block: exempt counts are
# yesterday's only; the noverdict two days back does not show
csvf <<EOF
$(row 2026-10-01T09:00:00Z ledger 0.40 lead-review "lead:o/r#3@$S2")
$(row 2026-10-01T09:05:00Z ledger 0.40 lead-review "lead:o/r#3@${S2}_noverdict")
$(row 2026-10-02T09:00:00Z ledger 0.40 review-autopilot "review-autopilot:o/r#1@$S")
$(row 2026-10-02T09:10:00Z ledger 0.40 review-autopilot "review-autopilot:o/r#1@$S")
$(row 2026-10-02T09:20:00Z ledger 0.40 review-autopilot "review-autopilot:o/r#1@$S")
$(row 2026-10-02T09:30:00Z ledger 0.40 review-autopilot "review:o/r#1@${S}_rereq")
EOF
run
jq -n --slurpfile m "$T/o.json" '{review_paid_unchanged: $m[0]}' > "$EH/cd/summary.json"
beat_case ""
jq -r .line < "$T/beat.log" 2>/dev/null | grep -qx 'review_paid_unchanged yesterday: review-autopilot=2 (exempt: rereq=1 stepup=0 noverdict=0)' \
  && ok || bad "E6g beat line: $(cat "$T/beat.log" 2>/dev/null) $(cat "$T/beat-out")"
grep -q -- '^--resolve --id review-paid-unchanged' "$T/lane-alert.log" && ok || bad "E6g want a resolve (day before is 0): $(cat "$T/lane-alert.log" 2>/dev/null)"

[ "$(ls "$EH/flags" | wc -l)" = "$flags_before" ] && ok || bad "E6 a flags/ file was written: $(ls "$EH/flags")"

# E6e: the compute block with a metric that fails leaves {"error": ...}
mkdir -p "$EH/bin"
printf '#!/bin/bash\necho boom >&2\necho "second line" >&2\nexit 1\n' > "$EH/bin/review-paid-unchanged.sh"; chmod +x "$EH/bin/review-paid-unchanged.sh"
( H="$EH"; CD="$EH/cd"; . "$T/compute-block.sh"; printf '%s' "$RPU_ERR" > "$T/rpu-err" ) > "$T/compute-out" 2>&1
[ "$(jq -c . "$EH/cd/.review-paid-unchanged.json" 2>/dev/null)" = '{"error":"boom"}' ] && ok || bad "E6e result: $(cat "$EH/cd/.review-paid-unchanged.json" 2>/dev/null) $(cat "$T/compute-out")"
[ "$(cat "$T/rpu-err")" = boom ] && ok || bad "E6e RPU_ERR: '$(cat "$T/rpu-err")'"
# and the real metric through the same block gives the real object
cp "$RPU" "$EH/bin/review-paid-unchanged.sh"
csvf <<EOF
$(row 2026-10-02T09:00:00Z ledger 0.40 review-prs "review-prs:o/r#1@$S")
EOF
cp "$T/f.csv" "$EH/cd/fleet-cost.csv"
( H="$EH"; CD="$EH/cd"; . "$T/compute-block.sh"; printf '%s' "$RPU_ERR" > "$T/rpu-err" ) > "$T/compute-out" 2>&1
[ "$(jq -c 'has("total_by_day") and has("top")' "$EH/cd/.review-paid-unchanged.json" 2>/dev/null)" = true ] && [ ! -s "$T/rpu-err" ] && ok \
  || bad "E6e the real metric through the block: $(cat "$EH/cd/.review-paid-unchanged.json" 2>/dev/null) err='$(cat "$T/rpu-err")'"

# ── E7: reasons group without trailing digits; _reason is the stored ~reason ──
csvf <<EOF
$(row 2026-10-02T08:00:00Z ledger 0.40 review-autopilot "review:o/r#1@$S")
$(row 2026-10-02T08:10:00Z ledger 0.40 review-autopilot "review:o/r#1@${S}~rebuy1696000000")
$(row 2026-10-02T08:20:00Z ledger 0.40 review-autopilot "review:o/r#1@${S}_rebuy1696000500")
$(row 2026-10-02T08:30:00Z ledger 0.40 review-autopilot "review:o/r#1@${S}_rereq")
EOF
run
[ "$RC" = 0 ] && [ "$(j '.exempt_by_reason')" = '{"rebuy":2,"rereq":1}' ] && ok || bad "E7 exempt_by_reason: $(j .exempt_by_reason) $(cat "$T/e.txt")"
[ "$(j '.exempt_by_day["2026-10-02"]')" = '{"rebuy":2,"rereq":1}' ] && ok || bad "E7 exempt_by_day: $(j .exempt_by_day)"
[ "$(j '[.total_by_day[]] | add')" = 0 ] && ok || bad "E7 an exempt row was counted: $(j .total_by_day)"
# a non-review fp never reaches the metric
csvf <<EOF
$(row 2026-10-02T08:00:00Z ledger 0.40 plan "plan:o/r#1@$S")
$(row 2026-10-02T08:10:00Z ledger 0.40 plan "plan:o/r#1@$S")
$(row 2026-10-02T08:20:00Z ledger 0.40 triage "triage:o/r#1@$S")
EOF
run
[ "$(j '[.total_by_day[]] | add')" = 0 ] && [ "$(j .unkeyed)" = 0 ] && ok || bad "E7 a plan/triage fp counted: $(cat "$T/o.json")"

# ── E8: exactly 7 UTC days ending on NOW's day, zero-filled ──
csvf <<EOF
$(row 2026-09-25T08:00:00Z ledger 0.40 review-prs "review-prs:o/r#5@$S")
$(row 2026-09-26T23:59:59Z ledger 0.40 review-prs "review-prs:o/r#5@$S")
$(row 2026-09-27T00:00:00Z ledger 0.40 review-prs "review-prs:o/r#5@$S")
EOF
run
[ "$(j '.total_by_day | keys')" = '["2026-09-27","2026-09-28","2026-09-29","2026-09-30","2026-10-01","2026-10-02","2026-10-03"]' ] \
  && ok || bad "E8 total_by_day keys: $(j '.total_by_day | keys')"
[ "$(j '.days | keys')" = "$(j '.total_by_day | keys')" ] && ok || bad "E8 days keys: $(j '.days | keys')"
[ "$(j '.total_by_day')" = '{"2026-09-27":1,"2026-09-28":0,"2026-09-29":0,"2026-09-30":0,"2026-10-01":0,"2026-10-02":0,"2026-10-03":0}' ] \
  && ok || bad "E8 the row 7 days back counted, or a day is not zero: $(j .total_by_day)"
[ "$(j '.days["2026-09-28"]')" = '{}' ] && [ "$(j '.exempt_by_day["2026-09-28"]')" = '{}' ] && ok || bad "E8 an empty day is not {}: $(j .days) $(j .exempt_by_day)"

echo "review-paid-unchanged.bh-3930: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
