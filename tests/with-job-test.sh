#!/bin/bash
# tests/with-job-test.sh — bin/with-job.sh is a LEDGER, never a gate.
#
# WHY DRIVEN AND NOT GREPPED. The wrapper's whole value is a claim about what
# happens when things go wrong: a killed run leaves a row whose beats stopped, a
# worker outage leaves the command running exactly as it would have unwrapped,
# and neither ever changes the command's exit code. That is control flow under
# failure, and `grep -q job_lane_open bin/with-job.sh` would pass just as
# happily on a version that exits 1 when the API 500s — which is the one bug
# that could take the fleet down with a coordination database nobody needs.
#
# curl is stubbed (no network in tests), so what is proven is the SHELL side:
# the claim body, the immediate first beat, the close status matching the real
# rc, the 409 refusal, and the fail-open paths. The worker's own behaviour is
# proven by worker/jobs/test.
# Run from anywhere: tests/with-job-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/flags" "$T/state" "$T/bin" "$T/fakebin" "$T/env"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# Fake curl: records METHOD, URL and body per request, answers per CURL_MODE.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET; AUTH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary) BODY="$2"; shift 2 ;;
    -X) M="$2"; shift 2 ;;
    -H) case "$2" in authorization:*) AUTH="$2" ;; esac; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s | %s\n' "$M" "$URL" "$BODY" "$AUTH" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down)   exit 7 ;;
  err500) printf 'boom\n500\n'; exit 0 ;;
  conflict) printf '{"error":"already in flight on another box","job":{"id":"fix-p-K1-1","box":"other-box"}}\n409\n'; exit 0 ;;
  *) case "$URL" in
       */heartbeat) printf '{"ok":true}\n200\n' ;;
       */events)    printf '{"event_id":1}\n201\n' ;;
       */api/jobs/*) printf '{"job":{"id":"job-1"}}\n200\n' ;;
       */api/jobs)  printf '{"job":{"id":"job-1","budget_usd":3}}\n201\n' ;;
       *)           printf '{}\n404\n' ;;
     esac ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# The command under test: records that it ran, exits with $RC_WANT.
cat > "$T/fakebin/work.sh" <<'EOF'
#!/bin/bash
echo "ran $*" >> "$RAN_SINK"
exit "${RC_WANT:-0}"
EOF
chmod +x "$T/fakebin/work.sh"

run() { # run <curl-mode> <rc-want> <args...>  -> prints the wrapper's rc
  local mode="$1" rcw="$2"; shift 2
  : > "$T/req.txt"; : > "$T/ran.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box JOBS_BEAT_SECS=3600 \
           CURL_MODE="$mode" REQ_SINK="$T/req.txt" RAN_SINK="$T/ran.txt" RC_WANT="$rcw"
    bash "$DIR/bin/with-job.sh" "$@" >"$T/out.txt" 2>"$T/err.txt" )
  echo $?
}
ran()  { [ -s "$T/ran.txt" ]; }
body_of() { grep -m1 "^POST $2" "$T/req.txt" | sed 's/^[^|]* //;s/ |.*//'; }
claim()  { grep -m1 '^POST .*/api/jobs ' "$T/req.txt" | sed -E 's|^POST [^ ]+ ||; s| \| .*$||'; }

# --- 1. the happy path: claim, beat, run, close ------------------------------
RC=$(run ok 0 execute/project-3/claude "$T/fakebin/work.sh" alpha)
[ "$RC" = 0 ] && ok || bad "a clean run must exit 0, got $RC"
ran && ok || bad "the wrapped command never ran"
C=$(claim)
[ "$(jq -r .project <<<"$C")" = project-3 ] && ok || bad "project must come from the lane, got: $C"
[ "$(jq -r .stage   <<<"$C")" = execute ] && ok || bad "stage must come from the lane, got: $C"
[ "$(jq -r .lane    <<<"$C")" = execute/project-3/claude ] && ok || bad "the lane must go up verbatim (it is the catalog key), got: $C"
[ "$(jq -r .kind    <<<"$C")" = execute ] && ok || bad "kind defaults to the stage, got: $C"
[ "$(jq -r '.ticket_id // "-"' <<<"$C")" = "-" ] \
  && ok || bad "an unkeyed run must send NO ticket_id — a ticketless row is deliberately not guarded, got: $C"

# The first beat is immediate, not one 150s interval later. A run killed inside
# its first interval must still be a row that BEAT ONCE, because the watchdog
# refuses to judge a row that never beat at all — so a late first beat converts
# a detectable death into an unjudgeable one.
grep -q 'POST .*/api/jobs/job-1/heartbeat' "$T/req.txt" \
  && ok || bad "no heartbeat was posted at claim time — a run killed in its first interval would never have beat"

# The close carries the REAL rc, not a hopeful one.
grep -q 'PATCH .*/api/jobs/job-1 .*"status":"done"' "$T/req.txt" \
  && ok || bad "a clean run must close status=done: $(grep PATCH "$T/req.txt")"

# --- 2. the rc is the COMMAND'S rc, and it reaches the row -------------------
RC=$(run ok 17 execute/project-3/claude "$T/fakebin/work.sh")
[ "$RC" = 17 ] && ok || bad "the wrapper must return the command's own rc, got $RC"
grep -q 'PATCH .*"status":"failed"' "$T/req.txt" \
  && ok || bad "a failing command must close status=failed"
grep -q 'POST .*/api/jobs/job-1/events .*rc=17' "$T/req.txt" \
  && ok || bad "the close event must name the real rc"

# --- 3. FAIL OPEN — the whole point ------------------------------------------
# Three separate ways for the ledger to be unavailable. In every one the command
# runs and its rc survives, because a coordination database that can stop a
# build is worse than no coordination database.
for MODE in down err500; do
  RC=$(run "$MODE" 0 execute/project-3/claude "$T/fakebin/work.sh")
  [ "$RC" = 0 ] && ran && ok || bad "with the worker $MODE the command must still run and exit 0 (rc=$RC)"
done
: > "$T/ran.txt"
RC=$( ( export PATH="$T/fakebin:$PATH" HARNESS="$T" JOBS_URL=https://jobs.invalid \
               RAN_SINK="$T/ran.txt" RC_WANT=0 CURL_MODE=ok
        unset HARNESS_SECRET
        bash "$DIR/bin/with-job.sh" execute/project-3/claude "$T/fakebin/work.sh" >/dev/null 2>&1 ); echo $? )
[ "$RC" = 0 ] && ran && ok || bad "a box with no HARNESS_SECRET must still run its work (rc=$RC)"
# ...and no client at all is the same story.
: > "$T/ran.txt"
mkdir -p "$T/noclient/logs"
RC=$( ( export PATH="$T/fakebin:$PATH" HARNESS="$T/noclient" HARNESS_SECRET=s \
               RAN_SINK="$T/ran.txt" RC_WANT=0
        bash "$DIR/bin/with-job.sh" execute/project-3/claude "$T/fakebin/work.sh" >/dev/null 2>&1 ); echo $? )
[ "$RC" = 0 ] && ran && ok || bad "with bin/jobs-client.sh absent the command must still run (rc=$RC)"

# --- 4. the 409 double-build guard, and its exact scope ----------------------
# A KEYED claim honours the guard: another box already holds this work, so the
# command must NOT run. This is the one case where the wrapper refuses, and it
# refuses BEFORE spending anything.
RC=$(run conflict 0 --key TK-400 fix/project-2/claude "$T/fakebin/work.sh")
[ "$RC" = 3 ] && ok || bad "a 409 on a keyed claim must exit 3, got $RC"
ran && bad "a 409 must stop the command from running — that is the double-build it exists to prevent" || ok
grep -q IN_FLIGHT "$T/err.txt" && ok || bad "the refusal must say WHICH box holds it: $(cat "$T/err.txt")"
C=$(claim)
[ "$(jq -r .ticket_id <<<"$C")" = TK-400 ] && ok || bad "--key must travel as ticket_id, got: $C"
[ "$(jq -r .kind <<<"$C")" = fix ] && ok || bad "kind defaults to the lane's stage, got: $C"
# --kind overrides it.
RC=$(run ok 0 --kind mine --key K9 triage/rule-miner/claude "$T/fakebin/work.sh")
[ "$(jq -r .kind <<<"$(claim)")" = mine ] && ok || bad "--kind must override the stage-derived kind"

# --- 5. usage errors refuse LOUDLY, and never half-run -----------------------
# A malformed invocation is a bug in the caller, not an outage, so it is the one
# thing that is NOT fail-open: silently running the command with no lane would
# put an unattributable row-less job on the fleet forever.
: > "$T/ran.txt"
RC=$( ( export PATH="$T/fakebin:$PATH" HARNESS="$T" RAN_SINK="$T/ran.txt"
        bash "$DIR/bin/with-job.sh" notalane "$T/fakebin/work.sh" >/dev/null 2>&1 ); echo $? )
[ "$RC" = 2 ] && ok || bad "a lane with no slash must be a usage error, got $RC"
ran && bad "a usage error must not run the command" || ok
RC=$( ( export PATH="$T/fakebin:$PATH" HARNESS="$T"
        bash "$DIR/bin/with-job.sh" execute/project-3/claude >/dev/null 2>&1 ); echo $? )
[ "$RC" = 2 ] && ok || bad "no command must be a usage error, got $RC"

# --- 6. NO SECRETS IN THE LOG -----------------------------------------------
# The wrapper writes a line per run to logs/with-job.log and the bearer is in
# scope when it does. One leak here would put HARNESS_SECRET in a file that gets
# tailed, pasted and shipped around.
run ok 0 execute/project-3/claude "$T/fakebin/work.sh" >/dev/null
grep -q test-secret "$T/logs/with-job.log" 2>/dev/null \
  && bad "HARNESS_SECRET leaked into logs/with-job.log" || ok
grep -q 'with-job.*execute/project-3/claude.*rc=0' "$T/logs/with-job.log" \
  && ok || bad "the run left no log line: $(cat "$T/logs/with-job.log" 2>/dev/null)"

# --- 7. a fleet-wide lane is not a project called "*" ------------------------
# The catalog writes a runner/project-agnostic lane as <stage>/*/<runner>, but
# the console groups job rows BY PROJECT, so a literal "*" would open a project
# nobody can navigate to.
run ok 0 'merge/*/none' "$T/fakebin/work.sh" >/dev/null
[ "$(jq -r .project <<<"$(claim)")" = fleet ] \
  && ok || bad "a '*' project must become 'fleet' on the row, got: $(claim)"

echo "with-job-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
