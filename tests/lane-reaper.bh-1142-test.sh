#!/bin/bash
# tests/lane-reaper.bh-1142-test.sh — BH-1142 item 1: a RETRY dir whose pid is
# still a live run-build.sh lane of the SAME key, but in a different process
# group than the one recorded, is unsignalable, not gone. Finishing that reap
# would release the claim, close the ledger row and alert "the kill landed" for
# a lane that is still running.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lane-reaper.bh-1142-test.sh
# (exit 0 = all pass).
#
# The fixture is a trimmed copy of tests/lane-reaper-test.sh's: real setsid'd
# lanes whose argv[0] is a run-build.sh command line, the REAL reaper, and the
# assertions are RESULT, REAPED, the claim file, the sinks, the log and the pid.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NOW=$(date +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Every pid started here, in a FILE (lane_start runs in a command substitution).
LANEPIDS="$SCRATCH/lane-pids"
: > "$LANEPIDS"
cleanup() {
  local p
  while read -r p; do
    [ -n "$p" ] || continue
    kill -9 -- "-$p" 2>/dev/null
    kill -9 "$p" 2>/dev/null
  done < "$LANEPIDS"
  scratch_cleanup
}
trap cleanup EXIT

alive() {
  kill -0 "$1" 2>/dev/null || return 1
  [ "$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $1}')" != Z ]
}
pgid_of() { sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $3}'; }

BODY_DEFAULT='echo $$ > "$1"
sleep 600 & wait'

fresh() { # scratch $HARNESS with recording stubs; sets T, ALERT_SINK, JOBS_SINK
  T=$(mktemp -d "$SCRATCH/case.XXXXXX")
  export HARNESS="$T"
  mkdir -p "$T/builds" "$T/logs" "$T/locks" "$T/flags" "$T/state/claims" "$T/bin/lib"
  cp "$DIR/bin/lib/scheduler-conf.sh" "$T/bin/lib/scheduler-conf.sh"
  ALERT_SINK="$T/alert-sink"; JOBS_SINK="$T/jobs-sink"
  cat > "$T/bin/lane-alert.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$ALERT_SINK"
EOF
  chmod +x "$T/bin/lane-alert.sh"
  cat > "$T/bin/jobs-client.sh" <<EOF
job_update() { echo "\$*" >> "$JOBS_SINK"; }
EOF
  # A scratch file, never the repo driver (rb-modules-source-test (f) seam guard).
  : > "$T/bin/run-build.sh"
  SCRIPT_OK="$T/bin/run-build.sh"
}

lane_start() { # lane_start <fake-argv0> <build-dir> <body> -> the lane pid
  local argv="$1" d="$2" body="$3" s pf pid="" i=0
  s=$(mktemp "$T/lane.XXXXXX"); pf=$(mktemp "$T/lanepid.XXXXXX")
  printf '%s\n%s\n' '#!/bin/bash' "$body" > "$s"
  setsid --fork bash -c 'exec -a "$1" bash "$2" "$3" "$4"' _ "$argv" "$s" "$pf" "$d" >/dev/null 2>&1
  while [ "$i" -lt 200 ]; do
    pid=$(head -1 "$pf" 2>/dev/null)
    [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] && break
    sleep 0.05; i=$((i+1))
  done
  [ -n "$pid" ] && printf '%s\n' "$pid" >> "$LANEPIDS"
  printf '%s\n' "$pid"
}

mkjob() { # mkjob <dir> <project> <key> <pid> <pgid> <script> <expected_by> [job_id]
  jq -nc --arg p "$2" --arg k "$3" --arg sc "$6" --arg j "${8:-}" \
     --argjson pid "$4" --argjson pgid "$5" --argjson exp "$7" \
     '{project:$p,ticket_id:"t1",key:$k,created_at:"2026-09-23",
       pid:$pid,pgid:$pgid,script:$sc,started_at:0,expected_by:$exp}
      | (if $j == "" then . else . + {job_id:$j} end)' > "$1/job.json"
}

sink_lines() { grep -c . "$ALERT_SINK" 2>/dev/null || echo 0; }
REAP() { LANE_REAP_KILL_WAIT_S=2 "$DIR/bin/lane-reaper.sh" >/dev/null 2>&1; }
LOG() { cat "$HARNESS/logs/lane-reaper.log" 2>/dev/null; }

# setup <dirname> <cmdline key> <recorded key> <pgid offset> <with RESULT 0|1>
# A live lane whose argv carries <cmdline key>, a job.json recording
# <recorded key> and the lane's real pgid plus <pgid offset>, a held claim, and
# (optionally) our own ABANDONED_TIMEOUT verdict on disk with no REAPED.
setup() {
  D="$HARNESS/builds/$1"; mkdir -p "$D"
  P=$(lane_start "/root/harness/bin/run-build.sh p1 t1 $2" "$D" "$BODY_DEFAULT")
  mkdir -p "$HARNESS/state/claims/p1"; echo held > "$HARNESS/state/claims/p1/$3"
  mkjob "$D" p1 "$3" "$P" "$(( $(pgid_of "$P") + $4 ))" "$SCRIPT_OK" "$((NOW - 3600))" J1142
  if [ "$5" = 1 ]; then
    VERDICT="ABANDONED_TIMEOUT past expected-by by 61m"
    echo "$VERDICT" > "$D/RESULT"
  fi
}

# ---------- R1 same KEY, pgid mismatch, our verdict on disk: NOT finished ----
fresh
setup p1-BH-670-a BH-670 BH-670 1 1
REAP
alive "$P" && ok || bad "R1 the live same-KEY lane was signalled (pid $P)"
[ ! -f "$D/REAPED" ] && ok || bad "R1 a live same-KEY lane was marked REAPED"
[ -f "$HARNESS/state/claims/p1/BH-670" ] && ok || bad "R1 the claim of a live lane was released"
[ "$(sink_lines)" = 0 ] && ok || bad "R1 an alert said the kill landed: $(cat "$ALERT_SINK" 2>/dev/null)"
grep -q 'status=failed' "$JOBS_SINK" 2>/dev/null && bad "R1 the ledger row of a live lane was closed: $(cat "$JOBS_SINK")" || ok
[ "$(head -1 "$D/RESULT")" = "$VERDICT" ] && [ "$(grep -c . "$D/RESULT")" = 1 ] && ok \
  || bad "R1 RESULT changed: $(cat "$D/RESULT")"

# ---------- R2 ...logged once per tick, and still not finished next tick ----
[ "$(LOG | grep -c 'process group.*not reaped')" = 1 ] && ok \
  || bad "R2 expected one 'process group ... not reaped' line: $(LOG)"
LOG | grep -q "live BH-670 lane" && ok || bad "R2 the log line does not name the live lane: $(LOG)"
REAP
[ ! -f "$D/REAPED" ] && [ -f "$HARNESS/state/claims/p1/BH-670" ] && [ "$(sink_lines)" = 0 ] && alive "$P" && ok \
  || bad "R2 the second tick finished the reap (REAPED: $([ -f "$D/REAPED" ] && echo yes), sink: $(sink_lines))"
[ "$(LOG | grep -c 'process group.*not reaped')" = 2 ] && ok \
  || bad "R2 the second tick did not log the refusal again: $(LOG)"

# ---------- R3 same shape, no RESULT (not a retry): not signalled, logged ----
fresh
setup p1-BH-671-a BH-671 BH-671 1 0
REAP
alive "$P" && [ ! -f "$D/RESULT" ] && [ ! -f "$D/REAPED" ] && [ "$(sink_lines)" = 0 ] && ok \
  || bad "R3 a stale recorded pgid was acted on"
[ -f "$HARNESS/state/claims/p1/BH-671" ] && ok || bad "R3 claim released"
LOG | grep -q 'process group' && ok || bad "R3 pgid mismatch was not logged: $(LOG)"

# ---------- R4 control: a DIFFERENT key on the reused pid still finishes ----
fresh
setup p1-BH-672-a BH-67 BH-672 0 1
REAP
alive "$P" && ok || bad "R4 the process holding the reused pid was signalled"
[ -f "$D/REAPED" ] && [ ! -f "$HARNESS/state/claims/p1/BH-672" ] && [ "$(sink_lines)" = 1 ] && ok \
  || bad "R4 a different-KEY reuse left the reap unfinished (REAPED: $([ -f "$D/REAPED" ] && echo yes), sink: $(sink_lines))"
grep -q 'J1142 status=failed' "$JOBS_SINK" 2>/dev/null && ok || bad "R4 ledger row not closed: $(cat "$JOBS_SINK" 2>/dev/null)"

echo "lane-reaper.bh-1142-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
