#!/bin/bash
# tests/main-red-pr-pair-first-error.bh-5988-test.sh — the "first error" that
# bin/main-red-pr-pair.sh groups PRs on is the job's real error, never a log
# marker line.
#
#   THE INCIDENT: at 2026-10-11 01:11:01Z the lane paged "main is probably red"
#   for #5978 and #5987 with first error "##[group]Run FAIL=0". Main was green.
#   That line is the step header of the job "Syntax + shellcheck + config
#   integrity", so EVERY failure of that job read the same first error, and any
#   two failing PRs paired. #5978 failed on "rules-pack rc=0 fast-lints rc=1",
#   #5987 on "rules-pack rc=1 fast-lints rc=0".
#
# The rule under test (first_error_of_job): marker lines (##[group], ##[endgroup],
# ##[notice], ##[warning] ...) and the echoed script inside a "##[group]Run"
# block are never the first error. The LAST ##[error] wins (a continue-on-error
# step's earlier ##[error] did not fail the job); a generic "Process completed
# with exit code N." reads as the line before it in the same step. MAIN_RED_ERR_RE
# applies only to a log with no ##[error] at all. A ledger row the old parser
# wrote (column 2 starts "##[") is read again once.
#
# The two fixtures in tests/fixtures/bh-5988/ are reconstructed job logs (see
# the README there). Every case drives the real script against a fake gh, a
# scratch $HARNESS and a recording lane-alert.sh. Every timestamp is a literal.
# Run from anywhere: tests/main-red-pr-pair-first-error.bh-5988-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FX="$DIR/tests/fixtures/bh-5988"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -f "$DIR/bin/main-red-pr-pair.sh" ] || {
  echo "FAIL: bin/main-red-pr-pair.sh does not exist — there is nothing to test"
  echo "main-red-pr-pair-first-error: 0 passed, 1 failed"; exit 1; }
for f in joblog-pr5978-114352824911.txt joblog-pr5987-114355281126.txt; do
  [ -s "$FX/$f" ] || { echo "FAIL: fixture $FX/$f is missing"
    echo "main-red-pr-pair-first-error: 0 passed, 1 failed"; exit 1; }
done
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  echo "main-red-pr-pair-first-error: SKIPPED — jq/python3 is not installed"; exit 0; }

mkdir -p "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin"
scratch_install_closure bin/main-red-pr-pair.sh "$T" >/dev/null \
  || { echo "FAIL: cannot install the closure of bin/main-red-pr-pair.sh"
       echo "main-red-pr-pair-first-error: 0 passed, 1 failed"; exit 1; }
: > "$T/env/global.env"

cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"

# gh shim, the same contract as tests/main-red-pr-pair-test.sh: the open PR
# list from $T/pulls.json, the runs of one head from $T/runs-<sha>.json, the
# failing job of a run from $T/jobs-<runid>.txt, one job's log from
# $T/joblog-<jobid>.txt (absent = the read failed). Every call is recorded.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
A="$*"
printf '%s\n' "$A" >> "$GH_SINK"
case "$A" in
  "api repos/"*" -q .id")     exit 0 ;;
  *"/pulls?state=open"*)      case "$A" in *" -i "*) printf 'HTTP/2.0 200\r\n\r\n' ;; esac
                              cat "$T/pulls.json" ;;
  "pr list"*)                 echo "[]" ;;
  *"/actions/jobs/"*"/logs"*) jid=${A##*/actions/jobs/}; jid=${jid%%/logs*}
                              case "$A" in *--allow-escape-sequences*) ;; *) exit 1 ;; esac
                              [ -f "$T/joblog-$jid.txt" ] || exit 1
                              cat "$T/joblog-$jid.txt" ;;
  *"/actions/runs/"*"/jobs"*) rid=${A##*/actions/runs/}; rid=${rid%%/jobs*}
                              cat "$T/jobs-$rid.txt" 2>/dev/null || echo "" ;;
  *"actions/runs"*)           sha=${A##*head_sha=}; sha=${sha%% *}
                              [ -s "$T/runs-$sha.json" ] || exit 1
                              jq -c '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, t:.created_at, u:.html_url, id:.id}]' "$T/runs-$sha.json" ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

CI=".github/workflows/harness-ci.yml"
JOB="Syntax + shellcheck + config integrity"
MARKS="$T/state/main-red/pairs/o-r"
LEDGER="$T/state/main-red/pr-errors/o-r"
LOG="$T/logs/main-red-pr-pair.log"
OLD="##[group]Run FAIL=0"              # what the old parser wrote for both heads
E5978="rules-pack rc=0 fast-lints rc=1 budget rc=0"
E5987="rules-pack rc=1 fast-lints rc=0 budget rc=0"

pulls() { # pulls <number:head-sha:updatedAt>...
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
head_run() { # head_run <head-sha> <created_at> <run-id> — one failed Harness CI run
  jq -nc --arg p "$CI" --arg t "$2" --argjson id "$3" \
    '{workflow_runs:[{name:"Harness CI", path:$p, status:"completed", conclusion:"failure",
       created_at:$t, html_url:"https://github.com/o/r/actions/runs/1", id:$id}]}' > "$T/runs-$1.json"
}
job_of()     { printf '%s\t%s\n' "$JOB" "$2" > "$T/jobs-$1.txt"; }  # job_of <run-id> <job id>
joblog_file() { cp "$2" "$T/joblog-$1.txt"; }                       # joblog_file <job id> <file>
joblog_text() { printf '%s\n' "$2" > "$T/joblog-$1.txt"; }          # joblog_text <job id> <text>

drive() { # drive [args...] — one tick
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
           ALERT_SINK="$T/alerts.txt"; unset GH_TOKEN HARNESS_SECRET JOBS_URL
    bash "$T/bin/main-red-pr-pair.sh" "$@" >"$T/out.txt" 2>"$T/err.txt" )
}
alerts()   { grep -cv -- '--resolve' "$T/alerts.txt" 2>/dev/null; }
resolves() { grep -c -- '--resolve' "$T/alerts.txt" 2>/dev/null; }
markers()  { ls -A "$MARKS" 2>/dev/null | awk 'END{print NR+0}'; }
logreads() { grep -c '/actions/jobs/.*/logs' "$T/gh.txt" 2>/dev/null; }
col2()     { cut -f2 "$LEDGER/$1.tsv" 2>/dev/null; }
reset_case() {
  : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$LOG"
  scratch_rm "$MARKS"; scratch_rm "$LEDGER"
  rm -f "$T"/runs-*.json "$T"/jobs-*.txt "$T"/joblog-*.txt "$T/flags/main-red-o-r"
}
# one_pr <log-file> — one open PR (head aaaa111) failing $JOB with that log.
one_pr() {
  reset_case
  pulls "5978:aaaa111:2026-10-11T00:50:00Z"
  head_run aaaa111 2026-10-11T00:40:00Z 9001; job_of 9001 8001; joblog_file 8001 "$1"
  drive o/r
}
# pair <log-a> <log-b> — #5978 (aaaa111) and #5987 (bbbb222), runs 10 min apart.
pair() {
  pulls "5978:aaaa111:2026-10-11T00:50:00Z" "5987:bbbb222:2026-10-11T01:00:00Z"
  head_run aaaa111 2026-10-11T00:40:00Z 9001; job_of 9001 8001; joblog_file 8001 "$1"
  head_run bbbb222 2026-10-11T00:50:00Z 9002; job_of 9002 8002; joblog_file 8002 "$2"
}
# seed_old — the ledger rows and the open marker the old parser left behind.
seed_old() {
  local h
  mkdir -p "$LEDGER" "$MARKS"
  printf '%s\t%s\t%s\n' "$JOB" "$OLD" 2026-10-11T00:40:00Z > "$LEDGER/aaaa111.tsv"
  printf '%s\t%s\t%s\n' "$JOB" "$OLD" 2026-10-11T00:50:00Z > "$LEDGER/bbbb222.tsv"
  h=$(printf '%s|%s' "$JOB" "$OLD" | sha1sum | cut -c1-12)
  printf 'job=%s\nfirst_error=%s\nprs=#5978, #5987\ndetected=2026-10-11T01:11:01Z\n' "$JOB" "$OLD" > "$MARKS/$h"
  OLD_ID="main-red-prs:o-r:$h"
}
not_marker() { case "$1" in '##['*) return 1 ;; esac; return 0; }

A="$FX/joblog-pr5978-114352824911.txt"
B="$FX/joblog-pr5987-114355281126.txt"
W="$T/work"; mkdir -p "$W"
STAMP="2026-10-11T00:41:00.0000000Z"

# ── F: which line is the first error ───────────────────────────────────────

# F1. the #5978 log: the line before the final generic ##[error].
one_pr "$A"
[ "$(col2 aaaa111)" = "$E5978" ] && ok || bad "F1: #5978 first error: '$(col2 aaaa111)', want '$E5978'"
not_marker "$(col2 aaaa111)" && ok || bad "F1: a marker line became the first error: '$(col2 aaaa111)'"

# F2. the #5987 log: the LAST ##[error], not the continue-on-error merge-reuse step's.
one_pr "$B"
[ "$(col2 aaaa111)" = "$E5987" ] && ok || bad "F2: #5987 first error: '$(col2 aaaa111)', want '$E5987'"
not_marker "$(col2 aaaa111)" && ok || bad "F2: a marker line became the first error: '$(col2 aaaa111)'"

# F3. first vs last: #5987 cut after the merge-reuse ##[error], then a later
#     step that fails after "boom: the real failure".
awk '{ print } /##\[error\]/ { exit }' "$B" > "$W/f3.txt"
grep -q 'MR_BEFORE is empty' "$W/f3.txt" || bad "F3: the cut fixture lost the merge-reuse step"
{ echo "$STAMP ##[group]Run bin/later-step.sh"
  printf '%s \033[36;1mbin/later-step.sh\033[0m\n' "$STAMP"
  echo "$STAMP ##[endgroup]"
  echo "$STAMP boom: the real failure"
  echo "$STAMP ##[error]Process completed with exit code 1."; } >> "$W/f3.txt"
one_pr "$W/f3.txt"
[ "$(col2 aaaa111)" = "boom: the real failure" ] && ok \
  || bad "F3: the last ##[error] must win: '$(col2 aaaa111)'"

# F4. two generic errors in two steps; the second step printed nothing.
{ echo "$STAMP ##[group]Run bin/step-one.sh"
  echo "$STAMP bin/step-one.sh"
  echo "$STAMP ##[endgroup]"
  echo "$STAMP FAIL: step one output"
  echo "$STAMP ##[error]Process completed with exit code 1."
  echo "$STAMP ##[group]Run bin/step-two.sh --all"
  echo "$STAMP bin/step-two.sh --all"
  echo "$STAMP shell: /usr/bin/bash -e {0}"
  echo "$STAMP ##[endgroup]"
  echo "$STAMP ##[error]Process completed with exit code 3."; } > "$W/f4.txt"
one_pr "$W/f4.txt"
[ "$(col2 aaaa111)" = "Run bin/step-two.sh --all: Process completed with exit code 3." ] && ok \
  || bad "F4: a silent failing step reads as its header: '$(col2 aaaa111)'"
case "$(col2 aaaa111)" in *"step one"*) bad "F4: the first step's output leaked into the second step's error" ;; *) ok ;; esac

# F5. an ::error:: annotation is its own message.
{ echo "$STAMP ##[group]Run sudo apt-get update"
  echo "$STAMP sudo apt-get update"
  echo "$STAMP ##[endgroup]"
  echo "$STAMP E: Failed to fetch"
  echo "$STAMP ##[error]CI infra (apt): apt-get update failed twice (rc 100)"; } > "$W/f5.txt"
one_pr "$W/f5.txt"
[ "$(col2 aaaa111)" = "CI infra (apt): apt-get update failed twice (rc 100)" ] && ok \
  || bad "F5: an annotation must be read as written: '$(col2 aaaa111)'"

# F6. no ##[error]: MAIN_RED_ERR_RE is the fallback, and a Run block is skipped.
{ echo "$STAMP ##[group]Run echo FAIL"
  echo "$STAMP echo FAIL"
  echo "$STAMP ##[endgroup]"
  echo "$STAMP fatal: bad thing"; } > "$W/f6.txt"
one_pr "$W/f6.txt"
[ "$(col2 aaaa111)" = "fatal: bad thing" ] && ok \
  || bad "F6: the fallback must skip the echoed script: '$(col2 aaaa111)'"

# F7. markers never win: every ERR_RE match is a marker or echoed script.
{ echo "$STAMP ##[group]Run FAIL=0"
  printf '%s \033[36;1mFAIL=1\033[0m\n' "$STAMP"
  echo "$STAMP   env: FAIL=1"
  echo "$STAMP ##[endgroup]"
  echo "$STAMP ##[warning]cache entry not found"
  echo "$STAMP all suites green"; } > "$W/f7.txt"
one_pr "$W/f7.txt"
[ "$(col2 aaaa111)" = "(unavailable)" ] && ok \
  || bad "F7: a log with only marker matches must read (unavailable): '$(col2 aaaa111)'"

# ── G: grouping through a real tick ────────────────────────────────────────

# G1. the incident: #5978 and #5987 fail the same job for different reasons.
reset_case; pair "$A" "$B"; drive o/r
[ "$(alerts)" = 0 ] && ok || bad "G1: different real errors paired: $(cat "$T/alerts.txt")"
[ "$(markers)" = 0 ] && ok || bad "G1: a pair marker was written: $(ls -A "$MARKS")"
[ ! -e "$T/flags/main-red-o-r" ] && ok || bad "G1: a suspected freeze was raised"
[ -n "$(col2 aaaa111)" ] && [ "$(col2 aaaa111)" != "$(col2 bbbb222)" ] && ok \
  || bad "G1: the two first errors must differ: '$(col2 aaaa111)' vs '$(col2 bbbb222)'"

# G2. positive control: the same real error on both PRs still pairs.
reset_case; pair "$A" "$A"; drive o/r
[ "$(alerts)" = 1 ] && ok || bad "G2: a real shared error must alert once: $(cat "$T/alerts.txt")"
grep -qF "first error: \"$E5978\"" "$T/alerts.txt" && ok \
  || bad "G2: the alert must name the summary line: $(cat "$T/alerts.txt")"
[ "$(markers)" = 1 ] && ok || bad "G2: want 1 marker, got $(markers)"

# ── L: ledger rows the old parser wrote ────────────────────────────────────

# L1. a stale row is read again once; the false pair resolves.
reset_case; seed_old; pair "$A" "$B"; drive o/r
[ "$(col2 aaaa111)" = "$E5978" ] && [ "$(col2 bbbb222)" = "$E5987" ] && ok \
  || bad "L1: stale rows not refreshed: '$(col2 aaaa111)' / '$(col2 bbbb222)'"
[ "$(resolves)" = 1 ] && grep -q -- "--resolve --id $OLD_ID " "$T/alerts.txt" && ok \
  || bad "L1: want one resolve of $OLD_ID: $(cat "$T/alerts.txt")"
[ "$(markers)" = 0 ] && ok || bad "L1: the false pair marker is still open"
[ "$(alerts)" = 0 ] && ok || bad "L1: a new alert fired: $(cat "$T/alerts.txt")"
: > "$T/gh.txt"; drive o/r
[ "$(logreads)" = 0 ] && ok || bad "L1: a fresh row was read again on the next tick ($(logreads) log reads)"

# L2. --explain reads but never rewrites a stale row.
reset_case; seed_old; pair "$A" "$B"
before=$(cat "$LEDGER/aaaa111.tsv" "$LEDGER/bbbb222.tsv")
drive --explain o/r
[ "$(cat "$LEDGER/aaaa111.tsv" "$LEDGER/bbbb222.tsv")" = "$before" ] && ok \
  || bad "L2: --explain changed the ledger"
[ "$(markers)" = 1 ] && ok || bad "L2: --explain removed the marker"
grep -q 'WOULD RECORD o/r bbbb222' "$T/out.txt" && ok || bad "L2: no WOULD RECORD line: $(cat "$T/out.txt")"
[ ! -s "$T/alerts.txt" ] && ok || bad "L2: --explain sent: $(cat "$T/alerts.txt")"

# L3. round trip: rows the new parser writes are never stale.
reset_case; pair "$A" "$B"; drive o/r
rows1=$(cat "$LEDGER/aaaa111.tsv" "$LEDGER/bbbb222.tsv" 2>/dev/null)
[ "$(ls -A "$LEDGER" | awk 'END{print NR+0}')" = 2 ] && ok || bad "L3: tick 1 wrote $(ls -A "$LEDGER" | wc -l) rows"
: > "$T/gh.txt"; drive o/r
[ "$(logreads)" = 0 ] && ok || bad "L3: tick 2 read $(logreads) job logs"
[ "$(cat "$LEDGER/aaaa111.tsv" "$LEDGER/bbbb222.tsv" 2>/dev/null)" = "$rows1" ] && ok || bad "L3: tick 2 changed a row"
[ ! -s "$T/alerts.txt" ] && ok || bad "L3: the round trip alerted: $(cat "$T/alerts.txt")"

# L4. a stale re-read that fails: no row, no resolve, the marker stays.
reset_case; seed_old; pair "$A" "$B"; rm -f "$T/joblog-8002.txt"; drive o/r
[ ! -e "$LEDGER/bbbb222.tsv" ] && ok || bad "L4: a stale row survived a failed re-read: $(cat "$LEDGER/bbbb222.tsv")"
[ "$(markers)" = 1 ] && ok || bad "L4: the marker went away without a complete look"
[ "$(resolves)" = 0 ] && ok || bad "L4: a resolve was sent on a partial look: $(cat "$T/alerts.txt")"
grep -q 'have no verdict this tick' "$LOG" && ok || bad "L4: the log does not say the look was partial: $(cat "$LOG")"

# L5. "##[" later in the text is not a stale row.
reset_case; pair "$A" "$B"; mkdir -p "$LEDGER"
printf '%s\t%s\t%s\n' "$JOB" "see ##[error] above" 2026-10-11T00:40:00Z > "$LEDGER/aaaa111.tsv"
drive o/r
grep -q 'head_sha=aaaa111' "$T/gh.txt" && bad "L5: a row with ##[ mid-text was read again" || ok
[ "$(col2 aaaa111)" = "see ##[error] above" ] && ok || bad "L5: the trusted row changed: '$(col2 aaaa111)'"

echo "main-red-pr-pair-first-error: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
