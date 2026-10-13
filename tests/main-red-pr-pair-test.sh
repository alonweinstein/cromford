#!/bin/bash
# tests/main-red-pr-pair-test.sh — bin/main-red-pr-pair.sh driven for real
# against a fake gh, a scratch $HARNESS and a recording lane-alert.sh.
#
#   THE PROPERTY UNDER TEST: when two OPEN PRs fail the SAME job with the SAME
#   first error inside one window, the fleet gets exactly ONE alert naming the
#   job and that error — because on 2026-09-17 main was red for nine hours,
#   every open PR inherited it, and each lane debugged its own innocent diff.
#   One PR failing is one PR's problem. Two failing identically is the repo's.
#
# The negatives carry the weight, and they come first. Anything that can raise
# an alert can also SUPPRESS one, and a signal that pages on two unrelated
# failures is a signal people turn off: different jobs, different errors, runs
# an hour apart, a job log we could not read and a PR list that would not load
# must all stay silent — and the last of those must not RESOLVE an open alert
# either, because "we could not look" is not "it is fixed".
#
# Every timestamp here is a literal: this suite refuses to do to itself what
# bin/test-determinism-lint.sh exists to catch.
# Run from anywhere: tests/main-red-pr-pair-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# A suite whose subject is absent must fail LOUD, never skip into green.
[ -f "$DIR/bin/main-red-pr-pair.sh" ] || {
  echo "FAIL: bin/main-red-pr-pair.sh does not exist — there is nothing to test"
  echo "main-red-pr-pair: 0 passed, 1 failed"; exit 1; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  echo "main-red-pr-pair-test: SKIPPED — jq/python3 is not installed"; exit 0; }

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin"
cp "$DIR/bin/main-red-pr-pair.sh" "$T/bin/"
# TEST-CHANGE (BH-782): bin/lib/gh-pr-list.sh reads REST through the contract
# lib now; without gh-rest.sh beside it every list answers 75 "no contract lib
# on this box" and this suite would be measuring a missing file.
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/env-path.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
: > "$T/env/global.env"

# lane-alert.sh, recording: one line per send, argv verbatim.
cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"

# gh shim. Every call is recorded. The open-PR list comes from $T/pulls.json
# (or fails outright when $T/pulls-fail exists, on BOTH the REST path and the
# per-author fallback bin/lib/gh-pr-list.sh drops to); the runs for one head sha
# from $T/runs-<sha>.json, absent = the read failed; the failing job of a run
# from $T/jobs-<runid>.txt (or a hard rc 1 when $T/jobs-fail exists — GitHub 5xx
# and secondary rate limits are the point of that case); one job's log from
# $T/joblog-<jobid>.txt, absent = the read failed.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
A="$*"                    # one string: ${*##...} would strip each argv word
printf '%s\n' "$A" >> "$GH_SINK"
case "$A" in
  "api repos/"*" -q .id")     exit 0 ;;
  *"/pulls?state=open"*)      [ -f "$T/pulls-fail" ] && exit 1
                              # TEST-CHANGE (BH-782): the REST list goes through
                              # bin/lib/gh-rest.sh, which runs `gh api -i` and
                              # parses the status line. Same fixture body, with
                              # the status line the library now reads.
                              case "$A" in *" -i "*) printf 'HTTP/2.0 200\r\n\r\n' ;; esac
                              cat "$T/pulls.json" ;;
  "pr list"*)                 [ -f "$T/pulls-fail" ] && exit 1
                              echo "[]" ;;
  *"/actions/jobs/"*"/logs"*) jid=${A##*/actions/jobs/}; jid=${jid%%/logs*}
                              # real gh: "the response contains terminal escape
                              # sequences; pass --allow-escape-sequences to
                              # output it anyway" — rc 1 and an EMPTY body.
                              case "$A" in *--allow-escape-sequences*) ;; *) exit 1 ;; esac
                              [ -f "$T/joblog-$jid.txt" ] || exit 1
                              cat "$T/joblog-$jid.txt" ;;
  *"/actions/runs/"*"/jobs"*) rid=${A##*/actions/runs/}; rid=${rid%%/jobs*}
                              [ -f "$T/jobs-fail" ] && exit 1
                              cat "$T/jobs-$rid.txt" 2>/dev/null || echo "" ;;
  *"actions/runs"*)           sha=${A##*head_sha=}; sha=${sha%% *}
                              [ -s "$T/runs-$sha.json" ] || exit 1
                              jq -c '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, t:.created_at, u:.html_url, id:.id}]' "$T/runs-$sha.json" ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

CI=".github/workflows/harness-ci.yml"; E2E=".github/workflows/e2e.yml"
MARKS="$T/state/main-red/pairs/o-r"
LEDGER="$T/state/main-red/pr-errors/o-r"
LOG="$T/logs/main-red-pr-pair.log"

# pulls <number:head-sha:updatedAt>... — the open PR list, authored by one of
# HARNESS_PR_AUTHORS so bin/lib/gh-pr-list.sh's own filter keeps it.
pulls() {
  local out='[' first=1 spec num sha upd
  for spec in "$@"; do
    IFS=':' read -r num sha upd <<<"$spec"
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --argjson n "$num" --arg sha "$sha" --arg u "$upd" \
      '{number:$n, html_url:("https://github.com/o/r/pull/"+($n|tostring)),
        title:"t", body:"", head:{sha:$sha, ref:("b"+($n|tostring))},
        base:{ref:"main"}, draft:false, user:{login:"operator", type:"User"},
        created_at:$u, updated_at:$u, merged_at:null, closed_at:null,
        labels:[], state:"open"}')
  done
  printf '%s]' "$out" > "$T/pulls.json"
}

# head_runs <head-sha> <name|path|conclusion|created_at|run-id[|status]>...
head_runs() {
  local sha="$1"; shift
  local out='{"workflow_runs":[' first=1 spec n p c t id s
  for spec in "$@"; do
    IFS='|' read -r n p c t id s <<<"$spec"; s=${s:-completed}
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg n "$n" --arg p "$p" --arg s "$s" --arg t "$t" \
      --argjson id "$id" --arg c "$c" \
      '{name:$n, path:$p, status:$s,
        conclusion:(if $c=="null" then null else $c end),
        created_at:$t, html_url:("https://github.com/o/r/actions/runs/"+($id|tostring)), id:$id}')
  done
  printf '%s]}' "$out" > "$T/runs-$sha.json"
}
job_of()  { printf '%s\t%s\n' "$2" "$3" > "$T/jobs-$1.txt"; }   # job_of <run-id> <job name> <job id>
joblog()  { printf '%s\n' "$2"          > "$T/joblog-$1.txt"; } # joblog <job id> <log text>

FLAG_WRITES=""
drive() { # drive [args...] — one tick, plus the standing "wrote no flag" check
  local before after
  before=$(ls -A "$T/flags" 2>/dev/null | sort)
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
           ALERT_SINK="$T/alerts.txt"; unset GH_TOKEN
    bash "$T/bin/main-red-pr-pair.sh" "$@" >"$T/out.txt" 2>"$T/err.txt" )
  after=$(ls -A "$T/flags" 2>/dev/null | sort)
  [ "$before" = "$after" ] || FLAG_WRITES="$FLAG_WRITES [$after]"
}
alerts()  { awk 'END{print NR+0}' "$T/alerts.txt" 2>/dev/null; }
markers() { ls -A "$MARKS" 2>/dev/null | awk 'END{print NR+0}'; }
reset_case() {
  : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$LOG"
  scratch_rm "$MARKS"; scratch_rm "$LEDGER"; rm -f "$T"/runs-*.json "$T"/jobs-*.txt "$T"/joblog-*.txt \
                                   "$T/pulls-fail" "$T/jobs-fail"
}
row_of() { cat "$LEDGER/$1.tsv" 2>/dev/null; }     # the ledger verdict for one head

# ── negatives first ─────────────────────────────────────────────────────────

# 1. ONE failing PR is one PR's problem, not the repo's.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
job_of 9001 "decisions" 8001; joblog 8001 "2026-09-18T10:01:02.1234567Z FAIL: tests/lib/scratch.sh: No such file"
drive o/r
{ [ "$(alerts)" = 0 ] && [ "$(markers)" = 0 ]; } && ok \
  || bad "1: a single failing PR alerted: $(cat "$T/alerts.txt")"

# 2. two PRs, DIFFERENT jobs: two unrelated reds, no shared cause.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z" "2:bbbb222:2026-09-18T10:06:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
head_runs bbbb222 "Harness CI|$CI|failure|2026-09-18T10:10:00Z|9002"
job_of 9001 "decisions" 8001; joblog 8001 "2026-09-18T10:01:02Z FAIL: same text both sides"
job_of 9002 "lint"      8002; joblog 8002 "2026-09-18T10:11:02Z FAIL: same text both sides"
drive o/r
{ [ "$(alerts)" = 0 ] && [ "$(markers)" = 0 ]; } && ok \
  || bad "2: different jobs must not group: $(cat "$T/alerts.txt")"

# 3. same job, DIFFERENT first error.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z" "2:bbbb222:2026-09-18T10:06:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
head_runs bbbb222 "Harness CI|$CI|failure|2026-09-18T10:10:00Z|9002"
job_of 9001 "decisions" 8001; joblog 8001 "2026-09-18T10:01:02Z FAIL: the cost rollup is wrong"
job_of 9002 "decisions" 8002; joblog 8002 "2026-09-18T10:11:02Z FAIL: the ladder never recovers"
drive o/r
{ [ "$(alerts)" = 0 ] && [ "$(markers)" = 0 ]; } && ok \
  || bad "3: same job with different errors must not group: $(cat "$T/alerts.txt")"

# 4. same job AND error, but the runs are WINDOW_S+1 apart: a fixture that ages
#    badly looks exactly like this, and it is not one episode.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z" "2:bbbb222:2026-09-18T11:06:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
head_runs bbbb222 "Harness CI|$CI|failure|2026-09-18T11:00:01Z|9002"
job_of 9001 "decisions" 8001; joblog 8001 "2026-09-18T10:01:02Z FAIL: scratch.sh: No such file"
job_of 9002 "decisions" 8002; joblog 8002 "2026-09-18T11:01:02Z FAIL: scratch.sh: No such file"
drive o/r
{ [ "$(alerts)" = 0 ] && [ "$(markers)" = 0 ]; } && ok \
  || bad "4: runs 3601s apart must not be one episode: $(cat "$T/alerts.txt")"

# 5. one PR green, one red: a green head is a terminal '-' row and groups with
#    nothing.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z" "2:bbbb222:2026-09-18T10:06:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
head_runs bbbb222 "Harness CI|$CI|success|2026-09-18T10:10:00Z|9002"
job_of 9001 "decisions" 8001; joblog 8001 "2026-09-18T10:01:02Z FAIL: scratch.sh: No such file"
drive o/r
{ [ "$(alerts)" = 0 ] && [ "$(markers)" = 0 ]; } && ok \
  || bad "5: a green PR must not group with a red one: $(cat "$T/alerts.txt")"
grep -qx -- '-	-	-' "$LEDGER/bbbb222.tsv" 2>/dev/null && ok \
  || bad "5: a finished green head must be recorded as terminal: $(cat "$LEDGER/bbbb222.tsv" 2>/dev/null)"

# 6. a head whose required runs are all still in progress has NO verdict yet.
#    Recording "did not fail" here is what would blind the signal in production:
#    the head is immutable, so the row would never be revisited.
reset_case
pulls "1:cccc333:2026-09-18T10:05:00Z"
head_runs cccc333 "Harness CI|$CI|null|2026-09-18T10:00:00Z|9003|in_progress"
drive o/r
{ [ ! -f "$LEDGER/cccc333.tsv" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "6: an in-progress head was recorded as a verdict: $(cat "$LEDGER/cccc333.tsv" 2>/dev/null)"
: > "$T/gh.txt"
drive o/r
grep -q 'actions/runs' "$T/gh.txt" && ok \
  || bad "6: the next tick did not ask about the still-running head again: $(cat "$T/gh.txt")"

# 6b. the MIXED head: one required run finished green, another is still in
#     flight. "Some run finished and it was green" is not "the head is green" —
#     the one still running is exactly the one that can go red. A head sha is
#     immutable, so the ledger never asks twice: a row written here would make
#     that failure invisible for the life of the head. One required workflow is
#     today's harness repo; two is any repo somebody adds to
#     MAIN_RED_PAIR_REPOS tomorrow.
reset_case
pulls "1:dddd444:2026-09-18T10:05:00Z"
head_runs dddd444 "Lint|$CI|success|2026-09-18T10:00:00Z|9010" \
                  "Harness CI|$CI|null|2026-09-18T10:00:00Z|9011|in_progress"
drive o/r
{ [ ! -f "$LEDGER/dddd444.tsv" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "6b: a head with a required run still in flight was recorded as a verdict: $(row_of dddd444)"
# the run finishes RED. The tick after must SEE it, not read a stale green.
head_runs dddd444 "Lint|$CI|success|2026-09-18T10:00:00Z|9010" \
                  "Harness CI|$CI|failure|2026-09-18T10:20:00Z|9011"
job_of 9011 "decisions" 8011; joblog 8011 "2026-09-18T10:21:02Z FAIL: it went red after all"
drive o/r
[ "$(row_of dddd444)" = "$(printf 'decisions\tFAIL: it went red after all\t2026-09-18T10:20:00Z')" ] && ok \
  || bad "6b: the failure that landed after the first tick was never seen: $(row_of dddd444)"

# 6c. a head with NO required run at all. GitHub answers an empty runs list for
#     a PR based outside main/ticket/** (harness-ci.yml never runs on it), and
#     the same head with only a nightly on it reads the same way. That never
#     changes for the life of the PR, so "no verdict" here would be permanent:
#     one runs read per tick forever, unknown>0 on every tick, and no marker in
#     the repo could ever resolve while that PR stayed open. Quiet for less than
#     a window it is still "ask again" (the run may not be scheduled yet); quiet
#     for longer, it is a terminal '-' that groups with nothing and blocks
#     nothing. The window is passed in as ten years to make a 2026 stamp
#     "recent" without a clock in this file.
reset_case
pulls "1:eeee555:2026-09-18T10:05:00Z"
head_runs eeee555                              # {"workflow_runs":[]}
( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" ALERT_SINK="$T/alerts.txt"; unset GH_TOKEN
  MAIN_RED_PAIR_WINDOW_S=315360000 bash "$T/bin/main-red-pr-pair.sh" o/r >/dev/null 2>&1 )
[ ! -f "$LEDGER/eeee555.tsv" ] && ok \
  || bad "6c: a run-less head on a PR updated inside the window was recorded as a verdict: $(row_of eeee555)"
drive o/r
grep -qx -- '-	-	-' "$LEDGER/eeee555.tsv" 2>/dev/null && ok \
  || bad "6c: a run-less head on a PR quiet for longer than a window is terminal, not a retry: $(row_of eeee555)"
reset_case
pulls "1:ffff666:2026-09-18T10:05:00Z"
head_runs ffff666 "E2E Nightly|$E2E|failure|2026-09-18T10:00:00Z|9006"   # only a SKIP_RE workflow
drive o/r
grep -qx -- '-	-	-' "$LEDGER/ffff666.tsv" 2>/dev/null && ok \
  || bad "6c: a head whose only run is not a required check must be terminal '-': $(row_of ffff666)"
# and the reason it matters: an open pair must still be able to RESOLVE while
# such a PR sits in the list.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z" "2:bbbb222:2026-09-18T10:12:00Z" "3:eeee555:2026-09-18T10:05:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
head_runs bbbb222 "Harness CI|$CI|failure|2026-09-18T10:10:00Z|9002"
head_runs eeee555
job_of 9001 "decisions" 8001; joblog 8001 "2026-09-18T10:01:02Z FAIL: shared cause"
job_of 9002 "decisions" 8002; joblog 8002 "2026-09-18T10:11:44Z FAIL: shared cause"
drive o/r
[ "$(markers)" = 1 ] || bad "6c: setup did not open a pair: $(cat "$T/alerts.txt")"
: > "$T/alerts.txt"; : > "$LOG"
pulls "2:bbbb222:2026-09-18T10:12:00Z" "3:eeee555:2026-09-18T10:05:00Z"
drive o/r
{ [ "$(markers)" = 0 ] && [ "$(alerts)" = 1 ]; } && ok \
  || bad "6c: a run-less open PR blocked the resolve of a pair it was never part of: markers=$(markers) log=$(cat "$LOG")"

# 7. the job log is unreadable on both sides: '(unavailable)' is not an error
#    two PRs can be said to share.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z" "2:bbbb222:2026-09-18T10:06:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
head_runs bbbb222 "Harness CI|$CI|failure|2026-09-18T10:10:00Z|9002"
job_of 9001 "decisions" 8001; job_of 9002 "decisions" 8002   # no joblog files
drive o/r
{ [ "$(alerts)" = 0 ] && [ "$(markers)" = 0 ]; } && ok \
  || bad "7: two unreadable job logs were grouped: $(cat "$T/alerts.txt")"
{ [ ! -f "$LEDGER/aaaa111.tsv" ] && [ ! -f "$LEDGER/bbbb222.tsv" ]; } && ok \
  || bad "7: a log we could not read was written to the ledger as a verdict: $(row_of aaaa111)"

# 7b. one 5xx on a job log must cost ONE TICK, never the life of a head. The
#     ledger is keyed on an immutable sha and is never re-asked, so recording
#     "(unavailable)" for a read that merely failed blinds this head for
#     LEDGER_DAYS — and the token on the hub does hit GitHub's rate limit.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
job_of 9001 "decisions" 8001                 # no joblog file yet: the read fails
drive o/r
[ ! -f "$LEDGER/aaaa111.tsv" ] && ok \
  || bad "7b: an unreadable job log became a terminal row: $(row_of aaaa111)"
joblog 8001 "2026-09-18T10:01:02Z FAIL: readable on the second look"
drive o/r
[ "$(row_of aaaa111)" = "$(printf 'decisions\tFAIL: readable on the second look\t2026-09-18T10:00:00Z')" ] && ok \
  || bad "7b: the tick after a transient log failure never re-read it: $(row_of aaaa111)"

# 7c. the same rule one level up: the JOBS list read fails.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
job_of 9001 "decisions" 8001; joblog 8001 "2026-09-18T10:01:02Z FAIL: scratch.sh: No such file"
touch "$T/jobs-fail"
drive o/r
[ ! -f "$LEDGER/aaaa111.tsv" ] && ok \
  || bad "7c: an unreadable jobs list became a terminal row: $(row_of aaaa111)"
rm -f "$T/jobs-fail"
drive o/r
[ "$(row_of aaaa111)" = "$(printf 'decisions\tFAIL: scratch.sh: No such file\t2026-09-18T10:00:00Z')" ] && ok \
  || bad "7c: the tick after a transient jobs-list failure never re-read it: $(row_of aaaa111)"

# 7d. the other half of the same coin, and the reason the cost model holds: a
#     job log that READS FINE and holds no error-shaped line IS an answer. An
#     immutable log will not grow an error line later, so it is recorded once
#     (as '(unavailable)', which groups with nothing) and never paid for again.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
job_of 9001 "decisions" 8001; joblog 8001 "2026-09-18T10:01:02Z everything looked quite well actually"
drive o/r
[ "$(row_of aaaa111)" = "$(printf 'decisions\t(unavailable)\t2026-09-18T10:00:00Z')" ] && ok \
  || bad "7d: a readable log with no error line is a verdict, not a retry: $(row_of aaaa111)"
: > "$T/gh.txt"
drive o/r
[ "$(grep -c 'actions/runs' "$T/gh.txt")" = 0 ] && ok \
  || bad "7d: a terminal verdict was paid for a second time: $(cat "$T/gh.txt")"

# 9. both PRs fail only a workflow that is NOT a required check.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z" "2:bbbb222:2026-09-18T10:06:00Z"
head_runs aaaa111 "E2E Nightly|$E2E|failure|2026-09-18T10:00:00Z|9001"
head_runs bbbb222 "E2E Nightly|$E2E|failure|2026-09-18T10:10:00Z|9002"
job_of 9001 "e2e" 8001; joblog 8001 "2026-09-18T10:01:02Z FAIL: the browser never started"
job_of 9002 "e2e" 8002; joblog 8002 "2026-09-18T10:11:02Z FAIL: the browser never started"
drive o/r
{ [ "$(alerts)" = 0 ] && [ "$(markers)" = 0 ]; } && ok \
  || bad "9: a nightly/e2e red on two PRs is not a main-red signal: $(cat "$T/alerts.txt")"

# 10. the kill switch: not one gh call.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z" "2:bbbb222:2026-09-18T10:06:00Z"
touch "$T/flags/main-red-pr-pair-off"
drive o/r
{ [ ! -s "$T/gh.txt" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "10: flags/main-red-pr-pair-off did not stop the run: gh=$(cat "$T/gh.txt")"
rm -f "$T/flags/main-red-pr-pair-off"

# ── positives ───────────────────────────────────────────────────────────────

# 11. two PRs, same job, same first error, inside the window: ONE alert that
#     names both, and a marker holding the condition open.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z" "2:bbbb222:2026-09-18T10:12:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
head_runs bbbb222 "Harness CI|$CI|failure|2026-09-18T10:10:00Z|9002"
job_of 9001 "decisions" 8001; joblog 8001 "2026-09-18T10:01:02.1234567Z FAIL: tests/lib/scratch.sh: No such file or directory"
job_of 9002 "decisions" 8002; joblog 8002 "2026-09-18T10:11:44.7654321Z FAIL: tests/lib/scratch.sh: No such file or directory"
drive o/r
[ "$(alerts)" = 1 ] && ok || bad "11: expected exactly one alert: $(cat "$T/alerts.txt")"
grep -q -- '--severity critical --id main-red-prs:o-r:' "$T/alerts.txt" && ok \
  || bad "11: the alert must be critical and carry a stable id: $(cat "$T/alerts.txt")"
grep -q 'fail job "decisions"' "$T/alerts.txt" && ok \
  || bad "11: the alert must name the JOB: $(cat "$T/alerts.txt")"
grep -q 'first error: "FAIL: tests/lib/scratch.sh: No such file or directory"' "$T/alerts.txt" && ok \
  || bad "11: the alert must quote the first error, timestamp stripped: $(cat "$T/alerts.txt")"
grep -q '(#1, #2)' "$T/alerts.txt" && ok \
  || bad "11: the alert must name both PRs: $(cat "$T/alerts.txt")"
[ "$(markers)" = 1 ] && ok || bad "11: expected exactly one marker: $(ls -A "$MARKS" 2>/dev/null)"
grep -q '^job=decisions$' "$MARKS"/* 2>/dev/null && ok \
  || bad "11: the marker must record the job: $(cat "$MARKS"/* 2>/dev/null)"

# 12. the same fixtures on the next tick: no second send, one "already open"
#     log line, and NOT ONE actions/runs read — both heads were answered from
#     the ledger, because a head sha is immutable and its verdict with it.
: > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$LOG"
drive o/r
[ "$(alerts)" = 0 ] && ok || bad "12: a still-open pair sent a second alert: $(cat "$T/alerts.txt")"
grep -q 'already open' "$LOG" && ok || bad "12: the repeat tick said nothing in the log: $(cat "$LOG")"
[ "$(grep -c 'actions/runs' "$T/gh.txt")" = 0 ] && ok \
  || bad "12: the ledger did not serve the second tick — GitHub was asked again: $(cat "$T/gh.txt")"
[ "$(markers)" = 1 ] && ok || bad "12: the marker did not survive the second tick"

# 13. one of the two PRs closes: the pair is gone, so exactly one resolve and
#     the marker with it.
: > "$T/alerts.txt"; : > "$LOG"
pulls "1:aaaa111:2026-09-18T10:05:00Z"
drive o/r
[ "$(alerts)" = 1 ] && ok || bad "13: expected exactly one resolve: $(cat "$T/alerts.txt")"
grep -q -- '--resolve --id main-red-prs:o-r:' "$T/alerts.txt" && ok \
  || bad "13: the resolve must close the same id: $(cat "$T/alerts.txt")"
[ "$(markers)" = 0 ] && ok || bad "13: the marker outlived the condition: $(ls -A "$MARKS" 2>/dev/null)"

# 8. the PR list will not load while a pair is open: the marker SURVIVES and
#    nothing is resolved. This is the whole fail-open contract in one case.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z" "2:bbbb222:2026-09-18T10:12:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
head_runs bbbb222 "Harness CI|$CI|failure|2026-09-18T10:10:00Z|9002"
job_of 9001 "decisions" 8001; joblog 8001 "2026-09-18T10:01:02Z FAIL: tests/lib/scratch.sh: No such file"
job_of 9002 "decisions" 8002; joblog 8002 "2026-09-18T10:11:44Z FAIL: tests/lib/scratch.sh: No such file"
drive o/r                                   # opens the condition
[ "$(markers)" = 1 ] || bad "8: setup did not open a pair: $(cat "$T/alerts.txt")"
: > "$T/alerts.txt"; : > "$LOG"; touch "$T/pulls-fail"
drive o/r
{ [ "$(markers)" = 1 ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "8: an unreadable PR list resolved an open pair: markers=$(markers) alerts=$(cat "$T/alerts.txt")"
grep -q 'unreadable' "$LOG" && ok || bad "8: a failed PR-list read was not logged: $(cat "$LOG")"
rm -f "$T/pulls-fail"

# 8b. a PARTIAL look is not a look either. The PR list loads fine, but both PRs
#     have rebased onto new head shas whose runs come back unreadable (a 5xx, a
#     secondary rate limit, a head pushed seconds ago). Neither head reaches the
#     grouping, so the open pair would read as GONE — one resolve now, and one
#     SECOND critical page on the very same condition the moment the reads
#     recover. A marker costs nothing standing; a false all-clear costs trust.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z" "2:bbbb222:2026-09-18T10:12:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
head_runs bbbb222 "Harness CI|$CI|failure|2026-09-18T10:10:00Z|9002"
job_of 9001 "decisions" 8001; joblog 8001 "2026-09-18T10:01:02Z FAIL: shared cause"
job_of 9002 "decisions" 8002; joblog 8002 "2026-09-18T10:11:44Z FAIL: shared cause"
drive o/r
[ "$(markers)" = 1 ] || bad "8b: setup did not open a pair: $(cat "$T/alerts.txt")"
: > "$T/alerts.txt"; : > "$LOG"
pulls "1:dddd444:2026-09-18T10:30:00Z" "2:eeee555:2026-09-18T10:31:00Z"
drive o/r
{ [ "$(markers)" = 1 ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "8b: heads we could not read resolved an open pair: markers=$(markers) alerts=$(cat "$T/alerts.txt")"
grep -q 'no verdict this tick' "$LOG" && ok \
  || bad "8b: the incomplete look was not logged: $(cat "$LOG")"

# 8c. the grouping step itself falls over. Same rule, one layer down: a tick
#     that produced no verdict may not claim the pair is fixed.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z" "2:bbbb222:2026-09-18T10:12:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
head_runs bbbb222 "Harness CI|$CI|failure|2026-09-18T10:10:00Z|9002"
job_of 9001 "decisions" 8001; joblog 8001 "2026-09-18T10:01:02Z FAIL: shared cause"
job_of 9002 "decisions" 8002; joblog 8002 "2026-09-18T10:11:44Z FAIL: shared cause"
drive o/r
[ "$(markers)" = 1 ] || bad "8c: setup did not open a pair: $(cat "$T/alerts.txt")"
: > "$T/alerts.txt"; : > "$LOG"
mkdir -p "$T/failpy"; printf '#!/bin/bash\nexit 3\n' > "$T/failpy/python3"; chmod +x "$T/failpy/python3"
( export PATH="$T/failpy:$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
         ALERT_SINK="$T/alerts.txt"; unset GH_TOKEN
  bash "$T/bin/main-red-pr-pair.sh" o/r >/dev/null 2>&1 )
{ [ "$(markers)" = 1 ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "8c: a failed grouping step resolved an open pair: markers=$(markers) alerts=$(cat "$T/alerts.txt")"
grep -q 'grouping step failed' "$LOG" && ok \
  || bad "8c: the failed grouping step said nothing in the log: $(cat "$LOG")"
rm -rf "$T/failpy"

# 18. the last open PR merges, so the repo has NO open PRs at all. That is an
#     answer, not a missing one (the unreadable cases log and leave early), so
#     the open marker must be resolved — not left standing until somebody opens
#     a PR again.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z" "2:bbbb222:2026-09-18T10:12:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
head_runs bbbb222 "Harness CI|$CI|failure|2026-09-18T10:10:00Z|9002"
job_of 9001 "decisions" 8001; joblog 8001 "2026-09-18T10:01:02Z FAIL: shared cause"
job_of 9002 "decisions" 8002; joblog 8002 "2026-09-18T10:11:44Z FAIL: shared cause"
drive o/r
[ "$(markers)" = 1 ] || bad "18: setup did not open a pair: $(cat "$T/alerts.txt")"
: > "$T/alerts.txt"; printf '[]' > "$T/pulls.json"
drive o/r
{ [ "$(alerts)" = 1 ] && [ "$(markers)" = 0 ]; } && ok \
  || bad "18: an empty PR list left the marker open: markers=$(markers) alerts=$(cat "$T/alerts.txt")"
grep -q -- '--resolve --id main-red-prs:o-r:' "$T/alerts.txt" && ok \
  || bad "18: the close was not a resolve on the same id: $(cat "$T/alerts.txt")"

# 14. more open PRs than the cap: the cap BITES, and it says so. A cap nobody
#     is told about is indistinguishable from a repo with no red PRs.
reset_case
SPECS=(); for i in $(seq 1 20); do SPECS+=("$i:head$i:2026-09-18T10:0$((i%10)):00Z"); done
pulls "${SPECS[@]}"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" ALERT_SINK="$T/alerts.txt"; unset GH_TOKEN
  MAIN_RED_PAIR_MAX_PRS=15 bash "$T/bin/main-red-pr-pair.sh" o/r >/dev/null 2>&1 )
grep -q 'capped at the 15 most recently updated' "$LOG" && ok \
  || bad "14: a cap that bit was never logged: $(cat "$LOG")"

# 14b. the cap is a PARTIAL look, and a partial look may not resolve. A pair is
#      open on #1 and #2; eighteen newer-updated PRs arrive and a cap of 15
#      pushes #1 and #2 out of the window this tick. Their heads were not read,
#      so they are not in the grouping, and the sweep would call the pair gone —
#      then page a second time the moment they drift back in. While the cap
#      bites, a marker resolves only once every PR it names has left the list.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z" "2:bbbb222:2026-09-18T10:12:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
head_runs bbbb222 "Harness CI|$CI|failure|2026-09-18T10:10:00Z|9002"
job_of 9001 "decisions" 8001; joblog 8001 "2026-09-18T10:01:02Z FAIL: shared cause"
job_of 9002 "decisions" 8002; joblog 8002 "2026-09-18T10:11:44Z FAIL: shared cause"
drive o/r
[ "$(markers)" = 1 ] || bad "14b: setup did not open a pair: $(cat "$T/alerts.txt")"
: > "$T/alerts.txt"; : > "$LOG"
SPECS=("1:aaaa111:2026-09-18T10:05:00Z" "2:bbbb222:2026-09-18T10:12:00Z")
for i in $(seq 3 20); do
  SPECS+=("$i:head$i:2026-09-18T11:$(printf '%02d' "$i"):00Z")
  head_runs "head$i" "Harness CI|$CI|success|2026-09-18T11:00:00Z|90$i"
done
pulls "${SPECS[@]}"
capdrive() { ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" ALERT_SINK="$T/alerts.txt"; unset GH_TOKEN
  MAIN_RED_PAIR_MAX_PRS=15 bash "$T/bin/main-red-pr-pair.sh" o/r >/dev/null 2>&1 ); }
capdrive
{ [ "$(markers)" = 1 ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "14b: the cap's partial look resolved an open pair: markers=$(markers) alerts=$(cat "$T/alerts.txt")"
grep -q 'unread this tick' "$LOG" && ok \
  || bad "14b: a pair held open by the cap was not logged as such: $(cat "$LOG")"
# #1 and #2 merge. They are gone from the FULL list, the cap still bites, and
# now the resolve is earned.
: > "$T/alerts.txt"; SPECS=("${SPECS[@]:2}"); pulls "${SPECS[@]}"
capdrive
{ [ "$(markers)" = 0 ] && [ "$(alerts)" = 1 ]; } && ok \
  || bad "14b: a pair whose PRs both left the open list was not resolved under the cap: markers=$(markers) alerts=$(cat "$T/alerts.txt")"

# 16. a REAL Actions job log: ANSI colour on every line, and gh will not write
#     one to a pipe without --allow-escape-sequences. The first version of this
#     lane read every log with a plain `gh api`, so every read failed, every
#     first error was "(unavailable)", and "(unavailable)" groups with nothing:
#     a canary that could not fire. The escape codes must also not reach the
#     alert text.
reset_case
pulls "1:aaaa111:2026-09-18T10:05:00Z" "2:bbbb222:2026-09-18T10:12:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
head_runs bbbb222 "Harness CI|$CI|failure|2026-09-18T10:10:00Z|9002"
job_of 9001 "Pure-logic gate fixtures" 8001
job_of 9002 "Pure-logic gate fixtures" 8002
ESC=$(printf '\033')
printf '2026-09-18T14:49:52.3257699Z %s[36;1m  bash "$t" || FAIL=1%s[0m\n' "$ESC" "$ESC" > "$T/joblog-8001.txt"
printf '2026-09-18T14:51:11.9999999Z %s[36;1m  bash "$t" || FAIL=1%s[0m\n' "$ESC" "$ESC" > "$T/joblog-8002.txt"
drive o/r
[ "$(alerts)" = 1 ] && ok || bad "16: a colourised job log did not group: $(cat "$T/alerts.txt")"
grep -q 'first error: "bash "\$t" || FAIL=1"' "$T/alerts.txt" && ok \
  || bad "16: the escape codes reached the alert text: $(cat "$T/alerts.txt")"
grep -q "$ESC" "$T/alerts.txt" && bad "16: a raw escape sequence is in the alert" || ok

# 17. a third PR failing the same way TWELVE HOURS ago must not cancel the two
#     that failed eighteen seconds apart. The window picks the cluster; it does
#     not measure the whole group's spread. (Found on live data, 2026-09-18:
#     three open cromford PRs, one stale, and the lane said nothing.)
reset_case
pulls "1:aaaa111:2026-09-18T14:24:00Z" "2:bbbb222:2026-09-18T14:24:00Z" "3:cccc333:2026-09-18T02:25:00Z"
head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T14:23:16Z|9001"
head_runs bbbb222 "Harness CI|$CI|failure|2026-09-18T14:23:34Z|9002"
head_runs cccc333 "Harness CI|$CI|failure|2026-09-18T02:24:21Z|9003"
for r in 9001 9002 9003; do job_of "$r" "Pure-logic gate fixtures" "8$r"; done
for j in 89001 89002 89003; do joblog "$j" "2026-09-18T14:23:20Z FAIL: the same shared cause"; done
drive o/r
[ "$(alerts)" = 1 ] && ok || bad "17: a stale third PR silenced a live pair: $(cat "$T/alerts.txt")"
grep -q '2 open PRs (#1, #2)' "$T/alerts.txt" && ok \
  || bad "17: the alert must name the two inside the window, not the stale one: $(cat "$T/alerts.txt")"

# 17b. the window must measure UTC, because GitHub's stamps ARE UTC and the Z
#      says so. strptime alone builds a NAIVE datetime and .timestamp() then
#      reads it as LOCAL time. On a hub in a DST-observing zone that is not
#      cosmetic: these two runs are FORTY MINUTES apart in reality, but a naive
#      parse straddling the 2026-11-01 fall-back puts them a hundred minutes
#      apart — outside the window, and a real pair is thrown away once a year.
reset_case
TZDST="America/New_York"
SKEW=$(TZ="$TZDST" python3 -c "from datetime import datetime
f='%Y-%m-%dT%H:%M:%SZ'
print(int(datetime.strptime('2026-11-01T02:10:00Z',f).timestamp()
        - datetime.strptime('2026-11-01T01:30:00Z',f).timestamp()))" 2>/dev/null)
if [ "$SKEW" != 6000 ]; then
  echo "note: this box has no DST rules for $TZDST (naive skew=$SKEW, wanted 6000) —"
  echo "note: case 17b cannot tell the two parses apart here and was not counted."
else
  pulls "1:aaaa111:2026-11-01T02:20:00Z" "2:bbbb222:2026-11-01T02:20:00Z"
  head_runs aaaa111 "Harness CI|$CI|failure|2026-11-01T01:30:00Z|9001"
  head_runs bbbb222 "Harness CI|$CI|failure|2026-11-01T02:10:00Z|9002"
  job_of 9001 "decisions" 8001; joblog 8001 "2026-11-01T01:31:02Z FAIL: the same shared cause"
  job_of 9002 "decisions" 8002; joblog 8002 "2026-11-01T02:11:02Z FAIL: the same shared cause"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
           ALERT_SINK="$T/alerts.txt" TZ="$TZDST"; unset GH_TOKEN
    bash "$T/bin/main-red-pr-pair.sh" o/r >/dev/null 2>&1 )
  [ "$(alerts)" = 1 ] && ok \
    || bad "17b: a DST transition in the hub's TZ discarded a 40-minute-apart pair: $(cat "$T/alerts.txt")"
fi

# 15. the lane is WIRED. A canary nobody runs told nobody anything.
grep -q 'main-red-pr-pair.sh' "$(rendered_cron hub)" && ok \
  || bad "15: cron/hub.cron does not run bin/main-red-pr-pair.sh"

# standing check over every drive above: none of these fixtures writes into
# flags/. SPEC CHANGE (BH-1451): this lane now DOES raise one freeze — the
# suspected one, when a pair fires against a detector verdict that says
# decision=none — and tests/main-red-pair-suspected.bh-1451-test.sh is where
# that path is driven. It cannot fire here, because no fixture in this file
# writes state/main-red/<slug>.verdict and an ABSENT verdict file freezes
# nothing (fail-open). So this check still holds, and now it also pins the
# fail-open half: a tree where the detector never wrote a verdict behaves
# exactly as this lane did before BH-1451.
[ -z "$FLAG_WRITES" ] && ok || bad "the PR-pair lane wrote into flags/:$FLAG_WRITES"

echo "main-red-pr-pair: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
