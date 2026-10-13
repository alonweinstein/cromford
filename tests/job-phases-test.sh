#!/bin/bash
# tests/job-phases-test.sh — per-PHASE tracking (phase 5), driven for real.
#
# WHY DRIVEN AND NOT GREPPED. Phase 5 makes three claims, and all three are
# claims about CONTROL FLOW, which a grep cannot see:
#   1. a stage opens a phase row and closes it with its REAL rc and its own
#      dollars — so the ledger can say which phase died and how;
#   2. a failed stage closes its phase FAILED, with the KILL_STOP / BUDGET_STOP
#      marker, BEFORE the job is closed — the ordering is the whole point, since
#      a job closed first would leave a phase reading `running` under a corpse;
#   3. none of it can block. A phase is a CHILD of the claim, never a second
#      claim: an unreachable worker, a 500, even a 409 must leave the stage
#      running exactly as it does today.
# `grep -q job_phase_open bin/agent-call.sh` would pass on a version that hard
# -fails a build when the worker blinks, which is the failure this layer exists
# to remove, reintroduced one level down.
#
# curl is stubbed (no network in tests), so the worker's SQL is not under test
# here — worker/jobs/test/index.test.js and the deploy smoke run cover that.
# What is proven is the shell: which requests are made, in which order, with
# which rc, and what happens to the stage when none of them can be made at all.
# Run from anywhere: tests/job-phases-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/bin" "$T/fakebin" "$T/builds/b1"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Fake curl: records METHOD + URL + BODY in order, and answers the phase routes.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down)     exit 7 ;;
  err500)   printf 'boom\n500\n'; exit 0 ;;
  conflict) printf '{"error":"already in flight on another box"}\n409\n'; exit 0 ;;
esac
case "$URL" in
  */phases/close) printf '{"job_id":"j","closed":1,"phases":[{"id":42,"phase":"execute"}]}\n200\n' ;;
  */phases)       printf '{"phase":{"id":42,"job_id":"j","phase":"eval","status":"running"}}\n201\n' ;;
  */api/phases/*) printf '{"phase":{"id":42,"status":"done"}}\n200\n' ;;
  */heartbeat)    printf '{"job_id":"j"}\n200\n' ;;
  */api/catalog/*) printf '{"lane":"x","matched":null,"budget_usd":3,"source":"tier"}\n200\n' ;;
  */api/jobs/*)   printf '{"job":{"id":"j"}}\n200\n' ;;
  *)              printf '{}\n404\n' ;;
esac
EOF
# Fake claude: answers normally, or dies the way a SIGKILL dies (no output,
# rc=137, immediately) when the sentinel is present.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$ARGV_SINK"
[ -f "$KILL_SENTINEL" ] && exit 137
printf '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}\n'
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
chmod +x "$T/fakebin/"* "$T/bin/beat.sh"

run_stage() { # run_stage <extra-env...>  — one agent-call.sh stage under a claim
  rm -f "$T/req.log" "$T/argv.txt"
  ( export ARGV_SINK="$T/argv.txt" REQ_SINK="$T/req.log" KILL_SENTINEL="$T/kill" \
           PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOB_ID=build-p-T1-1
    "$@" bash "$DIR/bin/agent-call.sh" eval testproj stage-model-id 600 "$T/builds/b1/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}
req() { cat "$T/req.log" 2>/dev/null; }

# --- 1. a stage opens a phase on its claim, and closes it with rc + spend -----
rm -f "$T/kill"
RC=$(run_stage env)
[ "$RC" = 0 ] && ok || bad "a healthy stage exited $RC"
grep -q 'POST .*/api/jobs/build-p-T1-1/phases .*"phase":"eval"' "$T/req.log" \
  && ok || bad "no phase was opened on the claim: $(req | head -5)"
grep -q 'POST .*/api/jobs/build-p-T1-1/phases .*"runner":"claude"' "$T/req.log" \
  && ok || bad "the phase did not record which lane was asked to run it"
grep -q 'PATCH .*/api/phases/42 .*"status":"done"' "$T/req.log" \
  && ok || bad "the phase was never closed: $(req | grep phases)"
grep -q 'PATCH .*/api/phases/42 .*"rc":0' "$T/req.log" \
  && ok || bad "the closed phase carries no exit code"
grep -q 'PATCH .*/api/phases/42 .*"spend_usd":0.01' "$T/req.log" \
  && ok || bad "the phase did not carry this stage's own dollars: $(req | grep 'api/phases')"

# --- 2. FAILURE ATTRIBUTION: the phase fails with the real rc and the marker --
# rc=137 is the OS ending the process. The phase must say 137 and say KILL_STOP,
# because "the vendor broke" and "we were killed" are different events with
# different responses, and telling them apart used to mean reading one box's
# ALERTS tail.
touch "$T/kill"
RC=$(run_stage env)
[ "$RC" = 137 ] && ok || bad "a killed stage exited $RC, not 137"
grep -q 'PATCH .*/api/phases/42 .*"status":"failed"' "$T/req.log" \
  && ok || bad "a killed stage did not close its phase failed: $(req | grep 'api/phases')"
grep -q 'PATCH .*/api/phases/42 .*"rc":137' "$T/req.log" \
  && ok || bad "the phase laundered the exit code instead of recording 137"
grep -q 'PATCH .*/api/phases/42 .*KILL_STOP' "$T/req.log" \
  && ok || bad "the phase carries no KILL_STOP marker, so the ledger cannot tell a kill from a vendor error"
# Exactly ONE phase per stage, however many times the ladder retried inside it.
N=$(grep -c 'POST .*/api/jobs/build-p-T1-1/phases ' "$T/req.log")
[ "$N" = 1 ] && ok || bad "expected 1 phase row for one stage, got $N (a retry must not open a second)"
rm -f "$T/kill"

# --- 3. FAIL-OPEN: the ledger being unreachable changes nothing ---------------
RC=$(run_stage env CURL_MODE=down)
[ "$RC" = 0 ] && ok || bad "an unreachable coordination DB made a healthy stage exit $RC"
[ -s "$T/argv.txt" ] && ok || bad "the runner was never invoked when the ledger was down"
RC=$(run_stage env CURL_MODE=err500)
[ "$RC" = 0 ] && ok || bad "a 500 from the coordination DB made a healthy stage exit $RC"
# The outage is SAID, once, in the client's own log — a silent degrade is
# indistinguishable from a working ledger.
grep -q 'jobs-client' "$T/logs/jobs-client.log" 2>/dev/null \
  && ok || bad "an unreachable ledger left nothing in logs/jobs-client.log"

# --- 4. a phase can never become a second claim -------------------------------
# The worker does not 409 a phase, and if it ever did, the client must treat it
# as an outage and keep running. One job, one claim: a stage that has already
# been granted permission must never wait for it again.
RC=$(run_stage env CURL_MODE=conflict)
[ "$RC" = 0 ] && ok || bad "a 409 on the phase route stopped a stage that already holds the claim (rc=$RC)"

# --- 5. the client helpers, on their own --------------------------------------
client() { # client <mode> <shell-snippet>
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" REQ_SINK="$T/req.log" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid CURL_MODE="$1"
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh"; eval "$2" ) 2>/dev/null
}
rm -f "$T/req.log"
[ "$(client ok 'job_phase_open plan claude m1 "" job-1; echo "$JOB_PHASE_ID"')" = 42 ] \
  && ok || bad "job_phase_open did not set JOB_PHASE_ID"
[ -z "$(client down 'job_phase_open plan claude m1 "" job-1; echo "$JOB_PHASE_ID"')" ] \
  && ok || bad "job_phase_open invented a phase id while the worker was unreachable"
client down 'job_phase_open plan claude m1 "" job-1'; [ $? -ne 0 ] \
  && ok || bad "job_phase_open returned success against an unreachable worker"
# close-open NAMES what it closed: that is how bin/jobs-watchdog.sh pages about
# the phase a job died in without a second round trip.
[ "$(client ok 'job_phase_close_open job-1 orphaned "" note')" = execute ] \
  && ok || bad "job_phase_close_open did not name the phase it closed"
[ -z "$(client down 'job_phase_close_open job-1 orphaned "" note')" ] \
  && ok || bad "job_phase_close_open printed a phase name it never got an answer for"
# A non-integer rc is DROPPED, never coerced: an invented 0 would read as a
# clean exit the stage never had, and an invented 1 as a vendor error it never
# hit. The phase still closes — it just closes without claiming an exit code.
rm -f "$T/req.log"
client ok 'job_phase_close boom "" "rc we cannot trust" 42' >/dev/null
grep -q '"rc"' "$T/req.log" && bad "an unparseable rc was coerced into a number: $(req | tail -1)" || ok
grep -q '"status":"failed"' "$T/req.log" && ok || bad "an unparseable rc did not close the phase failed"
# The house default (no rc argument at all) is the same one job_lane_close uses:
# a caller that closes without an rc is closing a stage that finished.
rm -f "$T/req.log"
client ok 'job_phase_close "" "" "" 42' >/dev/null
grep -q '"status":"done".*"rc":0' "$T/req.log" && ok || bad "closing with no rc did not read as a clean exit: $(req | tail -1)"

# --- 6. ORDERING: run-build closes the phase BEFORE it closes the job ---------
# Driven, not read: bin/run-build.sh's EXIT hook is extracted and run against
# stubs, because "which phase died" is only answerable if the phase is judged
# while the job is still open. A job closed first leaves a phase reading
# `running` under a corpse, which is the exact silence phase 3 removed one level
# up and phase 5 removes here.
cat > "$T/finish.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
JOB_ID=job-1; JOB_BEAT=""; BUILD="$BUILD_DIR"
job_beat_stop() { :; }
job_update() { echo "job_update $*" >> "$ORDER"; }
job_event()  { echo "job_event $*"  >> "$ORDER"; }
job_phase_close_open() { echo "phase_close_open $1 $2" >> "$ORDER"; echo execute; }
EOF
sed -n '/^_job_finish() {/,/^}$/p' "$RB_ALL" >> "$T/finish.sh"
echo '_job_finish' >> "$T/finish.sh"
printf 'BUILD FAILED something broke\n' > "$T/builds/b1/RESULT"
ORDER="$T/order.txt"; rm -f "$ORDER"
( export BUILD_DIR="$T/builds/b1" ORDER="$ORDER"; bash "$T/finish.sh" ) >/dev/null 2>&1
grep -q '^phase_close_open job-1 failed' "$ORDER" \
  && ok || bad "the pipeline did not close the open phase: $(cat "$ORDER" 2>/dev/null)"
[ "$(grep -n 'phase_close_open' "$ORDER" | cut -d: -f1)" -lt "$(grep -n 'job_update' "$ORDER" | cut -d: -f1)" ] \
  && ok || bad "the job was closed BEFORE its phase — the ledger would show a running phase under a dead job"
grep -q 'job_event .*phase left open: execute' "$ORDER" \
  && ok || bad "the job's closing event does not name the phase that was still open"
# A build that ENDED WELL must not have its phase recorded as a failure.
printf 'PR_CREATED https://github.com/x/pull/1\n' > "$T/builds/b1/RESULT"
rm -f "$ORDER"
( export BUILD_DIR="$T/builds/b1" ORDER="$ORDER"; bash "$T/finish.sh" ) >/dev/null 2>&1
grep -q '^phase_close_open job-1 done' "$ORDER" \
  && ok || bad "a successful build closed its phase as failed: $(cat "$ORDER" 2>/dev/null)"

echo "job-phases: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
