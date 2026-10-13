#!/bin/bash
# tests/claim-rules-test.sh — phase 6: a claim the DB may REFUSE, and a refusal
# every caller treats as a clean skip.
#
# WHY DRIVEN AND NOT GREPPED. Phase 6's whole claim is about control flow under
# a 409: the tick logs why and exits 0, the build defers instead of racing, and
# an unreachable worker changes nothing at all. A `grep -q REFUSED bin/…` would
# pass just as happily on a version that turns a refusal into a cron failure —
# which is the shape that trains a human to ignore the channel — or on one that
# stops building when the coordination DB blinks, which is the exact failure
# this whole layer exists to remove.
#
# curl is stubbed (no network in tests), so what is proven is the SHELL side:
# the rc mapping, the reason surfacing, and what each pipeline DOES with it. The
# worker's own rule SQL is proven in worker/jobs/test/index.test.js.
# Run from anywhere: tests/claim-rules-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/bin" "$T/fakebin" "$T/builds/p-K-1"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The worker's 409 shapes, one per rule scope, plus the two that predate phase 6.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CLAIM_MODE:-ok}" in
  down) exit 7 ;;
  err500) printf 'boom\n500\n'; exit 0 ;;
  ticket)
    printf '{"error":"refused by a concurrency rule","refused":true,"scope":"ticket","running":1,"rule":{"scope":"ticket","selector":"*","kind":"*","max_concurrent":1},"reason":"ticket max 1 already running: build-project-3-TK-66-1 on box-project-3-2 (one ticket, one claim, fleet-wide)","job":{"id":"build-project-3-TK-66-1","box":"box-project-3-2"}}\n409\n' ;;
  repo)
    printf '{"error":"refused by a concurrency rule","refused":true,"scope":"repo","running":1,"rule":{"scope":"repo","selector":"*","kind":"build","max_concurrent":1},"reason":"repo max 1 already running: build-project-3-TK-70-9 on box-project-3-2","job":{"id":"build-project-3-TK-70-9","box":"box-project-3-2"}}\n409\n' ;;
  box)
    printf '{"error":"refused by a concurrency rule","refused":true,"scope":"box","running":1,"rule":{"scope":"box","selector":"*","kind":"build","max_concurrent":1},"reason":"box max 1 already running: build-project-4-C-3 on test-box","job":{"id":"build-project-4-C-3","box":"test-box"}}\n409\n' ;;
  lane)
    printf '{"error":"refused by a concurrency rule","refused":true,"scope":"lane","running":2,"rule":{"scope":"lane","selector":"execute/project-3/claude","kind":"*","max_concurrent":2},"reason":"lane max 2 already running: build-project-3-TK-1-1 on box-a","job":{"id":"build-project-3-TK-1-1","box":"box-a"}}\n409\n' ;;
  retry)
    printf '{"error":"a retry of this work is scheduled","refused":true,"scope":"retry","reason":"retry scheduled for 2026-08-29T00:05:00Z (attempt 2 of 3)","job":{"id":"build-project-3-TK-66-1","box":"box-project-3-2"}}\n409\n' ;;
  inflight)
    printf '{"error":"already in flight on another box","job":{"id":"build-p-T1-1","box":"other-box"}}\n409\n' ;;
  *)
    case "$URL" in
      */api/jobs/*/heartbeat) printf '{"job_id":"j"}\n200\n' ;;
      */api/jobs)             printf '{"job":{"id":"build-p-T1-1","budget_usd":7.77}}\n201\n' ;;
      *)                      printf '{}\n200\n' ;;
    esac ;;
esac
EOF
chmod +x "$T/fakebin/curl"

probe() { # probe <claim-mode> <shell-snippet>
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box CLAIM_MODE="$1" REQ_SINK="$T/req.txt"
    # A box mid-run can already hold a claim; the tests below must read what
    # THIS call did, never what the harness around them was already doing.
    unset JOB_ID JOB_BEAT JOB_PHASE_ID
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh"; eval "$2" )
}

# --- 1. every rule scope refuses, and the refusal NAMES the scope -------------
# A refusal a human cannot explain is a refusal they will work around, so the
# scope and the rule's own words have to survive the trip out of the worker.
for SCOPE in ticket repo box lane; do
  OUT=$(probe "$SCOPE" 'job_open project-3 TK-66 build plan build/project-3/claude; echo " rc=$?"')
  case "$OUT" in
    "REFUSED $SCOPE :: "*"rc=9") ok ;;
    *) bad "a $SCOPE-scope refusal did not surface as rc=9 with its scope: $OUT" ;;
  esac
  case "$OUT" in
    *"max"*) ok ;;
    *) bad "the $SCOPE refusal lost the rule's own reason: $OUT" ;;
  esac
done

# --- 2. a scheduled retry refuses the same way -------------------------------
# Starting fresh work while a retry of the SAME work sits behind a backoff is
# how a backoff becomes a second attempt that arrives early.
OUT=$(probe retry 'job_open project-3 TK-66 build plan build/project-3/claude; echo " rc=$?"')
case "$OUT" in
  "REFUSED retry :: retry scheduled for 2026-08-29T00:05:00Z"*"rc=9") ok ;;
  *) bad "a scheduled retry did not refuse with its due time: $OUT" ;;
esac

# --- 3. the phase-1 shape is untouched ---------------------------------------
# Every caller written against "IN_FLIGHT <box> <id>" still reads it. A 409 that
# is not a rule refusal must not change shape, or a box running an older bin/
# would log a claim id it cannot parse.
OUT=$(probe inflight 'job_open p T1 build plan; echo " rc=$?"')
[ "$OUT" = "IN_FLIGHT other-box build-p-T1-1 rc=9" ] \
  && ok || bad "the pre-phase-6 409 changed shape: $OUT"

# --- 4. job_lane_open surfaces the reason WITHOUT a command substitution ------
# It sets variables, so it can never be captured; JOB_REFUSED is how the reason
# reaches a caller that cannot read its stdout.
OUT=$(probe repo 'job_lane_open build/project-3/claude TK-66 build; RC=$?; echo "rc=$RC ref=$JOB_REFUSED"')
case "$OUT" in
  "rc=9 ref=repo: repo max 1 already running"*) ok ;;
  *) bad "job_lane_open did not put the refusal in JOB_REFUSED: $OUT" ;;
esac
# ...and it opened no beater and left no claim behind when it was refused.
OUT=$(probe repo 'job_lane_open build/project-3/claude TK-66 build; echo "id=${JOB_ID:-none} beat=${JOB_BEAT:-none}"')
case "$OUT" in
  "id=none beat=none") ok ;;
  *) bad "a refused claim still set a job id or a heartbeat loop: $OUT" ;;
esac

# --- 5. FAIL-OPEN: rules bind only when the DB can answer ---------------------
# THE PROPERTY THE WHOLE LAYER RESTS ON. An unreachable worker is not a refusal;
# it is silence, and silence must never stop work. rc 1 with nothing printed is
# what every caller already treats as "behave exactly like today".
for MODE in down err500; do
  OUT=$(probe "$MODE" 'job_open project-3 TK-66 build plan build/project-3/claude; echo "rc=$?"')
  [ "$OUT" = "rc=1" ] \
    && ok || bad "with the worker $MODE a claim must fail QUIETLY with rc=1, got: $OUT"
done
OUT=$( ( export PATH="$T/fakebin:$PATH" HARNESS="$T" JOBS_URL=https://jobs.invalid
         unset HARNESS_SECRET
         # shellcheck source=/dev/null
         . "$T/bin/jobs-client.sh"; job_open project-3 TK-66 build plan; echo "rc=$?" ) )
[ "$OUT" = "rc=1" ] && ok || bad "a box with no HARNESS_SECRET must degrade, not refuse: $OUT"

# --- 6. run-triage: a refusal is a CLEAN SKIP, exit 0 -------------------------
# The REAL block from bin/run-triage.sh, so a regression in the shipped lines
# fails here rather than in production at 3am. A refusal is a decision the
# system made on purpose; surfacing it as a cron failure puts a human in front
# of it for nothing.
awk '/^# --- Coordination DB claim/,/^fi$/' "$DIR/bin/run-triage.sh" > "$T/triage-claim.sh"
grep -q 'job_open' "$T/triage-claim.sh" \
  && ok || bad "could not extract the claim block from bin/run-triage.sh — this step would test nothing"

run_triage_claim() { # run_triage_claim <claim-mode>
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box CLAIM_MODE="$1" REQ_SINK="$T/req.txt"
    PROJECT=project-3 LOG="$T/logs/project-3.log" STAMP="2026-08-29 00:00:00Z"
    export PROJECT LOG STAMP
    # shellcheck source=/dev/null
    bash -c 'set -uo pipefail
      HARNESS="'"$T"'"; PROJECT="'"$PROJECT"'"; LOG="'"$T"'/logs/project-3.log"; STAMP="run"
      # The extraction starts BELOW bin/run-triage.sh:96, where the real
      # LANE_TICK is defined, so the snippet calls a helper this harness does
      # not have. It is a heartbeat and returns 0 in production; stubbing it
      # keeps a suite that passes from printing "command not found" at the
      # reader, which is how a real error learns to look like noise.
      LANE_TICK() { :; }
      . "'"$T"'/triage-claim.sh"
      echo "REACHED-THE-WORK" >> "'"$T"'/triage-ran.txt"' )
}

: > "$T/logs/project-3.log"; rm -f "$T/triage-ran.txt"
run_triage_claim repo; RC=$?
[ "$RC" = 0 ] && ok || bad "a refused triage tick exited $RC — a refusal is not a failure"
[ -f "$T/triage-ran.txt" ] \
  && bad "a refused triage tick ran the work anyway" || ok
grep -q 'claim refused: repo :: repo max 1 already running' "$T/logs/project-3.log" \
  && ok || bad "the refused tick did not log the reason: $(cat "$T/logs/project-3.log")"

# ...and with the worker DOWN the very same block runs the work.
: > "$T/logs/project-3.log"; rm -f "$T/triage-ran.txt"
run_triage_claim down; RC=$?
[ "$RC" = 0 ] && ok || bad "an outage made the triage claim block exit $RC"
[ -f "$T/triage-ran.txt" ] \
  && ok || bad "an unreachable worker stopped the tick — rules must bind only when the DB answers"
grep -q 'claim refused' "$T/logs/project-3.log" \
  && bad "an outage was logged as a refusal" || ok

# --- 7. run-build: a refusal DEFERS, with the rule's words in the record ------
# BUILD_DEFERRED + rc 3 is this pipeline's existing word for "not now, not a
# failure"; the queue re-offers the ticket on the next tick. What phase 6 adds
# is that the deferral names the row an operator would edit.
awk '/^if command -v job_open/,/^fi$/' "$RB_ALL" > "$T/build-claim.sh"
grep -q 'BUILD_DEFERRED' "$T/build-claim.sh" \
  && ok || bad "could not extract the claim block from bin/run-build.sh — this step would test nothing"

run_build_claim() { # run_build_claim <claim-mode>
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box CLAIM_MODE="$1" REQ_SINK="$T/req.txt"
    bash -c 'set -uo pipefail
      HARNESS="'"$T"'"; PROJECT=project-3; KEY=TK-66; TICKET=TK-66
      BUILD="'"$T"'/builds/p-K-1"; ALERTS="'"$T"'/logs/ALERTS.log"
      STAMP() { echo "run"; }
      RESULT() { echo "$*" > "$BUILD/RESULT"; }
      . "'"$T"'/bin/jobs-client.sh"
      . "'"$T"'/build-claim.sh"
      echo "REACHED-THE-BUILD" >> "'"$T"'/build-ran.txt"' )
}

: > "$T/logs/ALERTS.log"; rm -f "$T/build-ran.txt" "$T/builds/p-K-1/RESULT"
run_build_claim ticket; RC=$?
[ "$RC" = 3 ] && ok || bad "a refused build exited $RC, not the pipeline's own deferral rc 3"
[ -f "$T/build-ran.txt" ] && bad "a refused build ran anyway" || ok
grep -q '^BUILD_DEFERRED REFUSED ticket' "$T/builds/p-K-1/RESULT" 2>/dev/null \
  && ok || bad "the deferral RESULT does not carry the refusal: $(cat "$T/builds/p-K-1/RESULT" 2>/dev/null)"
grep -q 'claim refused: ticket :: ticket max 1 already running' "$T/logs/ALERTS.log" \
  && ok || bad "the alert does not quote the rule that refused: $(cat "$T/logs/ALERTS.log")"

# The pre-phase-6 double-build 409 still reads as the double-build guard, in the
# words the operator learned it by.
: > "$T/logs/ALERTS.log"; rm -f "$T/build-ran.txt"
run_build_claim inflight; RC=$?
[ "$RC" = 3 ] && ok || bad "the phase-1 double-build guard stopped deferring (rc=$RC)"
grep -q 'double-build guard: IN_FLIGHT other-box' "$T/logs/ALERTS.log" \
  && ok || bad "the double-build alert changed shape: $(cat "$T/logs/ALERTS.log")"

# ...and with the worker unreachable the build RUNS. This is the TK-109 lesson:
# a build that cannot start because a config did not land is the failure this
# layer exists to remove, and it must not come back as "the rules DB blinked".
: > "$T/logs/ALERTS.log"; rm -f "$T/build-ran.txt"
run_build_claim down; RC=$?
[ "$RC" = 0 ] && ok || bad "an outage made the build claim block exit $RC"
[ -f "$T/build-ran.txt" ] \
  && ok || bad "an unreachable worker stopped a build — availability must never gate work"

# --- 8. no secret ever reaches a log -----------------------------------------
for F in "$T/logs/ALERTS.log" "$T/logs/project-3.log" "$T/logs/jobs-client.log" "$T/req.txt"; do
  [ -f "$F" ] || continue
  grep -q 'test-secret' "$F" \
    && bad "HARNESS_SECRET reached $(basename "$F")" || ok
done

echo "claim-rules-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
