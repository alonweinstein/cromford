#!/bin/bash
# tests/wake-classes-hook.bh-1034-test.sh — bin/wake-loop.sh's class loader and
# hooks, driven through the REAL loop with a fixture class file. Everything a
# sibling ticket's class will do goes through this path: the row hook, the
# dispatch hook, and remote_launch deciding which box runs the lane.
#
# Since BH-2637 the loop runs on EVERY box and never ssh's: remote_launch runs
# the lane HERE when this box owns the project (the owning box, or the hub for a
# `local` project) or its own crontab already drives that lane for it, and for
# any other box's project it only logs "owned by <box> — its own loop claims
# this wake". The worker is tests/lib/wake-claim-stub.sh; the loop runs as the
# hub (box-hub, which owns the `local` project-3) unless a case says
# otherwise, and as box-project-5-1 where the owning box is the point.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-classes-hook.bh-1034-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T"
mkdir -p "$T/bin" "$T/bin/lib" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" "$T/calls"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$T/env/global.env"
export WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE
HUB=box-hub TS=box-project-5-1
export BOX_NAME="$HUB"

# The real loop and lib.
cp "$DIR/bin/wake-loop.sh"   "$T/bin/wake-loop.sh"
cp "$DIR/bin/lib/wake-lanes.sh" "$T/bin/lib/wake-lanes.sh"

# The REAL jobs-client: wakes_claim / wake_cursor_* / wake_cooldown_take go to
# the stub worker, and flag_active reads flags/<name> (the flag sync's `{}`
# answer leaves the files alone).
mkdir -p "$T/bin/lib/jobs"
cp "$DIR/bin/jobs-client.sh" "$T/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
wcs_install "$T/bin"
wcs_identity "$T/bin" || { echo "wcs_identity failed"; exit 1; }

# Fleet registry: one local-box project and one remote-box project.
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'project-3\nproject-5\n'; exit 0; }
case "$1/$2" in
  project-3/repo)   echo example-org/project-3 ;;
  project-5/repo) echo example-org/project-5 ;;
  project-3/box)    echo local ;;
  project-5/box)  echo box-project-5-1 ;;
  project-3/board_prefix)   echo /api/feature-board ;;
  project-5/board_prefix) echo - ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/fleet-conf.sh"

# bin/box-for.sh is the REAL one (wcs_identity): it answers fleet-conf's box
# column above — project-3 `local` (the hub's), project-5 box-project-5-1.

cat > "$T/bin/unblocked-children.sh" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$T/bin/unblocked-children.sh"

# Recorders for the legacy lanes.
for s in merge-conductor deploy-train postmerge-qa run-triage; do
  cat > "$T/bin/$s.sh" <<SH
#!/bin/bash
echo "\$*" >> "\$HARNESS/calls/$s"
SH
  chmod +x "$T/bin/$s.sh"
done

# The lane a class launches through remote_launch. It records its argv AND the
# WAKE_LAUNCH the contract promises every wake-driven run carries.
cat > "$T/bin/lane-x.sh" <<'SH'
#!/bin/bash
echo "$* WAKE_LAUNCH=${WAKE_LAUNCH:-}" >> "$HARNESS/calls/lane-x"
SH
chmod +x "$T/bin/lane-x.sh"

# curl: every wake route (claim, cursor, cooldown take, ack) is the stub
# worker's, over $T/wakes.json; everything else answers {}.
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
# CURL_SLEEP_S: the first call of a run sleeps (the slowed run
# tests/gates-to-reports.bh-5292-test.sh R6 drives against case 8).
if [ -n "${CURL_SLEEP_S:-}" ] && [ ! -e "$HARNESS/calls/curl-slept" ]; then : > "$HARNESS/calls/curl-slept"; sleep "$CURL_SLEEP_S"; fi
"$(dirname "$0")/wcs-routes" "$@" && exit 0
printf '{}\n200'
SH
# ssh records its argv. The loop must never call it (BH-2637); SSH_SLEEP_S
# turns it into a slow box, which is how the "drain() never waits on ssh" case
# is driven.
cat > "$T/bin/ssh" <<'SH'
#!/bin/bash
[ -n "${SSH_SLEEP_S:-}" ] && sleep "$SSH_SLEEP_S"
echo "$*" >> "$HARNESS/calls/ssh"
SH
# crontab: the ROOT USER crontab, which is the format the fleet installs — no
# user column, which is exactly what /etc/crontab would have had.
cat > "$T/bin/crontab" <<'SH'
#!/bin/bash
[ "${1:-}" = "-l" ] || exit 1
[ -r "$HARNESS/crontab.out" ] || exit 1
cat "$HARNESS/crontab.out"
SH
# gh: no closed issues, no unblocked children.
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/gh"
echo '[]'
SH
cat > "$T/bin/setsid" <<'SH'
#!/bin/bash
exec "$@"
SH
cat > "$T/bin/flock" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$T/bin/curl" "$T/bin/ssh" "$T/bin/crontab" "$T/bin/gh" "$T/bin/setsid" "$T/bin/flock"
export PATH="$T/bin:$PATH"

# Fixture class: records row hook calls, and on dispatch asks the box that owns
# each project seen this drain to run lane-x.sh — the shape every sibling class
# will have, accumulator reset included.
cat > "$T/bin/lib/wake-class-fixture.sh" <<'SH'
#!/bin/bash
FIXTURE_PROJECTS=""
wc_fixture_row() {
  printf '%s\n' "$*" >> "$HARNESS/calls/wc-fixture-row"
  case " $FIXTURE_PROJECTS " in *" $1 "*) ;; *) FIXTURE_PROJECTS="$FIXTURE_PROJECTS $1" ;; esac
}
wc_fixture_dispatch() {
  printf 'dispatch\n' >> "$HARNESS/calls/wc-fixture-dispatch"
  local p
  for p in $FIXTURE_PROJECTS; do remote_launch "x[$p]" "$p" lane-x.sh "$p"; done
  FIXTURE_PROJECTS=""
}
SH
chmod +x "$T/bin/lib/wake-class-fixture.sh"

W() { printf '{"id":%s,"repo":"%s","kind":"%s","key":"%s","event":"%s","at":"2026-09-19T11:39:04Z"}' "$1" "${4:-example-org/project-3}" "$2" "$3" "${5:-ev}"; }
wakes() { printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/wakes.json"; }
reset() {
  rm -rf "$T/calls" "$T/state" "$T/flags" "$T/logs"
  mkdir -p "$T/calls" "$T/state" "$T/flags" "$T/logs"
  rm -f "$T/crontab.out"
}
settle() {
  local prev="" cur i
  for i in $(seq 1 12); do
    sleep 0.25
    cur=$(cat "$T/calls/"* 2>/dev/null | wc -c | tr -d ' ')
    [ "$cur" = "$prev" ] && [ "$i" -ge 2 ] && return 0
    prev="$cur"
  done
  return 0
}
run() { "$T/bin/wake-loop.sh"; RC=$?; settle; return "$RC"; }
run_as() { BOX_NAME="$1" "$T/bin/wake-loop.sh"; RC=$?; settle; return "$RC"; }
calls() { [ -f "$T/calls/$1" ] && wc -l < "$T/calls/$1" | tr -d ' ' || echo 0; }

# ---------------------------------------------------------------------------
# 1. no fixture flag -> no class row/dispatch calls; legacy counts match
# ---------------------------------------------------------------------------
reset; wakes "$(W 1 pr 272)" "$(W 2 push aaa1111)" "$(W 3 issue 41)"
run
[ "$(calls merge-conductor)" = 1 ] && ok || bad "no flag: conductor must launch once"
[ "$(calls deploy-train)" = 1 ] && ok || bad "no flag: deploy-train must launch once"
[ "$(calls run-triage)" = 1 ] && ok || bad "no flag: triage must launch once"
[ ! -f "$T/calls/wc-fixture-row" ] && ok || bad "no flag: no class row calls"
[ ! -f "$T/calls/wc-fixture-dispatch" ] && ok || bad "no flag: no class dispatch calls"
grep -q 'wake classes armed' "$T/logs/wake-loop.log" && bad "no flag: nothing is armed, so no armed line" || ok

# ---------------------------------------------------------------------------
# 2. fixture flag on -> one row line per fleet row, none for non-fleet rows,
#    and one line naming the armed class
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-fixture"
wakes "$(W 10 pr 272 example-org/project-3 pull_request.closed)" "$(W 11 push bbb2222 example-org/project-5 push)" "$(W 12 push ccc3333 SomeoneElse/not-ours)"
# TEST-CHANGE BH-2637: no single box sees every fleet row any more — each box
# claims its own repos — so "one row line per fleet row" is the fleet's two
# owning boxes together: the hub (project-3 is `local`) and box-project-5-1.
# CLAIM_ALL=1 is a worker that ignores the filter, so the non-fleet row and the
# other box's row are dropped by the LOOP, as the old single-GET loop did.
# project-5's box has a cursor row of 0 (it has claimed before), so it does not
# seed from the hub's.
mkdir -p "$T/state/wcs"; printf 0 > "$T/state/wcs/cursor.$TS"
CLAIM_ALL=1 run_as "$HUB"
CLAIM_ALL=1 run_as "$TS"
[ "$(calls wc-fixture-row)" -eq 2 ] && ok || bad "fixture flag: exactly two row calls (got $(calls wc-fixture-row))"
grep -q 'project-3 pr 272 pull_request.closed example-org/project-3 10' "$T/calls/wc-fixture-row" && ok || bad "fixture row missing project-3 pr"
grep -q 'project-5 push bbb2222 push example-org/project-5 11' "$T/calls/wc-fixture-row" && ok || bad "fixture row missing project-5 push"
! grep -q 'not-ours' "$T/calls/wc-fixture-row" && ok || bad "non-fleet row must not reach class hook"
grep -q 'wake classes armed: fixture' "$T/logs/wake-loop.log" && ok || bad "the loop must say which classes are armed"

# ---------------------------------------------------------------------------
# 3. fixture flag on -> dispatch called once per drain and not for an empty drain
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-fixture"
wakes "$(W 20 pr 272)"
run
[ "$(calls wc-fixture-dispatch)" = 1 ] && ok || bad "dispatch must fire once for a non-empty drain"
reset; touch "$T/flags/wake-lanes-fixture"; wakes
run
[ ! -f "$T/calls/wc-fixture-dispatch" ] && ok || bad "dispatch must not fire for an empty drain"

# ---------------------------------------------------------------------------
# 4. class flag on + flags/wake-lanes-off -> no class activity
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-fixture" "$T/flags/wake-lanes-off"
wakes "$(W 30 pr 272)"
run
[ ! -f "$T/calls/wc-fixture-row" ] && ok || bad "wake-lanes-off must suppress row hook"
[ ! -f "$T/calls/wc-fixture-dispatch" ] && ok || bad "wake-lanes-off must suppress dispatch hook"
grep -q 'wake classes armed' "$T/logs/wake-loop.log" && bad "wake-lanes-off must not report an armed class" || ok
# legacy lanes still run (only the class machinery is off).
[ "$(calls merge-conductor)" = 1 ] && ok || bad "wake-lanes-off must not suppress legacy lanes"

# ---------------------------------------------------------------------------
# 5. remote_launch for a project whose box is `local` runs the lane HERE, with
#    WAKE_LAUNCH=1 — driven through the class dispatch, not called by hand
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-fixture"
wakes "$(W 40 pr 272 example-org/project-3 pull_request.closed)"
run
[ "$(calls lane-x)" = 1 ] && ok || bad "box=local must run the lane once here (got $(calls lane-x))"
grep -qx 'project-3 WAKE_LAUNCH=1' "$T/calls/lane-x" && ok || bad "local lane must get the project and WAKE_LAUNCH=1 (got: $(cat "$T/calls/lane-x" 2>/dev/null))"
[ "$(calls ssh)" = 0 ] && ok || bad "box=local must not ssh"

# ---------------------------------------------------------------------------
# 6. lane_runs_here: this box's own crontab already drives the lane for that
#    project -> run it here instead of asking a second box to run it too.
#    The stub prints a USER crontab (`crontab -l`), which has no user column.
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-fixture"
printf '%s\n' '*/5 * * * * /root/harness/bin/lane-x.sh project-5 >/dev/null 2>&1' > "$T/crontab.out"
# TEST-CHANGE BH-2637: the hub claims another box's repo only for pr/checks
# rows, so the project-5 row that reaches the hub's class hook is a pr row (it
# was a push, which only box-project-5-1 claims now).
wakes "$(W 50 pr 273 example-org/project-5 pull_request.closed)"
run
[ "$(calls lane-x)" = 1 ] && ok || bad "a lane this box already crons must launch locally (got $(calls lane-x))"
grep -qx 'project-5 WAKE_LAUNCH=1' "$T/calls/lane-x" && ok || bad "locally-croned lane must carry WAKE_LAUNCH=1"
[ "$(calls ssh)" = 0 ] && ok || bad "a lane this box already crons must not also ssh"

# ---------------------------------------------------------------------------
# 7. no crontab match -> the hub does NOT run another box's lane and does not
#    ssh: it names the owning box in the log, and that box's own loop, claiming
#    the same wake, runs the lane there, detached, with WAKE_LAUNCH=1
#    (BH-2637: the ssh leg is gone)
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-fixture"
printf '%s\n' '*/5 * * * * /root/harness/bin/lane-x.sh project-3 >/dev/null 2>&1' > "$T/crontab.out"
# TEST-CHANGE BH-2637: a pr row, the project-5 kind the hub still claims (see 6).
wakes "$(W 60 pr 274 example-org/project-5 pull_request.closed)"
run
# TEST-CHANGE BH-2637: was "exactly one ssh call"; the loop never ssh's now.
[ "$(calls ssh)" -eq 0 ] && ok || bad "the hub must not ssh for another box's lane (got $(calls ssh): $(cat "$T/calls/ssh" 2>/dev/null))"
# TEST-CHANGE BH-2637: was "ssh targets root@box-project-5-1"; the box
# fleet.conf names is now the one the log line hands the wake to.
grep -q 'x\[project-5\]: owned by box-project-5-1' "$T/logs/wake-loop.log" && ok || bad "the hub must name the box fleet.conf names"
[ ! -f "$T/calls/lane-x" ] && ok || bad "the remote path must not also run the lane here"
# TEST-CHANGE BH-2637: was "the ssh outcome reaches the log"; the outcome is
# now the hand-off line.
grep -q 'owned by box-project-5-1 — its own loop claims this wake' "$T/logs/wake-loop.log" && ok || bad "the hand-off to the owning box must reach the log"
# The owning box claims the same wake and runs the lane itself.
reset; touch "$T/flags/wake-lanes-fixture"
printf '%s\n' '*/5 * * * * /root/harness/bin/lane-x.sh project-3 >/dev/null 2>&1' > "$T/crontab.out"
wakes "$(W 60 push bbb2222 example-org/project-5 push)"
run_as "$TS"
# TEST-CHANGE BH-2637: was "the remote (ssh) command carries WAKE_LAUNCH=1"; the
# owning box's own launch carries it.
grep -qx 'project-5 WAKE_LAUNCH=1' "$T/calls/lane-x" 2>/dev/null && ok || bad "the owning box's launch must carry WAKE_LAUNCH=1 (got: $(cat "$T/calls/lane-x" 2>/dev/null))"
# TEST-CHANGE BH-2637: was "the remote command is nohup setsid …"; the owning
# box launches through launch(), which is always detached (setsid, background).
grep -q 'x\[project-5\]: launched lane-x.sh project-5' "$T/logs/wake-loop.log" && ok || bad "the owning box must launch the lane detached (log: $(tail -5 "$T/logs/wake-loop.log" 2>/dev/null))"
[ "$(calls ssh)" = 0 ] && ok || bad "the owning box must not ssh either"

# ---------------------------------------------------------------------------
# 8. THE SSH NEVER HOLDS THE DOORBELL. drain() runs under locks/wake-loop.lock
#    and the cycle is 15s: a slow box must not park the loop while every other
#    project's rows queue behind it.
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-fixture"
printf '%s\n' '*/5 * * * * /root/harness/bin/lane-x.sh project-3 >/dev/null 2>&1' > "$T/crontab.out"
# TEST-CHANGE BH-2637: a pr row, so the hub claims it (see 6). There is no ssh
# to wait on now; the case pins that another box's row still costs the hub
# nothing, even with a 6s ssh on PATH.
wakes "$(W 70 pr 275 example-org/project-5 pull_request.closed)"
# TEST-CHANGE BH-5292: was `elapsed -lt 5`. the operator changed the rule (2026-10-07):
# no wall-clock asserts. "The ssh never holds the doorbell" is proved by the
# work: the drain exits on its own with rc 0 under a 60s hang guard (124 means
# it parked), ssh is never called (a loop that waited on a 6s ssh would have
# called it), and the row was drained (the class row hook saw it). A slowed
# curl still passes.
CURL_SLEEP_S="${WALLCLOCK_STUB_SLEEP_S:-}" SSH_SLEEP_S=6 timeout 60 "$T/bin/wake-loop.sh"
wrc=$?
[ "$wrc" = 0 ] && ok || bad "a 6s ssh must not park the loop (rc=$wrc; 124 = the 60s hang guard fired)"
settle
[ "$(calls ssh)" = 0 ] && ok || bad "the loop must never call ssh (got $(calls ssh))"
[ "$(calls wc-fixture-row)" -ge 1 ] && ok || bad "the row must have been drained through the class hook (got $(calls wc-fixture-row))"

# ---------------------------------------------------------------------------
# 9. an existing launch (PR row -> merge-conductor) passes WAKE_LAUNCH=1
# ---------------------------------------------------------------------------
cat > "$T/bin/env-recorder.sh" <<'SH'
#!/bin/bash
printf '%s\n' "WAKE_LAUNCH=${WAKE_LAUNCH:-}" >> "$HARNESS/calls/env-recorder"
SH
chmod +x "$T/bin/env-recorder.sh"
# Replace the real conductor with the env recorder for one drain.
cp "$T/bin/merge-conductor.sh" "$T/bin/merge-conductor.sh.bak"
cp "$T/bin/env-recorder.sh" "$T/bin/merge-conductor.sh"
reset; wakes "$(W 80 pr 272)"
run
cp "$T/bin/merge-conductor.sh.bak" "$T/bin/merge-conductor.sh"
[ -f "$T/calls/env-recorder" ] && grep -q 'WAKE_LAUNCH=1' "$T/calls/env-recorder" && ok \
  || bad "launch must export WAKE_LAUNCH=1 to children (got: $(cat "$T/calls/env-recorder" 2>/dev/null))"

# ---------------------------------------------------------------------------
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
