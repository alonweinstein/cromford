#!/bin/bash
# tests/wake-loop-test.sh — bin/wake-loop.sh turns a wake row into a launch of
# the lane that OWNS it, once, and never into a launch of anything else.
# docs/EVENTS.md.
#
# WHAT IS STUBBED AND WHAT IS UNDER TEST. `curl` is replaced so the worker is a
# file of JSON, and each owning script is replaced by a recorder — so the thing
# actually exercised is the routing: which script, for which project, how many
# times, and what the loop does with a repo the fleet does not own. The recorders
# also prove the NEGATIVE, which is the half that matters: a push must not wake
# the conductor, a push that released no Blocked-by child must not buy a triage
# session, and flags/wake-launch-off must put the loop back to the un-brake it
# did on 2026-09-13.
#
# TWO BOXES, and the fixture runs as both (BH-2637: the loop runs on EVERY box,
# claims its own rows and never ssh's). project-3 is box=local here, so the HUB
# (BOX_NAME=box-hub) owns it, and the hub also claims every repo's
# pr/checks rows for the conductor. project-5 is box=box-project-5-1, so
# its lanes run when the loop runs AS that box, and its triage lands in
# calls/run-triage there — calls/ssh (a recorder) must stay empty everywhere.
# Which box owns a project is a fleet.conf lookup through the REAL
# bin/box-for.sh, not something this loop decides. The worker is
# tests/lib/wake-claim-stub.sh: claims, the cursor row and cooldown rows.
#
# Run from anywhere: tests/wake-loop-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T" WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE
# Every run is the hub unless a case says otherwise (tsrun below).
HUB=box-hub TS=box-project-5-1
export BOX_NAME="$HUB" WCS_WAKES="$T/wakes.json"
mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" "$T/calls"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$T/env/global.env"

# --- the harness tree the loop runs out of ----------------------------------
# jobs-client.sh is the REAL one: the TSV shape it produces is half the contract
# under test, and stubbing it would test the stub.
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/wake-loop.sh"   "$T/bin/wake-loop.sh"
# The reverse-dependency lib rides along because the loop LOOKS FOR IT
# (2026-09-15): without it every expansion path is the off-path, and a fixture
# that silently tests the kill switch is a fixture that proves nothing about the
# loop the fleet runs. What the expansion itself decides is
# tests/reverse-dep-wake-test.sh's subject; here it only has to be armed.
mkdir -p "$T/bin/lib"
cp "$DIR/bin/lib/revdep-lib.sh" "$T/bin/lib/revdep-lib.sh"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/bin/lib/"
chmod +x "$T/bin/"*.sh
# The stub worker (claim / cursor / cooldown / ack routes) and the REAL identity
# scripts (box-name.sh honours BOX_NAME, hub-box.sh names the hub, box-for.sh
# reads the box column below). wcs_identity also points LANE_REGISTRY at the real
# registry, which off the hub is what lets a launch through at all.
wcs_install "$T/bin"
wcs_identity "$T/bin" || { echo "wcs_identity failed"; exit 1; }

cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'project-3\nproject-5\n'; exit 0; }
case "$1/$2" in
  project-3/repo)   echo example-org/project-3 ;;
  project-5/repo) echo example-org/project-5 ;;
  project-3/box)    echo local ;;
  project-5/box)  echo box-project-5-1 ;;
  # The board column, as fleet.conf really spells it: "-" is a GitHub-Issues
  # lane (project-5), a path is an in-app product board (project-3). The loop asks,
  # because only the first kind has a Blocked-by convention for a closure to
  # release anything through.
  project-3/board_prefix)   echo /api/feature-board ;;
  project-5/board_prefix) echo - ;;
  *) exit 1 ;;
esac
SH
# The REAL owner lookup and the REAL child expansion: which box a project runs on
# and whether a merge released a Blocked-by child are the two decisions the new
# path is made of, and a stub of either would be a test of the stub.
cp "$DIR/bin/box-for.sh"            "$T/bin/box-for.sh"
cp "$DIR/bin/unblocked-children.sh" "$T/bin/unblocked-children.sh"
# One recorder per owning script. Each writes its own argv, so "which script for
# which project, and how many times" is a line count in a file.
for s in merge-conductor deploy-train postmerge-qa run-triage; do
  cat > "$T/bin/$s.sh" <<SH
#!/bin/bash
echo "\$*" >> "\$HARNESS/calls/$s"
SH
done
chmod +x "$T/bin/"*.sh

# curl: every wake route goes to the stub worker (tests/lib/wake-claim-stub.sh),
# which serves $T/wakes.json through the claim and logs every request to
# state/wcs/curl.log. The loop must survive a worker that answers nothing, so an
# empty file is legal. REFILL: with state/refill.json present, every claim after
# the first appends a fresh copy of those rows (new ids) first, so a
# multi-cycle invocation finds a FRESH wake each cycle, the way a busy repo
# rings the doorbell — claims are per box, so the same row never comes twice.
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
case "$*" in
  *"/api/wakes/claim"*)
    tpl="$HARNESS/state/refill.json"
    if [ -f "$tpl" ]; then
      n=$(cat "$HARNESS/state/refill-n" 2>/dev/null || echo 0)
      if [ "$n" -gt 0 ]; then
        jq -c --slurpfile t "$tpl" '
          ([.wakes[].id] | max // 0) as $m
          | .wakes += [ $t[0].wakes | to_entries[] | .value + {id: ($m + 1 + .key)} ]' \
          "$HARNESS/wakes.json" > "$HARNESS/wakes.json.new" && mv "$HARNESS/wakes.json.new" "$HARNESS/wakes.json"
      fi
      echo $((n+1)) > "$HARNESS/state/refill-n"
    fi ;;
esac
"$(dirname "$0")/wcs-routes" "$@" && exit 0
printf '{}\n200'
SH
# ssh: nothing in this loop may reach for it any more (BH-2637). The recorder
# stays so every case can assert calls/ssh was never written.
cat > "$T/bin/ssh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/ssh"
SH
# gh: two shapes, both served from files so a test can say what GitHub knows.
#   --state closed -> what this push closed  (bin/wake-loop.sh closed_diff)
#   --state all    -> the ai-build issues    (bin/unblocked-children.sh)
# Absent file = "[]", which is how every test that is not about the push path
# gets today's answer: nothing closed, so nothing was unblocked.
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
# setsid is Linux-only and `flock` is exercised by its own suite; neither is
# under test here, and on macOS the first does not exist at all.
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
reset() { rm -rf "$T/calls" "$T/state"; mkdir -p "$T/calls" "$T/state"; rm -f "$T/gh-closed.json" "$T/gh-all.json"; }
# refill — keep serving the rows now in wakes.json as fresh wakes, one copy per
# later claim (see the curl stub).
refill() { cp "$T/wakes.json" "$T/state/refill.json"; }
# The stub worker's state: the request log, the cursor rows, the cooldown stamps.
REQ() { wcs_log; }
ACKS() { REQ | grep '^POST /api/wakes/ack '; }
cool_stamp() { mkdir -p "$T/state/wcs/cool"; printf '%s' "$2" > "$T/state/wcs/cool/$1"; }
# NOW, as GitHub would report it. The push path filters on a WINDOW
# (WAKE_PUSH_WINDOW_S, 900s), so a fixture that hardcodes a date rots into a
# passing-by-accident suite the day it falls out of the window.
NOW_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
# The loop launches every lane DETACHED on purpose (deploy-train polls a version
# endpoint for ~13 minutes), so each recorder writes a moment after the loop has
# already exited. The fixture waits for the recorders to QUIESCE rather than
# sleeping a fixed amount: a fixed sleep is a race with the loader on the box,
# and a suite that goes green or red by luck is worse than no suite. Quiesce =
# two consecutive samples with the same total recorded bytes, capped at ~3s so a
# genuinely silent run (the negative assertions) still finishes fast.
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
run()   { "$T/bin/wake-loop.sh"; RC=$?; settle; return "$RC"; }
# tsrun — the same, as the box that owns project-5.
tsrun() { BOX_NAME="$TS" "$T/bin/wake-loop.sh"; RC=$?; settle; return "$RC"; }
# waitfor <file> — the POSITIVE half of settle(). The push path detaches a gh
# lookup and a python expansion, which is slower than two quiet samples, so an
# assertion that something DID happen waits for the file rather than for silence.
waitfor() {
  local i
  for i in $(seq 1 40); do [ -s "$1" ] && return 0; sleep 0.25; done
  return 1
}
calls() { [ -f "$T/calls/$1" ] && wc -l < "$T/calls/$1" | tr -d ' ' || echo 0; }

# ---------------------------------------------------------------------------
# 1. a PR wake runs the CONDUCTOR, and nothing else
# ---------------------------------------------------------------------------
reset; wakes "$(W 1 pr 272)"
run
[ "$(calls merge-conductor)" = 1 ] && ok || bad "a pr wake must launch the conductor once (got $(calls merge-conductor))"
[ ! -f "$T/calls/deploy-train" ] && [ ! -f "$T/calls/postmerge-qa" ] && ok \
  || bad "a pr wake must launch nothing else"
[ ! -f "$T/calls/run-triage" ] && [ ! -f "$T/calls/ssh" ] && ok || bad "a pr wake must not buy a triage session"

# ---------------------------------------------------------------------------
# 2. a checks wake runs the conductor too — same owner, same lane
# ---------------------------------------------------------------------------
reset; wakes "$(W 2 checks abc1234)"
run
[ "$(calls merge-conductor)" = 1 ] && ok || bad "a checks wake must launch the conductor"

# ---------------------------------------------------------------------------
# 3. MANY presses in one batch collapse onto ONE conductor run
# ---------------------------------------------------------------------------
# The conductor buys metered re-reviews. Twenty deliveries on a busy PR must not
# become twenty launches — the conductor re-reads every open PR on every run, so
# one launch answers all of them.
reset
wakes "$(W 3 pr 1)" "$(W 4 pr 2)" "$(W 5 checks def4567)" "$(W 6 pr 3 example-org/project-5)"
run
[ "$(calls merge-conductor)" = 1 ] && ok || bad "a batch of pr/checks wakes must collapse to ONE conductor launch (got $(calls merge-conductor))"

# ---------------------------------------------------------------------------
# 4. a push to main asks the DEPLOY TRAIN, per project
# ---------------------------------------------------------------------------
# TEST-CHANGE BH-2637: each box claims only its own repos' push rows, so the two
# trains depart from the two owning loops — the hub for project-3, then
# box-project-5-1 for project-5 — against the same table.
reset; wakes "$(W 7 push aaa1111)" "$(W 8 push bbb2222 example-org/project-5)"
run
tsrun
[ "$(calls deploy-train)" = 2 ] && ok || bad "one train per project (got $(calls deploy-train))"
grep -qx 'project-3' "$T/calls/deploy-train" && grep -qx 'project-5' "$T/calls/deploy-train" && ok \
  || bad "the train must be launched with the PROJECT, resolved from the repo: $(cat "$T/calls/deploy-train" 2>/dev/null)"
[ ! -f "$T/calls/merge-conductor" ] && ok || bad "a push must not wake the conductor"

# ---------------------------------------------------------------------------
# 5. a successful deployment runs POST-MERGE QA for that project
# ---------------------------------------------------------------------------
reset; wakes "$(W 9 deploy ccc3333)"
run
[ "$(calls postmerge-qa)" = 1 ] && grep -qx 'project-3' "$T/calls/postmerge-qa" && ok \
  || bad "a deploy wake must launch postmerge-qa <project> (got: $(cat "$T/calls/postmerge-qa" 2>/dev/null))"

# ---------------------------------------------------------------------------
# 6. an ISSUE wake un-brakes the triage gate AND runs the tick that consumes it
# ---------------------------------------------------------------------------
# the operator, 2026-09-14: the un-brake alone reached nothing. This loop runs on the hub
# and every fleet.conf row names a box, so the file landed where that project's
# gate never looks — and even on the right box it only bought a tick that was not
# braked, up to ten minutes later.
reset; wakes "$(W 10 issue 41)"
run
[ -f "$T/state/wake-project-3" ] && ok || bad "an issue wake must still write state/wake-<project>"
waitfor "$T/calls/run-triage"
[ "$(calls run-triage)" = 1 ] && grep -qx 'project-3' "$T/calls/run-triage" && ok \
  || bad "an issue wake must run THIS project's triage now (got: $(cat "$T/calls/run-triage" 2>/dev/null))"
[ ! -f "$T/calls/merge-conductor" ] && [ ! -f "$T/calls/deploy-train" ] && ok \
  || bad "an issue wake must launch nothing but triage"
# …and the gate consumes it ONE-SHOT, before the 45-minute queue brake.
GATE_OUT=$(HARNESS="$T" bash "$DIR/bin/triage-gate.sh" project-3 2>/dev/null)
[ "$GATE_OUT" = "RUN event-wake" ] && ok || bad "triage-gate must honour the wake file (got '$GATE_OUT')"
[ ! -f "$T/state/wake-project-3" ] && ok || bad "the wake file must be one-shot"
GATE2=$(HARNESS="$T" bash "$DIR/bin/triage-gate.sh" project-3 2>/dev/null)
[ "$GATE2" != "RUN event-wake" ] && ok || bad "a consumed wake must not keep firing (got '$GATE2')"

# ---------------------------------------------------------------------------
# 7. a repo the fleet does not own is dropped, never guessed at
# ---------------------------------------------------------------------------
# TEST-CHANGE BH-2637: the worker only hands a box its own repos, so CLAIM_ALL=1
# (a mis-filtering worker) is what puts the foreign row in front of the loop.
reset; wakes "$(W 11 push ddd4444 SomeoneElse/not-ours)"
CLAIM_ALL=1 run
[ ! -f "$T/calls/deploy-train" ] && ok || bad "a foreign repo must launch nothing"
grep -q "not a fleet repo" "$T/logs/wake-loop.log" && ok || bad "a dropped wake must say so in the log"

# ---------------------------------------------------------------------------
# 8. the WATERMARK moves, and the ack is sent — in that order
# ---------------------------------------------------------------------------
reset; wakes "$(W 20 pr 1)" "$(W 24 pr 2)"
run
# TEST-CHANGE BH-2637: the watermark is this box's wake_cursors row (PUT before
# the ack), not a state/wake-cursor file.
[ "$(cat "$T/state/wcs/cursor.$HUB" 2>/dev/null)" = 24 ] && [ ! -e "$T/state/wake-cursor" ] && ok \
  || bad "cursor row must advance to the highest id handled (got $(cat "$T/state/wcs/cursor.$HUB" 2>/dev/null))"
PUTL=$(REQ | grep -n -m1 '^PUT /api/wakes/cursor ' | cut -d: -f1); ACKL=$(REQ | grep -n -m1 '^POST /api/wakes/ack ' | cut -d: -f1)
[ -n "$PUTL" ] && [ -n "$ACKL" ] && [ "$PUTL" -lt "$ACKL" ] && ok || bad "the cursor PUT must come before the ack: $(REQ)"
ACKS | grep -q '"ids"' && ok || bad "handled wakes must be acked"
ACKS | grep -q '20' && ACKS | grep -q '24' && ok || bad "every handled id must be acked: $(ACKS)"
# …and the NEXT invocation reads the cursor row and claims only rows past it,
# which is what makes a failed ack harmless.
# TEST-CHANGE BH-2637: no `since=` poll exists; the claim scans above the cursor
# row the loop GETs, so the proof is the GET and a drain that found nothing.
rm -f "$T/calls/merge-conductor"; : > "$T/state/wcs/curl.log"; : > "$T/logs/wake-loop.log"
WAKE_COOLDOWN_S=0 run
REQ | grep -q "^GET /api/wakes/cursor?box=$HUB" && ! grep -q 'drained' "$T/logs/wake-loop.log" \
  && [ ! -f "$T/calls/merge-conductor" ] && ok || bad "the next claim must start at the watermark: $(REQ) / $(cat "$T/logs/wake-loop.log")"

# ---------------------------------------------------------------------------
# 9. the COOLDOWN is a dedup-before-spend guard, not a nicety
# ---------------------------------------------------------------------------
# Two separate drains inside the cooldown window must produce ONE conductor run:
# the conductor buys metered re-reviews and a busy repo rings this doorbell many
# times a minute.
reset; wakes "$(W 30 pr 1)"
run
wakes "$(W 31 pr 2)"
run
[ "$(calls merge-conductor)" = 1 ] && ok || bad "the cooldown must hold a second launch inside the window (got $(calls merge-conductor))"
# With the cooldown at zero the second drain launches again — proving the guard
# is the COOLDOWN and not some accident of the fixture.
reset; wakes "$(W 40 pr 1)"
WAKE_COOLDOWN_S=0 run
wakes "$(W 41 pr 2)"
WAKE_COOLDOWN_S=0 run
[ "$(calls merge-conductor)" = 2 ] && ok || bad "with no cooldown both drains must launch (got $(calls merge-conductor))"

# ---------------------------------------------------------------------------
# 10. an empty feed, an unreachable worker and the kill switch are all silent
# ---------------------------------------------------------------------------
reset; wakes
run; RC=$?
[ "$RC" = 0 ] && [ ! -f "$T/calls/merge-conductor" ] && ok || bad "an empty feed must be a silent exit 0"
reset; printf 'not json at all' > "$T/wakes.json"
run; RC=$?
[ "$RC" = 0 ] && [ ! -f "$T/calls/merge-conductor" ] && ok || bad "a garbage answer must launch nothing and exit 0"
reset; wakes "$(W 45 pr 1)"
CLAIM_MODE=500 run; RC=$?
[ "$RC" = 0 ] && [ ! -f "$T/calls/merge-conductor" ] && grep -q 'claim unavailable' "$T/logs/wake-loop.log" && ok \
  || bad "an unreachable claim must launch nothing, say so and exit 0"
reset; wakes "$(W 50 pr 1)"; touch "$T/flags/wake-loop-off"
run; RC=$?
[ "$RC" = 0 ] && [ ! -f "$T/calls/merge-conductor" ] && ok || bad "flags/wake-loop-off must stop every launch"
rm -f "$T/flags/wake-loop-off"

# ---------------------------------------------------------------------------
# 11. a PUSH that closed a blocker launches triage ON THE OWNING BOX
# ---------------------------------------------------------------------------
# The row carries a head sha and nothing else, so "what did this merge close" is
# a gh lookup over the close timestamps, and only a released Blocked-by child
# makes the push worth a session. project-5 is box=box-project-5-1 here,
# so the launch — un-brake included — happens on THAT box, run by its own loop.
reset
printf '[{"number":331,"closedAt":"%s"}]\n' "$NOW_ISO" > "$T/gh-closed.json"
cat > "$T/gh-all.json" <<'J'
[{"number":331,"state":"CLOSED","title":"parent","body":"the blocker"},
 {"number":332,"state":"OPEN","title":"child","body":"Blocked-by: #331"}]
J
wakes "$(W 60 push eee5555 example-org/project-5)"
# TEST-CHANGE BH-2637: the ssh arm is gone. The owning box's own loop launches
# the tick locally; every ssh assertion below now pins that local launch and
# the ABSENCE of any ssh.
tsrun
waitfor "$T/calls/run-triage" || bad "a push that released a child must launch triage on its box"
grep -q "triage\[project-5\].*launched run-triage.sh project-5" "$T/logs/wake-loop.log" && [ ! -f "$T/calls/ssh" ] && ok \
  || bad "the launch must happen on the box fleet.conf names, never over ssh: $(cat "$T/calls/ssh" 2>/dev/null)"
[ "$(cat "$T/calls/run-triage" 2>/dev/null)" = project-5 ] && ok \
  || bad "the launched command must be that project's own run-triage.sh"
[ -f "$T/state/wake-project-5" ] && ok \
  || bad "the un-brake must be written before the launch, or the tick we just bought answers SKIP"
grep -q '332' "$T/state/wake-keys-project-5" 2>/dev/null && ok \
  || bad "the released child must be in the tick's keys file on the owning box"
[ ! -f "$T/calls/ssh" ] && ok || bad "no box ever launches triage over ssh"
# …and the hub, handed the same row by a mis-filtering worker, leaves it to its
# owner: no launch and no ssh there.
rm -f "$T/calls/run-triage"; : > "$T/logs/wake-loop.log"
wakes "$(W 61 push eee5556 example-org/project-5)"
CLAIM_ALL=1 run
[ ! -f "$T/calls/run-triage" ] && [ ! -f "$T/calls/ssh" ] \
  && grep -q 'another box owns the repo — example-org/project-5' "$T/logs/wake-loop.log" && ok \
  || bad "a box-owned project must never be triaged on the hub (TK-42, twin PRs): $(cat "$T/logs/wake-loop.log")"
[ "$(calls deploy-train)" = 1 ] && ok || bad "the deploy train must still depart on the same push"

# ---------------------------------------------------------------------------
# 12. a push that released NOTHING buys nothing
# ---------------------------------------------------------------------------
# The check still runs — that is the point of asserting on calls/gh — it just
# finds no child, and the merge's aftermath stays with the lanes that own it.
reset
printf '[]\n' > "$T/gh-closed.json"
wakes "$(W 70 push fff6666 example-org/project-5)"
tsrun
waitfor "$T/calls/gh" || bad "a push must check for unblocked children"
[ ! -f "$T/calls/ssh" ] && [ ! -f "$T/calls/run-triage" ] && ok \
  || bad "a push that closed nothing must not buy a triage session"

# ---------------------------------------------------------------------------
# 13. the close has to be RECENT — an old close is not this push's doing
# ---------------------------------------------------------------------------
reset
printf '[{"number":331,"closedAt":"2020-01-01T00:00:00Z"}]\n' > "$T/gh-closed.json"
cat > "$T/gh-all.json" <<'J'
[{"number":331,"state":"CLOSED","title":"parent","body":"the blocker"},
 {"number":332,"state":"OPEN","title":"child","body":"Blocked-by: #331"}]
J
wakes "$(W 75 push ggg7777 example-org/project-5)"
tsrun
waitfor "$T/calls/gh" || bad "a push must check for unblocked children"
# TEST-CHANGE BH-2637: the launch would be local now, so calls/run-triage is the
# half that can see it; no ssh stays asserted.
[ ! -f "$T/calls/ssh" ] && [ ! -f "$T/calls/run-triage" ] && ok \
  || bad "a close from 2020 is outside WAKE_PUSH_WINDOW_S and is not this merge's work"

# ---------------------------------------------------------------------------
# 14. the triage COOLDOWN is per project, and it is the guard before the spend
# ---------------------------------------------------------------------------
reset; wakes "$(W 80 issue 41)"
run; waitfor "$T/calls/run-triage"
wakes "$(W 81 issue 42)"
run
[ "$(calls run-triage)" = 1 ] && ok \
  || bad "two issue wakes inside the window must buy ONE triage tick (got $(calls run-triage))"
reset; wakes "$(W 85 issue 41)"
WAKE_TRIAGE_COOLDOWN_S=0 run; waitfor "$T/calls/run-triage"
wakes "$(W 86 issue 42)"
WAKE_TRIAGE_COOLDOWN_S=0 run
[ "$(calls run-triage)" = 2 ] && ok \
  || bad "with no triage cooldown both drains must launch (got $(calls run-triage))"

# ---------------------------------------------------------------------------
# 15. flags/wake-launch-off is byte-for-byte the loop of 2026-09-13
# ---------------------------------------------------------------------------
# The un-brake and the deploy train still happen; nothing is launched, and the
# children check is not even asked — no gh call at all.
reset
printf '[{"number":331,"closedAt":"%s"}]\n' "$NOW_ISO" > "$T/gh-closed.json"
cat > "$T/gh-all.json" <<'J'
[{"number":331,"state":"CLOSED","title":"parent","body":"the blocker"},
 {"number":332,"state":"OPEN","title":"child","body":"Blocked-by: #331"}]
J
touch "$T/flags/wake-launch-off"
wakes "$(W 90 issue 43)" "$(W 91 push hhh8888 example-org/project-5)"
# TEST-CHANGE BH-2637: the project-3 issue is the hub's, the project-5 push is
# box-project-5-1's — both loops run against the same table.
run
tsrun
[ -f "$T/state/wake-project-3" ] && ok || bad "with the flag set the un-brake must still happen"
[ ! -f "$T/calls/run-triage" ] && [ ! -f "$T/calls/ssh" ] && ok \
  || bad "wake-launch-off must launch no triage anywhere"
[ ! -f "$T/calls/gh" ] && ok || bad "wake-launch-off must not even ask GitHub what closed"
[ "$(calls deploy-train)" = 1 ] && ok || bad "wake-launch-off must leave the deploy train alone"
rm -f "$T/flags/wake-launch-off"


# ---------------------------------------------------------------------------
# 16. a push AND an issue for one project: the train departs, triage runs ONCE
# ---------------------------------------------------------------------------
# The deploy train's own `push` cooldown and the triage launch's `triage`
# cooldown are separate keys — share them and one lane silently eats the other's
# launch. The issue wake takes precedence over the push wake for the same
# project (a client's answer beats a merge that may have released nothing), so
# the children lookup is not even made.
reset
wakes "$(W 95 push iii9999)" "$(W 96 issue 44)"
run
waitfor "$T/calls/run-triage" || bad "an issue wake alongside a push must still run triage"
[ "$(calls run-triage)" = 1 ] && ok || bad "exactly one triage tick for one project (got $(calls run-triage))"
[ "$(calls deploy-train)" = 1 ] && ok || bad "the deploy train must not lose its launch to the triage cooldown"
[ ! -f "$T/calls/gh" ] && ok || bad "an issue wake already owns the tick — the push must not also look for children"


# ---------------------------------------------------------------------------
# 17. the DEFAULT conductor cooldown is 120s (BH-373)
# ---------------------------------------------------------------------------
# The hub ran WAKE_COOLDOWN_S=120 by hand from 2026-09-13 because 60s let the
# wake loop launch the conductor ~19 times an hour on top of the 12 cron ticks.
# The default is now that number, so a box with no env file gets the same brake.
# Nothing here sets WAKE_COOLDOWN_S: the point of the case is the DEFAULT, so
# the stamp is back-dated instead of the window being widened. The stamp is the
# (pr, fleet) wake_cooldowns row in the stub worker; the loop sends the window.
reset; wakes "$(W 100 pr 1)"
run
[ "$(calls merge-conductor)" = 1 ] && ok || bad "a pr wake must launch the conductor once (got $(calls merge-conductor))"
# TEST-CHANGE BH-2637: back-date the wake_cooldowns row, not a state file.
cool_stamp pr-fleet "$(date -d '-61 sec' +%s)"
wakes "$(W 101 pr 2)"
run
[ "$(calls merge-conductor)" = 1 ] && ok \
  || bad "61s after the last launch the DEFAULT window must still hold it (got $(calls merge-conductor) — is the default still 60?)"
# TEST-CHANGE BH-2637: back-date the wake_cooldowns row, not a state file.
cool_stamp pr-fleet "$(date -d '-121 sec' +%s)"
wakes "$(W 102 pr 3)"
run
[ "$(calls merge-conductor)" = 2 ] && ok \
  || bad "past 120s the default window must release the launch (got $(calls merge-conductor))"
# The one source pin the ticket asks for, guarded by equality so an ABSENT
# token fails instead of passing (D3).
[ "$(grep -c 'WAKE_COOLDOWN_S:-120' "$DIR/bin/wake-loop.sh")" = 1 ] && ok \
  || bad "bin/wake-loop.sh must default WAKE_COOLDOWN_S to 120, exactly once"

# ---------------------------------------------------------------------------
# 18. the PER-INVOCATION conductor cap (BH-373)
# ---------------------------------------------------------------------------
# The cooldown is the brake between ticks; this is the brake INSIDE one. A cron
# minute polls four times, and four cycles that each find a fresh pr wake used
# to buy four conductor runs at 40-60 API calls each. Cron */5 keeps firing, so
# a held launch is a launch deferred by minutes, never a launch lost.
held() { awk '/conductor launch held/{n++} END{print n+0}' "$T/logs/wake-loop.log" 2>/dev/null; }
# TEST-CHANGE BH-2637: a claimed row never comes back to the same box, so refill
# serves the fresh pr wake each cycle that the old stub served by ignoring since=.
reset; : > "$T/logs/wake-loop.log"; wakes "$(W 110 pr 1)"; refill
WAKE_COOLDOWN_S=0 WAKE_LOOP_CYCLES=3 run
[ "$(calls merge-conductor)" = 1 ] && ok \
  || bad "three cycles with the cooldown off must still buy ONE conductor launch (got $(calls merge-conductor))"
[ "$(grep -cF 'pr/checks: conductor launch held — per-tick cap 1 reached (the cron sweep still covers it)' "$T/logs/wake-loop.log")" = 1 ] && ok \
  || bad "the cap must say so ONCE per invocation, in those words (got $(held))"
# TEST-CHANGE BH-2637: acks are read from the stub worker's request log; 111 is
# the refilled row the second cycle held.
ACKS | grep -q 110 && ACKS | grep -q 111 && ok || bad "a wake held by the cap must still be acked: $(ACKS)"
# …and the counter is per INVOCATION: a second process starts at zero.
WAKE_COOLDOWN_S=0 WAKE_LOOP_CYCLES=3 run
[ "$(calls merge-conductor)" = 2 ] && ok \
  || bad "the cap must not survive the tick — a fresh invocation launches again (got $(calls merge-conductor))"
# 0 = unlimited, the fleet's cap convention.
reset; : > "$T/logs/wake-loop.log"; wakes "$(W 111 pr 1)"; refill
WAKE_CONDUCTOR_PER_TICK=0 WAKE_COOLDOWN_S=0 WAKE_LOOP_CYCLES=3 run
[ "$(calls merge-conductor)" = 3 ] && ok || bad "WAKE_CONDUCTOR_PER_TICK=0 must be unlimited (got $(calls merge-conductor))"
[ "$(held)" = 0 ] && ok || bad "an unlimited cap must hold nothing and say nothing (got $(held) held line(s))"
# an explicit number is honoured, never clamped
reset; : > "$T/logs/wake-loop.log"; wakes "$(W 112 pr 1)"; refill
WAKE_CONDUCTOR_PER_TICK=2 WAKE_COOLDOWN_S=0 WAKE_LOOP_CYCLES=3 run
[ "$(calls merge-conductor)" = 2 ] && ok || bad "an explicit cap of 2 must allow two launches (got $(calls merge-conductor))"
[ "$(held)" = 1 ] && ok || bad "the third cycle must be held, once (got $(held))"
# a typo is not a cap of zero and not silence
reset; : > "$T/logs/wake-loop.log"; wakes "$(W 113 pr 1)"; refill
WAKE_CONDUCTOR_PER_TICK=abc WAKE_COOLDOWN_S=0 WAKE_LOOP_CYCLES=3 run
[ "$(calls merge-conductor)" = 1 ] && ok || bad "a non-numeric cap must fall back to 1 (got $(calls merge-conductor))"
[ "$(grep -cF "WAKE_CONDUCTOR_PER_TICK='abc' is not a number" "$T/logs/wake-loop.log")" = 1 ] && ok \
  || bad "a non-numeric cap must say so once: $(grep -c . "$T/logs/wake-loop.log") log line(s)"
# the conductor is fleet-wide, so two projects in one drain were always one
# launch — the cap must not be what makes that true.
reset; : > "$T/logs/wake-loop.log"
wakes "$(W 120 pr 1)" "$(W 121 pr 2 example-org/project-5)"
WAKE_COOLDOWN_S=0 run
[ "$(calls merge-conductor)" = 1 ] && ok || bad "two projects' pr wakes in one drain are still one launch (got $(calls merge-conductor))"
[ "$(held)" = 0 ] && ok || bad "one launch for one drain must not report a held launch (got $(held))"
# and nothing else counts against it: the train departs on every cycle.
reset; : > "$T/logs/wake-loop.log"
wakes "$(W 130 pr 1)" "$(W 131 push abc1111)"; refill
WAKE_COOLDOWN_S=0 WAKE_LOOP_CYCLES=3 run
[ "$(calls merge-conductor)" = 1 ] && ok || bad "the cap must hold the conductor across cycles (got $(calls merge-conductor))"
[ "$(calls deploy-train)" = 3 ] && ok \
  || bad "push wakes must never count against the CONDUCTOR cap (got $(calls deploy-train) train launches)"

# ---------------------------------------------------------------------------
# 19. the BUDGET-LOW stretch of the conductor cooldown (BH-373)
# ---------------------------------------------------------------------------
# bin/lib/gh-budget.sh (#372) answers rc 0 low / 1 healthy / 2 unknown. Low means
# the hour's GitHub budget is nearly spent, and the conductor is the biggest
# spender this loop can start, so its window stretches by WAKE_BUDGET_STRETCH.
# The lib is optional on purpose: a box without it must behave exactly as before.
mkdir -p "$T/bin/lib"
cat > "$T/bin/lib/gh-budget.sh" <<'SH'
gh_budget_low() { return "${SHIM_BUDGET_RC:-1}"; }
SH
reset; : > "$T/logs/wake-loop.log"; wakes "$(W 140 pr 1)"
SHIM_BUDGET_RC=0 WAKE_COOLDOWN_S=10 run
[ "$(calls merge-conductor)" = 1 ] && ok || bad "a low budget must not stop the FIRST launch (got $(calls merge-conductor))"
# TEST-CHANGE BH-2637: back-date the wake_cooldowns row, not a state file.
cool_stamp pr-fleet "$(date -d '-30 sec' +%s)"
wakes "$(W 141 pr 2)"
SHIM_BUDGET_RC=0 WAKE_COOLDOWN_S=10 run
[ "$(calls merge-conductor)" = 1 ] && ok \
  || bad "30s into a stretched 50s window the launch must be held (got $(calls merge-conductor))"
# TEST-CHANGE BH-2637: back-date the wake_cooldowns row, not a state file.
cool_stamp pr-fleet "$(date -d '-60 sec' +%s)"
wakes "$(W 142 pr 3)"
SHIM_BUDGET_RC=0 WAKE_COOLDOWN_S=10 run
[ "$(calls merge-conductor)" = 2 ] && ok \
  || bad "past the stretched window the launch must happen (got $(calls merge-conductor))"
# rc 2 is UNKNOWN, not low: an unreadable budget must never slow the fleet down.
reset; wakes "$(W 150 pr 1)"
SHIM_BUDGET_RC=2 WAKE_COOLDOWN_S=10 run
# TEST-CHANGE BH-2637: back-date the wake_cooldowns row, not a state file.
cool_stamp pr-fleet "$(date -d '-30 sec' +%s)"
wakes "$(W 151 pr 2)"
SHIM_BUDGET_RC=2 WAKE_COOLDOWN_S=10 run
[ "$(calls merge-conductor)" = 2 ] && ok \
  || bad "rc 2 (unknown) must leave the window at WAKE_COOLDOWN_S (got $(calls merge-conductor))"
# rc 1 is HEALTHY: same, and this is the path every tick takes most of the time.
reset; wakes "$(W 155 pr 1)"
SHIM_BUDGET_RC=1 WAKE_COOLDOWN_S=10 run
# TEST-CHANGE BH-2637: back-date the wake_cooldowns row, not a state file.
cool_stamp pr-fleet "$(date -d '-30 sec' +%s)"
wakes "$(W 156 pr 2)"
SHIM_BUDGET_RC=1 WAKE_COOLDOWN_S=10 run
[ "$(calls merge-conductor)" = 2 ] && ok \
  || bad "a healthy budget must leave the window at WAKE_COOLDOWN_S (got $(calls merge-conductor))"
# an explicit stretch is honoured; a typo falls back to 5 with one line, because
# $((10 * abc)) is 0 in bash and would REMOVE the cooldown.
reset; : > "$T/logs/wake-loop.log"; wakes "$(W 160 pr 1)"
SHIM_BUDGET_RC=0 WAKE_COOLDOWN_S=10 WAKE_BUDGET_STRETCH=abc run
# TEST-CHANGE BH-2637: back-date the wake_cooldowns row, not a state file.
cool_stamp pr-fleet "$(date -d '-30 sec' +%s)"
wakes "$(W 161 pr 2)"
# truncated HERE so the count below is one invocation's worth: the line belongs
# to the config block, so a second tick with the same typo says it again.
: > "$T/logs/wake-loop.log"
SHIM_BUDGET_RC=0 WAKE_COOLDOWN_S=10 WAKE_BUDGET_STRETCH=abc run
[ "$(calls merge-conductor)" = 1 ] && ok \
  || bad "a non-numeric stretch must fall back to 5, never to no cooldown at all (got $(calls merge-conductor))"
[ "$(grep -cF "WAKE_BUDGET_STRETCH='abc' is not a number" "$T/logs/wake-loop.log")" = 1 ] && ok \
  || bad "a non-numeric stretch must say so once"
# …and with the lib absent the loop is byte-for-byte what it was: no stretch,
# no error noise from a function nobody defined.
rm -f "$T/bin/lib/gh-budget.sh"
reset; : > "$T/logs/wake-loop.log"; wakes "$(W 170 pr 1)"
WAKE_COOLDOWN_S=10 run
# TEST-CHANGE BH-2637: back-date the wake_cooldowns row, not a state file.
cool_stamp pr-fleet "$(date -d '-30 sec' +%s)"
wakes "$(W 171 pr 2)"
WAKE_COOLDOWN_S=10 run
[ "$(calls merge-conductor)" = 2 ] && ok \
  || bad "with no bin/lib/gh-budget.sh the window must stay at WAKE_COOLDOWN_S (got $(calls merge-conductor))"
! grep -q 'gh_budget_low' "$T/logs/wake-loop.log" && ok \
  || bad "a missing budget lib must be silent, not an error: $(grep -n 'gh_budget_low' "$T/logs/wake-loop.log")"

# ---------------------------------------------------------------------------
# 20. a PUSH that consumes the un-brake carries the COALESCED keys (BH-1130)
# ---------------------------------------------------------------------------
# The coalescing window is per PROJECT and so is the un-brake, but until BH-1130
# only the ISSUE arm ever emptied the pending list. Sequence, replayed below:
# an issue wake for 41 lands inside the window and is held (its key goes to
# state/wake-keys/pending-<p>, its un-brake is written); a push past the window
# then releases child 332 and takes the SAME project's `triage` cooldown, and
# its launch consumes that one-shot un-brake with a keys file naming 332 alone.
# bin/lib/rt/scope.sh scopes the tick it bought to 332, the push arm never
# key_takes, and 41 is worked by neither the fast path nor the tick — it waits
# for the NEXT issue wake, which on a quiet board may never come.
# The keys the window held must ride the launch that spent their un-brake.
NOW=$(date +%s)
# TEST-CHANGE BH-2637: the triage cooldown is the (triage, <p>) wake_cooldowns
# row, and the launch is local on the owning box, so "which keys did that tick
# get" is the keys file launch_triage wrote there — not an ssh argv.
stamp() { cool_stamp "triage-$1" "$2"; }
lockeys() { tr '\n' ' ' < "$T/state/wake-keys-$1" 2>/dev/null; }
has() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }
released() {
  printf '[{"number":331,"closedAt":"%s"}]\n' "$NOW_ISO" > "$T/gh-closed.json"
  cat > "$T/gh-all.json" <<'J'
[{"number":331,"state":"CLOSED","title":"parent","body":"the blocker"},
 {"number":332,"state":"OPEN","title":"child","body":"Blocked-by: #331"}]
J
}

# 20a — the ticket's own sequence, on box-project-5-1's own loop: issue
# wake 41 held, push wake releases 332, ONE tick and it carries BOTH.
reset
stamp project-5 "$NOW"
wakes "$(W 300 issue 41 example-org/project-5)"
tsrun
[ ! -f "$T/calls/ssh" ] && [ ! -f "$T/calls/run-triage" ] && ok \
  || bad "20a: an issue wake inside the window must buy nothing (got: $(cat "$T/calls/ssh" 2>/dev/null))"
grep -qx '41' "$T/state/wake-keys/pending-project-5" 2>/dev/null && ok \
  || bad "20a: the held key must be in the pending list (got: $(cat "$T/state/wake-keys/pending-project-5" 2>/dev/null))"
stamp project-5 "$(( NOW - 300 ))"
released
# The un-brake the ISSUE arm wrote above goes first (as in 20b), so the
# assertion below is about the launch this push makes.
rm -f "$T/state/wake-project-5"
wakes "$(W 301 push eee5555 example-org/project-5)"
tsrun
waitfor "$T/calls/run-triage" || bad "20a: a push that released a child must launch triage on its box"
# TEST-CHANGE BH-2637: one LOCAL launch on the owning box, and no ssh at all.
[ "$(calls run-triage)" = 1 ] && [ "$(calls ssh)" = 0 ] && ok || bad "20a: exactly one launch for one push (got $(calls run-triage), ssh $(calls ssh))"
K20=$(lockeys project-5)
has "$K20" 332 && ok || bad "20a: the released child must still scope the tick (got '$K20')"
has "$K20" 41 && ok \
  || bad "20a: the COALESCED issue key must ride the launch that consumed its un-brake (got '$K20')"
# TEST-CHANGE BH-2637: no connection to ride — the un-brake is written locally.
[ -f "$T/state/wake-project-5" ] && [ ! -f "$T/calls/ssh" ] && ok \
  || bad "20a: the un-brake must still be written for the tick it bought"
[ ! -s "$T/state/wake-keys/pending-project-5" ] && ok \
  || bad "20a: the keys must LEAVE the pending list with the launch that carries them (got: $(cat "$T/state/wake-keys/pending-project-5" 2>/dev/null))"
[ "$(calls deploy-train)" = 1 ] && ok || bad "20a: the deploy train must still depart (got $(calls deploy-train))"
# TEST-CHANGE BH-2637: the tick ran on box-project-5-1 (its log), for
# project-5 only; the hub was never involved and nothing left over ssh.
[ "$(cat "$T/calls/run-triage" 2>/dev/null)" = project-5 ] && [ ! -f "$T/calls/ssh" ] && ok \
  || bad "20a: a box-owned project must never be triaged on the hub (TK-42, twin PRs)"

# 20b — the LOCAL transport, and the half a released child cannot cover: the
# push released nothing at all (project-3 is an in-app board, so
# bin/unblocked-children.sh has no Blocked-by convention to answer through), and
# the ONLY reason to spend is the key the window held. Before BH-1130 that key's
# un-brake was consumed by nothing and the key sat there.
reset
stamp project-3 "$NOW"
wakes "$(W 310 issue 41)"
run
[ ! -f "$T/calls/run-triage" ] && ok \
  || bad "20b: an issue wake inside the window must buy nothing (got: $(cat "$T/calls/run-triage" 2>/dev/null))"
grep -qx '41' "$T/state/wake-keys/pending-project-3" 2>/dev/null && ok \
  || bad "20b: the held key must be in the pending list"
stamp project-3 "$(( NOW - 300 ))"
# The un-brake the ISSUE arm wrote in the drain above goes first, so the
# assertion below is about the launch this push makes and not about a file that
# was already lying there.
rm -f "$T/state/wake-project-3"
wakes "$(W 311 push jjj0000)"
run
waitfor "$T/calls/run-triage" || bad "20b: a push with keys pending must launch even with no released child"
[ "$(calls run-triage)" = 1 ] && grep -qx 'project-3' "$T/calls/run-triage" && ok \
  || bad "20b: one tick, on the box that owns the project (got: $(cat "$T/calls/run-triage" 2>/dev/null))"
grep -qx '41' "$T/state/wake-keys-project-3" 2>/dev/null && ok \
  || bad "20b: the folded key must be what the tick scopes itself to (got: $(cat "$T/state/wake-keys-project-3" 2>/dev/null))"
[ -f "$T/state/wake-project-3" ] && ok || bad "20b: the un-brake must be written for the tick it bought"
[ ! -s "$T/state/wake-keys/pending-project-3" ] && ok \
  || bad "20b: the pending list must be empty after the launch that carried it"
[ ! -f "$T/calls/ssh" ] && ok || bad "20b: a local project must not leave over ssh"

# 20c — the negative that keeps the fold honest: a push that released nothing
# with NOTHING pending still buys nothing. The fold must not turn every push
# into a session.
reset
printf '[]\n' > "$T/gh-closed.json"
wakes "$(W 320 push ggg2222 example-org/project-5)"
tsrun
waitfor "$T/calls/gh" || bad "20c: a push must still check for unblocked children"
[ ! -f "$T/calls/ssh" ] && [ ! -f "$T/calls/run-triage" ] && ok \
  || bad "20c: a push that closed nothing and held nothing must not buy a triage session"

# 20d — the window invariant, in the other direction: key_take runs only after
# `cooled triage` returned 0. A push HELD by the window buys no launch, so a key
# taken there would be dropped on the floor — the same orphan, one arm over.
reset
stamp project-5 "$NOW"
wakes "$(W 330 issue 41 example-org/project-5)"
tsrun
released
stamp project-5 "$NOW"
wakes "$(W 331 push iii4444 example-org/project-5)"
tsrun
[ ! -f "$T/calls/ssh" ] && [ ! -f "$T/calls/run-triage" ] && ok \
  || bad "20d: a push inside the triage window must buy nothing (got: $(cat "$T/calls/ssh" 2>/dev/null))"
grep -qx '41' "$T/state/wake-keys/pending-project-5" 2>/dev/null && ok \
  || bad "20d: a key must never leave the pending list without the launch that carries it (got: $(cat "$T/state/wake-keys/pending-project-5" 2>/dev/null))"

# 20e — flags/wake-coalesce-off is still 2026-09-13, byte for byte: no pending
# list at all, and the push arm carries exactly what it carried before.
reset
touch "$T/flags/wake-coalesce-off"
stamp project-5 "$NOW"
wakes "$(W 340 issue 41 example-org/project-5)"
tsrun
[ ! -e "$T/state/wake-keys/pending-project-5" ] && ok \
  || bad "20e: with coalescing off nothing may be written to a pending list"
stamp project-5 "$(( NOW - 300 ))"
released
wakes "$(W 341 push kkk5555 example-org/project-5)"
tsrun
waitfor "$T/calls/run-triage" || bad "20e: the push must still launch on its released child"
# TEST-CHANGE BH-2637: the keys come from the local keys file, not an ssh argv.
K20E=$(lockeys project-5)
has "$K20E" 332 && ! has "$K20E" 41 && ok \
  || bad "20e: with coalescing off the launch carries the released child and nothing else (got '$K20E')"
rm -f "$T/flags/wake-coalesce-off"


echo "wake-loop-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
