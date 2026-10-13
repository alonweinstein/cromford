#!/bin/bash
# tests/state-flip-evidence.bh-5000-test.sh — BH-5000 (BH-4951.1): the
# per-flip evidence runner and its pr-state-rows module, driven as shipped
# (bash $HARNESS/bin/state-flip-evidence.sh) with the real _jobs_req and the
# real `bin/jobs-client.sh flag-active` behind the fake curl of
# tests/lib/qrf-fixture.sh. Also names the console's STATE PATHS sources and
# runs their node suite when the console-ui dependencies are installed.
#   R1-R4  the frame: unknown path, bad --since, no JOBS_URL, GET-only
#   P1-P9  pr-state-rows: GREEN only when the row is up, the conductor wrote
#          an event since the flip, and every tsv line whose since is at or
#          after the flip matches its row (older lines have none: no backfill)
# Run from anywhere: tests/state-flip-evidence.bh-5000-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/qrf-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# The files under test, named for bin/test-impact.sh.
for f in "$DIR/bin/state-flip-evidence.sh" "$DIR/bin/lib/sfe/pr-state-rows.sh"; do
  [ -f "$f" ] || { bad "$f missing"; continue; }
  bash -n "$f" || bad "$f does not parse"
done
for f in "$DIR/console-ui/src/lib/state-path-modes.js" "$DIR/console-ui/src/ui/StatePathModes.js" \
         "$DIR/console-ui/src/screens/Settings.js"; do
  [ -f "$f" ] && ok || bad "$f missing"
done
check() { if eval "$2"; then ok; else bad "$1"; echo "--- out:"; cat "$OUT"; echo "--- err:"; cat "$ERR"; fi; }

SINCE=2026-10-07T00:00:00Z
case_init() { qrf_fixture_init "$T/$1" "$DIR" || { echo "fixture init failed"; exit 1; }; OUT="$T/$1/out"; ERR="$T/$1/err"
  mkdir -p "$HARNESS/state/merge-conductor" "$HARNESS/logs" "$HARNESS/flags"; }
run() { bash "$HARNESS/bin/state-flip-evidence.sh" "$@" > "$OUT" 2> "$ERR"; RC=$?; }
flag_row() { qrf_fixture_route GET /api/flags/pr-state-rows 200 "{\"flag\":{\"name\":\"pr-state-rows\",\"active\":$1,\"updated_at\":\"$2\"}}"; }
event_at() { qrf_fixture_route GET '/api/pr-state-events?limit=1&not_state=queue' 200 "{\"rows\":[{\"id\":7,\"repo\":\"example-org/project-3\",\"number\":41,\"state\":\"open\",\"at\":\"$1\"}]}"; }
# pr_rows <repo> <json rows array>
pr_rows() { qrf_fixture_route GET "/api/pr-state?repo=$(jq -nr --arg r "$1" '$r|@uri')&limit=1000" 200 "{\"rows\":$2}"; }
tsv() { printf '%s\n' "$@" > "$HARNESS/state/merge-conductor/pr-state.tsv"; }
# Column 3 is mc_now's epoch, as mc_transition writes it. POST/PRE are just
# after / just before SINCE (2026-10-07T00:00:00Z = 1791331200).
POST=1791331800; PRE=1791244800
L1=$'example-org/project-3#41\topen\t'$POST$'\tabc\tabc\t-\twaiting\thttps://x/41'
L2=$'example-org/project-3#42\tblocked\t'$POST$'\tdef\tdef\t-\tci\thttps://x/42'
L3=$'example-org/project-2#7\topen\t'$POST$'\tghi\tghi\t-\twaiting\thttps://x/7'
project-3='[{"id":3,"repo":"example-org/project-3","number":41,"state":"open"},{"id":4,"repo":"example-org/project-3","number":42,"state":"blocked"},{"id":5,"repo":"example-org/project-3","number":99,"state":"merged"}]'
project-2='[{"id":6,"repo":"example-org/project-2","number":7,"state":"open"}]'
# Everything green; each P case breaks one thing.
green() { flag_row 1 2026-10-07T00:00:00Z; event_at 2026-10-07T00:05:00Z; tsv '# key state since head reviewed alerted reason url' "$L1" "$L2" "$L3"
  pr_rows example-org/project-3 "$project-3"; pr_rows example-org/project-2 "$project-2"
  printf 'rebase example-org/project-3#41 abc\n' > "$HARNESS/state/merge-conductor/attempts.txt"; }

# --- R1: an unknown path is rc 2 and lists the modules that exist ---
for w in no-such-path 'Bad/Path'; do
  case_init "r1-${w//\//_}"; green; run "$w" --since "$SINCE"
  check "R1 '$w' → rc 2" "[ $RC = 2 ]"
  check "R1 '$w' names pr-state-rows" "grep -q 'pr-state-rows' '$ERR'"
  check "R1 '$w' no request sent" "[ ! -s '$QRF_FX/req.log' ]"
done
# --- R2: a missing or bad --since is rc 2 ---
for s in none yesterday '' 2026-13-45T00:00:00Z 2026-10-07; do
  case_init "r2-$s"; green
  if [ "$s" = none ]; then run pr-state-rows; else run pr-state-rows --since "$s"; fi
  check "R2 since='$s' → rc 2" "[ $RC = 2 ]"
  check "R2 since='$s' no request sent" "[ ! -s '$QRF_FX/req.log' ]"
done
# --- R3: an empty JOBS_URL is rc 2 before any request ---
case_init r3; green; printf 'HARNESS_SECRET=test-secret\nJOBS_URL=\n' > "$HARNESS/env/global.env"; run pr-state-rows --since "$SINCE"
check "R3 empty JOBS_URL → rc 2" "[ $RC = 2 ]"
check "R3 says not configured" "grep -q 'not configured' '$ERR'"
check "R3 zero requests" "[ ! -s '$QRF_FX/req.log' ]"
check "R3 not GREEN" "! grep -q 'RESULT: GREEN' '$OUT'"

# --- P1: all green → GREEN, rc 0, rollback printed, GETs only (R4) ---
case_init p1; green; run pr-state-rows --since "$SINCE"
check "P1 rc 0" "[ $RC = 0 ]"
check "P1 RESULT: GREEN" "grep -qx 'RESULT: GREEN pr-state-rows' '$OUT'"
check "P1 rollback line" "grep -qx 'rollback: bin/jobs-client.sh flag-set pr-state-rows off' '$OUT'"
check "P1 three sections in order" "[ \"\$(grep '^== ' '$OUT' | tr '\n' ' ')\" = '== flag == == tick == == parity == ' ]"
check "P1 flag source line printed" "grep -q 'source: pause_flags row (active=1' '$OUT'"
check "P1 parity counts 3 entries" "grep -q 'parity: 3 post-flip file entries' '$OUT'"
check "P1 extra row is info, not a fail" "grep -q 'example-org/project-3: 1 row(s) with no line' '$OUT'"
check "P1 attempts counted, not compared" "grep -q 'attempts.txt: 1 entries' '$OUT'"
check "R4 only GET sent" "[ \"\$(qrf_fixture_methods)\" = GET ]"
check "R4 flag-active reconcile read the flag row" "grep -qx 'GET /api/flags/pr-state-rows' '$QRF_FX/req.log'"
check "R4 one read per repo" "[ \"\$(grep -c '^GET /api/pr-state?repo=' '$QRF_FX/req.log')\" = 2 ]"
check "R4 TMPDIR empty after the run" "[ -z \"\$(ls -A '$TMPDIR')\" ]"
# --- P1b: no pr-state.tsv on the box → vacuous parity, said so ---
case_init p1b; green; rm -f "$HARNESS/state/merge-conductor/pr-state.tsv"; run pr-state-rows --since "$SINCE"
check "P1b rc 0" "[ $RC = 0 ]"
check "P1b says no tsv and 0 entries" "grep -q 'no pr-state.tsv on this box' '$OUT' && grep -q 'parity: 0 file entries' '$OUT'"

# --- P2: the row is active=0 → flag FAIL, rc 1 ---
case_init p2; green; flag_row 0 2026-10-07T00:00:00Z; run pr-state-rows --since "$SINCE"
check "P2 rc 1" "[ $RC = 1 ]"
check "P2 flag FAIL" "grep -q '^\[FAIL\] flag: pr-state-rows reads off' '$OUT'"
check "P2 NOT GREEN, 1 failed" "grep -qx 'RESULT: NOT GREEN pr-state-rows (1 check(s) failed)' '$OUT'"
# --- P3: no row, only a box file → FAIL naming 'file ONLY' ---
case_init p3; green; : > "$QRF_FX/routes"; event_at 2026-10-07T00:05:00Z; tsv "$L1"; pr_rows example-org/project-3 "$project-3"
touch "$HARNESS/flags/pr-state-rows"; run pr-state-rows --since "$SINCE"
check "P3 rc 1" "[ $RC = 1 ]"
check "P3 FAIL says file ONLY" "grep -q '^\[FAIL\] flag: .*file ONLY' '$OUT'"
# --- P3b: a file newer than an active=0 row → FAIL, never GREEN ---
case_init p3b; green; flag_row 0 2026-10-01T00:00:00Z; touch "$HARNESS/flags/pr-state-rows"; run pr-state-rows --since "$SINCE"
check "P3b rc 1" "[ $RC = 1 ]"
check "P3b FAIL says newer than the row" "grep -q '^\[FAIL\] flag: .*newer than the row' '$OUT'"

# --- P4: the newest event predates --since → tick FAIL ---
case_init p4; green; event_at 2026-10-06T23:59:59Z; run pr-state-rows --since "$SINCE"
check "P4 rc 1" "[ $RC = 1 ]"
check "P4 tick FAIL names the flip time" "grep -q '^\[FAIL\] tick: no pr_state_events row since $SINCE (newest at 2026-10-06T23:59:59Z)' '$OUT'"
# --- P4b: an empty event log → tick FAIL ---
case_init p4b; green; qrf_fixture_route GET '/api/pr-state-events?limit=1&not_state=queue' 200 '{"rows":[]}'; run pr-state-rows --since "$SINCE"
check "P4b empty log is a tick FAIL" "[ $RC = 1 ] && grep -q '^\[FAIL\] tick: no pr_state_events row since' '$OUT'"
# --- P5: the events route answers 500 → 'unreadable', never 'no row since' ---
case_init p5; green; qrf_fixture_route GET '/api/pr-state-events?limit=1&not_state=queue' 500 'boom'; run pr-state-rows --since "$SINCE"
check "P5 rc 1" "[ $RC = 1 ]"
check "P5 FAIL says unreadable http=500" "grep -q '^\[FAIL\] tick: pr_state_events unreadable http=500' '$OUT'"
check "P5 never 'no row since'" "! grep -q 'no pr_state_events row since' '$OUT'"

# --- P5b: a newest event whose `at` is not a time → unreadable, not a tick ---
case_init p5b; green; event_at yesterday; run pr-state-rows --since "$SINCE"
check "P5b malformed at is unreadable" "[ $RC = 1 ] && grep -q \"^\\[FAIL\\] tick: pr_state_events unreadable: newest at 'yesterday'\" '$OUT'"

# --- P6: one key's state differs → parity FAIL naming that key (a since that
#     is not an epoch cannot be shown to predate the flip, so it is compared) ---
case_init p6; green; tsv "$L1" $'example-org/project-3#42\topen\t-\t-\t-\t-\t-\t-' "$L3"; run pr-state-rows --since "$SINCE"
check "P6 rc 1" "[ $RC = 1 ]"
check "P6 names the key and both states" "grep -qx '\[FAIL\] parity: example-org/project-3#42 file=open row=blocked' '$OUT'"
check "P6 exactly one parity FAIL" "[ \"\$(grep -c '^\[FAIL\] parity' '$OUT')\" = 1 ]"
# --- P7: a repo read at exactly the limit → 'incomplete read' ---
case_init p7; green
pr_rows example-org/project-3 "$(jq -nc '[range(1;1001) | {id: ., repo: "example-org/project-3", number: ., state: "open"}]')"
run pr-state-rows --since "$SINCE"
check "P7 rc 1" "[ $RC = 1 ]"
check "P7 incomplete read" "grep -q '^\[FAIL\] parity: example-org/project-3: incomplete read' '$OUT'"
# --- P7b: the pr-state route answers 500 → unreadable, not 'no row' ---
case_init p7b; green; qrf_fixture_route GET '/api/pr-state?repo=example-org%2Fproject-2&limit=1000' 500 'boom'; run pr-state-rows --since "$SINCE"
check "P7b unreadable http=500" "[ $RC = 1 ] && grep -q '^\[FAIL\] parity: example-org/project-2: pr_state unreadable http=500' '$OUT'"
check "P7b never 'no row' for that repo" "! grep -q 'project-2#7 no row' '$OUT'"
# --- P8: a tsv key with no row → 'no row' (and a 404 repo fails every key) ---
case_init p8; green; tsv "$L1" "$L2" "$L3" $'example-org/project-3#43\topen\t'$POST$'\t-\t-\t-\t-\t-' $'example-org/gone#1\topen\t'$POST$'\t-\t-\t-\t-\t-'
run pr-state-rows --since "$SINCE"
check "P8 rc 1" "[ $RC = 1 ]"
check "P8 no row for #43" "grep -qx '\[FAIL\] parity: example-org/project-3#43 no row (file=open)' '$OUT'"
check "P8 404 repo → no row" "grep -qx '\[FAIL\] parity: example-org/gone#1 no row (file=open)' '$OUT'"
check "P8 NOT GREEN, 2 failed" "grep -qx 'RESULT: NOT GREEN pr-state-rows (2 check(s) failed)' '$OUT'"

# --- P9: a pre-flip steady line has no row (no backfill) → info, still GREEN ---
case_init p9; green
tsv "$L1" "$L2" "$L3" $'example-org/project-3#44\tBLOCKED_HUMAN\t'$PRE$'\t-\t-\t-\t-\t-' $'example-org/held-only#5\topen\t'$PRE$'\t-\t-\t-\t-\t-'
run pr-state-rows --since "$SINCE"
check "P9 rc 0" "[ $RC = 0 ]"
check "P9 RESULT: GREEN" "grep -qx 'RESULT: GREEN pr-state-rows' '$OUT'"
check "P9 pre-flip lines counted as info" "grep -q '2 pre-flip entries (since before $SINCE, no backfill, not compared)' '$OUT'"
check "P9 compares only the 3 post-flip lines" "grep -q 'parity: 3 post-flip file entries' '$OUT'"
check "P9 no 'no row' for a pre-flip line" "! grep -q 'no row' '$OUT'"
check "P9 a pre-flip-only repo is not read" "! grep -q 'held-only' '$QRF_FX/req.log'"
# --- P9b: the same key changed after the flip and has no row → FAIL ---
case_init p9b; green
tsv "$L1" "$L2" "$L3" $'example-org/project-3#44\tBLOCKED_HUMAN\t'$POST$'\t-\t-\t-\t-\t-'
run pr-state-rows --since "$SINCE"
check "P9b rc 1" "[ $RC = 1 ]"
check "P9b post-flip line with no row FAILs" "grep -qx '\[FAIL\] parity: example-org/project-3#44 no row (file=BLOCKED_HUMAN)' '$OUT'"
# --- P9c: every line predates the flip → nothing to compare, said so, GREEN ---
case_init p9c; green; tsv $'example-org/project-3#44\topen\t'$PRE$'\t-\t-\t-\t-\t-'
run pr-state-rows --since "$SINCE"
check "P9c rc 0 with 0 post-flip entries" "[ $RC = 0 ] && grep -q 'parity: 0 post-flip file entries' '$OUT'"
check "P9c no pr-state read" "! grep -q '^GET /api/pr-state?' '$QRF_FX/req.log'"

# --- the console STATE PATHS node suite, when the console deps are installed ---
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "state-flip-evidence: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
elif ! command -v node >/dev/null 2>&1; then
  echo "state-flip-evidence: node suite SKIPPED — node is not installed on this box"
elif NOUT=$(cd "$DIR/console-ui" && node --test tests/state-path-modes.bh-5000.test.js 2>&1); then ok
else bad "console-ui/tests/state-path-modes.bh-5000.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "state-flip-evidence: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
