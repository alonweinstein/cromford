#!/bin/bash
# tests/lane-reaper-test.sh — assertions for bin/lane-reaper.sh (#648, the
# BH-643 stale-lane reaper).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lane-reaper-test.sh
# (exit 0 = all pass).
#
# Every case runs the REAL script against a scratch $HARNESS holding REAL
# backgrounded processes: a lane here is a setsid'd bash whose argv[0] is a
# run-build.sh command line, so /proc/<pid>/cmdline carries what the reaper
# checks before it signals anything. Nothing is extracted, nothing is grepped
# out of the source — the assertions are RESULT, REAPED, the claim file, the
# alert sink, the jobs sink, the log, and whether the pid is still there.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NOW=$(date +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Every pid this file starts, recorded in a FILE and not a variable: lane_start
# is only ever called inside a command substitution, so an append to a shell
# variable would land in that subshell and the trap would kill nothing. The file
# lives at the top of $SCRATCH, so the per-case mktemp -d trees do not take it
# with them. Each lane is its own process group (setsid), so the group kill takes
# the lane's children too — the TERM-immune body forks a sleep five times a
# second and would otherwise outlive the run forever.
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

# A pid that exists and is not a zombie. A reaped orphan stays in the process
# table until init collects it, and "still listed" is not "still running".
alive() {
  kill -0 "$1" 2>/dev/null || return 1
  [ "$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $1}')" != Z ]
}
pgid_of() { sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $3}'; }

# Lane bodies. $1 is the pidfile, $2 the build dir. None of them exec, so the
# process keeps the fake argv[0] the launcher gave it.
BODY_DEFAULT='echo $$ > "$1"
sleep 600 & wait'
BODY_SAW=$(cat <<'EOS'
trap '[ -f "$2/RESULT" ] && touch "$2/SAW_RESULT_AT_TERM"; exit 0' TERM
echo $$ > "$1"
sleep 600 & wait
EOS
)
BODY_TERM_IMMUNE=$(cat <<'EOS'
trap '' TERM
echo $$ > "$1"
while :; do sleep 0.2; done
EOS
)

fresh() { # scratch $HARNESS with an alert-recording stub; sets T, ALERT_SINK, JOBS_SINK
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
  # A recorded script path that really is on disk. The reaper only ever asks
  # `[ -e ]` of it, so this is a scratch file, not the repo's driver: pointing
  # it at $DIR/bin/run-build.sh would make this suite a raw reader of the
  # driver, which the BH-568 seam guard (tests/rb-modules-source-test.sh (f))
  # allows only for the two suites that must execute or grade it.
  : > "$T/bin/run-build.sh"
  SCRIPT_OK="$T/bin/run-build.sh"
  SCRIPT_GONE="$T/deleted-checkout/bin/run-build.sh"
}

with_jobs_client() { # a jobs-client whose job_update records instead of calling out
  cat > "$HARNESS/bin/jobs-client.sh" <<EOF
job_update() { echo "\$*" >> "$JOBS_SINK"; }
EOF
}

lane_start() { # lane_start <fake-argv0> <build-dir> <body> -> the lane pid
  local argv="$1" d="$2" body="$3" s pf pid="" i=0
  s=$(mktemp "$T/lane.XXXXXX"); pf=$(mktemp "$T/lanepid.XXXXXX")
  printf '%s\n%s\n' '#!/bin/bash' "$body" > "$s"
  # exec -a so the lane's /proc cmdline is the run-build.sh command line the
  # reaper matches on; setsid so it owns its process group, like a real lane.
  setsid --fork bash -c 'exec -a "$1" bash "$2" "$3" "$4"' _ "$argv" "$s" "$pf" "$d" >/dev/null 2>&1
  while [ "$i" -lt 200 ]; do
    pid=$(head -1 "$pf" 2>/dev/null)
    [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] && break
    sleep 0.05; i=$((i+1))
  done
  [ -n "$pid" ] && printf '%s\n' "$pid" >> "$LANEPIDS"
  printf '%s\n' "$pid"
}

mkjob() { # mkjob <dir> <project> <key> <pid> <pgid> <script> <expected_by|null> [job_id]
  jq -nc --arg p "$2" --arg k "$3" --arg sc "$6" --arg j "${8:-}" \
     --argjson pid "$4" --argjson pgid "$5" --argjson exp "$7" \
     '{project:$p,ticket_id:"t1",key:$k,created_at:"2026-09-18",
       pid:$pid,pgid:$pgid,script:$sc,started_at:0,expected_by:$exp}
      | (if $j == "" then . else . + {job_id:$j} end)
      | (if .expected_by == null then del(.expected_by) else . end)' > "$1/job.json"
}

mklane() { # mklane <dirname> <project> <key> <expected_by> [body] [job_id] [script] -> the dir
  local d="$HARNESS/builds/$1" pid pgid
  mkdir -p "$d"
  pid=$(lane_start "/root/harness/bin/run-build.sh $2 t1 $3" "$d" "${5:-$BODY_DEFAULT}")
  pgid=$(pgid_of "$pid")
  mkdir -p "$HARNESS/state/claims/$2"
  echo "bin/lane-reaper.sh" > "$HARNESS/state/claims/$2/$3"
  mkjob "$d" "$2" "$3" "${pid:-null}" "${pgid:-null}" "${7:-$SCRIPT_OK}" "$4" "${6:-}"
  printf '%s\n' "$d"
}

pid_of() { jq -r '.pid // ""' "$1/job.json" 2>/dev/null; }
sink_lines() { grep -c . "$ALERT_SINK" 2>/dev/null || echo 0; }
REAP() { LANE_REAP_KILL_WAIT_S=2 "$DIR/bin/lane-reaper.sh" >/dev/null 2>&1; }

# ---------- §1 a lane past its deadline is reaped, once ----------------------
fresh; with_jobs_client
D1=$(mklane p1-BH-648-a p1 BH-648 $((NOW - 3600)) "" J1)
P1=$(pid_of "$D1")
REAP
alive "$P1" && bad "§1 past-deadline lane still running (pid $P1)" || ok
[ ! -f "$HARNESS/state/claims/p1/BH-648" ] && ok || bad "§1 claim not released"
head -1 "$D1/RESULT" 2>/dev/null | grep -q '^ABANDONED_TIMEOUT past expected-by by' && ok \
  || bad "§1 RESULT is not the timeout verdict: $(head -1 "$D1/RESULT" 2>/dev/null)"
[ -f "$D1/REAPED" ] && ok || bad "§1 no REAPED marker"
[ "$(sink_lines)" = 1 ] && grep -q -- "--id lane-reaper:p1:BH-648" "$ALERT_SINK" && ok \
  || bad "§1 alert sink should hold exactly one lane-reaper line: $(cat "$ALERT_SINK" 2>/dev/null)"
grep -q 'J1 status=failed' "$JOBS_SINK" 2>/dev/null && ok \
  || bad "§1 ledger row not closed as failed: $(cat "$JOBS_SINK" 2>/dev/null)"
REAP   # second tick: nothing left to do, nothing new said
[ "$(sink_lines)" = 1 ] && ok || bad "§1 second run wrote another alert line"
[ "$(grep -c 'reaping pid' "$HARNESS/logs/lane-reaper.log" 2>/dev/null)" = 1 ] && ok \
  || bad "§1 second run reaped the dir again: $(grep -c 'reaping pid' "$HARNESS/logs/lane-reaper.log" 2>/dev/null)"

# ---------- §1b the verdict is on disk BEFORE the signal --------------------
# The lane's own EXIT trap closes its ledger row against whatever RESULT says,
# so a RESULT written after the kill is a row closed against nothing.
fresh
D1B=$(mklane p1-BH-648-b p1 BH-648 $((NOW - 3600)) "$BODY_SAW")
REAP
[ -f "$D1B/SAW_RESULT_AT_TERM" ] && ok \
  || bad "§1b RESULT did not exist when the lane got SIGTERM"

# ---------- §2 a lane inside its deadline is left alone ---------------------
fresh
D2=$(mklane p1-BH-649-a p1 BH-649 $((NOW + 600)))
P2=$(pid_of "$D2")
REAP
alive "$P2" && ok || bad "§2 lane inside its deadline was killed"
[ ! -f "$D2/RESULT" ] && [ ! -f "$D2/REAPED" ] && [ "$(sink_lines)" = 0 ] && ok \
  || bad "§2 lane inside its deadline was touched"

# ---------- §3 a lane whose checkout vanished is reaped now -----------------
fresh
D3=$(mklane p1-BH-650-a p1 BH-650 $((NOW + 600)) "" "" "$SCRIPT_GONE")
P3=$(pid_of "$D3")
REAP
alive "$P3" && bad "§3 lane with a deleted script path still running" || ok
head -1 "$D3/RESULT" 2>/dev/null | grep -q '^ABANDONED_TIMEOUT script path gone' && ok \
  || bad "§3 wrong verdict: $(head -1 "$D3/RESULT" 2>/dev/null)"
[ -f "$D3/REAPED" ] && [ "$(sink_lines)" = 1 ] && ok \
  || bad "§3 not reaped/announced (REAPED: $([ -f "$D3/REAPED" ] && echo yes), sink: $(sink_lines))"
[ ! -f "$HARNESS/state/claims/p1/BH-650" ] && ok || bad "§3 claim not released"

# ---------- §4 a dead pid belongs to resume-dead-builds.sh ------------------
fresh
D4=$(mklane p1-BH-651-a p1 BH-651 $((NOW - 3600)))
P4=$(pid_of "$D4")
kill -9 "$P4" 2>/dev/null
I=0; while alive "$P4" && [ "$I" -lt 100 ]; do sleep 0.05; I=$((I+1)); done
REAP
[ ! -f "$D4/RESULT" ] && [ ! -f "$D4/REAPED" ] && [ "$(sink_lines)" = 0 ] && ok \
  || bad "§4 a dead pid was reaped (RESULT: $(head -1 "$D4/RESULT" 2>/dev/null))"
# ...and silently: every finished build on a box has a dead pid, and a lane that
# logged a line for each of them every ten minutes would bury its own findings.
[ ! -s "$HARNESS/logs/lane-reaper.log" ] && ok \
  || bad "§4 a dead pid should be skipped without a word: $(cat "$HARNESS/logs/lane-reaper.log")"

# ---------- §5 pid reuse: the cmdline must carry the key --------------------
fresh
D5="$HARNESS/builds/p1-BH-648-c"; mkdir -p "$D5"
P5=$(lane_start "/root/harness/bin/run-build.sh p1 t1 BH-64" "$D5" "$BODY_DEFAULT")
mkdir -p "$HARNESS/state/claims/p1"; echo x > "$HARNESS/state/claims/p1/BH-648"
mkjob "$D5" p1 BH-648 "$P5" "$(pgid_of "$P5")" "$SCRIPT_OK" "$((NOW - 3600))"
REAP
alive "$P5" && [ ! -f "$D5/RESULT" ] && [ "$(sink_lines)" = 0 ] && ok \
  || bad "§5 a pid whose cmdline key is only a prefix was signalled"
grep -q 'pid reuse' "$HARNESS/logs/lane-reaper.log" 2>/dev/null && ok \
  || bad "§5 pid-reuse skip was not logged: $(cat "$HARNESS/logs/lane-reaper.log" 2>/dev/null)"

# ---------- §5b the recorded pgid must be the live one ----------------------
fresh
D5B="$HARNESS/builds/p1-BH-652-a"; mkdir -p "$D5B"
P5B=$(lane_start "/root/harness/bin/run-build.sh p1 t1 BH-652" "$D5B" "$BODY_DEFAULT")
mkjob "$D5B" p1 BH-652 "$P5B" "$(( $(pgid_of "$P5B") + 1 ))" "$SCRIPT_OK" "$((NOW - 3600))"
REAP
alive "$P5B" && [ ! -f "$D5B/RESULT" ] && [ "$(sink_lines)" = 0 ] && ok \
  || bad "§5b a stale recorded pgid was signalled anyway"
grep -q 'process group' "$HARNESS/logs/lane-reaper.log" 2>/dev/null && ok \
  || bad "§5b pgid mismatch was not logged: $(cat "$HARNESS/logs/lane-reaper.log" 2>/dev/null)"

# ---------- §6 kill switch answers before any write -------------------------
fresh
touch "$HARNESS/flags/lane-reaper-off"
D6=$(mklane p1-BH-653-a p1 BH-653 $((NOW - 3600)))
P6=$(pid_of "$D6")
REAP
alive "$P6" && [ ! -f "$D6/RESULT" ] && [ "$(sink_lines)" = 0 ] && ok \
  || bad "§6 kill switch ignored"
[ ! -s "$HARNESS/logs/lane-reaper.log" ] && ok \
  || bad "§6 kill switch still wrote to the log: $(cat "$HARNESS/logs/lane-reaper.log")"

# ---------- §7 no jobs-client here: reap anyway, say so ---------------------
fresh
D7=$(mklane p1-BH-654-a p1 BH-654 $((NOW - 3600)) "" J7)
P7=$(pid_of "$D7")
REAP
alive "$P7" && bad "§7 lane survived a reap with no jobs-client" || ok
[ -f "$D7/REAPED" ] && [ "$(sink_lines)" = 1 ] && ok \
  || bad "§7 reap did not complete without a jobs-client (REAPED: $([ -f "$D7/REAPED" ] && echo yes), sink: $(sink_lines))"
grep -q 'watchdog' "$HARNESS/logs/lane-reaper.log" 2>/dev/null && ok \
  || bad "§7 open ledger row not named in the log: $(cat "$HARNESS/logs/lane-reaper.log" 2>/dev/null)"

# ---------- §8 absent is not zero -------------------------------------------
fresh
D8=$(mklane p1-BH-655-a p1 BH-655 null)           # no expected_by at all
P8=$(pid_of "$D8")
D8B="$HARNESS/builds/p1-BH-656-a"; mkdir -p "$D8B"
mkjob "$D8B" p1 BH-656 null null "$SCRIPT_OK" "$((NOW - 3600))"   # no pid
REAP
alive "$P8" && [ ! -f "$D8/RESULT" ] && [ ! -f "$D8B/RESULT" ] && [ "$(sink_lines)" = 0 ] && ok \
  || bad "§8 a missing pid/expected_by was treated as 0"
[ "$(grep -c 'unknown' "$HARNESS/logs/lane-reaper.log" 2>/dev/null)" = 2 ] && ok \
  || bad "§8 both unknown dirs should log: $(cat "$HARNESS/logs/lane-reaper.log" 2>/dev/null)"

# ---------- §9 LANE_REAP_MAX caps the tick and defers the rest --------------
fresh
echo "LANE_REAP_MAX=1" > "$HARNESS/flags/scheduler.conf"
D9A=$(mklane p1-BH-657-a p1 BH-657 $((NOW - 3600)))
D9B=$(mklane p1-BH-658-a p1 BH-658 $((NOW - 3600)))
REAP
R=0; [ -f "$D9A/REAPED" ] && R=$((R+1)); [ -f "$D9B/REAPED" ] && R=$((R+1))
[ "$R" = 1 ] && [ "$(sink_lines)" = 1 ] && ok \
  || bad "§9 cap of 1 reaped $R dirs, sink $(sink_lines)"
grep -q 'deferred' "$HARNESS/logs/lane-reaper.log" 2>/dev/null && ok \
  || bad "§9 deferred work was not logged: $(cat "$HARNESS/logs/lane-reaper.log" 2>/dev/null)"
REAP
[ -f "$D9A/REAPED" ] && [ -f "$D9B/REAPED" ] && [ "$(sink_lines)" = 2 ] && ok \
  || bad "§9 the deferred lane was dropped instead of re-offered"

# ---------- §10 pool-* and fly-* dirs are not ours --------------------------
fresh
DP="$HARNESS/builds/pool-x"; mkdir -p "$DP"
PP=$(lane_start "/root/harness/bin/run-build.sh p1 t1 BH-659" "$DP" "$BODY_DEFAULT")
mkjob "$DP" p1 BH-659 "$PP" "$(pgid_of "$PP")" "$SCRIPT_OK" "$((NOW - 3600))"
DF="$HARNESS/builds/fly-p1-BH-660-1"; mkdir -p "$DF"
PF=$(lane_start "/root/harness/bin/run-build.sh p1 t1 BH-660" "$DF" "$BODY_DEFAULT")
mkjob "$DF" p1 BH-660 "$PF" "$(pgid_of "$PF")" "$SCRIPT_OK" "$((NOW - 3600))"
REAP
alive "$PP" && alive "$PF" && [ ! -f "$DP/RESULT" ] && [ ! -f "$DF/RESULT" ] \
  && [ "$(sink_lines)" = 0 ] && ok || bad "§10 a pool-*/fly-* dir was reaped"

# ---------- §11 a lane that ignores SIGTERM still dies ----------------------
fresh
D11=$(mklane p1-BH-661-a p1 BH-661 $((NOW - 3600)) "$BODY_TERM_IMMUNE")
P11=$(pid_of "$D11")
REAP
alive "$P11" && bad "§11 a TERM-immune lane survived the reaper" || ok
[ -f "$D11/REAPED" ] && [ "$(sink_lines)" = 1 ] && ok \
  || bad "§11 KILLed lane not marked/announced (REAPED: $([ -f "$D11/REAPED" ] && echo yes), sink: $(sink_lines))"

# ---------- §12 somebody else's RESULT is never ours to act on --------------
fresh
D12=$(mklane p1-BH-662-a p1 BH-662 $((NOW - 3600)))
P12=$(pid_of "$D12")
echo "PR_CREATED https://github.com/example-org/cromford/pull/1" > "$D12/RESULT"
REAP
alive "$P12" && [ ! -f "$D12/REAPED" ] && [ "$(sink_lines)" = 0 ] && ok \
  || bad "§12 a dir with a foreign terminal RESULT was reaped"
head -1 "$D12/RESULT" | grep -q '^PR_CREATED' && ok || bad "§12 foreign RESULT was overwritten"

# ---------- §13 a reap we started and never confirmed is finished -----------
# Our verdict on disk, no REAPED, and the process it named is gone: that is a
# SIGKILL that landed after the sending tick gave up, or a reboot between the
# verdict and the marker. Nothing else on the box will release that claim or
# close that row, so this tick has to.
fresh; with_jobs_client
D13=$(mklane p1-BH-663-a p1 BH-663 $((NOW - 3600)) "" J13)
P13=$(pid_of "$D13")
echo "ABANDONED_TIMEOUT script path gone (/gone/bin/run-build.sh)" > "$D13/RESULT"
kill -9 "$P13" 2>/dev/null
I=0; while alive "$P13" && [ "$I" -lt 100 ]; do sleep 0.05; I=$((I+1)); done
REAP
[ -f "$D13/REAPED" ] && ok || bad "§13 an unfinished reap with a dead pid was left unfinished"
[ ! -f "$HARNESS/state/claims/p1/BH-663" ] && ok || bad "§13 claim still held after the kill landed"
[ "$(sink_lines)" = 1 ] && grep -q -- "--id lane-reaper:p1:BH-663" "$ALERT_SINK" && ok \
  || bad "§13 the finished reap was not announced exactly once: $(cat "$ALERT_SINK" 2>/dev/null)"
grep -q 'J13 status=failed' "$JOBS_SINK" 2>/dev/null && ok \
  || bad "§13 ledger row not closed as failed: $(cat "$JOBS_SINK" 2>/dev/null)"
head -1 "$D13/RESULT" | grep -q 'script path gone (/gone/bin/run-build.sh)' && ok \
  || bad "§13 the verdict on disk was rewritten: $(head -1 "$D13/RESULT")"
REAP   # and it stays finished
[ "$(sink_lines)" = 1 ] && ok || bad "§13 second run announced the same reap again"

# ---------- §13b ...even when the pid has been reused meanwhile -------------
fresh
D13B="$HARNESS/builds/p1-BH-664-a"; mkdir -p "$D13B"
P13B=$(lane_start "/root/harness/bin/run-build.sh p1 t1 BH-66" "$D13B" "$BODY_DEFAULT")
mkdir -p "$HARNESS/state/claims/p1"; echo x > "$HARNESS/state/claims/p1/BH-664"
mkjob "$D13B" p1 BH-664 "$P13B" "$(pgid_of "$P13B")" "$SCRIPT_OK" "$((NOW - 3600))"
echo "ABANDONED_TIMEOUT past expected-by by 61m" > "$D13B/RESULT"
REAP
alive "$P13B" && ok || bad "§13b the process now holding the reused pid was signalled"
[ -f "$D13B/REAPED" ] && [ ! -f "$HARNESS/state/claims/p1/BH-664" ] && [ "$(sink_lines)" = 1 ] && ok \
  || bad "§13b a reused pid left the reap unfinished (REAPED: $([ -f "$D13B/REAPED" ] && echo yes), sink: $(sink_lines))"

# ---------- §13c ...and a lane still breathing gets the kill again ----------
# Inside its deadline with its script present, so neither eligibility reason
# applies: it is the verdict on disk that makes this dir ours, and the reason in
# the alert comes from that verdict, not from a fresh judgement.
fresh
D13C=$(mklane p1-BH-665-a p1 BH-665 $((NOW + 600)))
P13C=$(pid_of "$D13C")
echo "ABANDONED_TIMEOUT past expected-by by 77m" > "$D13C/RESULT"
REAP
alive "$P13C" && bad "§13c the retried kill never landed" || ok
[ -f "$D13C/REAPED" ] && [ "$(sink_lines)" = 1 ] && ok \
  || bad "§13c retried kill not marked/announced (REAPED: $([ -f "$D13C/REAPED" ] && echo yes), sink: $(sink_lines))"
grep -q 'past expected-by by 77m' "$ALERT_SINK" && ok \
  || bad "§13c the alert did not carry the reason from the verdict: $(cat "$ALERT_SINK")"

echo "lane-reaper-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
