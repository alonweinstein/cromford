#!/bin/bash
# tests/wake-fastpath-test.sh — a wake tries bin/launch-fastpath.sh ON THE
# OWNING BOX before it buys a triage tick, and buys the tick whenever the
# fast-path did not launch every key (BH-482.2).
#
# WHAT IS STUBBED AND WHAT IS UNDER TEST. Same shape as tests/wake-loop-test.sh:
# `curl` serves a file of wakes, each owning script is a recorder, and the thing
# actually exercised is the REAL bin/wake-loop.sh — which arm it takes, what argv
# it hands the fast-path, and what it does with the exit code. The fast-path
# itself is a recorder shim whose exit code is $FP_RC, because "every key
# launched" vs "something was declined" is the whole decision under test.
#
# BOTH ARMS ARE LOCAL NOW (BH-2637). The loop runs on every box, each box
# claims its own wakes from the stub worker (tests/lib/wake-claim-stub.sh), and
# nothing is ever sent over ssh. project-3 is box=local, so it is run AS THE HUB
# (BOX_NAME=box-hub); project-5 is box=box-project-5-1, so it is
# run AS THAT BOX, and its fast-path call, keys file and un-brake all land in
# this scratch tree exactly as project-3's do. The ssh stub still records to
# calls/ssh, and every case that used to read the remote string now asserts
# that file stays empty.
#
# Run from anywhere: tests/wake-fastpath-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T" WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0
mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" "$T/calls"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$T/env/global.env"

# --- the harness tree the loop runs out of ----------------------------------
# jobs-client.sh, box-for.sh and unblocked-children.sh are the REAL ones: which
# box owns a project and whether a merge released a Blocked-by child are the two
# decisions that pick the arm, and a stub of either would be a test of the stub.
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/wake-loop.sh"   "$T/bin/wake-loop.sh"
mkdir -p "$T/bin/lib"
cp "$DIR/bin/lib/revdep-lib.sh" "$T/bin/lib/revdep-lib.sh"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/bin/lib/"
cp "$DIR/bin/box-for.sh"            "$T/bin/box-for.sh"
cp "$DIR/bin/unblocked-children.sh" "$T/bin/unblocked-children.sh"
chmod +x "$T/bin/"*.sh
# The stub worker (claim / cursor / cooldown / ack routes) and the REAL identity
# scripts: which box the loop is decides which wakes it claims and which arm runs.
wcs_install "$T/bin"
wcs_identity "$T/bin" || { echo "wcs_identity failed"; exit 1; }
HUB=box-hub
TSBOX=box-project-5-1

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
for s in merge-conductor deploy-train postmerge-qa run-triage; do
  cat > "$T/bin/$s.sh" <<SH
#!/bin/bash
echo "\$*" >> "\$HARNESS/calls/$s"
SH
done
# The fast-path shim: argv in, $FP_RC out. Exit 1 is the default because that is
# what the contract stub on a real box does today (bin/launch-fastpath.sh
# declines every key), so a case that forgets to say makes the loop take the
# fall-through path it takes in production right now.
cat > "$T/bin/launch-fastpath.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/launch-fastpath"
exit "${FP_RC:-1}"
SH
chmod +x "$T/bin/"*.sh

# curl is wcs_install's: the wake routes answer from $T/wakes.json, all else `{}` 200.
# ssh: recorded verbatim. No case may ever find anything in it — the loop never
# ssh's (BH-2637); each box claims and launches its own wakes.
cat > "$T/bin/ssh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/ssh"
SH
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
# TEST-CHANGE BH-1651: closed_diff lists through gh_rest_issue_list, answered
# from the same fixture BEFORE the adapter, whose list shape has no closed_at.
case "$*" in *"-i -X GET"*"/issues"*"state=closed"*)
  echo "$*" >> "$HARNESS/calls/gh"
  printf 'HTTP/2 200\r\n\r\n'; jq -c 'map(. + {closed_at: .closedAt})' "$HARNESS/gh-closed.json" 2>/dev/null || echo '[]'
  exit 0 ;;
esac
. "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" "$@" && exit 0
echo "$*" >> "$HARNESS/calls/gh"
case "$*" in
  *"--state closed"*) cat "$HARNESS/gh-closed.json" 2>/dev/null || echo '[]' ;;
  *"--state all"*)    cat "$HARNESS/gh-all.json"    2>/dev/null || echo '[]' ;;
  *)                  echo '[]' ;;
esac
SH
chmod +x "$T/bin/ssh" "$T/bin/gh"
cat > "$T/bin/setsid" <<'SH'
#!/bin/bash
exec "$@"
SH
cat > "$T/bin/flock" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$T/bin/curl" "$T/bin/setsid" "$T/bin/flock"
export PATH="$T/bin:$PATH"

wakes() { printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/wakes.json"; }
W() { # W <id> <kind> <key> [repo] [event]
  printf '{"id":%s,"repo":"%s","kind":"%s","key":"%s","event":"%s","at":"2026-09-12T11:39:04Z"}' \
    "$1" "${4:-example-org/project-3}" "$2" "$3" "${5:-ev}"
}
reset() {
  rm -rf "$T/calls" "$T/state" "$T/remote"
  mkdir -p "$T/calls" "$T/state"
  rm -f "$T/gh-closed.json" "$T/gh-all.json"
  : > "$T/logs/wake-loop.log"
}
# ONE clock read for the whole suite: the push path filters closures on a window
# (WAKE_PUSH_WINDOW_S), so a second read is a suite that can pick its own red day.
NOW=$(date +%s)
NOW_ISO=$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ')
settle() {
  local prev="" cur i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 0.25
    cur=$(cat "$T/calls/"* 2>/dev/null | wc -c | tr -d " ")
    [ "$cur" = "$prev" ] && [ "$i" -ge 2 ] && return 0
    prev="$cur"
  done
  return 0
}
# run [box] — one loop invocation AS <box> (default the hub, which owns project-3).
run()   { BOX_NAME="${1:-$HUB}" "$T/bin/wake-loop.sh"; RC=$?; settle; return "$RC"; }
waitfor() {
  local i
  for i in $(seq 1 40); do [ -s "$1" ] && return 0; sleep 0.25; done
  return 1
}
calls() { [ -f "$T/calls/$1" ] && wc -l < "$T/calls/$1" | tr -d ' ' || echo 0; }
logged() { grep -qE "$1" "$T/logs/wake-loop.log"; }


# ---------------------------------------------------------------------------
# T2.1 local arm: the fast-path launched every key, so NO triage tick is bought
# ---------------------------------------------------------------------------
# "No session bought" is two assertions, not one. The run-triage launch must not
# happen HERE — and the gate un-brake state/wake-<project>, which the issue loop
# wrote before any of this, must be gone too, because bin/triage-gate.sh answers
# RUN event-wake on that file alone and the next cron minute would buy the
# session this wake did not. The keys file goes with it: it is what that session
# would have been scoped by.
reset; export FP_RC=0; wakes "$(W 10 issue 41)"
run
waitfor "$T/calls/launch-fastpath" || bad "T2.1: the local arm must try the fast-path first"
[ "$(cat "$T/calls/launch-fastpath" 2>/dev/null)" = "project-3 41" ] && ok \
  || bad "T2.1: the fast-path must get <project> then the keys (got '$(cat "$T/calls/launch-fastpath" 2>/dev/null)')"
[ "$(calls launch-fastpath)" = 1 ] && ok || bad "T2.1: one wake, one fast-path call (got $(calls launch-fastpath))"
[ ! -f "$T/calls/run-triage" ] && ok \
  || bad "T2.1: exit 0 means every key launched — no triage session may be bought (got: $(cat "$T/calls/run-triage" 2>/dev/null))"
[ ! -f "$T/state/wake-project-3" ] && ok \
  || bad "T2.1: the un-brake must not survive a fast-path success — triage-gate would answer RUN event-wake at the next cron minute"
[ ! -f "$T/state/wake-keys-project-3" ] && ok \
  || bad "T2.1: the keys file must go with the un-brake (got '$(cat "$T/state/wake-keys-project-3" 2>/dev/null)')"
logged 'fastpath\[project-3\]: every key launched' && ok \
  || bad "T2.1: the skipped tick must say so in the log: $(grep -c . "$T/logs/wake-loop.log") line(s)"

# ---------------------------------------------------------------------------
# T2.2 local arm: ANY nonzero exit is today's tick, with the keys intact
# ---------------------------------------------------------------------------
# Exit code is the only signal (a declined key, a partial launch and a crash are
# one answer), and the fall-through has to be byte-for-byte what the loop did
# before this change: keys file, un-brake, launch.
reset; export FP_RC=1; wakes "$(W 11 issue 41)"
run
waitfor "$T/calls/run-triage" || bad "T2.2: a declined key must still buy the tick"
[ "$(cat "$T/calls/launch-fastpath" 2>/dev/null)" = "project-3 41" ] && ok \
  || bad "T2.2: the fast-path must still be tried (got '$(cat "$T/calls/launch-fastpath" 2>/dev/null)')"
grep -qx 'project-3' "$T/calls/run-triage" 2>/dev/null && ok \
  || bad "T2.2: exit 1 must fall through to this project's own triage tick"
[ -f "$T/state/wake-project-3" ] && ok || bad "T2.2: the un-brake must still be written"
[ "$(cat "$T/state/wake-keys-project-3" 2>/dev/null)" = 41 ] && ok \
  || bad "T2.2: the tick must still be scoped to the key (got '$(cat "$T/state/wake-keys-project-3" 2>/dev/null)')"
! logged 'fastpath\[project-3\]: every key launched' && ok \
  || bad "T2.2: a declined key must never be logged as launched (D9)"

# ---------------------------------------------------------------------------
# T2.3 box-owned project: the fast-path runs ON THE OWNING BOX, locally
# ---------------------------------------------------------------------------
# TEST-CHANGE BH-2637: the hub no longer ssh's a launch string to the box. The
# box runs its own loop, claims its own wake and takes the same local arm as
# T2.1/T2.2. So what used to be read out of the ssh argv (and executed by
# remote_run) is asserted on files the owning box's own run writes, and the ssh
# log must stay empty. The hub half — TK-42, never fast-pathed or triaged on the
# hub — is proved against a MIS-FILTERING worker (CLAIM_ALL=1) so it is the
# loop's own ownership guard under test, not the stub's filter.
reset; export FP_RC=0; wakes "$(W 20 issue 41 example-org/project-5)"
CLAIM_ALL=1 run "$HUB"
# TEST-CHANGE BH-2637: the hub leaves the wake to the box fleet.conf names — it drops the row as another box's repo instead of ssh'ing it there.
logged 'another box owns the repo —.*[Ff]ortunian/project-5' && ok \
  || bad "T2.3: the hub must leave the launch to the box fleet.conf names: $(cat "$T/logs/wake-loop.log")"
[ ! -f "$T/calls/launch-fastpath" ] && [ ! -f "$T/calls/run-triage" ] && [ ! -s "$T/calls/ssh" ] && ok \
  || bad "T2.3: a box-owned project is never fast-pathed or triaged ON THE HUB (TK-42), nor sent over ssh"
reset; export FP_RC=0; wakes "$(W 20 issue 41 example-org/project-5)"
run "$TSBOX"; RUN_RC=$RC
# TEST-CHANGE BH-2637: the wake no longer leaves over ssh; the owning box calls the fast-path itself.
waitfor "$T/calls/launch-fastpath" || bad "T2.3: a box-owned issue wake must reach the fast-path on its own box"
# TEST-CHANGE BH-2637: one wake, one LOCAL fast-path call, zero ssh.
[ "$(calls launch-fastpath)" = 1 ] && [ ! -s "$T/calls/ssh" ] && ok \
  || bad "T2.3: one wake, one local fast-path call, no ssh (got fp=$(calls launch-fastpath) ssh=$(calls ssh))"
# TEST-CHANGE BH-2637: argv of the local call, not a token in a remote string.
grep -qx 'project-5 41' "$T/calls/launch-fastpath" 2>/dev/null && ok \
  || bad "T2.3: the fast-path must be called with <project> <keys>: $(cat "$T/calls/launch-fastpath" 2>/dev/null)"
# TEST-CHANGE BH-2637: the un-brake is handled on the same box that ran the fast-path — taken back on success.
[ ! -f "$T/state/wake-keys-project-5" ] && ok \
  || bad "T2.3: a fast-pathed wake must take its keys file back on the owning box (got '$(cat "$T/state/wake-keys-project-5" 2>/dev/null)')"
# TEST-CHANGE BH-2637: the owning box logs the skipped tick itself.
logged 'fastpath\[project-5\]: every key launched' && ok \
  || bad "T2.3: the owning box must log that the fast-path launched every key: $(grep 'project-5' "$T/logs/wake-loop.log")"
# TEST-CHANGE BH-2637: no remote shell program exists any more; the owning box's loop itself must exit clean.
[ "$RUN_RC" = 0 ] && ok || bad "T2.3: the owning box's loop must exit 0 (rc $RUN_RC)"
# TEST-CHANGE BH-2637: stdin can no longer be eaten by ssh -n-less ssh; the drain must still reach the ack.
[ ! -s "$T/calls/ssh" ] && wcs_log | grep -q '^POST /api/wakes/ack .*20' && ok \
  || bad "T2.3: no ssh, and the drain must run to its ack of wake 20: $(wcs_log | grep ack)"
# TEST-CHANGE BH-2637: was remote_run 0 — the same argument check, on the local recorder.
[ "$(cat "$T/calls/launch-fastpath" 2>/dev/null)" = "project-5 41" ] && ok \
  || bad "T2.3: on the box the key must arrive as an ARGUMENT (got '$(cat "$T/calls/launch-fastpath" 2>/dev/null)')"
[ ! -f "$T/calls/run-triage" ] && ok \
  || bad "T2.3: the box must buy no tick when the fast-path launched every key"
[ ! -f "$T/state/wake-project-5" ] && ok \
  || bad "T2.3: a fast-pathed wake must not un-brake the next tick on the box either"
# TEST-CHANGE BH-2637: was remote_run 1 — the owning box runs again with a declining fast-path.
reset; export FP_RC=1; wakes "$(W 21 issue 41 example-org/project-5)"
run "$TSBOX"
waitfor "$T/calls/run-triage"
[ "$(calls launch-fastpath)" = 1 ] && grep -qx 'project-5' "$T/calls/run-triage" 2>/dev/null && ok \
  || bad "T2.3: a declining box must fall through to its own run-triage (got '$(cat "$T/calls/run-triage" 2>/dev/null)')"
[ -f "$T/state/wake-project-5" ] && ok \
  || bad "T2.3: the fall-through must still un-brake that box's gate"
# TEST-CHANGE BH-2637: was "run-triage.sh project-5 in the ssh string" — the fall-through tick is launched locally.
logged 'triage\[project-5\] .*: launched run-triage.sh project-5' && ok \
  || bad "T2.3: the fall-through must still be that project's own run-triage.sh: $(grep 'project-5' "$T/logs/wake-loop.log")"
# TEST-CHANGE BH-2637: was "nohup setsid in the ssh string" — no remote session exists to outlive; the tick is the owning box's own, scoped to its key.
[ "$(cat "$T/state/wake-keys-project-5" 2>/dev/null)" = 41 ] && [ ! -s "$T/calls/ssh" ] && ok \
  || bad "T2.3: the fall-through tick must be scoped to the key on the box, with no ssh (got '$(cat "$T/state/wake-keys-project-5" 2>/dev/null)')"

# ---------------------------------------------------------------------------
# T2.4 a PUSH that released a Blocked-by child fast-paths the CHILD's key
# ---------------------------------------------------------------------------
# TEST-CHANGE BH-2637: run as the owning box; the child key reaches the local
# fast-path, and nothing goes over ssh.
reset; export FP_RC=0
printf '[{"number":331,"closedAt":"%s"}]\n' "$NOW_ISO" > "$T/gh-closed.json"
cat > "$T/gh-all.json" <<'J'
[{"number":331,"state":"CLOSED","title":"parent","body":"the blocker"},
 {"number":332,"state":"OPEN","title":"child","body":"Blocked-by: #331"}]
J
wakes "$(W 30 push eee5555 example-org/project-5)"
run "$TSBOX"
waitfor "$T/calls/launch-fastpath" || bad "T2.4: a push that released a child must launch on its box"
grep -qx 'project-5 332' "$T/calls/launch-fastpath" 2>/dev/null && ok \
  || bad "T2.4: the released child is the key the fast-path gets: $(cat "$T/calls/launch-fastpath" 2>/dev/null)"
[ "$(calls deploy-train)" = 1 ] && ok \
  || bad "T2.4: the deploy train must still depart on the same push (got $(calls deploy-train))"
[ "$(cat "$T/calls/launch-fastpath" 2>/dev/null)" = "project-5 332" ] && [ ! -s "$T/calls/ssh" ] && ok \
  || bad "T2.4: on the box the child key must arrive as an argument, no ssh (got '$(cat "$T/calls/launch-fastpath" 2>/dev/null)')"

# ---------------------------------------------------------------------------
# T2.5 flags/fastpath-off is today's loop on every box
# ---------------------------------------------------------------------------
# TEST-CHANGE BH-2637: each box runs its own loop, so the project-5 half is run
# as box-project-5-1 and the project-3 half as the hub. The old "ssh
# string byte for byte" is now the plain local launch on the owning box: keys
# file, un-brake, run-triage.sh <project>, no fast-path, no ssh.
reset; export FP_RC=0; touch "$T/flags/fastpath-off"
wakes "$(W 40 issue 41 example-org/project-5)" "$(W 41 issue 41)"
run "$TSBOX"
# TEST-CHANGE BH-2637: the launch is the owning box's local tick, not an ssh.
waitfor "$T/calls/run-triage" || bad "T2.5: the flag must not stop the launch itself"
# TEST-CHANGE BH-2637: "today's string" is today's local arm: keys file, un-brake, triage, no ssh.
grep -qx 'project-5' "$T/calls/run-triage" 2>/dev/null && [ "$(cat "$T/state/wake-keys-project-5" 2>/dev/null)" = 41 ] \
  && [ -f "$T/state/wake-project-5" ] && [ ! -s "$T/calls/ssh" ] && ok \
  || bad "T2.5: with the flag the owning box must take today's plain local arm, no ssh.
  run-triage: $(cat "$T/calls/run-triage" 2>/dev/null)  keys: $(cat "$T/state/wake-keys-project-5" 2>/dev/null)  ssh: $(cat "$T/calls/ssh" 2>/dev/null)"
run "$HUB"
waitfor "$T/calls/run-triage" || bad "T2.5: the local arm must still buy its tick"
grep -qx 'project-3' "$T/calls/run-triage" 2>/dev/null && ok \
  || bad "T2.5: the local arm must launch triage directly with the flag set"
[ ! -f "$T/calls/launch-fastpath" ] && ok \
  || bad "T2.5: the flag must stop the call being made at all (got: $(cat "$T/calls/launch-fastpath" 2>/dev/null))"
# TEST-CHANGE BH-2637: the "(fast-path first)" ssh log line is gone; the made-call line is "fastpath[<p>]: every key launched".
! logged 'fastpath\[' && ok || bad "T2.5: a call that was not made must not be logged as made (D5)"
rm -f "$T/flags/fastpath-off"

# ---------------------------------------------------------------------------
# T2.6 flags/wake-launch-off still launches nothing, fast-path included
# ---------------------------------------------------------------------------
reset; export FP_RC=0; touch "$T/flags/wake-launch-off"
printf '[{"number":331,"closedAt":"%s"}]\n' "$NOW_ISO" > "$T/gh-closed.json"
cat > "$T/gh-all.json" <<'J'
[{"number":331,"state":"CLOSED","title":"parent","body":"the blocker"},
 {"number":332,"state":"OPEN","title":"child","body":"Blocked-by: #331"}]
J
wakes "$(W 50 issue 43)" "$(W 51 push hhh8888 example-org/project-5)"
# TEST-CHANGE BH-2637: each wake is claimed by the box that owns its repo, so both boxes run.
run "$HUB"; run "$TSBOX"
[ ! -f "$T/calls/launch-fastpath" ] && ok \
  || bad "T2.6: wake-launch-off must not reach the fast-path either"
[ ! -f "$T/calls/run-triage" ] && [ ! -f "$T/calls/ssh" ] && ok \
  || bad "T2.6: wake-launch-off must launch no triage anywhere"
[ -f "$T/state/wake-project-3" ] && ok || bad "T2.6: the un-brake must still happen"
[ "$(calls deploy-train)" = 1 ] && ok || bad "T2.6: the deploy train must still depart"
rm -f "$T/flags/wake-launch-off"

# ---------------------------------------------------------------------------
# T2.7 no launch-fastpath.sh on the box: both arms are today's loop
# ---------------------------------------------------------------------------
# TEST-CHANGE BH-2637: as in T2.5, the project-5 half runs as its owning box and
# the byte-for-byte ssh string becomes the plain local arm with no ssh.
# This is why tests/wake-loop-test.sh, tests/reverse-dep-wake-test.sh and
# tests/event-wake-scope-test.sh keep passing with zero edits — their fixtures
# copy named scripts, and this one is not among them.
reset; export FP_RC=0; rm -f "$T/bin/launch-fastpath.sh"
wakes "$(W 60 issue 41 example-org/project-5)" "$(W 61 issue 41)"
run "$TSBOX"
# TEST-CHANGE BH-2637: the launch is the owning box's local tick, not an ssh.
waitfor "$T/calls/run-triage" || bad "T2.7: a missing fast-path must not stop the launch"
# TEST-CHANGE BH-2637: "today's string" is today's local arm: keys file, un-brake, triage, no ssh.
grep -qx 'project-5' "$T/calls/run-triage" 2>/dev/null && [ "$(cat "$T/state/wake-keys-project-5" 2>/dev/null)" = 41 ] \
  && [ -f "$T/state/wake-project-5" ] && [ ! -s "$T/calls/ssh" ] && ok \
  || bad "T2.7: with no fast-path on the box the owning box must take today's plain local arm, no ssh.
  run-triage: $(cat "$T/calls/run-triage" 2>/dev/null)  keys: $(cat "$T/state/wake-keys-project-5" 2>/dev/null)  ssh: $(cat "$T/calls/ssh" 2>/dev/null)"
run "$HUB"
waitfor "$T/calls/run-triage" || bad "T2.7: the local arm must still buy its tick"
grep -qx 'project-3' "$T/calls/run-triage" 2>/dev/null && ok \
  || bad "T2.7: the local arm must launch triage directly when the script is absent"
[ ! -f "$T/calls/launch-fastpath" ] && ok || bad "T2.7: nothing may be called"
# TEST-CHANGE BH-2637: the "(fast-path first)" ssh log line is gone; the made-call line is "fastpath[<p>]: every key launched".
! logged 'fastpath\[' && ok || bad "T2.7: an absent script must not be logged as tried (D5)"
cat > "$T/bin/launch-fastpath.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/launch-fastpath"
exit "${FP_RC:-1}"
SH
chmod +x "$T/bin/launch-fastpath.sh"

# ---------------------------------------------------------------------------
# T2.8 a wake that names NO key never calls the fast-path
# ---------------------------------------------------------------------------
# Zero keys is exit 1 by the contract, so calling it would be one ssh round trip
# to be declined — and the keyless remote string is the one that REMOVES a stale
# keys file, which must survive untouched.
# WHICH ROUTE THIS FIXTURE TAKES: an empty "key" in the wake row does not survive
# the TSV (the event field slides into it), so the key that reaches key_add is a
# real string — 49 characters, one past the ticket-key ceiling key_add enforces.
# It is dropped there, which is the production shape of "a key we cannot spell":
# the wake still launches its tick, keyless.
KEY49=$(printf 'k%.0s' $(seq 1 49))
# TEST-CHANGE BH-2637: run as the owning box; the stale keys file it must remove
# is seeded in this tree, where the local arm now runs, instead of read off an
# ssh string.
reset; export FP_RC=0; wakes "$(W 70 issue "$KEY49" example-org/project-5)"
printf 'stale\n' > "$T/state/wake-keys-project-5"
run "$TSBOX"
# TEST-CHANGE BH-2637: the tick is launched locally on the owning box.
waitfor "$T/calls/run-triage" || bad "T2.8: a keyless issue wake must still launch the tick"
# TEST-CHANGE BH-2637: the stale keys file is removed on the owning box itself.
[ ! -f "$T/state/wake-keys-project-5" ] && grep -qx 'project-5' "$T/calls/run-triage" && ok \
  || bad "T2.8: a keyless wake must still remove a stale keys file: '$(cat "$T/state/wake-keys-project-5" 2>/dev/null)'"
# TEST-CHANGE BH-2637: no ssh string to search — nothing is sent over ssh, and the fast-path is not called.
[ ! -s "$T/calls/ssh" ] && [ ! -f "$T/calls/launch-fastpath" ] && ok \
  || bad "T2.8: zero keys must never be handed to the fast-path, and nothing goes over ssh: $(cat "$T/calls/ssh" "$T/calls/launch-fastpath" 2>/dev/null)"
[ ! -f "$T/calls/launch-fastpath" ] && ok || bad "T2.8: zero keys, no call"
# TEST-CHANGE BH-2637: the "(fast-path first)" ssh log line is gone; the made-call line is "fastpath[<p>]: every key launched".
! logged 'fastpath\[' && ok || bad "T2.8: a keyless launch must not claim a fast-path (D5)"

# ---------------------------------------------------------------------------
# T2.9 the REAL bin/launch-fastpath.sh in the loop is today's behaviour
# ---------------------------------------------------------------------------
# The safety argument for shipping this before the script exists is that the
# contract stub declines every key, so nothing changes. That is a claim about
# two files together, so the recorder is swapped for the REAL one and the pair
# is run as it would ship: declined, logged, and the tick bought exactly as it
# was yesterday.
cp "$DIR/bin/launch-fastpath.sh" "$T/bin/launch-fastpath.sh"
chmod +x "$T/bin/launch-fastpath.sh"
reset; unset FP_RC; wakes "$(W 80 issue 41)"
run
waitfor "$T/calls/run-triage" || bad "T2.9: the real stub declines, so the tick must still be bought"
grep -qx 'project-3' "$T/calls/run-triage" 2>/dev/null && ok \
  || bad "T2.9: with the contract stub the loop must behave exactly as it did before it"
# The reason is the launcher's own: the BH-553 stub says "fastpath not
# implemented", the BH-554 launcher names the first failing condition. Only the
# contract's SHAPE is held here — `FASTPATH-DECLINED <key> :: <reason>` — so the
# fixture stays green on either side of that swap (the per-condition reasons
# are pinned in tests/launch-fastpath-test.sh once that file exists).
grep -qE 'FASTPATH-DECLINED 41 :: [^:].*$' "$T/logs/project-3.log" 2>/dev/null && ok \
  || bad "T2.9: the launcher must say why it declined: $(cat "$T/logs/project-3.log" 2>/dev/null)"
! logged 'fastpath\[project-3\]: every key launched' && ok \
  || bad "T2.9: a declined key must never be logged as launched (D9)"
[ "$(cat "$T/state/wake-keys-project-3" 2>/dev/null)" = 41 ] && ok \
  || bad "T2.9: the bought tick must still be scoped to the key"

echo "wake-fastpath-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
