#!/bin/bash
# tests/lane-reaper.bh-1770-test.sh — the reap deadline is PER LANE (BH-1770
# part B1, the #1142 item 7 remainder; the operator's decision 2026-09-24).
#
# THE DEFECT. bin/lane-reaper.sh killed every run-build.sh lane at the same
# flat 4h30m (expected_by = started_at + LANE_EXPECTED_SECS 14400, plus
# LANE_REAP_GRACE_SECS 1800), including a project whose builds are legitimately
# long. The decision: a registry knob, LANE_REAP_DEADLINE_SECS on the
# lane-reaper lane, default 16200, with a DB settings row that overrides it —
# per build lane (lane.lane-reaper.<project>.lane_reap_deadline_secs) or fleet
# wide (lane.lane-reaper.lane_reap_deadline_secs).
#
# What is pinned, on the REAL reaper against REAL setsid'd lanes (the fixture is
# tests/lane-reaper.bh-1142-test.sh's):
#   D1  no row: a run 4h31m old is reaped            (the default is 4h30m)
#   D2  no row: a run 4h29m old is not
#   D3  a project row of 12h spares that project's 5h-old run; a SIBLING
#       project's 5h-old run is still reaped (per lane, not fleet)
#   D4  a fleet row of 2h reaps a 3h-old run
#   D5  a row below the registry min is clamped, never obeyed as written
#   D6  a legacy dir (started_at 0 — no build writes that) keeps the old
#       expected_by + LANE_REAP_GRACE_SECS rule
#   D7  an operator's legacy LANE_EXPECTED_SECS + LANE_REAP_GRACE_SECS total
#       carries over as the new knob's env tier; a settings row still beats it
#   D8  RESULT names the deadline that applied
#   D9  the alert names the relaunch owner: bin/blocked-resolver.sh
#   D10 the per-lane row is WRITABLE: `bin/harness-ctl.sh set lane-reaper
#       LANE_REAP_DEADLINE_SECS <secs> <project>` writes the project key, on a
#       lane that is box-scoped — and a knob that does not declare
#       project_scoped is still refused a project
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lane-reaper.bh-1770-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
REG=$(rendered_registry)
NOW=$(date +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }

LANEPIDS="$SCRATCH/lane-pids"
: > "$LANEPIDS"
# This trap replaces tests/lib/rendered.sh's, so it reads rendered_verdict
# itself, before scratch_cleanup deletes the marker (BH-2263).
cleanup() {
  local rc=$? p
  while read -r p; do
    [ -n "$p" ] || continue
    kill -9 -- "-$p" 2>/dev/null
    kill -9 "$p" 2>/dev/null
  done < "$LANEPIDS"
  rendered_verdict || { [ "$rc" -eq 0 ] && rc=1; }
  scratch_cleanup
  exit "$rc"
}
trap cleanup EXIT

alive() {
  kill -0 "$1" 2>/dev/null || return 1
  [ "$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $1}')" != Z ]
}
pgid_of() { sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $3}'; }

BODY='echo $$ > "$1"
sleep 600 & wait'

fresh() { # a scratch $HARNESS with the lane gate, a stub worker and recording sinks
  T=$(mktemp -d "$SCRATCH/case.XXXXXX")
  export HARNESS="$T"
  mkdir -p "$T/builds" "$T/logs" "$T/locks" "$T/flags" "$T/state/claims" "$T/bin/lib"
  cp "$DIR/bin/lib/scheduler-conf.sh" "$DIR/bin/lib/lane-gate.sh" "$T/bin/lib/"
  ALERT_SINK="$T/alert-sink"; JOBS_SINK="$T/jobs-sink"
  cat > "$T/bin/lane-alert.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$ALERT_SINK"
EOF
  chmod +x "$T/bin/lane-alert.sh"
  # /api/settings answers the rows in $ROWS; every other path is an outage, and
  # the gate fails OPEN on those.
  cat > "$T/bin/jobs-client.sh" <<EOF
job_update() { echo "\$*" >> "$JOBS_SINK"; }
_jobs_req() {
  case "\$2" in
    /api/settings)
      local out="[]" kv
      for kv in \${ROWS:-}; do
        out=\$(printf '%s' "\$out" | jq -c --arg k "\${kv%%=*}" --arg v "\${kv#*=}" '. + [{key:\$k,value:\$v,actor:"t"}]')
      done
      printf '{"settings":%s}' "\$out" ;;
    *) return 1 ;;
  esac
}
EOF
  : > "$T/bin/run-build.sh"
  SCRIPT_OK="$T/bin/run-build.sh"
}

lane_start() { # lane_start <fake-argv0> <build-dir> -> the lane pid
  local argv="$1" d="$2" s pf pid="" i=0
  s=$(mktemp "$T/lane.XXXXXX"); pf=$(mktemp "$T/lanepid.XXXXXX")
  printf '%s\n%s\n' '#!/bin/bash' "$BODY" > "$s"
  setsid --fork bash -c 'exec -a "$1" bash "$2" "$3" "$4"' _ "$argv" "$s" "$pf" "$d" >/dev/null 2>&1
  while [ "$i" -lt 200 ]; do
    pid=$(head -1 "$pf" 2>/dev/null)
    [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] && break
    sleep 0.05; i=$((i+1))
  done
  [ -n "$pid" ] && printf '%s\n' "$pid" >> "$LANEPIDS"
  printf '%s\n' "$pid"
}

# lane <project> <key> <age-seconds> [started_at-override] [expected_by-override]
#   A live run-build.sh lane of <project>/<key> that started <age> seconds ago.
#   expected_by is what bin/run-build.sh writes by default: started + 14400.
#   Sets D (the build dir) and P (the lane pid).
lane() {
  local pj="$1" key="$2" age="$3" st exp
  st="${4:-$((NOW - age))}"; exp="${5:-$((NOW - age + 14400))}"
  D="$HARNESS/builds/$pj-$key-202609240000"; mkdir -p "$D"
  P=$(lane_start "/root/harness/bin/run-build.sh $pj t1 $key" "$D")
  mkdir -p "$HARNESS/state/claims/$pj"; echo held > "$HARNESS/state/claims/$pj/$key"
  jq -nc --arg p "$pj" --arg k "$key" --arg sc "$SCRIPT_OK" \
     --argjson pid "$P" --argjson pgid "$(pgid_of "$P")" --argjson st "$st" --argjson exp "$exp" \
     '{project:$p,ticket_id:"t1",key:$k,created_at:"2026-09-24",pid:$pid,pgid:$pgid,
       script:$sc,started_at:$st,expected_by:$exp,job_id:"J1770"}' > "$D/job.json"
}

REAP() { env LANE_REGISTRY="$REG" LANE_REAP_KILL_WAIT_S=2 ROWS="${ROWS:-}" "$@" \
           "$DIR/bin/lane-reaper.sh" >/dev/null 2>&1; }
reaped()     { [ -f "$1/REAPED" ] && ! alive "$2"; }
not_reaped() { [ ! -f "$1/REAPED" ] && [ ! -f "$1/RESULT" ] && alive "$2"; }

# ---------- D1 / D2: the default is the old 4h30m, now a registry default -----
fresh; ROWS=""
lane p1 BH-701 $((16200 + 60)); D1=$D; P1=$P
lane p1 BH-702 $((16200 - 60)); D2=$D; P2=$P
REAP
reaped "$D1" "$P1" && ok || bad "D1 a run 4h31m old with no row must be reaped (RESULT: $(cat "$D1/RESULT" 2>/dev/null))"
not_reaped "$D2" "$P2" && ok || bad "D2 a run 4h29m old with no row must be left alone (RESULT: $(cat "$D2/RESULT" 2>/dev/null))"

# ---------- D8 / D9: what the reap SAYS -------------------------------------
case "$(head -1 "$D1/RESULT" 2>/dev/null)" in
  "ABANDONED_TIMEOUT "*"deadline"*) ok ;;
  *) bad "D8 RESULT must name the deadline that applied, got '$(head -1 "$D1/RESULT" 2>/dev/null)'" ;;
esac
grep -q 'LANE_REAP_DEADLINE_SECS' "$D1/RESULT" 2>/dev/null && ok \
  || bad "D8 RESULT must name the knob an operator would change, got '$(head -1 "$D1/RESULT" 2>/dev/null)'"
grep -q 'bin/blocked-resolver.sh' "$ALERT_SINK" 2>/dev/null && ok \
  || bad "D9 the alert must name bin/blocked-resolver.sh as the relaunch owner, got: $(cat "$ALERT_SINK" 2>/dev/null)"
[ "$(grep -c . "$ALERT_SINK" 2>/dev/null)" = 1 ] && ok \
  || bad "D9 exactly one alert for one reap, got $(grep -c . "$ALERT_SINK" 2>/dev/null)"

# ---------- D3: a PROJECT row is per lane -----------------------------------
fresh; ROWS="lane.lane-reaper.p1.lane_reap_deadline_secs=43200"
lane p1 BH-703 $((5 * 3600)); D3=$D; P3=$P
lane p2 BH-704 $((5 * 3600)); D4=$D; P4=$P
REAP
not_reaped "$D3" "$P3" && ok \
  || bad "D3 p1's 12h row must spare p1's 5h-old run (RESULT: $(cat "$D3/RESULT" 2>/dev/null))"
reaped "$D4" "$P4" && ok \
  || bad "D3 p2 has no row: its 5h-old run must still be reaped at the 4h30m default"

# ---------- D4: a FLEET row -------------------------------------------------
fresh; ROWS="lane.lane-reaper.lane_reap_deadline_secs=7200"
lane p1 BH-705 $((3 * 3600)); D5=$D; P5=$P
lane p1 BH-706 $((1 * 3600)); D6=$D; P6=$P
REAP
reaped "$D5" "$P5" && ok || bad "D4 a fleet row of 2h must reap a 3h-old run"
not_reaped "$D6" "$P6" && ok || bad "D4 a fleet row of 2h must spare a 1h-old run"
# the project row still beats the fleet row
fresh; ROWS="lane.lane-reaper.lane_reap_deadline_secs=7200 lane.lane-reaper.p1.lane_reap_deadline_secs=43200"
lane p1 BH-707 $((3 * 3600)); D7=$D; P7=$P
REAP
not_reaped "$D7" "$P7" && ok || bad "D4 the project row must beat the fleet row"

# ---------- D5: a row below the registry min is CLAMPED ----------------------
fresh; ROWS="lane.lane-reaper.p1.lane_reap_deadline_secs=60"
lane p1 BH-708 600; D8=$D; P8=$P        # 10 minutes: under the 1800s floor
lane p1 BH-709 2400; D9=$D; P9=$P       # 40 minutes: over it
REAP
not_reaped "$D8" "$P8" && ok || bad "D5 a 60s row must be clamped to the registry min, not reap a 10m-old run"
reaped "$D9" "$P9" && ok || bad "D5 the clamped deadline (1800s) must still reap a 40m-old run"
grep -q 'CLAMPED' "$HARNESS/logs/lane-gate.log" 2>/dev/null && ok \
  || bad "D5 the clamp must be logged: $(cat "$HARNESS/logs/lane-gate.log" 2>/dev/null)"

# ---------- D6: a legacy dir keeps the legacy rule --------------------------
fresh; ROWS="lane.lane-reaper.p1.lane_reap_deadline_secs=43200"
lane p1 BH-710 0 0 $((NOW - 3600)); D10=$D; P10=$P   # started_at 0, expected_by an hour ago
lane p1 BH-711 0 0 "$NOW";          D11=$D; P11=$P   # started_at 0, expected_by now
REAP
reaped "$D10" "$P10" && ok || bad "D6 a started_at-less dir an hour past expected_by (+30m grace) must still be reaped"
not_reaped "$D11" "$P11" && ok || bad "D6 a started_at-less dir inside its grace must be left alone"

# ---------- D7: an operator's legacy tuning carries over ---------------------
fresh; ROWS=""
printf 'LANE_EXPECTED_SECS=36000\n' > "$HARNESS/flags/scheduler.conf"   # 10h + the 30m grace
lane p1 BH-712 $((5 * 3600)); D12=$D; P12=$P
REAP
not_reaped "$D12" "$P12" && ok \
  || bad "D7 a box that set LANE_EXPECTED_SECS=36000 must keep its 10h30m deadline (RESULT: $(cat "$D12/RESULT" 2>/dev/null))"
fresh; ROWS="lane.lane-reaper.lane_reap_deadline_secs=7200"
printf 'LANE_EXPECTED_SECS=36000\n' > "$HARNESS/flags/scheduler.conf"
lane p1 BH-713 $((3 * 3600)); D13=$D; P13=$P
REAP
reaped "$D13" "$P13" && ok || bad "D7 a settings row must beat the legacy scheduler.conf total"

# ---------- D10: the per-lane row can be written from the CLI ----------------
C="$SCRATCH/ctl"; mkdir -p "$C/bin/lib" "$C/catalog" "$C/flags" "$C/env" "$C/logs" "$C/state"
cp "$DIR/bin/harness-ctl.sh" "$C/bin/"
cp "$DIR/bin/lib/env-path.sh" "$C/bin/lib/" 2>/dev/null || true
cp "$REG" "$C/catalog/lanes.json"
cat > "$C/bin/jobs-client.sh" <<'SH'
JOBS_BOX=testbox
flag_set()    { echo "flag_set $1 $2 $3" >> "$OPS"; }
setting_set() { echo "setting_set $1 $2" >> "$OPS"; }
_jobs_req()   { echo "req $1 $2 ${3:-}" >> "$OPS"; return 1; }
SH
# `set … <project>` refuses a project fleet.conf does not list (BH-1985).
printf 'project-4 example-org/project-4 x\n' > "$C/fleet.conf"
ctl() { env -u FLEET_CONF HARNESS="$C" OPS="$C/ops" bash "$C/bin/harness-ctl.sh" "$@" 2>&1; }
: > "$C/ops"; OUT=$(ctl set lane-reaper LANE_REAP_DEADLINE_SECS 43200 project-4); RC=$?
[ "$RC" = 0 ] && grep -qx 'setting_set lane.lane-reaper.project-4.lane_reap_deadline_secs 43200' "$C/ops" && ok \
  || bad "D10 set with a project must write lane.lane-reaper.project-4.lane_reap_deadline_secs: rc=$RC out=$OUT ops=$(cat "$C/ops")"
: > "$C/ops"; OUT=$(ctl set lane-reaper LANE_REAP_DEADLINE_SECS 60 project-4); RC=$?
[ "$RC" != 0 ] && [ ! -s "$C/ops" ] && ok || bad "D10 a value below the registry min must be refused: rc=$RC out=$OUT"
: > "$C/ops"; OUT=$(ctl set lane-reaper LANE_REAP_KILL_WAIT_S 10 project-4); RC=$?
[ "$RC" != 0 ] && [ ! -s "$C/ops" ] && ok \
  || bad "D10 a knob with no project_scoped must still refuse a project on a box lane: rc=$RC out=$OUT"

echo "lane-reaper.bh-1770-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
