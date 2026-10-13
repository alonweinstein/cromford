#!/bin/bash
# tests/ci-batch-ledger.bh-4964-test.sh — bin/ci-batch-ledger.sh (BH-4971,
# BH-4964.3) driven against a scratch harness: a fake `gh` that serves fixture
# run lists, job lists and check-run annotations, and a fake bin/jobs-client.sh
# whose _jobs_req keeps the ledger in a jq file (store.json) the way the worker's
# PUT/GET /api/ci-batches would.
#
# WHAT IT PINS:
#   1  billed_min = sum of ceil(job seconds / 60) over MonkCI jobs only, and the
#      ci-plan notice's mode/count/total land on the row
#   2  the ledger is the skip-set: a recorded run is never read again
#   3  no ci-plan notice (or a notice under another title) = full-legacy, with
#      selected and total NULL, never a made-up corpus size
#   4  an annotations read that FAILS is not "no notice": unrecorded, retried
#   5  a failed PUT is logged and retried next tick
#   6  only mergify/merge-queue/ branches are batch runs
#   7  CI_BATCH_LEDGER_MAX caps a tick, the rest is deferred and drains; the
#      runs list asks for the last CI_BATCH_LEDGER_DAYS days
#   8-10 budget low, not configured, ledger unreadable: no GitHub read at all
#   11 a re-run of a recorded batch is read again: billed_min sums EVERY
#      attempt's jobs (filter=all), conclusion/run_attempt are the latest's, and
#      a jobs list longer than the pages read records nothing
#   12 an escalation reason drops ci-plan's '; tiers: ...' suffix; annotations
#      are read 100 a page
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u -d '2026-10-07T09:00:00Z' +%s)
iso() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
R=example-org/cromford

HH="$T/h"
mkdir -p "$HH/bin/lib" "$HH/logs" "$HH/fx" "$T/stub"
# Stubs first: scratch_install_closure never clobbers a file already there.
cat > "$HH/bin/lib/lane-gate.sh" <<'SH'
lane_gate_or_exit() { :; }
lane_env_apply() { :; }
SH
cat > "$HH/bin/lib/gh-budget.sh" <<'SH'
gh_budget_low() { return "${FAKE_BUDGET_LOW:-1}"; }
SH
cat > "$HH/bin/lib/gh-repo-token.sh" <<'SH'
gh_repo_use_token() { return 0; }
gh_repo_token_reset() { :; }
SH
cat > "$HH/bin/jobs-client.sh" <<'SH'
jobs_configured() { [ -n "${JOBS_URL:-}" ]; }
JOBS_HTTP=""; JOBS_BODY=""
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" S="$HARNESS/store.json"
  JOBS_HTTP=""; JOBS_BODY=""
  echo "$m $p" >> "$HARNESS/jobs-calls.txt"
  [ -f "$S" ] || echo '[]' > "$S"
  case "$m" in
    GET)
      if [ -n "${FAKE_GET_FAIL:-}" ]; then JOBS_HTTP=503; JOBS_BODY='{"error":"ci_batches schema not applied"}'; return 1; fi
      JOBS_HTTP=200
      jq -c --argjson tr "${FAKE_TRUNC:-false}" '{rows: ., as_of: "x", truncated: $tr}' "$S" ;;
    PUT)
      if [ "${FAKE_PUT_FAIL:-}" = 1 ]; then JOBS_HTTP=503; JOBS_BODY='{"error":"ci_batches unavailable"}'; return 1; fi
      jq -c --argjson r "$b" '[.[] | select(.run_id != $r.run_id)] + [$r]' "$S" > "$S.n" && mv "$S.n" "$S"
      JOBS_HTTP=200; printf '{"ok":true}' ;;
  esac
}
SH
scratch_install_closure bin/ci-batch-ledger.sh "$HH" >/dev/null || { echo "FAIL: cannot install the lane closure"; exit 1; }

# The fake gh: `api [-X M] <path> [-f k=v]... [-q filter]`. Every call's
# arguments go to calls.txt, one line each.
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls.txt"
shift   # "api"
P=""; Q=""; PG=1
while [ $# -gt 0 ]; do
  case "$1" in
    -X) shift 2 ;;
    -q|--jq) Q="$2"; shift 2 ;;
    -f) case "$2" in page=*) PG="${2#page=}" ;; esac; shift 2 ;;
    *) P="$1"; shift ;;
  esac
done
case "$P" in
  */actions/workflows/harness-ci.yml/runs) F="$HARNESS/fx/runs.$PG.json" ;;
  */actions/runs/*/jobs*) ID=$(sed -E 's#.*/runs/([0-9]+)/jobs.*#\1#' <<<"$P"); F="$HARNESS/fx/jobs.$ID.json" ;;
  */check-runs/*/annotations*) C=$(sed -E 's#.*/check-runs/([0-9]+)/annotations.*#\1#' <<<"$P"); F="$HARNESS/fx/ann.$C.json" ;;
  *) exit 1 ;;
esac
[ -r "$F" ] || exit 1
if [ -n "$Q" ]; then jq -c "$Q" "$F"; else cat "$F"; fi
SH
chmod +x "$T/stub/gh"

RUNS=""
run() { # run <id> <head_branch> <age-seconds>  — completed run, 20 wall minutes
  RUNS="$RUNS${RUNS:+,}{\"id\":$1,\"head_branch\":\"$2\",\"head_sha\":\"sha$1\",\"conclusion\":\"success\",\"status\":\"completed\",\"event\":\"pull_request\",\"run_started_at\":\"$(iso $(( $3 + 1200 )))\",\"updated_at\":\"$(iso "$3")\"}"
  jq -n --argjson r "[$RUNS]" '{total_count: ($r | length), workflow_runs: $r}' > "$HH/fx/runs.1.json"
}
job() { # job <label> <secs> [name] [check-run id]  — one job JSON object
  printf '{"name":"%s","labels":["%s"],"runner_name":"%s-1","started_at":"%s","completed_at":"%s","check_run_url":"https://api.github.com/repos/%s/check-runs/%s"}' \
    "${3:-test (0)}" "$1" "$1" "$(iso $(( 4000 + $2 )))" "$(iso 4000)" "$R" "${4:-1}"
}
jobs() { # jobs <run-id> <job-json>...
  local id="$1"; shift
  local IFS=,; echo "{\"total_count\":$#,\"jobs\":[$*]}" > "$HH/fx/jobs.$id.json"
}
ann() { # ann <check-run id> <json array>
  echo "$2" > "$HH/fx/ann.$1.json"
}
NOTE='{"title":"ci-plan","annotation_level":"notice","message":"mode=batch-selected count=12 total=900 n=4 reason=impact"}'
drive() { # drive [env assignments...]
  rm -f "$HH/calls.txt" "$HH/jobs-calls.txt"
  ( export HARNESS="$HH" NOW PATH="$T/stub:$PATH" JOBS_URL=https://jobs.test HARNESS_SECRET=dummy-secret
    [ $# -gt 0 ] && export "${@?}"
    bash "$HH/bin/ci-batch-ledger.sh" ) >"$T/out.txt" 2>&1
  RC=$?
}
reset() { RUNS=""; rm -f "$HH/fx/"* "$HH/store.json" "$HH/logs/ci-batch-ledger.log"; }
calls() { if [ -f "$HH/calls.txt" ]; then grep -c -- "$1" "$HH/calls.txt"; else echo 0; fi; }
puts() { if [ -f "$HH/jobs-calls.txt" ]; then grep -c '^PUT ' "$HH/jobs-calls.txt"; else echo 0; fi; }
row() { jq -c --argjson id "$1" '.[] | select(.run_id == $id)' "$HH/store.json" 2>/dev/null; }
LOG="$HH/logs/ci-batch-ledger.log"
lastlog() { tail -1 "$LOG" 2>/dev/null; }

# ── scenario A: a selected batch, two notice-less batches, an escalated one,
#    and four runs that are not batch runs at all
reset
run 900 mergify/merge-queue/main/abc 3600
jobs 900 "$(job ubuntu-latest 10 'CI plan (what this run tests)' 5900)" \
  "$(job monkci-ubuntu-24.04-4 61)" "$(job monkci-ubuntu-24.04-4 59)" "$(job monkci-ubuntu-24.04-4 120)" \
  "$(job ubuntu-latest 300)"
ann 5900 "[{\"title\":\"other\",\"message\":\"mode=full count=1 total=1 n=1 reason=x\"},$NOTE]"
run 901 mergify/merge-queue/main/def 3500
jobs 901 "$(job ubuntu-latest 10 'CI plan (what this run tests)' 5901)" "$(job monkci-ubuntu-24.04-4 60)"
ann 5901 '[{"title":"lint","message":"mode=batch-selected count=3 total=900 n=1 reason=impact"}]'
run 904 mergify/merge-queue/main/ghi 3400
jobs 904 "$(job monkci-ubuntu-24.04-4 90)"
run 905 mergify/merge-queue/main/jkl 3300
jobs 905 "$(job ubuntu-latest 10 'CI plan (what this run tests)' 5905)" "$(job monkci-ubuntu-24.04-4 30)"
ann 5905 '[{"title":"ci-plan","message":"mode=full count=900 total=900 n=8 reason=full: selection input: bin/ci-plan.sh x=y"}]'
for nb in "910 ticket/bh-1" "911 main" "912 mergify/other/x" "913 feature/mergify/merge-queue/y"; do
  set -- $nb
  run "$1" "$2" 3000
  jobs "$1" "$(job monkci-ubuntu-24.04-4 600)"
done
drive
[ "$RC" = 0 ] && ok || bad "A: rc must be 0, got $RC ($(cat "$T/out.txt"))"

# 1. billing + the observable row
R900=$(row 900)
[ "$(jq -r .billed_min <<<"$R900")" = 5 ] && ok || bad "1: 61s+59s+120s on MonkCI bill 2+1+2 = 5, the ubuntu-latest jobs nothing: $R900"
[ "$(jq -r '[.mode, .selected, .total, (.escalation|tostring)] | join(" ")' <<<"$R900")" = "batch-selected 12 900 null" ] \
  && ok || bad "1: the ci-plan notice sets mode/selected/total, escalation null: $R900"
[ "$(jq -r '[.repo, .head_ref, .head_sha, .conclusion, .wall_s, .started_at, .completed_at] | join(" ")' <<<"$R900")" \
  = "$R mergify/merge-queue/main/abc sha900 success 1200 $(iso 4800) $(iso 3600)" ] \
  && ok || bad "1: the run's own fields land on the row: $R900"
[ "$(grep -c '^PUT /api/ci-batches$' "$HH/jobs-calls.txt")" = 4 ] && ok || bad "1: one PUT per batch run (4): $(cat "$HH/jobs-calls.txt")"

# 3. no notice: full-legacy, both counts null — for a notice under another
#    title (901) and for a run with no plan job at all (904)
for id in 901 904; do
  [ "$(jq -c '[.mode, .selected, .total, .escalation]' <<<"$(row $id)")" = '["full-legacy",null,null,null]' ] \
    && ok || bad "3: run $id has no ci-plan notice -> full-legacy, selected=total=null: $(row $id)"
done
[ "$(jq -r .billed_min <<<"$(row 904)")" = 2 ] && ok || bad "3: a legacy run is still billed: $(row 904)"
[ "$(jq -c '[.mode, .selected, .total, .escalation]' <<<"$(row 905)")" = '["full",900,900,"selection input: bin/ci-plan.sh x=y"]' ] \
  && ok || bad "3: an escalated batch keeps the reason after 'full: ', spaces and = included: $(row 905)"

# 6. not a batch run: never PUT, jobs never read
for id in 910 911 912 913; do
  [ -z "$(row $id)" ] && [ "$(calls "runs/$id/jobs")" = 0 ] && ok || bad "6: run $id is not on mergify/merge-queue/ and must be neither read nor recorded"
done
grep -q "repo=$R queue_runs=4 already=0 recorded=4 put_failed=0 unread=0 deferred=0" "$LOG" && ok \
  || bad "A: the summary line counts what happened: $(lastlog)"

# 2. the skip-set: the second tick reads no jobs and PUTs nothing
drive
[ "$(calls 'runs/900/jobs')" = 0 ] && [ "$(puts)" = 0 ] && ok \
  || bad "2: a recorded run is skipped before any read (jobs reads: $(calls 'runs/900/jobs'), PUTs: $(puts))"
head -1 "$HH/jobs-calls.txt" | grep -q "^GET /api/ci-batches?repo=example-org%2Fcromford&since=$(iso $(( 7 * 86400 )))&limit=5000$" \
  && ok || bad "2: the skip-set read asks for the window: $(head -1 "$HH/jobs-calls.txt")"
lastlog | grep -q 'already=4 recorded=0' && ok || bad "2: tick 2 counts the runs already recorded: $(lastlog)"

# ── 4. an annotations read that fails is not "no notice"
reset
run 902 mergify/merge-queue/main/x 3600
jobs 902 "$(job ubuntu-latest 10 'CI plan (what this run tests)' 5902)" "$(job monkci-ubuntu-24.04-4 60)"
drive
[ -z "$(row 902)" ] && [ "$(puts)" = 0 ] && ok || bad "4: a failed annotations read must record nothing: $(row 902)"
grep -q 'run 902.*unread\|unread.*run 902' "$LOG" && lastlog | grep -q 'unread=1' && ok \
  || bad "4: the log names the unread run: $(cat "$LOG")"
ann 5902 "[$NOTE]"
drive
[ "$(jq -r .mode <<<"$(row 902)")" = batch-selected ] && ok || bad "4: the next healthy tick records it: $(row 902)"

# ── 5. a failed PUT is logged and retried next tick
reset
run 903 mergify/merge-queue/main/y 3600
jobs 903 "$(job monkci-ubuntu-24.04-4 60)"
drive FAKE_PUT_FAIL=1
grep -q 'PUT failed run 903 (http=503)' "$LOG" && [ -z "$(row 903)" ] && [ "$RC" = 0 ] && ok \
  || bad "5: a failed PUT is a log line and no row, rc 0 (rc=$RC): $(cat "$LOG")"
lastlog | grep -q 'recorded=0 put_failed=1' && ok || bad "5: put_failed counted, not recorded: $(lastlog)"
drive
[ "$(puts)" = 1 ] && [ -n "$(row 903)" ] && ok || bad "5: the next tick PUTs 903 again and it lands"

# ── 7. the cap, the deferred count, the drain, the window
reset
run 920 mergify/merge-queue/main/a 7200
jobs 920 "$(job monkci-ubuntu-24.04-4 60)"
run 921 mergify/merge-queue/main/b 3600
jobs 921 "$(job monkci-ubuntu-24.04-4 60)"
drive CI_BATCH_LEDGER_MAX=1
[ "$(puts)" = 1 ] && [ -n "$(row 920)" ] && [ -z "$(row 921)" ] && ok || bad "7: MAX=1 records one run, the OLDEST first"
lastlog | grep -q 'deferred=1' && ok || bad "7: the summary says one run was deferred: $(lastlog)"
grep -q 'deferred 1 to next tick' "$LOG" && ok || bad "7: the deferral has its own line"
grep -q "workflows/harness-ci.yml/runs .*created=>=$(iso $(( 7 * 86400 )))" "$HH/calls.txt" \
  && grep -q 'event=pull_request' "$HH/calls.txt" && grep -q 'status=completed' "$HH/calls.txt" && ok \
  || bad "7: the runs list asks for completed pull_request runs of the last 7 days: $(head -1 "$HH/calls.txt")"
drive CI_BATCH_LEDGER_MAX=1
[ -n "$(row 921)" ] && lastlog | grep -q 'already=1 recorded=1 put_failed=0 unread=0 deferred=0' && ok \
  || bad "7: tick 2 drains the deferred run: $(lastlog)"
drive CI_BATCH_LEDGER_DAYS=2
grep -q "created=>=$(iso $(( 2 * 86400 )))" "$HH/calls.txt" && ok || bad "7: CI_BATCH_LEDGER_DAYS moves the window"

# ── 8-10. no GitHub read at all
reset
run 930 mergify/merge-queue/main/z 3600
jobs 930 "$(job monkci-ubuntu-24.04-4 60)"
drive FAKE_BUDGET_LOW=0
[ "$RC" = 0 ] && [ ! -s "$HH/calls.txt" ] && [ ! -s "$HH/jobs-calls.txt" ] && ok || bad "8: budget low -> rc 0, no reads (rc=$RC)"
grep -q 'budget is low' "$LOG" && ok || bad "8: the skip is logged: $(cat "$LOG")"
drive JOBS_URL=
[ "$RC" = 0 ] && [ ! -s "$HH/calls.txt" ] && grep -q 'not configured' "$LOG" && ok \
  || bad "9: no JOBS_URL -> rc 0, 'not configured', no GitHub read (rc=$RC): $(lastlog)"
drive HARNESS_SECRET=
[ "$RC" = 0 ] && [ ! -s "$HH/calls.txt" ] && lastlog | grep -q 'not configured' && ok \
  || bad "9: no HARNESS_SECRET -> the same"
grep -q 'dummy-secret' "$LOG" "$T/out.txt" && bad "the secret must never be logged" || ok
drive FAKE_GET_FAIL=1
[ "$RC" = 0 ] && [ ! -s "$HH/calls.txt" ] && lastlog | grep -q 'ledger unreadable (http=503)' && ok \
  || bad "10: an unreadable ledger -> zero GitHub reads, rc 0 (rc=$RC): $(lastlog)"
drive FAKE_TRUNC=true
[ "$RC" = 0 ] && [ ! -s "$HH/calls.txt" ] && lastlog | grep -q 'truncated' && ok \
  || bad "10: a truncated skip-set -> zero GitHub reads: $(lastlog)"
[ -z "$(row 930)" ] && ok || bad "8-10: none of these ticks records anything"

# ── 11. a re-run batch: attempt 1 failed and was recorded, attempt 2 passed
reset
run 950 mergify/merge-queue/main/r 3600
jq '.workflow_runs[0] += {conclusion: "failure", run_attempt: 1}' "$HH/fx/runs.1.json" > "$T/r" && mv "$T/r" "$HH/fx/runs.1.json"
jobs 950 "$(job monkci-ubuntu-24.04-4 120)"
drive
[ "$(jq -c '[.run_attempt, .conclusion, .billed_min]' <<<"$(row 950)")" = '[1,"failure",2]' ] && ok \
  || bad "11: attempt 1 is recorded as read: $(row 950)"
grep -q 'runs/950/jobs?filter=all&per_page=100' "$HH/calls.txt" && ok \
  || bad "11: the jobs read asks for every attempt (filter=all): $(grep 'runs/950/jobs' "$HH/calls.txt")"
jq '.workflow_runs[0] += {conclusion: "success", run_attempt: 2}' "$HH/fx/runs.1.json" > "$T/r" && mv "$T/r" "$HH/fx/runs.1.json"
jobs 950 "$(job monkci-ubuntu-24.04-4 120)" "$(job monkci-ubuntu-24.04-4 61)"
drive
[ "$(jq -c '[.run_attempt, .conclusion, .billed_min]' <<<"$(row 950)")" = '[2,"success",4]' ] && ok \
  || bad "11: the re-run is read again, the row is the latest attempt's and bills both attempts (2+2): $(row 950)"
lastlog | grep -q 'already=0 recorded=1' && ok || bad "11: the re-run is not counted already-recorded: $(lastlog)"
drive
[ "$(calls 'runs/950/jobs')" = 0 ] && [ "$(puts)" = 0 ] && ok \
  || bad "11: once attempt 2 is recorded the run is skipped again"
reset
run 951 mergify/merge-queue/main/s 3600
jobs 951 "$(job monkci-ubuntu-24.04-4 60)"
jq '.total_count = 150' "$HH/fx/jobs.951.json" > "$T/r" && mv "$T/r" "$HH/fx/jobs.951.json"
drive
[ -z "$(row 951)" ] && grep -q 'run 951: 1 of 150 jobs read' "$LOG" && lastlog | grep -q 'unread=1' && ok \
  || bad "11: a jobs list longer than what was read records nothing: $(cat "$LOG")"

# ── 12. the escalation reason without the tier note; annotations 100 a page
reset
run 960 mergify/merge-queue/main/t 3600
jobs 960 "$(job ubuntu-latest 10 'CI plan (what this run tests)' 5960)" "$(job monkci-ubuntu-24.04-4 30)"
ann 5960 '[{"title":"ci-plan","message":"mode=full count=900 total=900 n=8 reason=full: label full; tiers: 3 guard suites kept"}]'
drive
[ "$(jq -r .escalation <<<"$(row 960)")" = "label full" ] && ok || bad "12: the tier note is not part of the escalation reason: $(row 960)"
grep -q 'check-runs/5960/annotations?per_page=100' "$HH/calls.txt" && ok || bad "12: annotations are read 100 a page"

# --dry-run reads and prints, never PUTs
drive
reset
run 940 mergify/merge-queue/main/d 3600
jobs 940 "$(job monkci-ubuntu-24.04-4 60)"
rm -f "$HH/calls.txt" "$HH/jobs-calls.txt"
( export HARNESS="$HH" NOW PATH="$T/stub:$PATH" JOBS_URL=https://jobs.test HARNESS_SECRET=dummy-secret
  bash "$HH/bin/ci-batch-ledger.sh" --dry-run ) >"$T/out.txt" 2>&1
[ "$(puts)" = 0 ] && grep -q '"run_id":940' "$T/out.txt" && ok || bad "--dry-run prints the row and PUTs nothing: $(cat "$T/out.txt")"

echo "ci-batch-ledger: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
