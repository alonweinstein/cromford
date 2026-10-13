#!/bin/bash
# tests/jobs-watchdog-test.sh — orphan detection, driven for real.
#
# WHY DRIVEN AND NOT GREPPED. The whole claim of phase 3 is a classification:
# a row that WAS beating and stopped is a corpse (mark it, page once, attach the
# kill forensics); a row that NEVER beat is merely quiet on an older box (say so
# late, and DO NOT release its claim, because a released claim is how one ticket
# gets built twice). A grep for "orphaned" in bin/jobs-watchdog.sh would pass on
# a version that marks everything it sees.
#
# curl is stubbed — no network in tests — so the worker's own SQL is not what is
# proven here. What is proven is the shell: which rows are marked, how many
# ALERTS lines are written, that a second run is silent, and that an unreachable
# worker changes nothing at all.
# Run from anywhere: tests/jobs-watchdog-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait_holder, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/locks" "$T/state" "$T/flags" "$T/bin" "$T/env" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/jobs-watchdog.sh" "$T/bin/jobs-watchdog.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The worker's answer to GET /api/jobs?stale_min=..., plus a sink so the test can
# read back exactly which PATCH/POST calls the watchdog made.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down) exit 7 ;;
esac
case "$URL" in
  */api/jobs\?status=running*) cat "$STALE_JSON"; printf '\n200\n' ;;
  */retry)                     cat "${RETRY_JSON:-/dev/null}"; printf '\n%s\n' "${RETRY_CODE:-200}" ;;
  */phases/close)              printf '{"closed":1,"phases":[{"id":9,"phase":"execute"}]}\n200\n' ;;
  */heartbeat)                 printf '{"job_id":"x"}\n200\n' ;;
  */events)                    printf '{"event_id":1}\n201\n' ;;
  */api/jobs/*)                printf '{"job":{"id":"x","status":"orphaned"}}\n200\n' ;;
  # The build_queue routes. `claimed` is what the stale-claim sweep asks for and
  # `done`/`failed` what the deferral sweep asks for; both default to an empty
  # queue, so every test above this line sees exactly the behaviour it always
  # did. A POST is the re-enqueue.
  */api/queue\?status=claimed*) printf '{"queue":[]}\n200\n' ;;
  */api/queue\?status=done*)    cat "${QUEUE_DONE_JSON:-/dev/null}"; printf '\n200\n' ;;
  */api/queue\?status=failed*)  cat "${QUEUE_FAILED_JSON:-/dev/null}"; printf '\n200\n' ;;
  */api/queue)                 printf '{"queued":{"status":"queued"}}\n201\n' ;;
  *)                           printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
# The reaper's ONE summary page per run, recorded so the test can count it.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$T/bin/lane-alert.sh"
chmod +x "$T/bin/lane-alert.sh"

# Any script that would RUN work, stubbed to leave a trace. Nothing in the
# watchdog should ever reach one of these.
for W in run-build.sh run-triage.sh with-job.sh orc-job.sh; do
  printf '#!/bin/bash\ntouch "%s/was-run"\nexit 0\n' "$T" > "$T/fakebin/$W"
  chmod +x "$T/fakebin/$W"
done

# Three rows the worker would return at stale_min=10, one of each shape:
#   dead   — beat, then stopped 35 minutes ago      -> orphan + alert
#   quiet  — never beat, inactive 40 minutes        -> below the 90m threshold, nothing
#   silent — never beat, inactive 200 minutes       -> alert only, status untouched
cat > "$T/stale.json" <<'EOF'
{"jobs":[
 {"id":"build-project-3-TK-109-1","project":"project-3","kind":"build","stage":"execute",
  "box":"box-project-3-2","ticket_id":"TK-109","activity_age_s":2100,
  "budget_usd":150,"spent_usd":4.12,"last_beat_at":"2026-08-27T17:48:00Z"},
 {"id":"triage-project-4-2","project":"project-4","kind":"triage","stage":"triage",
  "box":"box-project-4-1","ticket_id":null,"activity_age_s":2400,
  "budget_usd":25,"spent_usd":0.4,"last_beat_at":null},
 {"id":"build-project-2-TK-400-3","project":"project-2","kind":"fix","stage":"execute",
  "box":"box-project-2-1","ticket_id":"TK-400","activity_age_s":12000,
  "budget_usd":150,"spent_usd":9.5,"last_beat_at":null}
]}
EOF

# The worker's answer to POST /api/jobs/<id>/retry — phase 6's ONE call. The
# default is the no-policy verdict, which is exactly the behaviour these boxes
# had before phase 6: mark it orphaned, retry nothing.
cat > "$T/retry-nopolicy.json" <<'EOF'
{"decision":"orphaned","attempts":1,"max_attempts":null,"next_attempt_at":null,
 "reason":"no retry policy for lane build/project-3/execute — detection only, as before phase 6"}
EOF
cat > "$T/retry-queued.json" <<'EOF'
{"decision":"queued_for_retry","attempts":1,"max_attempts":3,
 "next_attempt_at":"2026-08-29T00:05:00Z",
 "reason":"attempt 1 of 3 ended (no heartbeat for 35m); queued for the lane's next tick"}
EOF
cat > "$T/retry-parked.json" <<'EOF'
{"decision":"parked","attempts":3,"max_attempts":3,"next_attempt_at":null,
 "reason":"retries exhausted (3 of 3) after no heartbeat for 35m — parked for a human"}
EOF

# The forensics the alert must carry: agent-call.sh's own kills.log row shape.
cat > "$T/logs/kills.log" <<'EOF'
2026-08-27 17:20:11Z project-4 triage grok rc=137 killed after 90s of 3600s; mem_avail=812000kB load=6.10 5.90 5.40
2026-08-27 17:48:31Z project-3 execute claude rc=137 killed after 812s of 10800s; mem_avail=190112kB load=9.31 8.02 7.44
EOF

run_watchdog() { # run_watchdog [env...]
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid STALE_JSON="$T/stale.json" REQ_SINK="$T/req.log" \
           RETRY_JSON="$T/retry-nopolicy.json"
    "$@" bash "$T/bin/jobs-watchdog.sh" >/dev/null 2>&1 )
}

alerts() { cat "$T/logs/ALERTS.log" 2>/dev/null; }

# --- 1. a row that stopped beating is marked orphaned -------------------------
rm -f "$T/req.log" "$T/logs/ALERTS.log" "$T/state/jobs-watchdog-alerted.txt"
run_watchdog env
# Phase 6: the watchdog does not decide the corpse's fate any more, it ASKS.
# One POST to the judge endpoint, and the status it writes is the DB's answer.
grep -q 'POST .*/api/jobs/build-project-3-TK-109-1/retry' "$T/req.log" \
  && ok || bad "the dead row was never judged (req.log: $(head -3 "$T/req.log" 2>/dev/null))"
# ...and with no policy for the lane, that answer is the phase-5 verdict, so a
# fleet with an empty retry_policies table behaves exactly as it does today.
grep -q 'ORPHANED job' "$T/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "a no-policy lane did not land on ORPHANED: $(cat "$T/logs/ALERTS.log" 2>/dev/null | head -2)"

# --- 2. exactly ONE alert line, naming project / lane / key / elapsed ---------
N=$(alerts | grep -c 'ORPHANED job')
[ "$N" = 1 ] && ok || bad "expected 1 ORPHANED alert, got $N"
L=$(alerts | grep 'ORPHANED job' | head -1)
case "$L" in
  *project-3*build/project-3/execute*key=TK-109*35m*) ok ;;
  *) bad "the alert does not name project/lane/key/elapsed: $L" ;;
esac

# --- 3. the kill forensics from THIS box's kills.log ride along ---------------
case "$L" in
  *"rc=137 killed after 812s"*) ok ;;
  *) bad "no kills.log forensics in the alert: $L" ;;
esac
# ...and it is the row for THIS lane, not merely the newest kill on the box.
case "$L" in
  *"project-4 triage grok"*) bad "the alert quoted another lane's kill row" ;;
  *) ok ;;
esac

# --- 3b. the job's open PHASE dies with it, and the page NAMES it (phase 5) ---
# A phase left reading `running` under an orphaned job is a lie the next reader
# has to unpick, and "which stage was it in" is the first question recovery asks.
grep -q 'POST .*/api/jobs/build-project-3-TK-109-1/phases/close .*"status":"orphaned"' "$T/req.log" \
  && ok || bad "the orphaned job's open phase was left running: $(grep phases "$T/req.log" | head -2)"
case "$L" in
  *"died in phase: execute"*) ok ;;
  *) bad "the alert does not name the phase the job died in: $L" ;;
esac

# --- 4. THE WATCHDOG NEVER EXECS WORK ----------------------------------------
# Phase 6 gave it hands, and this is the boundary of them: it may ask the DB for
# a verdict and write what comes back. It may not START anything. Two ways that
# is checked, because the old bare grep for "retry" now matches the judge call
# itself and would have quietly stopped testing anything.
#   a) no work script on PATH is ever invoked
if [ -f "$T/was-run" ]; then
  bad "the watchdog invoked a build/pipeline script — it must never exec work"
else ok; fi
#   b) no CLAIM is ever opened: a POST to /api/jobs (no id) is how work starts,
#      and a queued row is picked up by the LANE'S OWN tick, never from here.
if grep -qE 'POST [^ ]*/api/jobs( |$)' "$T/req.log" 2>/dev/null; then
  bad "the watchdog opened a claim — starting work is the lane's job, not the watchdog's"
else ok; fi

# --- 5. a row that NEVER beat keeps its claim --------------------------------
# 40 minutes of quiet on a box whose bin/ predates heartbeats is not proof of
# death, and marking it would release the ticket for a second builder.
grep -q 'triage-project-4-2' "$T/req.log" \
  && bad "a never-beating row was touched at 40m — that releases a claim that may still be working" || ok
grep -q 'triage-project-4-2' "$T/logs/ALERTS.log" 2>/dev/null \
  && bad "a 40m quiet row paged; the silent threshold is 90m" || ok

# --- 6. ...but it is REPORTED once it is properly old, still without marking --
S=$(alerts | grep -c 'SILENT job')
[ "$S" = 1 ] && ok || bad "expected 1 SILENT alert for the 200m never-beating row, got $S"
grep -q 'PATCH .*/api/jobs/build-project-2-TK-400-3' "$T/req.log" \
  && bad "the silent row's status was changed — its age is a lower bound, not proof" || ok

# --- 7. one alert per job, ever ----------------------------------------------
BEFORE=$(alerts | wc -l)
run_watchdog env
AFTER=$(alerts | wc -l)
[ "$BEFORE" = "$AFTER" ] && ok || bad "a second run re-paged the same jobs ($BEFORE -> $AFTER lines)"

# --- 8. worker unreachable: no marking, no page, no crash --------------------
rm -f "$T/req.log" "$T/logs/ALERTS.log" "$T/state/jobs-watchdog-alerted.txt"
run_watchdog env CURL_MODE=down; RC=$?
[ "$RC" = 0 ] && ok || bad "the watchdog exited $RC when the worker was down; cron must not see failures for an outage"
# jobs-client's own once-a-day "coordination is degraded" line is expected here
# and is a different event: the watchdog cannot see, which is not a job dying.
J=$(alerts | grep -cE 'ORPHANED job|SILENT job')
[ "$J" = 0 ] && ok || bad "an unreachable worker produced job alerts: $(alerts | grep -E 'ORPHANED|SILENT' | head -2)"

# --- 9. the threshold is configurable and it is the thing that decides --------
# At a 60-minute orphan threshold the 35m corpse is not yet called dead.
rm -f "$T/req.log" "$T/logs/ALERTS.log" "$T/state/jobs-watchdog-alerted.txt"
run_watchdog env JOBS_ORPHAN_MIN=60
grep -q 'ORPHANED job' "$T/logs/ALERTS.log" 2>/dev/null \
  && bad "a 35m-stale row was orphaned under a 60m threshold" || ok

# --- 10. phase 6: a QUEUED verdict is written, and nothing is launched -------
# The watchdog's whole new power is writing back what the DB decided. The row
# it queues is picked up by the lane's own cron tick through the normal claim
# path — so the page must SAY that, and this box must still start nothing.
rm -f "$T/req.log" "$T/logs/ALERTS.log" "$T/state/jobs-watchdog-alerted.txt" "$T/was-run"
run_watchdog env RETRY_JSON="$T/retry-queued.json"
L=$(alerts | grep 'QUEUED_FOR_RETRY job' | head -1)
[ -n "$L" ] && ok || bad "a queued verdict did not page as QUEUED_FOR_RETRY: $(alerts | head -2)"
case "$L" in
  *"attempt 1 of 3"*) ok ;;
  *) bad "the queued alert does not carry the attempt count: $L" ;;
esac
case "$L" in
  *"2026-08-29T00:05:00Z"*) ok ;;
  *) bad "the queued alert does not say when the next attempt becomes due: $L" ;;
esac
case "$L" in
  *"watchdog launched nothing"*) ok ;;
  *) bad "the queued alert must say the watchdog launched nothing: $L" ;;
esac
[ -f "$T/was-run" ] && bad "a queued verdict made the watchdog exec work" || ok
grep -qE 'POST [^ ]*/api/jobs( |$)' "$T/req.log" \
  && bad "a queued verdict made the watchdog open a claim" || ok
# The status the watchdog writes is the DB's, and it writes it through the judge
# call alone — no second PATCH inventing a status of its own.
grep -q 'PATCH .*/api/jobs/build-project-3-TK-109-1 ' "$T/req.log" \
  && bad "the watchdog PATCHed a status of its own on top of the verdict" || ok

# --- 11. phase 6: an EXHAUSTED policy parks the row, and says so -------------
rm -f "$T/req.log" "$T/logs/ALERTS.log" "$T/state/jobs-watchdog-alerted.txt"
run_watchdog env RETRY_JSON="$T/retry-parked.json"
L=$(alerts | grep 'PARKED job' | head -1)
[ -n "$L" ] && ok || bad "an exhausted policy did not page as PARKED: $(alerts | head -2)"
case "$L" in
  *"retries exhausted (3 of 3)"*needs*human*|*"retries exhausted (3 of 3)"*) ok ;;
  *) bad "the parked alert does not carry the count that made it a human's problem: $L" ;;
esac

# --- 12. a judge the worker cannot answer falls back to today's behavior -----
# FAIL-OPEN, applied to the verdict itself: an unreadable answer must not stop
# the row being marked at all, and must not print a "?" verdict into an alert.
rm -f "$T/req.log" "$T/logs/ALERTS.log" "$T/state/jobs-watchdog-alerted.txt"
printf '{"job":{"id":"x","status":"orphaned"}}' > "$T/retry-garbage.json"
run_watchdog env RETRY_JSON="$T/retry-garbage.json"
grep -q 'PATCH .*/api/jobs/build-project-3-TK-109-1 .*"status":"orphaned"' "$T/req.log" \
  && ok || bad "with no usable verdict the watchdog did not fall back to marking orphaned: $(cat "$T/req.log")"
N=$(alerts | grep -c 'ORPHANED job')
[ "$N" = 1 ] && ok || bad "the fallback path did not page exactly once (got $N)"
grep -q '? job:' <<<"$(alerts)" \
  && bad "an unparseable verdict was printed into the alert as a verdict" || ok

# --- 13. one alert per ATTEMPT, not per job ----------------------------------
# Through phase 5 a job could only die once, so keying the alert memory on the
# id was right. A retried row dies again under the SAME id, and suppressing that
# page would hide the death that actually exhausted the policy.
rm -f "$T/req.log" "$T/logs/ALERTS.log" "$T/state/jobs-watchdog-alerted.txt"
run_watchdog env RETRY_JSON="$T/retry-queued.json"
BEFORE=$(alerts | wc -l)
run_watchdog env RETRY_JSON="$T/retry-queued.json"
[ "$(alerts | wc -l)" = "$BEFORE" ] && ok || bad "the same attempt paged twice"
# Same row, now on its SECOND attempt (the worker reports attempts on the row).
sed 's/"budget_usd":150,"spent_usd":4.12/"attempts":2,"budget_usd":150,"spent_usd":4.12/' \
  "$T/stale.json" > "$T/stale-attempt2.json"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
         JOBS_URL=https://jobs.invalid STALE_JSON="$T/stale-attempt2.json" REQ_SINK="$T/req.log" \
         RETRY_JSON="$T/retry-parked.json"
  bash "$T/bin/jobs-watchdog.sh" >/dev/null 2>&1 )
[ "$(alerts | wc -l)" -gt "$BEFORE" ] \
  && ok || bad "the second attempt's death was suppressed by the first attempt's alert record"

# --- 14. a DEFERRAL filed as a finished build is re-queued, exactly once -----
# The pool-cap refusal class (2026-09-11): bin/fly-pool.sh closed the row `done`
# for a build that never ran, so the ticket was never offered again. Nothing
# above could see it — the claim was REFUSED before a job row existed, so no row
# ages and no claim goes stale. These rows are the shape the fleet is carrying
# right now, reason text included.
cat > "$T/queue-done.json" <<'EOF'
{"queue":[
 {"project":"project-5","ticket_key":"TK-268","ticket_id":"268","status":"done",
  "target":"fly","attempt":1,"claimed_by":"pool-project-5","enqueued_at":"2026-09-11T09:00:00Z",
  "reason":"BUILD_DEFERRED REFUSED box :: box max 1 already running",
  "meta":"{\"deferrals\":1}"},
 {"project":"project-4","ticket_key":"TK-1600","ticket_id":"1600","status":"done",
  "target":"fly","attempt":0,"claimed_by":"pool-project-4","enqueued_at":"2026-09-11T09:10:00Z",
  "reason":"PR_CREATED https://github.com/example-org/project-4/pull/77"}
]}
EOF
rm -f "$T/req.log" "$T/logs/ALERTS.log" "$T/state/jobs-watchdog-alerted.txt" \
      "$T/state/jobs-watchdog-deferred.txt"
run_watchdog env QUEUE_DONE_JSON="$T/queue-done.json"
QB=$(grep 'POST .*/api/queue ' "$T/req.log" | head -1 | cut -d' ' -f3-)
[ "$(jq -r '.key' <<<"$QB" 2>/dev/null)" = TK-268 ] \
  && ok || bad "the deferred row was not re-queued: $(grep queue "$T/req.log")"
# ATTEMPT IS DEATHS and must not move — bin/fly-pool.sh parks a machine that
# died twice on it, so spending it on stand-downs parks a ticket that never
# actually failed. The stand-down count is its own field, in the row's meta.
[ "$(jq -r '.attempt' <<<"$QB" 2>/dev/null)" = 1 ] \
  && ok || bad "the sweep moved the DEATH counter for a stand-down: $QB"
[ "$(jq -r '.meta' <<<"$QB" 2>/dev/null | jq -r '.deferrals')" = 2 ] \
  && ok || bad "the re-queue does not carry deferrals=2: $QB"
grep -q '"target":"fly"' "$T/req.log" \
  && ok || bad "the re-queue dropped the fly lane, so the pool would never see it"
# THE OTHER HALF, and the expensive one to get wrong: a row that really did
# finish must never be re-queued. That is a second build of merged work.
grep -q 'TK-1600' "$T/req.log" \
  && bad "a genuinely finished build was re-queued: $(grep TK-1600 "$T/req.log")" || ok
N=$(alerts | grep -c 'QUEUE DEFERRAL REQUEUED')
[ "$N" = 1 ] && ok || bad "expected 1 requeue alert, got $N"
alerts | grep -q 'TK-268' && ok || bad "the alert does not name the ticket"

# EXACTLY ONCE. The sweep runs every five minutes; a row it has already handled
# must not page again, and the latch is keyed on the ATTEMPT so a row that
# defers AGAIN is still reported.
run_watchdog env QUEUE_DONE_JSON="$T/queue-done.json"
[ "$(alerts | grep -c 'QUEUE DEFERRAL REQUEUED')" = 1 ] \
  && ok || bad "the same deferral paged twice"
# Counted on the ENQUEUE, not on total requests: the sweep re-reads the queue
# every tick by design, and a test that counted reads would fail on the reads.
[ "$(grep -c 'POST .*/api/queue' "$T/req.log")" = 1 ] \
  && ok || bad "the same deferral was re-queued twice: $(grep 'POST .*/api/queue' "$T/req.log")"

# --- 15. six stand-downs is a human's problem, not a loop --------------------
sed 's/deferrals\\":1/deferrals\\":6/' "$T/queue-done.json" > "$T/queue-done-capped.json"
rm -f "$T/req.log" "$T/logs/ALERTS.log" "$T/state/jobs-watchdog-deferred.txt"
run_watchdog env QUEUE_DONE_JSON="$T/queue-done-capped.json"
grep -q 'POST .*/api/queue' "$T/req.log" \
  && bad "a row past the cap was re-queued anyway: $(grep POST "$T/req.log")" || ok
alerts | grep -q 'QUEUE DEFERRAL PARKED' \
  && ok || bad "the cap did not page: $(alerts | head -2)"
[ -f "$T/was-run" ] && bad "the deferral sweep exec'd work" || ok

# --- 16. a row a HUMAN was asked to look at stays parked ---------------------
# bin/fly-pool.sh's own cap closes the row `failed` with "parked for a human"
# and quotes the refusal in the same reason. Read as a fresh deferral, that
# park would be handed straight back to the pool — the sweep undoing the very
# stop it exists to make visible.
cat > "$T/queue-failed.json" <<'EOF'
{"queue":[
 {"project":"project-5","ticket_key":"TK-270","ticket_id":"270","status":"failed",
  "target":"fly","attempt":1,"claimed_by":"pool-project-5","enqueued_at":"2026-09-11T09:20:00Z",
  "reason":"deferred 6 times (BUILD_DEFERRED REFUSED box :: box max 1 already running) — parked for a human",
  "meta":"{\"deferrals\":6}"}
]}
EOF
rm -f "$T/req.log" "$T/logs/ALERTS.log" "$T/state/jobs-watchdog-deferred.txt"
run_watchdog env QUEUE_FAILED_JSON="$T/queue-failed.json"
grep -q 'POST .*/api/queue' "$T/req.log" \
  && bad "a row parked for a human was handed back to the pool: $(grep POST "$T/req.log")" || ok
grep -q 'TK-270' <<<"$(alerts)" \
  && bad "the park paged again on every tick: $(alerts | head -2)" || ok

# ============================================================================
# 17. THE pr-* ROW REAPER (2026-09-15)
#
# bin/triage-shard.sh claims one row per triage unit, keyed `pr-<n>` when the
# unit is a pull request, and closes it when the session returns. A shard that
# is killed before its first beat never reaches that line, so the row reads
# `running` with last_beat_at NULL for ever — the never-beat branch above
# deliberately leaves it alone. On 2026-09-15 eight project-5 rows (pr-913,
# pr-943, pr-968, pr-970, pr-972, pr-974, pr-975, pr-976), all claimed at
# 00:59:22Z and none of which ever beat, were still `running` twelve hours
# later, re-printing "Status left as running on purpose" on every tick.
# ============================================================================
# The predicate is driven directly: which rows are eligible is the whole claim,
# and the one row class that must NEVER be eligible is a BUILD row, whose claim
# is the fleet's double-build guard.
awk '/^jw_pr_row_reapable\(\)/{f=1} f{print} f&&/^}$/{exit}' "$T/bin/jobs-watchdog.sh" > "$T/reap.sh"
[ -s "$T/reap.sh" ] && ok || bad "could not extract jw_pr_row_reapable"
R() { bash -c 'PR_ROW_TTL_MIN=360; . "$0"; jw_pr_row_reapable "$1" "$2" "$3" "$4" && echo REAP || echo KEEP' \
        "$T/reap.sh" "$1" "$2" "$3" "$4"; }
[ "$(R triage pr-972 - 720)" = REAP ] && ok || bad "a pr-* row that never beat and is 12h old must be reaped"
[ "$(R triage pr-972 - 360)" = REAP ] && ok || bad "the TTL boundary itself must be reapable"
[ "$(R triage pr-972 - 359)" = KEEP ] && ok || bad "a pr-* row under the TTL must be left alone"
[ "$(R build pr-972 - 720)" = KEEP ] && ok || bad "a BUILD row must NEVER be reaped, whatever its key"
[ "$(R triage TK-775 - 720)" = KEEP ] && ok || bad "a ticket-keyed row is not a pr-* row"
[ "$(R triage - - 720)" = KEEP ] && ok || bad "a keyless row is not a pr-* row"
[ "$(R triage pr-972 2026-09-15T00:59:22Z 720)" = KEEP ] && ok \
  || bad "a row that HAS beaten belongs to the heartbeat path, not the reaper"
[ "$(R triage prs-972 - 720)" = KEEP ] && ok || bad "only the literal pr-<number> key shape is reapable"

# Driven, with the row shape the ledger actually held.
cat > "$T/pr-stale.json" <<'EOF'
{"jobs":[
 {"id":"triage-project-5-pr-972-1789433970090","project":"project-5","kind":"triage","stage":"triage",
  "box":"box-project-5-1","ticket_id":"pr-972","activity_age_s":44176,
  "budget_usd":10,"spent_usd":0,"last_beat_at":null},
 {"id":"triage-project-5-pr-976-1789433970089","project":"project-5","kind":"triage","stage":"triage",
  "box":"box-project-5-1","ticket_id":"pr-976","activity_age_s":44176,
  "budget_usd":10,"spent_usd":0,"last_beat_at":null},
 {"id":"triage-project-5-pr-1150-1789478000000","project":"project-5","kind":"triage","stage":"triage",
  "box":"box-project-5-1","ticket_id":"pr-1150","activity_age_s":7200,
  "budget_usd":10,"spent_usd":0,"last_beat_at":null},
 {"id":"build-project-5-TK-775-1789477063881","project":"project-5","kind":"build","stage":"plan",
  "box":"pool-project-5-d8d0ed1f","ticket_id":"pr-775","activity_age_s":44176,
  "budget_usd":150,"spent_usd":0,"last_beat_at":null}
]}
EOF
rm -f "$T/req.log" "$T/logs/ALERTS.log" "$T/lane-alert.txt" "$T/state/jobs-watchdog-alerted.txt"
: > "$T/logs/jobs-watchdog.log"
run_watchdog env STALE_JSON="$T/pr-stale.json"
for id in triage-project-5-pr-972-1789433970090 triage-project-5-pr-976-1789433970089; do
  grep -q "PATCH .*/api/jobs/$id .*orphaned" "$T/req.log" \
    && ok || bad "$id was not closed as orphaned (req.log: $(grep PATCH "$T/req.log" | head -3))"
  grep -q "pr-row-reaped $id" "$T/logs/jobs-watchdog.log" \
    && ok || bad "$id was reaped without its own log line"
done
grep -q 'POST .*/api/jobs/triage-project-5-pr-972-1789433970090/phases/close' "$T/req.log" \
  && ok || bad "the reaped row's open phase must be closed through the same path as a heartbeat-dead job"
grep -q 'PATCH .*/api/jobs/triage-project-5-pr-1150-' "$T/req.log" \
  && bad "a pr-* row under the TTL was reaped anyway" || ok
grep -q 'PATCH .*/api/jobs/build-project-5-TK-775-' "$T/req.log" \
  && bad "a BUILD row was reaped — that releases the double-build guard" || ok
[ "$(wc -l < "$T/lane-alert.txt")" = 1 ] \
  && ok || bad "the reap must page ONCE per run, not once per row (got $(wc -l < "$T/lane-alert.txt") line(s))"
grep -q 'pr-972' "$T/lane-alert.txt" && grep -q 'pr-976' "$T/lane-alert.txt" \
  && ok || bad "the summary page must name the ids it reaped: $(cat "$T/lane-alert.txt")"
# The rows it did NOT reap still page as SILENT — that branch is untouched —
# but a row it DID reap must not also be paged as quiet-but-alive.
grep -qE 'pr-972|pr-976' <<<"$(alerts | grep 'SILENT job')" \
  && bad "a reaped row must not ALSO page as SILENT: $(alerts | grep 'SILENT job' | head -1)" || ok
[ "$(alerts | grep -c 'SILENT job')" = 2 ] \
  && ok || bad "the rows under the TTL must still page as SILENT exactly as before ($(alerts | grep -c 'SILENT job') line(s))"
grep -q 'pr-rows: 2 reaped' "$T/logs/jobs-watchdog.log" \
  && ok || bad "the scan summary must count the reap: $(tail -1 "$T/logs/jobs-watchdog.log")"
[ -f "$T/was-run" ] && bad "the reaper exec'd work" || ok

# A row ALREADY paged as SILENT is exactly the population this exists for, so
# the reaper must run in front of the alerted-once dedupe, not behind it.
rm -f "$T/req.log"; : > "$T/logs/jobs-watchdog.log"
printf 'triage-project-5-pr-972-1789433970090#1
' > "$T/state/jobs-watchdog-alerted.txt"
run_watchdog env STALE_JSON="$T/pr-stale.json"
grep -q 'PATCH .*/api/jobs/triage-project-5-pr-972-1789433970090 .*orphaned' "$T/req.log" \
  && ok || bad "a row already paged as SILENT must still be reaped"

# THE BUSY GATE. A row claimed on THIS box whose shard still holds its per-key
# lock is still working: age alone must not release it.
rm -f "$T/req.log"; : > "$T/logs/jobs-watchdog.log"; : > "$T/state/jobs-watchdog-alerted.txt"
sed 's/box-project-5-1/test-box/' "$T/pr-stale.json" > "$T/pr-stale-here.json"
( exec 5>"$T/locks/triage-key-project-5-pr-972.lock"; flock -n 5 || exit 1; exec sleep 20 ) &
LOCKPID=$!
wait_holder "$LOCKPID"
run_watchdog env STALE_JSON="$T/pr-stale-here.json" JOBS_BOX=test-box
kill "$LOCKPID" 2>/dev/null; wait "$LOCKPID" 2>/dev/null
grep -q 'PATCH .*/api/jobs/triage-project-5-pr-972-1789433970090 .*orphaned' "$T/req.log" \
  && bad "a row whose shard still holds its key lock on this box was reaped anyway" || ok
grep -q 'pr-row-kept triage-project-5-pr-972' "$T/logs/jobs-watchdog.log" \
  && ok || bad "keeping a still-locked row must say so: $(cat "$T/logs/jobs-watchdog.log")"
# ...and the row beside it, whose lock nobody holds, is still reaped.
grep -q 'PATCH .*/api/jobs/triage-project-5-pr-976-1789433970089 .*orphaned' "$T/req.log" \
  && ok || bad "one held lock must not spare every other row"

echo "jobs-watchdog-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
