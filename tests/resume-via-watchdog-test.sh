#!/bin/bash
# tests/resume-via-watchdog-test.sh — the dead-build resume is ONE detector now,
# and it is the jobs watchdog's (BH-1031, state→DB slice 6).
#
# WHAT WAS WRONG. bin/resume-dead-builds.sh ran on its own */30 cron on every
# box and decided death for itself: the per-key flock was free and nothing in
# the dir had been touched for twenty minutes. bin/jobs-watchdog.sh decided the
# same question from the claim's heartbeat. Two detectors, one question, and
# they disagree exactly where it costs — a lock is held by a PROCESS on ONE box,
# so it says nothing about a build whose machine is gone, and twenty quiet
# minutes is true of a perfectly healthy build whose agent is thinking.
#
# The fold keeps the recovery and drops the second opinion: death is the row
# (running and beating = alive), and the resume is bounded by the row too — the
# worker requeues under the lane's retry_policies, so "requeued once, never
# twice" is a fact about a row rather than a race between two crons.
#
# THE CLAIMS DRIVEN HERE, all of them about behaviour under failure:
#   1. AN ORPHANED ROW WITH A RETRY POLICY IS REQUEUED ONCE, NEVER TWICE.
#   2. The watchdog is the entry point: `--resume` on a box, and the tail of a
#      full hub sweep, run the same pass.
#   3. A beating claim is never resumed, and a ledger that cannot answer resumes
#      NOTHING — this is the one pass in the harness that fails closed.
#   4. The kill switch still stops it, through the new entry point.
#
# Run from anywhere: tests/resume-via-watchdog-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait for the launch, not a fixed sleep
# BH-3223: scratch.sh blanks JOBS_URL; this suite's fake curl answers a worker URL.
export JOBS_URL=https://jobs.invalid
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
command -v jq >/dev/null 2>&1 || { echo "resume-via-watchdog-test: SKIPPED — jq is not installed"; exit 0; }
BASE="$T"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# A scratch $HARNESS driven through the REAL bin/jobs-client.sh, with curl
# faked: the requeue route is STATEFUL, because "once, never twice" is the
# worker's answer (`already` on the second ask) and a stub that said
# queued_for_retry for ever would pass a pass that requeues on every tick.
new_harness() {
  local H; H=$(mktemp -d "$BASE/h-XXXXXX")
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/locks" \
           "$H/builds" "$H/fakebin"
  cp "$DIR/bin/jobs-client.sh" "$DIR/bin/jobs-watchdog.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
  # The client is a SHIM over bin/lib/jobs/ since BH-1194 and refuses to
  # half-load, so a fixture that copies it copies the modules beside it too.
  mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
  cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/resume-dead.sh" "$H/bin/lib/"
  printf 'HARNESS_SECRET=test-secret\n' > "$H/env/global.env"
  printf 'box-test\n' > "$H/state/box-name"
  printf '%s\n' '#!/bin/bash' 'echo "$RESUME_BUILD|$1|$2|$3" >> "$HARNESS/launches.txt"' \
    > "$H/run-build-stub.sh"; chmod +x "$H/run-build-stub.sh"
  printf '%s\n' '#!/bin/bash' 'echo "2 (0 build(s) running, 2 box slot(s))"' \
    > "$H/free-slots-stub.sh"; chmod +x "$H/free-slots-stub.sh"
  cat > "$H/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
[ "${CURL_MODE:-ok}" = down ] && exit 7
case "$URL" in
  */requeue*)
    # THE WORKER'S OWN ONCE-ONLY RULE, modelled: the first ask requeues the row,
    # every later ask finds it no longer running and writes nothing.
    N=$(cat "${REQUEUE_COUNT:-/dev/null}" 2>/dev/null); case "$N" in ''|*[!0-9]*) N=0 ;; esac
    echo $((N+1)) > "${REQUEUE_COUNT:-/dev/null}" 2>/dev/null
    if [ "$N" = 0 ]; then printf '{"decision":"queued_for_retry","attempts":1,"max_attempts":3,"reason":"within policy"}\n200\n'
    else printf '{"decision":"already","attempts":1,"max_attempts":3,"reason":"the row is no longer running"}\n200\n'; fi ;;
  */api/jobs?status=running*|*/api/jobs\?status=running*)
    printf '%s\n200\n' "$(cat "${JOBS_FIXTURE:-/dev/null}" 2>/dev/null || echo '{"jobs":[]}')" ;;
  */api/jobs*)  printf '%s\n200\n' "$(cat "${JOBS_FIXTURE:-/dev/null}" 2>/dev/null || echo '{"jobs":[]}')" ;;
  */api/lanes*) printf '{"lanes":[]}\n200\n' ;;
  */api/flags/*) printf '{"error":"not found"}\n404\n' ;;
  *)            printf '{"ok":1}\n200\n' ;;
esac
STUB
  chmod +x "$H/fakebin/curl"
  command -v flock >/dev/null 2>&1 \
    || { printf '#!/bin/bash\nexit 0\n' > "$H/fakebin/flock"; chmod +x "$H/fakebin/flock"; }
  : > "$H/launches.txt"; : > "$H/req.txt"; echo 0 > "$H/requeue-count"
  printf '%s' "$H"
}

# mkbuild <harness> <dir> <project> <board-id> <key> [age-min]
# The two identities are always different strings here, because they are in
# production: job.json's `ticket_id` is the BOARD id run-build.sh was called
# with, and the job ROW's ticket_id column is the ticket KEY (run-build.sh calls
# job_open "$PROJECT" "$KEY").
mkbuild() {
  local H="$1" D="$1/builds/$2" TS
  mkdir -p "$D"
  printf '{"project":"%s","ticket_id":"%s","key":"%s"}\n' "$3" "$4" "$5" > "$D/job.json"
  echo plan > "$D/plan.md"
  TS=$(date -u -d "${6:-60} min ago" +%Y%m%d%H%M 2>/dev/null || date -v-"${6:-60}"M +%Y%m%d%H%M)
  touch -t "$TS" "$D" "$D"/*
  printf '%s' "$D"
}

# One RUNNING row for (project, KEY), with the beat the caller names. The
# ticket_id column carries the ticket KEY, which is what job_open puts there —
# never the board id the build dir's job.json records.
jobs_json() { # jobs_json <id> <project> <key> <last_beat|null>
  jq -nc --arg i "$1" --arg p "$2" --arg t "$3" --arg b "$4" \
    '{jobs:[{id:$i,project:$p,kind:"build",stage:"execute",box:"box-test",
             ticket_id:$t,status:"running",activity_age_s:9000,budget_usd:150,spent_usd:3,
             last_beat_at:(if $b=="null" then null else $b end),attempts:1}]}'
}

watchdog() { # watchdog <harness> [mode] [args...]
  local H="$1" mode="${2:-ok}"; shift 2 2>/dev/null || shift
  ( export PATH="$H/fakebin:$PATH" HARNESS="$H" REQ_SINK="$H/req.txt" CURL_MODE="$mode" \
           JOBS_FIXTURE="$H/jobs.json" REQUEUE_COUNT="$H/requeue-count" \
           RUN_BUILD="$H/run-build-stub.sh" FREE_SLOTS="$H/free-slots-stub.sh" \
           JOBS_TIMEOUT=4 JOBS_RETRIES=0
    bash "$H/bin/jobs-watchdog.sh" "$@" >/dev/null 2>&1 )
  sleep 1   # the relaunch is backgrounded, exactly as a real resume is
}
requeues() { grep -c '/requeue' "$1/req.txt" 2>/dev/null | tr -dc '0-9'; }
launches() { grep -c . "$1/launches.txt" 2>/dev/null | tr -dc '0-9'; }

# ===========================================================================
# 1. An orphaned row with a retry policy is REQUEUED ONCE, NEVER TWICE
# ===========================================================================
H=$(new_harness)
D=$(mkbuild "$H" p1-T-7-x p1 tid7 T-7 60)
jobs_json build-p1-T-7 p1 T-7 null > "$H/jobs.json"   # claimed, never beat
watchdog "$H" ok --resume; wait_for 10 grep -q "T-7" "$H/launches.txt"
[ "$(requeues "$H")" = 1 ] \
  && ok || bad "the dead claim must be requeued under its retry policy (requeues: $(requeues "$H"))"
[ "$(launches "$H")" = 1 ] \
  && ok || bad "the build must be resumed from its checkpoints (launches: $(cat "$H/launches.txt"))"
grep -q "^$D|p1|tid7|T-7$" "$H/launches.txt" \
  && ok || bad "the resume must carry RESUME_BUILD and the row's identity (got: $(cat "$H/launches.txt"))"
[ "$(cat "$D/resume-attempts" 2>/dev/null)" = 1 ] \
  && ok || bad "the attempt must be spent, or a broken build relaunches for ever"

# The SECOND tick, same state: the worker answers `already` — the row is no
# longer running and nothing was written — so nothing may be launched on top of
# it. This is the double build the fold must never cause.
watchdog "$H" ok --resume
[ "$(launches "$H")" = 1 ] \
  && ok || bad "a row already requeued must never be requeued INTO a second build (launches: $(cat "$H/launches.txt"))"
[ "$(cat "$D/resume-attempts" 2>/dev/null)" = 1 ] \
  && ok || bad "the second tick must not spend another attempt"
[ ! -f "$D/RESULT" ] \
  && ok || bad "an already-settled row says nothing about this build dir: $(cat "$D/RESULT" 2>/dev/null)"

# ===========================================================================
# 2. A beating claim is alive — this is what replaced the flock probe
# ===========================================================================
H=$(new_harness)
mkbuild "$H" p1-T-9-x p1 tid9 T-9 60 >/dev/null
jobs_json build-p1-T-9 p1 T-9 "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$H/jobs.json"
watchdog "$H" ok --resume
[ "$(launches "$H")" = 0 ] \
  && ok || bad "a build whose claim is beating was resumed: $(cat "$H/launches.txt")"
[ "$(requeues "$H")" = 0 ] \
  && ok || bad "a live claim must not be requeued"

# ===========================================================================
# 3. The ledger could not answer -> nothing is judged. THIS PASS FAILS CLOSED.
# ===========================================================================
H=$(new_harness)
D3=$(mkbuild "$H" p1-T-11-x p1 tid11 T-11 60)
jobs_json build-p1-T-11 p1 T-11 null > "$H/jobs.json"
watchdog "$H" down --resume
[ "$(launches "$H")" = 0 ] \
  && ok || bad "an unreachable worker must not resume anything: $(cat "$H/launches.txt")"
[ ! -f "$D3/resume-attempts" ] \
  && ok || bad "an unreachable worker must not spend an attempt"
grep -q 'ledger could not answer' "$H/logs/resume-dead.log" 2>/dev/null \
  && ok || bad "a pass that judged nothing must say why (log: $(cat "$H/logs/resume-dead.log" 2>/dev/null))"

# ===========================================================================
# 4. The watchdog IS the entry point — both halves of the fold
# ===========================================================================
# A full hub sweep carries the pass at its tail, so the hub needs no second
# cron line for it...
H=$(new_harness)
mkbuild "$H" p1-T-12-x p1 tid12 T-12 60 >/dev/null
jobs_json build-p1-T-12 p1 T-12 null > "$H/jobs.json"
watchdog "$H"; wait_for 10 grep -q "T-12" "$H/launches.txt"
[ "$(launches "$H")" = 1 ] \
  && ok || bad "a full watchdog sweep must run the resume pass it absorbed (launches: $(cat "$H/launches.txt"))"
# ...and the boxes keep their own cadence through --resume, which is the line
# every cron/<box>.cron now carries.
# CODE, not prose: hub.cron keeps a comment saying where its line went, which
# is correct. What must be gone is a cron line that RUNS the deleted script.
for C in "$(rendered_cron_dir)"/*.cron; do
  # grep -c reads to EOF: a grep -q here could SIGPIPE the producer and read a
  # live cron line as gone (BH-1818).
  [ "$(grep -h 'resume-dead-builds' "$C" 2>/dev/null | grep -vc '^[[:space:]]*#')" != 0 ] \
    && { bad "$(basename "$C") still runs the deleted script"; break; }
done
NEEDS=$(grep -l 'jobs-watchdog.sh --resume' "$(rendered_cron_dir)"/*.cron 2>/dev/null | wc -l | tr -dc '0-9')
[ "${NEEDS:-0}" -ge 8 ] \
  && ok || bad "every box cron that resumed dead builds must now run the watchdog's pass (got ${NEEDS:-0})"

# ===========================================================================
# 5. The kill switch still stops it, through the new entry point
# ===========================================================================
H=$(new_harness)
mkbuild "$H" p1-T-13-x p1 tid13 T-13 60 >/dev/null
jobs_json build-p1-T-13 p1 T-13 null > "$H/jobs.json"
touch "$H/flags/resume-disabled"
watchdog "$H" ok --resume
[ "$(launches "$H")" = 0 ] && ok || bad "flags/resume-disabled ignored by the folded pass"
[ "$(requeues "$H")" = 0 ] && ok || bad "a disabled resume must not even ask the worker"

# ...and a dir the pool owns is still not ours to resume.
H=$(new_harness)
mkbuild "$H" p2-T-14-x p2 tid14 T-14 60 >/dev/null
jobs_json build-p2-T-14 p2 T-14 null > "$H/jobs.json"
touch "$H/flags/builder-fly-p2"
watchdog "$H" ok --resume
[ "$(launches "$H")" = 0 ] && ok || bad "a fly-routed project's dir was resumed locally"

echo "resume-via-watchdog-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
