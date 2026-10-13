#!/bin/bash
# tests/lane-run-lease.bh-6125-test.sh — BH-6125 (BH-6047 part 2 of 5): the
# heartbeat loop of a lane run (bin/lib/lane-run-heartbeat.sh) and the death
# count, driven over real curl against the REAL jobs worker
# (tests/lib/lane-run-lease.bh-6125.mjs) and through the real
# bin/lane-run-worker.sh and bin/project-lane-run.sh.
#
#   H1  lrh_start beats every lane_run.heartbeat_s; lrh_stop ends the loop;
#       lrh_lost rc 1
#   H2  a 409 lost kills the run's whole process group; lrh_lost rc 0
#   H3  a transport failure, a 503, a 500 and a 409 that is not `lost` kill
#       nothing, and lrh_lost stays rc 1
#   H4  pgid "", 0, 1, -5 and this shell's own pid are never signalled
#   H5  a loop whose worker is gone stops beating
#   F3a A claims and never beats; after the lease B's worker claims the same
#       id, attempts 2, the run ends done on B; A's late report is refused
#   F3b A's worker beats; B takes the row over; A's run is killed and A sends
#       no report
#   W4s at lane_run.max_attempts=1 an expired row dies rc 137 and B's worker
#       runs nothing
#
# A lease expires through the fixture's /__expire hook, never by waiting.
# Run from anywhere: tests/lane-run-lease.bh-6125-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/lane-run-lease.bh-6125.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  && command -v setsid >/dev/null 2>&1 && command -v ps >/dev/null 2>&1 \
  || { echo "SKIP: node, jq, flock, setsid or ps missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags"
for L in bin/project-lane-run.sh bin/lane-run-worker.sh bin/fleet-conf.sh bin/jobs-client.sh \
         bin/alert-line.sh bin/lib/gh-app-auth.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null
[ -f "$H/bin/lib/lane-run-heartbeat.sh" ] && ok "the worker's closure installs bin/lib/lane-run-heartbeat.sh" \
  || bad "closure lacks bin/lib/lane-run-heartbeat.sh"
export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
export HARNESS_SECRET=fixture-harness-secret GH_TOKEN=tok-fixture-default
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 LANE_RUN_NOW=1791000000
export BOX_NAME=fixture-box
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\np2 o/p2 - - 2 box-p2 192.0.2.2\np3 o/p3 - - 2 box-p3 192.0.2.3\n' > "$H/fleet.conf"

# The fake lane: args <sleep seconds> <project>. Writes its pid, records the
# run, sleeps, exits 3.
cat > "$H/bin/fake-lane.sh" <<EOF
#!/bin/bash
p="\${@: -1}"
echo \$\$ > "$T/lane-\$p.pid"
printf '%s\t%s\n' "\$p" "\${LANE_RUN_ID:-hub}" >> "$T/runs.tsv"
sleep "\$1"
exit 3
EOF
chmod +x "$H/bin/fake-lane.sh"
: > "$T/runs.tsv"

: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
BG=()
trap 'for p in "${BG[@]}" "$SPID"; do kill "$p" 2>/dev/null; done' EXIT

api() { curl -sS -X POST -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' -d "$2" "$JOBS_URL$1"; }
apicode() { curl -sS -o "$T/apicode.out" -w '%{http_code}' -X POST -H "authorization: Bearer $HARNESS_SECRET" \
  -H 'content-type: application/json' -d "$2" "$JOBS_URL$1"; }
hook() { curl -sS -X "$1" -d "$3" "$JOBS_URL$2" > /dev/null; }
setting() { hook PUT /__setting "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')"; }
expire() { hook POST /__expire "{\"id\":$1}"; }
rowf() { curl -sS "$JOBS_URL/__lane_runs" | jq -r --argjson id "$1" ".rows[] | select(.id == \$id) | $2"; }
enqueue() { api /api/lane-runs "$(jq -nc --arg p "$1" --arg s "$2" '{lane:"demo",project:$p,args:["bin/fake-lane.sh",$s]}')" | jq -r .id; }
claim_as() { api /api/lane-runs/claim "{\"machine\":\"$1\"}" | jq -r '.id // empty'; }
# alive <pid> — the process exists and is not a zombie.
alive() { local s; s=$(ps -o stat= -p "$1" 2>/dev/null) || return 1; case "$s" in Z*|'') return 1 ;; esac; return 0; }
WAITFOR() { local i; for i in $(seq 1 "${2:-50}"); do eval "$1" && return 0; sleep 0.1; done; return 1; }
nbeats() { grep -c "^POST /api/lane-runs/$1/heartbeat $2\$" "$T/srv.log"; }
# group <name> — a process group like the worker's run: setsid in place from
# this non-interactive shell, so $! is the group id. Its child pid lands in
# $T/<name>.child.
group() { setsid bash -c "sleep 60 & echo \$! > '$T/$1.child'; wait" < /dev/null > /dev/null 2>&1 & GPID=$!; BG+=("$GPID")
  WAITFOR "[ -s '$T/$1.child' ]" || bad "setup: group $1 did not start"; GCHILD=$(cat "$T/$1.child"); }
# The lib in a subshell with the jobs client, as lane-run-worker.sh sources it.
LIBS=". '$H/bin/jobs-client.sh' && . '$H/bin/lib/lane-run-heartbeat.sh'"
setting lane_run.heartbeat_s 1

# ============================================================================
echo "H1: the claimer beats every second; lrh_stop ends the loop"
ID1=$(enqueue h1 0); [ "$(claim_as wa)" = "$ID1" ] || bad "H1 setup claim"
group h1
( eval "$LIBS"; MACHINE=wa
  lrh_start "$ID1" "$GPID"; echo "$LRH_PID" > "$T/h1.loop"
  WAITFOR "[ \$(nbeats $ID1 200) -ge 2 ]" 40 && echo beats-ok
  lrh_stop; echo "stop-rc=$?"
  lrh_lost; echo "lost-rc=$?" ) > "$T/h1.out" 2> "$T/h1.err"
grep -q beats-ok "$T/h1.out" && ok "H1 two heartbeats answered 200 within 4 s" || bad "H1 beats: $(cat "$T/srv.log" | tail -3)"
[ -n "$(rowf "$ID1" .heartbeat_at)" ] && [ "$(rowf "$ID1" .claimed_by)" = wa ] && ok "H1 the row keeps claimed_by wa with heartbeat_at" || bad "H1 row"
grep -q 'stop-rc=0' "$T/h1.out" && ! alive "$(cat "$T/h1.loop")" && ok "H1 lrh_stop rc 0 and the loop pid is gone" || bad "H1 stop: $(cat "$T/h1.out")"
grep -q 'lost-rc=1' "$T/h1.out" && ok "H1 lrh_lost rc 1" || bad "H1 lost: $(cat "$T/h1.out")"
alive "$GPID" && alive "$GCHILD" && ok "H1 the run is not touched" || bad "H1 the run died"
N=$(nbeats "$ID1" 200); sleep 1.5
[ "$(nbeats "$ID1" 200)" = "$N" ] && ok "H1 no beat after lrh_stop" || bad "H1 beats went on"
kill -- "-$GPID" 2>/dev/null

# ============================================================================
echo "H2: a 409 lost kills the run's process group"
ID2=$(enqueue h2 0); [ "$(claim_as wb)" = "$ID2" ] || bad "H2 setup claim"
group h2
( eval "$LIBS"; MACHINE=wa
  lrh_start "$ID2" "$GPID"
  WAITFOR "! alive $GPID && ! alive $GCHILD" 30 && echo dead-ok
  lrh_stop; lrh_lost; echo "lost-rc=$?" ) > "$T/h2.out" 2> "$T/h2.err"
grep -q dead-ok "$T/h2.out" && ok "H2 the leader and its child are gone within 3 s" || bad "H2 group alive: $(cat "$T/h2.err")"
grep -q 'lost-rc=0' "$T/h2.out" && ok "H2 lrh_lost rc 0" || bad "H2 lost: $(cat "$T/h2.out")"
grep -q "run $ID2: lease lost (not_claimer); killing process group $GPID" "$T/h2.err" && ok "H2 the log names the reason and the group" || bad "H2 log: $(cat "$T/h2.err")"
[ "$(nbeats "$ID2" 409)" = 1 ] && ok "H2 the loop stops after the lost answer" || bad "H2 beats: $(nbeats "$ID2" 409)"
[ "$(rowf "$ID2" .claimed_by)" = wb ] && ok "H2 the row stays with wb" || bad "H2 row"

# ============================================================================
echo "H3: an outage is not a lost lease"
h3() { # h3 <name> <fail json> [JOBS_URL]
  local id; id=$(enqueue "h3$1" 0); [ "$(claim_as wb)" = "$id" ] || bad "H3 $1 setup claim"
  hook PUT /__heartbeat_fail "$2"; group "h3$1"
  ( eval "$LIBS"; MACHINE=wa
    lrh_start "$id" "$GPID"
    WAITFOR "[ \$(grep -c 'heartbeat failed' '$T/h3$1.err') -ge 2 ]" 40 && echo failed-ok
    lrh_stop; lrh_lost; echo "lost-rc=$?" ) > "$T/h3$1.out" 2> "$T/h3$1.err"
  hook PUT /__heartbeat_fail '{}'
  grep -q failed-ok "$T/h3$1.out" && grep -q 'lost-rc=1' "$T/h3$1.out" && alive "$GPID" && alive "$GCHILD" \
    && ok "H3 $1: two failed beats logged, run alive, lrh_lost rc 1" || bad "H3 $1: $(cat "$T/h3$1.out" "$T/h3$1.err" | tail -4)"
  kill -- "-$GPID" 2>/dev/null
}
h3 transport '{"status":0}'
h3 http503 '{"status":503,"body":"{\"error\":\"lane_runs schema not applied\"}"}'
h3 http500 '{"status":500}'
h3 other409 '{"status":409,"body":"{\"error\":\"not reported\",\"reason\":\"not_claimer\"}"}'

# ============================================================================
echo "H4: a bad pgid is never signalled"
for g in "" 0 1 -5 "$$"; do
  id=$(enqueue "h4x${g//[^0-9]/}y" 0); [ "$(claim_as wb)" = "$id" ] || bad "H4 '$g' setup claim"
  : > "$T/kill.rec"; : > "$T/h4.err"
  ( eval "$LIBS"; MACHINE=wa
    # A recording kill: a TERM or KILL is written down and NEVER sent.
    kill() { case "$1" in -TERM|-KILL) echo "$*" >> "$T/kill.rec"; return 0 ;; esac; builtin kill "$@"; }
    lrh_start "$id" "$g"
    WAITFOR "lrh_lost" 40; sleep 0.3
    lrh_stop; lrh_lost; echo "lost-rc=$?" ) > "$T/h4.out" 2> "$T/h4.err"
  [ ! -s "$T/kill.rec" ] && grep -q 'lost-rc=0' "$T/h4.out" && grep -q "not killed: bad pgid '$g'" "$T/h4.err" \
    && ok "H4 pgid '$g': no signal sent, lrh_lost rc 0, logged" || bad "H4 pgid '$g': rec=$(cat "$T/kill.rec") $(cat "$T/h4.out" "$T/h4.err")"
done

# ============================================================================
echo "H5: a loop whose worker is gone stops beating"
ID5=$(enqueue h5 0); [ "$(claim_as wa)" = "$ID5" ] || bad "H5 setup claim"
bash -c "$LIBS; MACHINE=wa; lrh_start $ID5 999999; echo \$LRH_PID > '$T/h5.loop'; sleep 60" < /dev/null > /dev/null 2> "$T/h5.err" &
W5=$!; BG+=("$W5")
WAITFOR "[ \$(nbeats $ID5 200) -ge 1 ]" 40 || bad "H5 the loop never beat"
kill -KILL "$W5" 2>/dev/null; wait "$W5" 2>/dev/null
WAITFOR "! alive \$(cat '$T/h5.loop')" 30 && ok "H5 the loop exits within 3 s of its worker" || bad "H5 the loop outlived its worker"
N=$(nbeats "$ID5" 200); sleep 1.5
[ "$(nbeats "$ID5" 200)" = "$N" ] && ok "H5 no beat after the worker is gone" || bad "H5 beats went on"

# ============================================================================
echo "F3a: A never beats; B's worker takes the row over after the lease"
setting lane_run.heartbeat_s 30
IDA=$(enqueue p1 0)
[ "$(claim_as wa)" = "$IDA" ] && ok "F3a wa claims by curl" || bad "F3a claim"
expire "$IDA"
timeout 20 "$H/bin/lane-run-worker.sh" --once --machine wb > "$T/f3a.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "F3a wb's --once exits 0" || bad "F3a rc=$rc $(cat "$T/f3a.out")"
[ "$(rowf "$IDA" .status)" = done ] && [ "$(rowf "$IDA" .rc)" = 3 ] && [ "$(rowf "$IDA" .claimed_by)" = wb ] \
  && [ "$(rowf "$IDA" .attempts)" = 2 ] && ok "F3a row done, rc 3, claimed_by wb, attempts 2" \
  || bad "F3a row: $(curl -sS "$JOBS_URL/__lane_runs" | jq -c --argjson id "$IDA" '.rows[] | select(.id == $id)')"
grep -q "^p1	$IDA\$" "$T/runs.tsv" && ok "F3a the run ran on wb with LANE_RUN_ID $IDA" || bad "F3a runs: $(cat "$T/runs.tsv")"
code=$(apicode "/api/lane-runs/$IDA/report" '{"machine":"wa","rc":0}')
[ "$code" = 409 ] && [ "$(jq -r .reason "$T/apicode.out")" = not_claimer ] && [ "$(rowf "$IDA" .rc)" = 3 ] \
  && ok "F3a A's late report is 409 not_claimer and changes nothing" || bad "F3a late report: $code $(cat "$T/apicode.out")"

# ============================================================================
echo "F3b: B takes over while A's worker runs; A is killed and sends no report"
setting lane_run.heartbeat_s 1
IDB=$(enqueue p2 60)
rm -f "$T/lane-p2.pid"
"$H/bin/lane-run-worker.sh" --once --machine wa > "$T/f3b.out" 2>&1 &
WA=$!; BG+=("$WA")
WAITFOR "[ \"\$(rowf $IDB .claimed_by)\" = wa ] && [ -s '$T/lane-p2.pid' ]" 100 && ok "F3b wa claims and starts the run" || bad "F3b wa did not start"
LP=$(cat "$T/lane-p2.pid" 2>/dev/null)
WAITFOR "[ \$(nbeats $IDB 200) -ge 1 ]" 40 && ok "F3b wa beats 200 while it holds the row" || bad "F3b no beat"
TOOK=""
for _ in 1 2 3 4 5; do expire "$IDB"; [ "$(claim_as wb)" = "$IDB" ] && { TOOK=1; break; }; done
[ -n "$TOOK" ] && ok "F3b wb claims the same id after the lease" || bad "F3b wb could not claim"
WAITFOR "! alive $WA" 50 && ok "F3b wa exits within 5 s" || bad "F3b wa still running"
wait "$WA"; rc=$?
[ "$rc" = 0 ] && ok "F3b wa's --once exits 0" || bad "F3b wa rc=$rc"
[ -n "$LP" ] && ! alive "$LP" && ok "F3b wa's fake lane process is gone" || bad "F3b lane pid '$LP' alive"
grep -q "run $IDB demo/p2 rc [0-9]*: lease lost; not reported" "$H/logs/lane-run-worker.log" && ok "F3b wa logs lease lost; not reported" \
  || bad "F3b log: $(tail -5 "$H/logs/lane-run-worker.log")"
[ "$(grep -c "^POST /api/lane-runs/$IDB/report" "$T/srv.log")" = 0 ] && ok "F3b 0 report POSTs for the row" || bad "F3b a report was sent"
[ "$(rowf "$IDB" .status)" = claimed ] && [ "$(rowf "$IDB" .claimed_by)" = wb ] && [ "$(rowf "$IDB" .attempts)" = 2 ] \
  && ok "F3b row still claimed by wb, attempts 2" || bad "F3b row: $(curl -sS "$JOBS_URL/__lane_runs" | jq -c --argjson id "$IDB" '.rows[] | select(.id == $id)')"

# ============================================================================
echo "W4s: at lane_run.max_attempts=1 an expired row dies and nothing runs"
setting lane_run.max_attempts 1
IDC=$(enqueue p3 0)
[ "$(claim_as wa)" = "$IDC" ] || bad "W4s claim"
expire "$IDC"
timeout 20 "$H/bin/lane-run-worker.sh" --once --machine wb > "$T/w4s.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "W4s wb's --once exits 0" || bad "W4s rc=$rc $(cat "$T/w4s.out")"
[ "$(rowf "$IDC" .status)" = died ] && [ "$(rowf "$IDC" .rc)" = 137 ] && [ -n "$(rowf "$IDC" .finished_at)" ] \
  && ok "W4s row died, rc 137, finished_at set" || bad "W4s row: $(curl -sS "$JOBS_URL/__lane_runs" | jq -c --argjson id "$IDC" '.rows[] | select(.id == $id)')"
! grep -q '^p3	' "$T/runs.tsv" && ok "W4s nothing ran" || bad "W4s a run started: $(cat "$T/runs.tsv")"
setting lane_run.max_attempts 3

echo "lane-run-lease: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
