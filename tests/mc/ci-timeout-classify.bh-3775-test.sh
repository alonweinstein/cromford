#!/bin/bash
# tests/mc/ci-timeout-classify.bh-3775-test.sh — A JOB KILLED AT ITS
# timeout-minutes IS NOT A FLAKE (BH-3785, AT-1 of BH-3775).
#
# bin/lib/mc-ci-timeout-scan.sh fills the contract's cit_scan hook: it reads a
# flaked run's dead jobs and the workflow YAML at the PR head, classifies each
# dead job TIMEOUT or FLAKE, and writes one ledger line per job. Pinned here:
#   C1-C5  cit_classify: the duration-vs-limit rule, the slack boundary, the
#          default limit, garbage in -> FLAKE, MC_CI_TIMEOUT=0 -> FLAKE;
#   C6     cit_job_timeout: name match, key match, job-level only (never a
#          step's), detected indent, matrix names never match (+ mawk);
#   C7     end to end through the contract's cit_assess against a fake gh:
#          one TIMEOUT ledger line, CIT_TIMEOUTS/CIT_CHECK/CIT_WF/CIT_T, and a
#          second call served from the ledger with no REST read at all;
#          C7b a null started_at and a short kill both read FLAKE;
#   C8     every read failure (runs, jobs, contents) fails open: no ledger
#          line, no CIT_TIMEOUTS, CIT_RUNS_LEFT = the input, no YAML cached.
# Every timestamp is a literal or derived from ONE clock read (NOW).
# Run from anywhere: tests/mc/ci-timeout-classify.bh-3775-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)
RS=$(date -u -d "@$((NOW - 900))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$((NOW - 900))" +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/state" "$T/fakebin"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-budget.sh" "$DIR/bin/lib/gh-pr-list.sh" \
   "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/mc-ci-timeout.sh" "$T/h/bin/lib/"
[ -r "$DIR/bin/lib/mc-ci-timeout-scan.sh" ] && cp "$DIR/bin/lib/mc-ci-timeout-scan.sh" "$T/h/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# scratch-closure-allow: BH-4080 the lane under test runs under env -i or in its own harness root, so HARNESS_DEPLOYMENT_FILE does not reach it and bin/lib/deployment.sh must sit beside its copied libs
cp "$DIR/bin/lib/deployment.sh" "$T/h/bin/lib/"  # BH-4080: mc/rebase.sh sources it
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"

# ---- the workflow, the payloads, and the fake gh that serves them -----------
# The real project-4 shape: a job-level limit of 10 and a step-level one of 3
# that must never be read as the job's.
cat > "$T/ci.yml" <<'YAML'
name: CI
on: [pull_request]
# a comment at column 0 inside the file
jobs:
  unit:
    name: "Unit tests (incl. Inner Circle parity guard)"
    runs-on: ubuntu-latest
    timeout-minutes: 10 # raised from 8
    steps:
      - name: Install
        timeout-minutes: 3
        run: npm ci
      - run: |
          echo "timeout-minutes: 99"

  lint:
    runs-on: ubuntu-latest
    timeout-minutes: '5'
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Compile
        timeout-minutes: 3
  matrix:
    name: Unit (${{ matrix.n }})
    timeout-minutes: 7
env:
  timeout-minutes: 1
YAML
# Same file, every indent doubled (job keys at 4 spaces).
awk '{ match($0, /^ */); printf "%s%s\n", sprintf("%" (2 * RLENGTH) "s", ""), substr($0, RLENGTH + 1) }' "$T/ci.yml" > "$T/ci4.yml"
jq -n --arg c "$(base64 -w0 < "$T/ci.yml" 2>/dev/null || base64 < "$T/ci.yml" | tr -d '\n')" '{name:"ci.yml", encoding:"base64", content:$c}' > "$T/contents.json"

# runs_for <sha> <id> <name> <path>: one completed/cancelled run on that head.
runs_for() {
  jq -n --arg id "$2" --arg n "$3" --arg p "$4" --arg t "$RS" \
    '{workflow_runs:[{id:($id|tonumber), name:$n, path:$p, status:"completed", conclusion:"cancelled",
       run_started_at:$t, created_at:$t, run_attempt:1}]}' > "$T/runs-$1.json"
}
runs_for h7 501 CI .github/workflows/ci.yml
runs_for h7b 502 CI .github/workflows/ci.yml
# GitHub's own job fields; completed_at carries fractional seconds on purpose.
cat > "$T/jobs-501.json" <<'JSON'
{"total_count":2,"jobs":[
 {"id":9001,"name":"Unit tests (incl. Inner Circle parity guard)","status":"completed","conclusion":"cancelled",
  "started_at":"2026-09-30T10:00:00Z","completed_at":"2026-09-30T10:10:17.000Z"},
 {"id":9002,"name":"lint","status":"completed","conclusion":"success",
  "started_at":"2026-09-30T10:00:00Z","completed_at":"2026-09-30T10:01:00Z"}]}
JSON
cat > "$T/jobs-502.json" <<'JSON'
{"total_count":2,"jobs":[
 {"id":9101,"name":"Unit tests (incl. Inner Circle parity guard)","status":"completed","conclusion":"cancelled",
  "started_at":null,"completed_at":"2026-09-30T10:00:05Z"},
 {"id":9102,"name":"lint","status":"completed","conclusion":"timed_out",
  "started_at":"2026-09-30T10:00:00Z","completed_at":"2026-09-30T10:01:35Z"}]}
JSON

{ printf '#!/bin/bash\nT=%s\n' "$T"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
[ "$1 $2 $3 $4" = "api -i -X GET" ] || { echo ""; exit 0; }
case "$5" in
  repos/*/actions/runs\?head_sha=*)
    [ -f "$T/fail-runs" ] && { printf 'HTTP/1.1 500 Server Error\r\n\r\n{"message":"boom"}'; exit 0; }
    SHA=${5##*head_sha=}; SHA=${SHA%%&*}
    F="$T/runs-$SHA.json"; [ -f "$F" ] || { printf 'HTTP/1.1 200 OK\r\n\r\n{"workflow_runs":[]}'; exit 0; }
    printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$F" ;;
  repos/*/actions/runs/*/jobs*)
    [ -f "$T/fail-jobs" ] && { printf 'HTTP/1.1 500 Server Error\r\n\r\n{"message":"boom"}'; exit 0; }
    ID=${5#*/actions/runs/}; ID=${ID%%/*}
    printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$T/jobs-$ID.json" ;;
  repos/*/contents/.github/workflows/ci.yml\?ref=*)
    [ -f "$T/fail-contents" ] && { printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}'; exit 0; }
    printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$T/contents.json" ;;
  *) printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}' ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
: > "$T/gh-calls.txt"

# run_in <state-dir> <script> [args...]: a clean shell with the conductor lib,
# a pinned mc_now and the contract (which sources the scan part file).
run_in() {
  local st="$1" sc="$2"; shift 2
  env -i PATH="$T/fakebin:$PATH" HOME="$T" HARNESS="$T/h" NOW="$NOW" ST="$st" bash -c '
    . "$HARNESS/bin/lib/merge-conductor-lib.sh" || exit 9
    mc_now() { printf %s "$NOW"; }
    MC_STATE_DIR=$ST
    . "$HARNESS/bin/lib/mc-ci-timeout.sh" || exit 9
    '"$sc" _ "$@"
}
cls() { run_in "$T/st-c" 'cit_classify "$@"' "$@"; }

# ---- C1-C5 cit_classify ------------------------------------------------------
[ "$(cls 617 10)" = TIMEOUT ] && ok || bad "C1: 617 s on a 10-minute job is TIMEOUT, got '$(cls 617 10)'"
[ "$(cls 95 10)" = FLAKE ] && ok || bad "C2: a 95 s cancel on a 10-minute job is FLAKE, got '$(cls 95 10)'"
[ "$(cls 617 "")" = FLAKE ] && ok || bad "C3: no limit means the 360-minute default, so 617 s is FLAKE, got '$(cls 617 "")'"
[ "$(cls 540 10)" = TIMEOUT ] && ok || bad "C4: 540 s is within the 60 s slack of 600, got '$(cls 540 10)'"
[ "$(cls 539 10)" = FLAKE ] && ok || bad "C4: 539 s is outside the slack, got '$(cls 539 10)'"
C4A=$(env -i PATH="$PATH" HOME="$T" MC_STATE_DIR="$T/st-c" MC_CI_TIMEOUT_SLACK_S=0 bash -c '. "$1"; cit_classify 599 10; cit_classify 600 10' _ "$T/h/bin/lib/mc-ci-timeout.sh" | tr '\n' ' ')
[ "$C4A" = "FLAKE TIMEOUT " ] && ok || bad "C4: slack 0 puts the boundary at exactly 600 s (599 FLAKE, 600 TIMEOUT), got '$C4A'"
[ "$(cls 599 10 0)" = FLAKE ] && [ "$(cls 600 10 0)" = TIMEOUT ] && ok || bad "C4: an explicit slack argument of 0 gives the same boundary"
[ "$(cls "" 10)" = FLAKE ] && ok || bad "C5: an empty duration is FLAKE"
[ "$(cls abc 10)" = FLAKE ] && ok || bad "C5: a non-numeric duration is FLAKE"
[ "$(cls - 10)" = FLAKE ] && [ "$(cls -700 10)" = FLAKE ] && ok || bad "C5: '-' and a negative duration are FLAKE"
# shellcheck disable=SC2016
[ "$(cls 617 '${{ x }}')" = FLAKE ] && ok || bad "C5: a \${{ }} limit gets the 360-minute default, so 617 s is FLAKE"
[ "$(cls 0617 010)" = TIMEOUT ] && ok || bad "C5: leading zeros are decimal, never octal (0617 vs 010)"
C5OFF=$(env -i PATH="$PATH" HOME="$T" MC_STATE_DIR="$T/st-c" MC_CI_TIMEOUT=0 bash -c '. "$1"; cit_classify 617 10' _ "$T/h/bin/lib/mc-ci-timeout.sh")
[ "$C5OFF" = FLAKE ] && ok || bad "C5: MC_CI_TIMEOUT=0 is always FLAKE, got '$C5OFF'"

# ---- C6 cit_job_timeout ------------------------------------------------------
c6() { # c6 <awk> <yaml file> <label>
  local aw="$1" y="$2" l="$3" g
  jt() { run_in "$T/st-c" 'CIT_AWK=$2 cit_job_timeout "$(cat "$1")" "$3"' "$y" "$aw" "$1"; }
  g=$(jt "Unit tests (incl. Inner Circle parity guard)")
  [ "$g" = 10 ] && ok || bad "C6[$l]: the quoted name matches and the job's own limit (not the step's 3) wins, got '$g'"
  g=$(jt lint); [ "$g" = 5 ] && ok || bad "C6[$l]: a nameless job is matched by key, quotes stripped, got '$g'"
  g=$(jt build); [ -z "$g" ] && ok || bad "C6[$l]: a job with only a step-level limit has none of its own, got '$g'"
  g=$(jt "Unit (3)"); [ -z "$g" ] && ok || bad "C6[$l]: a matrix name never equals the reported check, got '$g'"
  g=$(jt env); [ -z "$g" ] && ok || bad "C6[$l]: a top-level key after jobs: is not a job, got '$g'"
  g=$(jt unit); [ "$g" = 10 ] && ok || bad "C6[$l]: no job is NAMED 'unit', so its key matches, got '$g'"
}
c6 awk "$T/ci.yml" "awk,2"
c6 awk "$T/ci4.yml" "awk,4"
if command -v mawk >/dev/null 2>&1; then c6 mawk "$T/ci.yml" "mawk,2"; c6 mawk "$T/ci4.yml" "mawk,4"
else echo "note: mawk not installed, C6 ran under $(readlink -f "$(command -v awk)") only"; fi

# ---- C7 end to end through cit_assess ----------------------------------------
# shellcheck disable=SC2016
ASSESS='cit_assess o/demo o/demo#7 "$1" main 7 "$2"
  printf "%s\n--\n%s\n--\n%s|%s|%s\n" "$CIT_RUNS_LEFT" "$CIT_TIMEOUTS" "$CIT_CHECK" "$CIT_WF" "$CIT_T"'
JOB="Unit tests (incl. Inner Circle parity guard)"
L7="$T/st7/ci-timeout.tsv"
OUT7=$(run_in "$T/st7" "$ASSESS" h7 "501|CI")
[ -f "$L7" ] && [ "$(wc -l < "$L7")" -eq 1 ] && ok || bad "C7: exactly one ledger line, got $(wc -l < "$L7" 2>/dev/null || echo none)"
WANT7=$(printf '%s\to/demo\t%s\to/demo#7\th7\t501\t617\t10\tTIMEOUT\t.github/workflows/ci.yml\t%s' "$NOW" "$JOB" "$RS")
[ "$(head -1 "$L7" 2>/dev/null)" = "$WANT7" ] && ok || bad "C7: ledger line fields, got '$(head -1 "$L7" 2>/dev/null)'"
WOUT7=$(printf '501|CI\n--\n501\t%s\t.github/workflows/ci.yml\t10\t%s\n--\n%s|.github/workflows/ci.yml|10' "$JOB" "$RS" "$JOB")
[ "$OUT7" = "$WOUT7" ] && ok || bad "C7: CIT_RUNS_LEFT whole, one CIT_TIMEOUTS line, CIT_CHECK/WF/T set; got: $OUT7"
N7=$(wc -l < "$T/gh-calls.txt")
OUT7B=$(run_in "$T/st7" "$ASSESS" h7 "501|CI")
N7B=$(wc -l < "$T/gh-calls.txt")
[ "$N7B" -eq "$N7" ] && ok || bad "C7: a run already in the ledger costs no REST read at all, got $((N7B - N7)): $(tail -n +"$((N7 + 1))" "$T/gh-calls.txt" | tr '\n' ';')"
[ "$(wc -l < "$L7")" -eq 1 ] && ok || bad "C7: the second call writes no second ledger line"
[ "$OUT7B" = "$WOUT7" ] && ok || bad "C7: the second call serves the same answer from the ledger, got: $OUT7B"
[ -s "$T/st7/ci-timeout/yaml/o_demo-.github_workflows_ci.yml-h7" ] && ok || bad "C7: the YAML at the head sha is cached on disk"

# C7b: a cancel before start (null started_at) and a 95 s kill on a 5-minute
# job both read FLAKE, are written down, and withhold nothing.
L7B="$T/st7b/ci-timeout.tsv"
OUT7C=$(run_in "$T/st7b" "$ASSESS" h7b "502|CI")
G7B=$(cut -f3,7,8,9 "$L7B" 2>/dev/null | tr '\t\n' '|;')
[ "$G7B" = "$JOB|-|10|FLAKE;lint|95|5|FLAKE;" ] && ok || bad "C7b: null started_at -> '-'/FLAKE and a timed_out 95 s kill -> FLAKE, got '$G7B'"
[ "$OUT7C" = "$(printf '502|CI\n--\n\n--\n||')" ] && ok || bad "C7b: no TIMEOUT means CIT_TIMEOUTS empty and the list whole, got: $OUT7C"

# ---- C8 fail open --------------------------------------------------------------
c8() { # c8 <flag file> <label>
  local st="$T/st8-$2" o
  scratch_rm "$st"; touch "$T/$1"
  o=$(run_in "$st" "$ASSESS" h7 "501|CI")
  rm -f "$T/$1"
  [ ! -s "$st/ci-timeout.tsv" ] && ok || bad "C8[$2]: a failed read writes no ledger line, got '$(cat "$st/ci-timeout.tsv")'"
  [ "$o" = "$(printf '501|CI\n--\n\n--\n||')" ] && ok || bad "C8[$2]: CIT_TIMEOUTS empty and CIT_RUNS_LEFT = the input, got: $o"
  [ -z "$(ls -A "$st/ci-timeout/yaml" 2>/dev/null)" ] && ok || bad "C8[$2]: nothing is cached, got $(ls "$st/ci-timeout/yaml")"
}
c8 fail-jobs jobs
c8 fail-contents contents
c8 fail-runs runs
# And after the failure clears, the next tick classifies the run (nothing cemented).
OUT8=$(run_in "$T/st8-jobs" "$ASSESS" h7 "501|CI")
[ "$OUT8" = "$WOUT7" ] && ok || bad "C8: once the read recovers the run is classified, got: $OUT8"

echo "ci-timeout-classify.bh-3775: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
