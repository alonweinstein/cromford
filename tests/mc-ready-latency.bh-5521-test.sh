#!/bin/bash
# tests/mc-ready-latency.bh-5521-test.sh — BH-5521 item 4: bin/mc-ready-latency.sh
# measures READY -> enqueued from the conductor's own log and GitHub's gate times.
#
# Every log line is written by the REAL writer: bin/lib/mc/log.sh +
# bin/lib/mc/settle.sh `mc_transition`, sourced with HARNESS pointed at the
# scratch tree and mc_stamp/mc_now pinned to a fixture clock. GitHub is a `gh`
# stub that answers `gh api -i -X GET <path>` from $T/fx/<path with / -> _>,
# fails a read when the same name with `.fail` exists, and logs each call.
#
#   L1 round trip: ready_log_s=30, green_s=120 (prequeue-verdict ignored)
#   L2 p50/p90/max/over_120s/target over 10 s, 50 s, 200 s
#   L3 a failed status read -> green_s=unread, unread=1, INCOMPLETE
#   L4 an empty window -> INCOMPLETE line, rc 3
#   L5 --no-github -> no gh call, green_s=-, ready_log_s printed
#   L6 --max 1 with 2 rows -> one row read, capped=1, INCOMPLETE
#   L7 check runs: the latest green run at or before the enqueue counts
#   L8 the head's pre-queue workflow run counts
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-ready-latency.bh-5521-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

[ -f "$DIR/bin/mc-ready-latency.sh" ] || bad "bin/mc-ready-latency.sh must exist"
H="$T/h"; FB="$T/fakebin"
mkdir -p "$H/logs" "$H/state/merge-conductor" "$H/env" "$FB" "$T/fx"
: > "$H/env/global.env"
cat > "$FB/gh" <<'EOF'
#!/bin/bash
p=""; prev=""
for a in "$@"; do [ "$prev" = GET ] && p="$a"; prev="$a"; done
printf '%s\n' "${p:-$*}" >> "$FX/gh-calls.txt"
f="$FX/$(printf %s "$p" | tr '/?&=' '____')"
[ -e "$f.fail" ] && { printf 'HTTP/2 403\r\nx-ratelimit-remaining: 0\r\n\r\n{"message":"API rate limit exceeded"}\n'; exit 1; }
if [ -f "$f" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$f"; exit 0; fi
printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; exit 1
EOF
chmod +x "$FB/gh"

E0=1791700000                         # 2026-10-11 06:26:40Z, the fixture clock
SINCE=2026-10-11T06:00; UNTIL=2026-10-11T07:00
HA=$(printf 'a%.0s' {1..40}); HB=$(printf 'b%.0s' {1..40}); HC=$(printf 'c%.0s' {1..40})
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
fxname() { printf %s "$1" | tr '/?&=' '____'; }

# tr_at <epoch> <key> <state> <head> — one transition through the real writer.
tr_at() {
  ( export HARNESS="$H"
    . "$DIR/bin/lib/mc/log.sh" && . "$DIR/bin/lib/mc/settle.sh" || exit 1
    touch "$MC_ROWS"
    E="$1"; mc_stamp() { date -u -d "@$E" '+%Y-%m-%d %H:%M:%SZ'; }; mc_now() { echo "$E"; }
    mc_transition "$2" "$3" "fixture" "$4" - "https://github.com/${2%#*}/pull/${2##*#}" APPROVE CLEAN - >/dev/null ) 2>/dev/null
}
# status <h8> <context=state@epoch>... — the combined-status answer for a head.
status() {
  local h="$1"; shift
  local s c st at items=()
  for s in "$@"; do c="${s%%=*}"; st="${s#*=}"; at="${st#*@}"; st="${st%@*}"
    items+=("$(jq -nc --arg c "$c" --arg s "$st" --arg u "$(iso "$at")" '{context:$c,state:$s,updated_at:$u}')"); done
  printf '{"state":"success","statuses":[%s]}\n' "$(IFS=,; echo "${items[*]}")" > "$T/fx/$(fxname "repos/example-org/demo/commits/$h/status")"
}
checks() { # checks <h8> <conclusion@epoch>...
  local h="$1"; shift
  local s items=()
  for s in "$@"; do items+=("$(jq -nc --arg c "${s%@*}" --arg u "$(iso "${s#*@}")" '{name:"CI",status:"completed",conclusion:$c,completed_at:$u}')"); done
  printf '{"total_count":%s,"check_runs":[%s]}\n' "${#items[@]}" "$(IFS=,; echo "${items[*]}")" \
    > "$T/fx/$(fxname "repos/example-org/demo/commits/$h/check-runs?per_page=100")"
}
pqruns() { # pqruns <json array of workflow_runs>
  printf '{"workflow_runs":%s}\n' "$1" > "$T/fx/$(fxname "repos/example-org/demo/actions/workflows/prequeue-gate.yml/runs?event=workflow_dispatch&per_page=100")"
}
reset() {
  rm -f "$H/logs/merge-conductor.log" "$H/state/merge-conductor/pr-state.tsv" "$T/fx/"*
  : > "$T/fx/gh-calls.txt"
  pqruns '[]'
}
report() { # report [args...] — stdout to $T/out, rc echoed
  env PATH="$FB:$PATH" HARNESS="$H" FX="$T/fx" HARNESS_TEST_SANDBOX=1 GH_ETAG=0 \
    bash "$DIR/bin/mc-ready-latency.sh" --since "$SINCE" --until "$UNTIL" "$@" > "$T/out" 2>"$T/err"
  echo $?
}
row() { awk -F'\t' -v k="$1" '$1==k' "$T/out"; }
col() { row "$1" | cut -f"$2"; }
summary() { grep '^READY_TO_QUEUED ' "$T/out"; }

# L1 round trip. Fields: ready_log_s, green_s, head, the summary's n/measured.
reset
tr_at $((E0 - 200)) example-org/demo#5 WAIT_CI "$HA"
tr_at "$E0"         example-org/demo#5 READY   "$HA"
tr_at $((E0 + 30))  example-org/demo#5 QUEUED  "$HA"
status aaaaaaaa "lead-verdict=success@$((E0 - 90))" "prequeue-verdict=success@$((E0 + 29))" "CI=failure@$((E0 - 5))"
checks aaaaaaaa
rc=$(report)
[ "$rc" = 0 ] && ok || bad "L1: rc 0 expected, got $rc ($(cat "$T/err"))"
[ "$(col example-org/demo#5 2)" = aaaaaaaa ] && ok || bad "L1: head column (out: $(cat "$T/out"))"
[ "$(col example-org/demo#5 4)" = 30 ] && ok || bad "L1: ready_log_s must be 30 (got '$(col example-org/demo#5 4)')"
[ "$(col example-org/demo#5 5)" = 120 ] && ok || bad "L1: green_s must be 120, prequeue-verdict ignored (got '$(col example-org/demo#5 5)')"
summary | grep -q ' n=1 measured=1 unread=0 capped=0 ' && ok || bad "L1: summary counts (got '$(summary)')"
grep -qx 'repos/example-org/demo/commits/aaaaaaaa/status' "$T/fx/gh-calls.txt" && ok || bad "L1: the status read uses the 8-char head"

# L2 three measured rows: 10 s, 50 s, 200 s. Fields: p50, p90, max, over_120s, target.
reset
for spec in "1:$HA:10" "2:$HB:50" "3:$HC:200"; do
  n="${spec%%:*}"; h="${spec#*:}"; h="${h%%:*}"; g="${spec##*:}"
  tr_at "$E0" "example-org/demo#$n" READY "$h"
  tr_at $((E0 + n)) "example-org/demo#$n" QUEUED "$h"
  status "${h:0:8}" "lead-verdict=success@$((E0 + n - g))"; checks "${h:0:8}"
done
report >/dev/null
summary | grep -q 'n=3 measured=3 unread=0 capped=0 p50=50 p90=200 max=200 over_120s=1 target_p90_120s=missed' && ok \
  || bad "L2: summary (got '$(summary)')"
grep -q 'INCOMPLETE' <<<"$(summary)" && bad "L2: a complete read is not INCOMPLETE" || ok
# ...and a fast set meets the target.
reset
tr_at "$E0" example-org/demo#1 READY "$HA"; tr_at $((E0 + 1)) example-org/demo#1 QUEUED "$HA"
status aaaaaaaa "lead-verdict=success@$((E0 - 20))"; checks aaaaaaaa
report >/dev/null
summary | grep -q 'p90=21 max=21 over_120s=0 target_p90_120s=met' && ok || bad "L2b: target met (got '$(summary)')"

# L3 one status read fails. Fields: that row's green_s, unread, INCOMPLETE, the
# other row still measured.
reset
tr_at "$E0" example-org/demo#1 READY "$HA"; tr_at $((E0 + 1)) example-org/demo#1 QUEUED "$HA"
tr_at "$E0" example-org/demo#2 READY "$HB"; tr_at $((E0 + 2)) example-org/demo#2 QUEUED "$HB"
status aaaaaaaa "lead-verdict=success@$((E0 - 10))"; checks aaaaaaaa
checks bbbbbbbb; touch "$T/fx/$(fxname repos/example-org/demo/commits/bbbbbbbb/status).fail"
report >/dev/null
[ "$(col example-org/demo#2 5)" = unread ] && ok || bad "L3: a failed read is green_s=unread (got '$(col example-org/demo#2 5)')"
[ "$(col example-org/demo#1 5)" = 11 ] && ok || bad "L3: the other row is still measured (got '$(col example-org/demo#1 5)')"
summary | grep -q 'measured=1 unread=1 ' && ok || bad "L3: unread=1 (got '$(summary)')"
summary | grep -q ' INCOMPLETE$' && ok || bad "L3: INCOMPLETE (got '$(summary)')"
summary | grep -q 'p50=11 ' && ok || bad "L3: an unread row is never counted as 0 s (got '$(summary)')"

# L4 an empty window. Fields: the line, rc 3.
reset
tr_at "$E0" example-org/demo#1 READY "$HA"; tr_at $((E0 + 1)) example-org/demo#1 QUEUED "$HA"
rc=$(env PATH="$FB:$PATH" HARNESS="$H" FX="$T/fx" HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/mc-ready-latency.sh" --since 2026-10-12T00:00 --until 2026-10-12T01:00 > "$T/out" 2>"$T/err"; echo $?)
[ "$rc" = 3 ] && ok || bad "L4: an empty window exits 3 (got $rc)"
grep -qx 'INCOMPLETE: no QUEUED transition in the window' "$T/out" && ok || bad "L4: the INCOMPLETE line (got '$(cat "$T/out")')"
# ...and no log file at all is the same answer.
rm -f "$H/logs/merge-conductor.log"
rc=$(report)
[ "$rc" = 3 ] && ok || bad "L4: no log file exits 3 (got $rc)"

# L5 --no-github. Fields: gh call log, green_s, ready_log_s.
reset
tr_at "$E0" example-org/demo#1 READY "$HA"; tr_at $((E0 + 7)) example-org/demo#1 QUEUED "$HA"
report --no-github >/dev/null
[ ! -s "$T/fx/gh-calls.txt" ] && ok || bad "L5: --no-github must call gh 0 times (got $(cat "$T/fx/gh-calls.txt"))"
[ "$(col example-org/demo#1 5)" = - ] && ok || bad "L5: green_s is - (got '$(col example-org/demo#1 5)')"
[ "$(col example-org/demo#1 4)" = 7 ] && ok || bad "L5: ready_log_s is still printed (got '$(col example-org/demo#1 4)')"

# L6 --max 1 with 2 rows. Fields: status reads, capped, INCOMPLETE, the newest row read.
reset
tr_at "$E0" example-org/demo#1 READY "$HA"; tr_at $((E0 + 1)) example-org/demo#1 QUEUED "$HA"
tr_at "$E0" example-org/demo#2 READY "$HB"; tr_at $((E0 + 9)) example-org/demo#2 QUEUED "$HB"
status aaaaaaaa "lead-verdict=success@$E0"; checks aaaaaaaa
status bbbbbbbb "lead-verdict=success@$E0"; checks bbbbbbbb
report --max 1 >/dev/null
[ "$(grep -c '/status$' "$T/fx/gh-calls.txt")" = 1 ] && ok || bad "L6: one row read (got $(grep -c '/status$' "$T/fx/gh-calls.txt"))"
[ "$(col example-org/demo#2 5)" = 9 ] && ok || bad "L6: the NEWEST row is the one read (got '$(col example-org/demo#2 5)')"
[ "$(col example-org/demo#1 5)" = capped ] && ok || bad "L6: the other row says capped (got '$(col example-org/demo#1 5)')"
summary | grep -q 'capped=1 ' && summary | grep -q ' INCOMPLETE$' && ok || bad "L6: capped=1 INCOMPLETE (got '$(summary)')"

# L7 check runs: the latest green run at or before the enqueue. Fields: green_s.
reset
tr_at "$E0" example-org/demo#1 READY "$HA"; tr_at $((E0 + 100)) example-org/demo#1 QUEUED "$HA"
status aaaaaaaa
checks aaaaaaaa "success@$((E0 + 60))" "failure@$((E0 + 90))" "success@$((E0 + 105))" "skipped@$((E0 + 10))"
report >/dev/null
[ "$(col example-org/demo#1 5)" = 40 ] && ok || bad "L7: the latest green check at/before the enqueue counts (got '$(col example-org/demo#1 5)')"

# L8 the head's pre-queue run. Fields: green_s.
reset
tr_at "$E0" example-org/demo#4 READY "$HA"; tr_at $((E0 + 100)) example-org/demo#4 QUEUED "$HA"
status aaaaaaaa "lead-verdict=success@$E0"; checks aaaaaaaa
pqruns "$(jq -nc --arg h "$HA" --arg m "$HB" --arg u "$(iso $((E0 + 80)))" --arg u2 "$(iso $((E0 + 95)))" \
  '[{display_title:("prequeue pr=4 head="+$h+" main="+$m), conclusion:"success", updated_at:$u},
    {display_title:("prequeue pr=44 head="+$h+" main="+$m), conclusion:"success", updated_at:$u2}]')"
report >/dev/null
[ "$(col example-org/demo#4 5)" = 20 ] && ok || bad "L8: the pre-queue run of THIS PR counts, pr=44 does not (got '$(col example-org/demo#4 5)')"
[ "$(grep -c 'actions/workflows/prequeue-gate.yml/runs' "$T/fx/gh-calls.txt")" = 1 ] && ok || bad "L8: one runs read per repo"

echo "mc-ready-latency.bh-5521: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
