#!/bin/bash
# tests/heartbeat-lock-release-test.sh — THE BEATER MUST NOT CARRY THE BUILD'S
# LOCKS. bin/jobs-client.sh's job_beat_start forks a loop that sleeps between
# beats, and until 2026-09-12 that fork inherited every descriptor the caller
# held open — in bin/run-build.sh that is the slot flock (fd 8+) and the
# per-key flock (fd 7). job_beat_stop kills the LOOP; its `sleep` is orphaned
# with those descriptors still open, and an flock lives exactly as long as a
# descriptor holding it, so the slot stayed locked for the rest of the interval
# (150s in production). The box then answered the next ticket with
# "BUILD_DEFERRED all N slots busy" — a refusal that lands BEFORE the DB claim,
# so nothing in the jobs ledger explains it. Seen on a live project-5 pool
# machine (ALERTS.log 2026-09-12 22:56Z).
#
# What is proven here, by driving the real function and taking a real flock:
#   1. after job_beat_stop and the caller's exit, a fresh `flock -n` succeeds
#      within 0.5s (on the unfixed version it fails until the interval ends);
#   2. no `sleep` child survives job_beat_stop;
#   3. the beater still beats — a fix that silences the heartbeat is not a fix.
#
# Run from anywhere: tests/heartbeat-lock-release-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/fakebin" "$T/logs" "$T/flags" "$T/locks"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v flock >/dev/null 2>&1 || { echo "heartbeat-lock-release: flock absent — skipping"; exit 0; }

# A pid that exists AND is not a zombie — `kill -0` alone cannot tell a survivor
# from a corpse. Under Fly's init an orphan keeps its process-table entry for
# about a second after the TERM landed and its trap ran, so every "still alive"
# assertion below read a reaped-but-unwaited beat loop as a survivor and this
# suite was red on every Fly machine while the fd-release assertion — the one
# that matters — passed in the same run. GitHub-hosted's systemd reaps at once,
# which is the only reason the suite was ever green there. Mirrors proc_alive in
# bin/lane-reaper.sh; the `ps` arm covers a host without /proc. An unreadable
# state counts as alive, so a host with neither source still fails on a process
# that genuinely outlived job_beat_stop.
proc_alive() { # proc_alive <pid>
  kill -0 "$1" 2>/dev/null || return 1
  local st
  st=$(awk '/^State:/ {print $2; exit}' "/proc/$1/status" 2>/dev/null)
  [ -n "$st" ] || st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d '[:space:]')
  case "$st" in Z*) return 1 ;; esac
  return 0
}

# Fake curl: a heartbeat must be countable without a network.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
[ -n "${REQ_SINK:-}" ] && printf '%s\n' "$URL" >> "$REQ_SINK"
printf '{}\n200\n'
EOF
chmod +x "$T/fakebin/curl"

run_caller() { # run_caller <script> — a SEPARATE process, so its own fds die with it
  env "PATH=$T/fakebin:$PATH" "HARNESS=$T" HARNESS_SECRET=test-secret \
      JOBS_URL=https://jobs.invalid JOBS_BOX=test-box "REQ_SINK=$T/req.txt" \
      bash -c "$1"
}

# --- 1. the slot lock is free the moment the build that held it is gone ------
# The caller is a separate process: whatever still holds the lock after it exits
# can only be something the beater left behind.
LOCK="$T/locks/build-slot-1.lock"
: > "$T/req.txt"
run_caller '
  exec 8>"'"$LOCK"'"
  flock -n 8 || exit 9
  . "'"$T"'/bin/jobs-client.sh"
  B=$(job_beat_start job-1 3) || exit 8
  [ -n "$B" ] || exit 7
  printf "%s\n" "$B" > "'"$T"'/beat1.pid"
  job_beat_stop "$B"
'
RC=$?
[ "$RC" = 0 ] && ok || bad "the lock-holding caller did not run cleanly (rc=$RC)"

GOT=0; TRIES=0
for _ in 1 2 3 4 5; do
  TRIES=$((TRIES+1))
  if ( exec 9>>"$LOCK"; flock -n 9 ) 2>/dev/null; then GOT=1; break; fi
  sleep 0.1
done
[ "$GOT" = 1 ] \
  && ok || bad "the build slot is STILL locked 0.5s after the build exited — the beater's orphaned sleep holds fd 8 for the rest of its interval, and the next ticket gets BUILD_DEFERRED"
{ [ "$GOT" = 1 ] && [ "$TRIES" -le 2 ]; } \
  && ok || bad "the slot took ${TRIES}00ms to come free — a stopped beater must not hold it at all"

B1=$(cat "$T/beat1.pid" 2>/dev/null)
{ [ -n "$B1" ] && ! proc_alive "$B1"; } \
  && ok || bad "the beat loop (${B1:-?}) is still alive after job_beat_stop"

# --- 2. no sleep child survives job_beat_stop --------------------------------
# A long interval so the child is unambiguously the sleep, recorded while it is
# still attached to the loop: once the loop dies an orphan is reparented and no
# ppid query can find it again.
: > "$T/kids.txt"
run_caller '
  . "'"$T"'/bin/jobs-client.sh"
  B=$(job_beat_start job-2 60) || exit 8
  printf "%s\n" "$B" > "'"$T"'/beat2.pid"
  sleep 0.6
  { pgrep -P "$B" 2>/dev/null || ps -A -o pid=,ppid= 2>/dev/null | awk -v p="$B" "\$2==p {print \$1}"; } > "'"$T"'/kids.txt"
  job_beat_stop "$B"
'
KIDS=$(tr '\n' ' ' < "$T/kids.txt" 2>/dev/null)
[ -n "$(printf '%s' "$KIDS" | tr -d ' ')" ] \
  && ok || bad "no child of the beat loop was observed — the test cannot prove anything about orphans"
sleep 0.4
SURVIVORS=""
for K in $KIDS; do proc_alive "$K" && SURVIVORS="$SURVIVORS $K"; done
[ -z "$SURVIVORS" ] \
  && ok || bad "a sleep child ($SURVIVORS) outlived job_beat_stop — it still holds every descriptor the caller had open"
B2=$(cat "$T/beat2.pid" 2>/dev/null)
{ [ -n "$B2" ] && ! proc_alive "$B2"; } \
  && ok || bad "the beat loop (${B2:-?}) survived job_beat_stop"

# --- 3. it still beats -------------------------------------------------------
# Shedding descriptors must not cost the heartbeat: a silent beater makes every
# live job look dead to bin/jobs-watchdog.sh.
: > "$T/req.txt"
run_caller '
  . "'"$T"'/bin/jobs-client.sh"
  B=$(job_beat_start job-3 1) || exit 8
  sleep 2.6   # determinism: ok elapsed time is the assertion: a 1s beater must beat inside it
  job_beat_stop "$B"
'
BEATS=$(grep -c '/heartbeat' "$T/req.txt" 2>/dev/null)
[ "${BEATS:-0}" -ge 1 ] \
  && ok || bad "the beater sent no heartbeat in 2.6s at a 1s interval (got ${BEATS:-0})"

echo "heartbeat-lock-release: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
