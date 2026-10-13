#!/bin/bash
# tests/jobs-watchdog-ttl-test.sh — ledger hygiene, driven for real.
#
# WHAT IS ACTUALLY AT STAKE HERE. On the afternoon of 2026-09-15 the hub jobs
# ledger carried 42 rows reading `running`; nine had shown no sign of life for
# over an hour and eight of those were `pr-*` review/rescue claims taken at
# 00:59Z and still open fifteen hours later. Not one of them was wrong under the
# rules the watchdog had: a row that never beat is REPORTED at SILENT_MIN and
# left alone on purpose, because age is not proof of death and releasing a live
# claim is how one ticket gets built twice. Nothing convicted them, and nothing
# re-offered their tickets — a box only re-offers on its own tick if the ticket
# is still visible on its board.
#
# So three claims are tested here, and each one is a classification a grep could
# not check:
#   * a TTL is PER CLASS and comes from catalog/ledger-ttl.conf — a pr-* row
#     dies at 45m while a build/execute row of the same age is still working;
#   * the reap pages ONCE per tick listing every row, because eight rows dying
#     together used to mean eight identical alerts, which is how a channel stops
#     being read;
#   * a reaped triage row is handed BACK to the queue with a counter, and after
#     the cap it is parked — and a BUILD row never is, because its queue row is
#     bin/fly-pool.sh's to re-offer and two re-offerers is a double build.
#
# curl and gh are both stubbed — no network — so neither the worker's SQL nor
# GitHub is under test. What is proven is the shell: which rows are convicted,
# how many alert lines exist, which requeues are asked for, that the GitHub pass
# is bounded to every Nth tick, and that hygiene.json's counts are the same
# arithmetic the alert used.
# Run from anywhere: tests/jobs-watchdog-ttl-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait_holder, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/locks" "$T/state" "$T/flags" "$T/bin/lib" "$T/catalog" "$T/env" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh"   "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/jobs-watchdog.sh" "$T/bin/jobs-watchdog.sh"
cp "$DIR/bin/fleet-conf.sh"    "$T/bin/fleet-conf.sh"
cp "$DIR/bin/lib/gh-repo-token.sh" "$T/bin/lib/gh-repo-token.sh"
# THE SHIPPED NUMBERS, not a fixture copy of them. A test that invents its own
# TTLs proves the mechanism and nothing about the table the fleet runs, and the
# table is where the judgement lives.
cp "$DIR/catalog/ledger-ttl.conf" "$T/catalog/ledger-ttl.conf"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/fleet.conf" <<'EOF'
project-5     example-org/project-5   https://project-5.example  -             9 box-project-5-1 10.0.0.5
project-3       example-org/project-3     https://os.project-3.example  /api/board    6 box-project-3-2    10.0.0.3
project-2 example-org/project-2 https://os.project-2.example /api/board 4 box-project-2   10.0.0.2
EOF

# The worker, by URL. Every write lands in REQ_SINK so the test can read back
# exactly which PATCH/POST the sweep made — and, just as importantly, which it
# did not.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in down) exit 7 ;; esac
case "$URL" in
  */api/jobs\?status=running*)          cat "$STALE_JSON"; printf '\n200\n' ;;
  */api/jobs\?status=queued_for_retry*) cat "${QUEUED_JSON:-/dev/null}"; printf '\n200\n' ;;
  */requeue)                   cat "${REQUEUE_JSON:-/dev/null}"; printf '\n200\n' ;;
  */retry)                     cat "${RETRY_JSON:-/dev/null}"; printf '\n200\n' ;;
  */phases/close)              printf '{"closed":1,"phases":[{"id":9,"phase":"triage"}]}\n200\n' ;;
  */events)                    printf '{"event_id":1}\n201\n' ;;
  */api/queue\?status=*)       printf '{"queue":[]}\n200\n' ;;
  */api/lanes)                 printf '{"lanes":[]}\n200\n' ;;
  */api/jobs/*)                printf '{"job":{"id":"x","status":"orphaned"}}\n200\n' ;;
  *)                           printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# GitHub, by PR number. PR_STATES holds "<num> <STATE>" lines; a number not in
# it answers nothing, which is exactly what an unreachable gh looks like and
# must leave the row alone.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
[ -n "${GH_SINK:-}" ] && printf '%s\n' "$*" >> "$GH_SINK"
case "${1:-}" in
  api) exit 0 ;;                       # every repo is visible to the default token
  pr)  N="${3:-}"
       S=$(awk -v n="$N" '$1 == n { print $2; exit }' "${PR_STATES:-/dev/null}" 2>/dev/null)
       [ -n "$S" ] || exit 1
       printf '%s\n' "$S" ;;
  *)   exit 1 ;;
esac
EOF
chmod +x "$T/fakebin/gh"

# Anything that would RUN work. Nothing in this sweep may reach one.
for W in run-build.sh run-triage.sh with-job.sh orc-job.sh; do
  printf '#!/bin/bash\ntouch "%s/was-run"\nexit 0\n' "$T" > "$T/fakebin/$W"
  chmod +x "$T/fakebin/$W"
done

# The rows, shaped like the ones the hub was actually carrying at 16:00Z on
# 2026-09-15. Ages in seconds, as the worker reports them.
#   pr-976 / pr-975  916m, never beat   -> class pr-*        TTL 360m  REAP
#   noticket         30m,  never beat   -> class triage      TTL 360m  live
#   TK-400           200m, never beat   -> class execute     TTL 360m  live (SILENT)
#   TK-109           400m, never beat   -> class execute     TTL 360m  REAP, no requeue
#   TK-900           35m,  beat + died  -> the HEARTBEAT pass owns it, not the TTL
cat > "$T/stale.json" <<'EOF'
{"jobs":[
 {"id":"triage-project-5-pr-976","project":"project-5","kind":"triage","stage":"triage",
  "box":"box-project-5-1","ticket_id":"pr-976","activity_age_s":54960,
  "budget_usd":25,"spent_usd":0.4,"last_beat_at":null},
 {"id":"triage-project-5-pr-975","project":"project-5","kind":"triage","stage":"triage",
  "box":"box-project-5-1","ticket_id":"pr-975","activity_age_s":54960,
  "budget_usd":25,"spent_usd":0.4,"last_beat_at":null},
 {"id":"triage-project-3-noticket","project":"project-3","kind":"triage","stage":"triage",
  "box":"box-project-3-2","ticket_id":null,"activity_age_s":1800,
  "budget_usd":25,"spent_usd":0.1,"last_beat_at":null},
 {"id":"build-project-2-TK-400","project":"project-2","kind":"build","stage":"execute",
  "box":"box-project-2","ticket_id":"TK-400","activity_age_s":12000,
  "budget_usd":150,"spent_usd":9.5,"last_beat_at":null},
 {"id":"build-project-3-TK-109","project":"project-3","kind":"build","stage":"execute",
  "box":"box-project-3-2","ticket_id":"TK-109","activity_age_s":24000,
  "budget_usd":150,"spent_usd":4.12,"last_beat_at":null},
 {"id":"build-project-5-TK-900","project":"project-5","kind":"build","stage":"execute",
  "box":"pool-project-5-1","ticket_id":"TK-900","activity_age_s":2100,
  "budget_usd":150,"spent_usd":3.0,"last_beat_at":"2026-09-15T15:25:00Z"}
]}
EOF

cat > "$T/requeue-queued.json" <<'EOF'
{"job_id":"x","decision":"queued_for_retry","attempts":1,"max_attempts":3,
 "reason":"requeued after 916m running with no heartbeat (auto-requeue 1 of 3); the lane's own next tick picks it up"}
EOF
cat > "$T/requeue-parked.json" <<'EOF'
{"job_id":"x","decision":"parked","attempts":4,"max_attempts":3,
 "reason":"auto-requeued 3 times already (cap 3) after 916m running with no heartbeat — parked for bin/blocked-resolver.sh"}
EOF
cat > "$T/requeue-held.json" <<'EOF'
{"job_id":"x","decision":"held","attempts":0,"max_attempts":3,
 "reason":"project-5/pr-976 is already live as triage-project-5-pr-976-b (triage/triage on box-project-5-1)"}
EOF
cat > "$T/retry-nopolicy.json" <<'EOF'
{"decision":"orphaned","attempts":1,"max_attempts":null,"next_attempt_at":null,
 "reason":"no retry policy for lane build/project-5/execute — detection only"}
EOF
printf '976 MERGED\n975 CLOSED\n' > "$T/pr-states.txt"

# A row the requeue already handed back to the queue, for a PR that has since
# merged. Nothing will ever claim it again — the shard list no longer carries a
# merged PR — so without the reconciliation pass reading this status too, the
# requeue simply moves a stuck row from one status to another.
cat > "$T/queued.json" <<'EOF'
{"jobs":[
 {"id":"triage-project-5-pr-968","project":"project-5","kind":"triage","stage":"triage",
  "box":"box-project-5-1","ticket_id":"pr-968","activity_age_s":60000,
  "budget_usd":25,"spent_usd":0.4,"last_beat_at":null}
]}
EOF
printf '968 MERGED\n' >> "$T/pr-states.txt"

run_wd() { # run_wd [env...]
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid STALE_JSON="$T/stale.json" \
           REQ_SINK="$T/req.log" GH_SINK="$T/gh.log" PR_STATES="$T/pr-states.txt" \
           FLEET_CONF="$T/fleet.conf" RETRY_JSON="$T/retry-nopolicy.json" \
           REQUEUE_JSON="$T/requeue-queued.json" QUEUED_JSON="$T/queued.json" \
           JOBS_RECONCILE_EVERY=0
    "$@" bash "$T/bin/jobs-watchdog.sh" >/dev/null 2>&1 )
}
reset() { rm -f "$T/req.log" "$T/gh.log" "$T/logs/ALERTS.log" "$T/was-run" \
                 "$T/state/jobs-watchdog-alerted.txt" "$T/state/jobs-watchdog-reconcile-tick"; }
alerts() { cat "$T/logs/ALERTS.log" 2>/dev/null; }
reap_line() { alerts | grep 'LEDGER TTL REAP' | head -1; }

# --- 1. the TTL is PER CLASS, and the class comes from the shipped table ------
reset; run_wd env
L=$(reap_line)
[ -n "$L" ] && ok || bad "nothing was reaped at all: $(alerts | head -3)"
# 916m against the 360m pr-* TTL: both PR-keyed rows die.
grep -q 'PATCH .*/api/jobs/triage-project-5-pr-976 .*"status":"orphaned"' "$T/req.log" \
  && ok || bad "a 916m pr-* row survived its 360m TTL: $(grep PATCH "$T/req.log")"
grep -q 'PATCH .*/api/jobs/triage-project-5-pr-975 .*"status":"orphaned"' "$T/req.log" \
  && ok || bad "only one of the two pr-* rows was reaped"
# 400m against the 360m execute TTL: dead.
grep -q 'PATCH .*/api/jobs/build-project-3-TK-109 .*"status":"orphaned"' "$T/req.log" \
  && ok || bad "a 400m build/execute row survived its 360m TTL"
# AND THE OTHER HALF, which is the expensive one to get wrong. A 200m
# build/execute row is INSIDE its 360m TTL — the longest an execute stage has
# ever honestly taken is 139m — so convicting it would release a claim on a
# build that is still running.
grep -q 'PATCH .*/api/jobs/build-project-2-TK-400' "$T/req.log" \
  && bad "a 200m execute row was reaped under a 360m TTL — that releases live work" || ok
# A 30m triage row is inside its 360m TTL.
grep -q 'PATCH .*/api/jobs/triage-project-3-noticket' "$T/req.log" \
  && bad "a 30m triage row was reaped under a 360m TTL" || ok
# The TTL must not steal a row the HEARTBEAT pass owns: that row gets a retry
# verdict from the policy, and a TTL opinion on top would spend its attempts.
grep -q 'POST .*/api/jobs/build-project-5-TK-900/retry' "$T/req.log" \
  && ok || bad "the beating-then-dead row was not judged by the heartbeat pass"
grep -q 'POST .*/api/jobs/build-project-5-TK-900/requeue' "$T/req.log" \
  && bad "the TTL pass requeued a row the retry policy owns" || ok

# The stage event is the record a reader opens to find out whether the row ever
# showed a sign of life, so "-" (job_stale's never-beat sentinel) must be spelt
# out there, not printed as a timestamp.
EV=$(grep 'POST .*/api/jobs/triage-project-5-pr-976/events' "$T/req.log" | head -1)
case "$EV" in *"no heartbeat ever"*) ok ;; *) bad "the TTL event does not say the row never beat: $EV" ;; esac
case "$EV" in *"last beat -"*) bad "the never-beat sentinel was printed as a timestamp: $EV" ;; *) ok ;; esac

# --- 2. ONE alert per tick, listing them -------------------------------------
# Eight rows died together at 00:59Z. Eight identical alert lines is how a
# channel stops being read.
N=$(alerts | grep -c 'LEDGER TTL REAP')
[ "$N" = 1 ] && ok || bad "expected exactly 1 TTL reap alert, got $N"
case "$L" in *pr-976*) ok ;; *) bad "the reap alert does not name pr-976: $L" ;; esac
case "$L" in *pr-975*) ok ;; *) bad "the reap alert does not name pr-975: $L" ;; esac
case "$L" in *TK-109*) ok ;; *) bad "the reap alert does not name TK-109: $L" ;; esac
# It has to say the arithmetic that convicted them, or nobody can check it.
case "$L" in *"916m vs 360m"*) ok ;; *) bad "the alert does not show age against TTL: $L" ;; esac
case "$L" in *"3 running row(s) outlived"*) ok ;; *) bad "the alert does not carry the count: $L" ;; esac

# --- 3. the requeue, with a counter ------------------------------------------
grep -q 'POST .*/api/jobs/triage-project-5-pr-976/requeue' "$T/req.log" \
  && ok || bad "a reaped triage row was not handed back to the queue"
RB=$(grep 'POST .*/requeue' "$T/req.log" | head -1 | cut -d' ' -f3-)
[ "$(jq -r '.max_attempts' <<<"$RB" 2>/dev/null)" = 3 ] \
  && ok || bad "the requeue did not carry the configured cap: $RB"
case "$L" in *"auto-requeue 1 of 3"*) ok ;; *) bad "the alert does not carry the requeue counter: $L" ;; esac
# A BUILD row is reaped and NOT requeued. Its queue row belongs to
# bin/fly-pool.sh; two things re-offering one build is a double build.
grep -q 'POST .*/api/jobs/build-project-3-TK-109/requeue' "$T/req.log" \
  && bad "a build row was handed back to the queue by the ledger sweep" || ok

# --- 4. the watchdog still executes NOTHING ----------------------------------
[ -f "$T/was-run" ] && bad "the hygiene passes exec'd work" || ok
grep -qE 'POST [^ ]*/api/jobs( |$)' "$T/req.log" \
  && bad "a hygiene pass opened a claim — starting work is the lane's job" || ok

# --- 5. the cap parks, once, and says whose problem it is now -----------------
reset; run_wd env REQUEUE_JSON="$T/requeue-parked.json"
L=$(reap_line)
case "$L" in *"PARKED after 3 auto-requeues"*) ok ;; *) bad "a capped requeue did not read as parked: $L" ;; esac
case "$L" in *"blocked-resolver"*) ok ;; *) bad "the park does not say who owns it now: $L" ;; esac
[ "$(alerts | grep -c 'LEDGER TTL REAP')" = 1 ] \
  && ok || bad "the park paged more than once in a tick"

# --- 6. a ticket with a live sibling is HELD, never requeued twice ------------
reset; run_wd env REQUEUE_JSON="$T/requeue-held.json"
L=$(reap_line)
case "$L" in *"not requeued"*already\ live*) ok ;; *) bad "a held requeue does not name the live owner: $L" ;; esac

# --- 7. a claim for a PR THAT ALREADY LANDED --------------------------------
# The class nothing else here can see: the PR merged, the session is gone, no
# beat stops and no queue row ages, so the claim reads `running` forever.
reset; run_wd env JOBS_RECONCILE_EVERY=1
grep -q 'pr view 976 --repo example-org/project-5' "$T/gh.log" \
  && ok || bad "the reconciliation pass never asked GitHub: $(cat "$T/gh.log" 2>/dev/null)"
grep -q 'PATCH .*/api/jobs/triage-project-5-pr-976 .*"status":"done"' "$T/req.log" \
  && ok || bad "a MERGED PR's claim was not closed done: $(grep pr-976 "$T/req.log")"
# Closed unmerged is NOT done. A ledger that files an abandoned PR as a finished
# one is the same lie in the other direction.
grep -q 'PATCH .*/api/jobs/triage-project-5-pr-975 .*"status":"failed"' "$T/req.log" \
  && ok || bad "a CLOSED-unmerged PR's claim was filed as done or left running"
RL=$(alerts | grep 'LEDGER RECONCILED' | head -1)
case "$RL" in *"2 claim(s) closed done"*"1 closed failed"*) ok ;; *) bad "the reconcile alert miscounts: $RL" ;; esac
[ "$(alerts | grep -c 'LEDGER RECONCILED')" = 1 ] \
  && ok || bad "the reconciliation pass paged per row instead of per tick"
# A row settled by GitHub must not then be reaped by the TTL pass as well: its
# status has already moved, and a second verdict on one death is a row whose
# history cannot be true.
[ "$(grep -c 'PATCH .*/api/jobs/triage-project-5-pr-976' "$T/req.log")" = 1 ] \
  && ok || bad "the merged row was written twice in one tick"
# ...and only PR-KEYED rows cost a GitHub call. A ticket key is not a PR number.
grep -q 'pr view TK-109' "$T/gh.log" \
  && bad "the sweep asked GitHub about a ticket key: $(cat "$T/gh.log")" || ok
# A row ALREADY on the queue is reconciled too. A requeue that only moves a row
# from `running` to `queued_for_retry` has not unstuck anything if nothing will
# ever claim that key again — and nothing claims a merged PR.
grep -q 'PATCH .*/api/jobs/triage-project-5-pr-968 .*"status":"done"' "$T/req.log" \
  && ok || bad "a queued_for_retry row for a merged PR was left on the queue for ever"
# ...but the TTL pass must NOT touch it: a queued row is not a claim on anything.
grep -q 'PATCH .*/api/jobs/triage-project-5-pr-968 .*"status":"orphaned"' "$T/req.log" \
  && bad "the TTL pass convicted a row that is sitting on the queue, not running" || ok

# --- 8. the GitHub pass is bounded to every Nth tick -------------------------
# It is the only part of this sweep that spends API calls, and a merged PR does
# not become less merged in half an hour.
reset; run_wd env JOBS_RECONCILE_EVERY=6
[ -s "$T/gh.log" ] \
  && bad "the reconciliation pass ran on tick 1 of 6: $(cat "$T/gh.log")" || ok
for _ in 2 3 4 5; do run_wd env JOBS_RECONCILE_EVERY=6; done
[ -s "$T/gh.log" ] && bad "the reconciliation pass ran before its 6th tick" || ok
run_wd env JOBS_RECONCILE_EVERY=6
grep -q 'pr view 976' "$T/gh.log" \
  && ok || bad "the reconciliation pass never ran on its 6th tick"

# --- 9. hygiene.json — the same arithmetic as the alert ----------------------
reset; run_wd env
HJ="$T/state/ledger/hygiene.json"
[ -s "$HJ" ] && ok || bad "no state/ledger/hygiene.json was written"
jq -e . "$HJ" >/dev/null 2>&1 && ok || bad "hygiene.json is not valid json: $(cat "$HJ" 2>/dev/null | head -c 300)"
[ "$(jq -r '.totals.ttl_orphaned' "$HJ" 2>/dev/null)" = 3 ] \
  && ok || bad "hygiene.json totals disagree with the alert: $(jq -c '.totals' "$HJ" 2>/dev/null)"
[ "$(jq -r '.by_class["pr-*"].ttl_orphaned' "$HJ" 2>/dev/null)" = 2 ] \
  && ok || bad "hygiene.json does not count by class: $(jq -c '.by_class' "$HJ" 2>/dev/null)"
# The TTL that convicted the class rides along, so a reader can check the number
# without opening the config on some other box.
[ "$(jq -r '.by_class["pr-*"].ttl_min' "$HJ" 2>/dev/null)" = 360 ] \
  && ok || bad "hygiene.json does not carry the class TTL: $(jq -c '.by_class' "$HJ" 2>/dev/null)"
[ "$(jq -r '.by_class.execute.requeued // 0' "$HJ" 2>/dev/null)" = 0 ] \
  && ok || bad "hygiene.json claims a build class was requeued"
[ "$(jq -r '.thresholds.requeue_max' "$HJ" 2>/dev/null)" = 3 ] \
  && ok || bad "hygiene.json does not record the thresholds it ran under"
# Written on a QUIET tick too: a file that only appears when something is wrong
# cannot answer "is the ledger clean right now".
printf '{"jobs":[]}\n' > "$T/empty.json"
reset; rm -f "$HJ"; run_wd env STALE_JSON="$T/empty.json"
[ -s "$HJ" ] && [ "$(jq -r '.totals | length' "$HJ" 2>/dev/null)" = 0 ] \
  && ok || bad "a quiet tick left no hygiene.json: $(cat "$HJ" 2>/dev/null | head -c 200)"

# --- 10. a box-local override wins, row by row -------------------------------
# The emergency lever that needs no deploy — and it must widen ONE class without
# silently discarding the rest of the shipped table.
reset
printf 'ttl pr-*  2000\n' > "$T/flags/ledger-ttl.conf"
run_wd env
grep -q 'PATCH .*/api/jobs/triage-project-5-pr-976' "$T/req.log" \
  && bad "the box-local TTL override was ignored" || ok
grep -q 'PATCH .*/api/jobs/build-project-3-TK-109 .*"status":"orphaned"' "$T/req.log" \
  && ok || bad "an override of one class discarded the rest of the shipped table"
rm -f "$T/flags/ledger-ttl.conf"

# --- 10b. requeue eligibility is a CONFIG ROW, not a constant ---------------
# And the list holds a glob (`pr-*`), so the membership test must never expand
# it against whatever directory cron left this script in.
reset
printf 'set requeue_classes execute\n' > "$T/flags/ledger-ttl.conf"
touch "$T/pr-976" "$T/pr-975"   # bait for a globbing membership test
( cd "$T" && run_wd env )
grep -q 'POST .*/api/jobs/build-project-3-TK-109/requeue' "$T/req.log" \
  && ok || bad "the requeue_classes config row was ignored"
grep -q 'POST .*/api/jobs/triage-project-5-pr-976/requeue' "$T/req.log" \
  && bad "a class removed from requeue_classes was requeued anyway" || ok
rm -f "$T/flags/ledger-ttl.conf" "$T/pr-976" "$T/pr-975"

# --- 10c. a typo'd TTL is dropped, not obeyed --------------------------------
# `ttl pr-* banana` in the box-local override would fail the age comparison and
# drop the row through to the 720m default in total silence — a typo deciding
# policy. A dropped row must leave the key UNSET instead, so the next file in
# the ladder (the shipped catalog's 45m) still answers for it.
reset
printf 'ttl pr-*  banana\n' > "$T/flags/ledger-ttl.conf"
run_wd env
grep -q 'PATCH .*/api/jobs/triage-project-5-pr-976 .*"status":"orphaned"' "$T/req.log" \
  && ok || bad "a typo'd override row silenced the shipped table"
[ "$(jq -r '.by_class["pr-*"].ttl_min' "$T/state/ledger/hygiene.json" 2>/dev/null)" = 360 ] \
  && ok || bad "the typo'd row was taken rather than dropped: $(jq -c '.by_class' "$T/state/ledger/hygiene.json" 2>/dev/null)"
rm -f "$T/flags/ledger-ttl.conf"

# --- 11. no config at all: the sweep degrades, it does not misfire ----------
# Every box renders its own checkout, and a box mid-render has no catalog file.
# The fallback is the 1440m default written into bin/jobs-watchdog.sh — a full
# day, past anything the fleet has honestly run (the longest terminal row in the
# 723-row sample was 284m), so a missing table REPORTS and convicts nothing.
reset; mv "$T/catalog/ledger-ttl.conf" "$T/ledger-ttl.conf.bak"
run_wd env
grep -q 'LEDGER TTL REAP' <<<"$(alerts)" \
  && bad "with no TTL table the sweep convicted rows on a number from nowhere: $(reap_line)" || ok
grep -q 'PATCH .*/api/jobs/build-project-3-TK-109' "$T/req.log" \
  && bad "a 400m build row was convicted under the 1440m fallback" || ok
grep -q 'POST .*/requeue' "$T/req.log" \
  && bad "with no TTL table something was still handed back to the queue" || ok
# ...and #358's own pr-* reaper is untouched by any of this: its 360m fallback
# still closes the rows this whole ticket started from, table or no table.
grep -q 'PATCH .*/api/jobs/triage-project-5-pr-976 .*"status":"orphaned"' "$T/req.log" \
  && ok || bad "the fallback lost #358's pr-* reap"
mv "$T/ledger-ttl.conf.bak" "$T/catalog/ledger-ttl.conf"

# --- 11b. a per-key lock still held on THIS box keeps the row ---------------
# AGE AND EVIDENCE, not age alone (#358's rule, generalised). The hub can read
# its own locks: a row whose shard lock is held by a live process here is being
# worked on right now, whatever the ledger's clock says, and reaping it would
# release a claim out from under a running session.
reset
HOSTBOX=$(hostname)
sed "s/box-project-5-1/$HOSTBOX/" "$T/stale.json" > "$T/stale-here.json"
flock "$T/locks/triage-key-project-5-pr-976.lock" sleep 20 &
LOCKPID=$!
wait_holder "$LOCKPID"
run_wd env STALE_JSON="$T/stale-here.json"
grep -q 'PATCH .*/api/jobs/triage-project-5-pr-976' "$T/req.log" \
  && bad "a row whose own shard lock is still held here was reaped" || ok
# ...and its sibling, whose lock nobody holds, still dies in the same tick.
grep -q 'PATCH .*/api/jobs/triage-project-5-pr-975 .*"status":"orphaned"' "$T/req.log" \
  && ok || bad "one held lock stopped the whole pass"
kill "$LOCKPID" 2>/dev/null; wait "$LOCKPID" 2>/dev/null

# --- 12. worker unreachable: no writes, no page, no crash --------------------
reset; run_wd env CURL_MODE=down; RC=$?
[ "$RC" = 0 ] && ok || bad "the sweep exited $RC with the worker down; cron must not see failures for an outage"
[ "$(alerts | grep -cE 'LEDGER TTL REAP|LEDGER RECONCILED')" = 0 ] \
  && ok || bad "an unreachable worker produced hygiene alerts: $(alerts | head -2)"

echo "jobs-watchdog-ttl-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
