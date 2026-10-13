#!/bin/bash
# tests/triage-lock-inherit-test.sh — NOTHING A TRIAGE TICK SPAWNS MAY CARRY THE
# TICK'S LOCK.
#
# BH-651: the tick opens locks/<project>.lock on fd 9 and flocks it. The shard
# fork closed that fd across its setsid; the single-session agent call did not.
# So the `setsid run-build.sh ... &` the SOP tells every triage session to run
# inherited fd 9 and held the project lock for the build's WHOLE LIFE — pid 8911
# (`run-build.sh cromford 421 BH-421`) was still the only holder 43 minutes
# after its tick had exited, and every tick from 16:13Z to 16:48Z answered
# "previous run still active, skipping". One level down, bin/triage-shard.sh had
# the same leak against fd 8 (the per-ticket key lock).
#
# This runs the REAL bin/run-triage.sh and bin/triage-shard.sh end to end, with
# only their harness and repo ROOTS rewritten (the precedent:
# tests/triage-shards-test.sh). The assertions are artifacts, never source text:
# which fds a DETACHED CHILD can still see, whether the lock is free while that
# child is alive, whether a second tick actually runs, the log line, the argv the
# lane-alert stub received, and the resolve marker under state/.
#
# The stubbed session does what a real one does: it detaches a long-lived build
# and returns. That child is the whole subject of this file.
# Run from anywhere: tests/triage-lock-inherit-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || { T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" project-5 || exit 1  # BH-1510.2: lanes read models from model_routes
# EXPORTED, and never left to the sed rewrite alone: every script here resolves
# HARNESS="${HARNESS:-/root/harness}", so a box where the operator's shell
# already exports HARNESS would run this fixture against the LIVE harness tree.
# That is incident #388's shape, and one line stops it.
export HARNESS="$H"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" "$H/prompts" \
         "$H/builds" "$H/catalog" "$T/calls" "$T/repos"
: > "$H/env/global.env"
P=project-5
echo "SOP for $P. Fetch the thread. Do the work." > "$H/prompts/$P.md"
export FLEET_CONF="$DIR/fleet.conf"

# Where the stubs record what they saw. Exported, because they are reached
# through run-triage.sh and (in the shard case) two forks below it.
export FD_SINK="$T/fds.txt"
export ALERT_SINK="$T/alerts.tsv"
export FAKE_BUILD="$H/bin/run-build.sh"
: > "$FD_SINK"; : > "$ALERT_SINK"

# the scripts under test, with only their roots repointed
for s in run-triage.sh triage-shard.sh; do
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/$s" > "$H/bin/$s"
  chmod +x "$H/bin/$s"
done
# ...and the tick's stage files, which is where the two spawn sites under test
# now live (BH-479). The driver refuses to run without them, so a fixture that
# copies only the driver tests nothing (tests/triage-shards-test.sh precedent).
mkdir -p "$H/bin/lib/rt"
for s in "$DIR"/bin/lib/rt/*.sh; do
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$s" > "$H/bin/lib/rt/$(basename "$s")"
done
# the real decision-makers. lock-hygiene.sh is the lib under test; it is copied
# when it exists so this file also runs at the merge base, where it does not.
for l in triage-shards-lib.sh lock-hygiene.sh; do
  [ -f "$DIR/bin/lib/$l" ] && cp "$DIR/bin/lib/$l" "$H/bin/lib/$l"
done
for s in fleet-conf.sh project-of.sh decision-log.sh queue-line-drop.sh; do
  ln -sf "$DIR/bin/$s" "$H/bin/$s"
done
printf '#!/bin/sh\necho box-project-5-1\n' > "$H/bin/box-name.sh"; chmod +x "$H/bin/box-name.sh"

# --- stubs -------------------------------------------------------------------
cat > "$H/bin/triage-gate.sh" <<STUB
#!/bin/bash
P="\$1"; MODE="\${2:-}"
cp "$H/fixture/pending.json" "$H/state/\$P.gate.pending" 2>/dev/null
[ "\$MODE" = "--pending" ] && exit 0
cat "$H/fixture/gate-decision"
exit 0
STUB
chmod +x "$H/bin/triage-gate.sh"
cat > "$H/bin/gate-diff.sh" <<STUB
#!/bin/bash
[ -s "$H/fixture/diff" ] || exit 2
cat "$H/fixture/diff"
STUB
chmod +x "$H/bin/gate-diff.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/unblocked-children.sh"; chmod +x "$H/bin/unblocked-children.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"; chmod +x "$H/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"

# The session. It records the lock fds it can still see, then does exactly what
# the SOP tells a triage session to do with a ready ticket: detach a build and
# return. THE DETACHED CHILD IS THE SUBJECT OF THIS TEST.
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
D="${CALLDIR:?}"
PR="$6"; case "$PR" in @/*) PR=$(cat "${PR#@}") ;; esac
F=$(mktemp "$D/prompt-XXXXXXXX.txt")
printf '%s' "$PR" > "$F"
printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$D/calls.tsv"
printf 'role=agent pid=%s fd8=%s fd9=%s\n' "$$" \
  "$(readlink /proc/self/fd/8 2>/dev/null || echo closed)" \
  "$(readlink /proc/self/fd/9 2>/dev/null || echo closed)" >> "${FD_SINK:?}"
echo "tickets=1 done" > "$5"
setsid "${FAKE_BUILD:?}" "$2" 1 TK-1 </dev/null >/dev/null 2>&1 &
# The build is recorded BEFORE this lingers, so a caller can look at the locks
# while the session is still in flight — which is when a shell left waiting on
# the fork is visible.
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
exit "${STUB_RC:-0}"
STUB
chmod +x "$H/bin/agent-call.sh"

# The build the session launched: long-lived, detached, and the thing that used
# to hold the tick lock for its whole run.
cat > "$H/bin/run-build.sh" <<'STUB'
#!/bin/bash
printf 'role=build pid=%s fd8=%s fd9=%s\n' "$$" \
  "$(readlink /proc/self/fd/8 2>/dev/null || echo closed)" \
  "$(readlink /proc/self/fd/9 2>/dev/null || echo closed)" >> "${FD_SINK:?}"
exec -a fake-run-build sleep 30
STUB
chmod +x "$H/bin/run-build.sh"

cat > "$H/bin/lane-alert.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${ALERT_SINK:?}"
exit 0
STUB
chmod +x "$H/bin/lane-alert.sh"

mkdir -p "$H/fixture"
FP='{"issues":[{"number":561,"state":"OPEN","title":"a"},{"number":562,"state":"OPEN","title":"b"},{"number":563,"state":"OPEN","title":"c"}],"prs":[]}'
DIFF1='board issues: CHANGED 561 "a" (comments: 1 -> 2)'
DIFF3='board issues: CHANGED 561 "a" (comments: 1 -> 2)
board issues: CHANGED 562 "b" (comments: 3 -> 4)
board issues: CHANGED 563 "c" (comments: 0 -> 1)'

held() { # held <lockfile> -> 0 when some other process holds it
  [ -e "$1" ] || return 1
  if ( exec 9>"$1" || exit 0; flock -n 9 || exit 1 ) 2>/dev/null; then return 1; fi
  return 0
}
ncalls()  { ls "$T/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }
nbuilds() { grep -c '^role=build' "$FD_SINK" 2>/dev/null | tr -d ' '; }
nalerts() { grep -c . "$ALERT_SINK" 2>/dev/null | tr -d ' '; }
build_line() { grep '^role=build' "$FD_SINK" 2>/dev/null | sed -n "${1:-1}p"; }
pid_of() { printf '%s\n' "$1" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p'; }

wait_builds() { # wait_builds <n> — the detached children have recorded their fds
  local i=0
  while [ "$i" -lt 100 ]; do
    [ "$(nbuilds)" -ge "$1" ] && return 0
    i=$((i+1)); sleep 0.2
  done
  return 1
}
wait_free() { # wait_free <lockfile> — bounded, never a blocking wait
  local i=0
  while [ "$i" -lt 60 ]; do
    held "$1" || return 0
    i=$((i+1)); sleep 0.2
  done
  return 1
}
wait_held() { # wait_held <lockfile>
  local i=0
  while [ "$i" -lt 60 ]; do
    held "$1" && return 0
    i=$((i+1)); sleep 0.2
  done
  return 1
}
kill_builds() { # the fake builds are the only thing this file leaves running
  local p
  for p in $(awk '$1=="role=build"{sub(/^pid=/,"",$2); print $2}' "$FD_SINK" 2>/dev/null); do
    kill "$p" 2>/dev/null
  done
}

reset() { # reset <gate-decision> <diff-text>
  kill_builds
  rm -rf "$T/calls"; mkdir -p "$T/calls"
  rm -rf "$T/h/state" "$T/h/locks" "$T/h/logs" "$T/h/builds"
  model_routes_fixture "$T/h" project-5 || exit 1   # the reset above took the model-routes cache with it
  mkdir -p "$H/state" "$H/locks" "$H/logs" "$H/builds"
  rm -f "$H/flags/triage-shards-off"
  : > "$FD_SINK"; : > "$ALERT_SINK"
  printf '%s' "$FP" > "$H/fixture/pending.json"
  printf '%s' "$FP" > "$H/state/$P.gate.json"
  echo "$1" > "$H/fixture/gate-decision"
  printf '%s' "$2" > "$H/fixture/diff"
  : > "$H/logs/READY-QUEUE.log"
}
run() { CALLDIR="$T/calls" "$@" "$H/bin/run-triage.sh" "$P" >/dev/null 2>&1; }

# ---------- 1. the single session's detached build sees no tick lock ---------
# The ticket's own reproduction: one tick, one session, one long-lived build
# launched the way the SOP launches them, then a SECOND tick.
reset "RUN board-changed" "$DIFF1"
run env TRIAGE_SHARDS=0
wait_builds 1 || bad "the session's detached build never recorded its fds — the fixture did not run"
B=$(build_line 1)
case "$B" in
  *fd9=closed*) ok ;;
  *) bad "the build launched from the tick must not inherit the tick's fd 9 (recorded: ${B:-nothing})" ;;
esac
BPID=$(pid_of "$B")
if [ -n "$BPID" ] && kill -0 "$BPID" 2>/dev/null; then ok
else bad "the fake build must still be alive for the lock assertions to mean anything (pid ${BPID:-none})"; fi
held "$H/locks/$P.lock" \
  && bad "a build detached by the tick's session must NOT hold locks/$P.lock after the tick exits (fd 9 leaked)" \
  || ok
run env TRIAGE_SHARDS=0
grep -q "previous run still active" "$H/logs/$P.log" \
  && bad "the second tick must acquire the lock, not skip on a lock the finished tick's child still holds" \
  || ok
[ "$(ncalls)" = 2 ] && ok || bad "the second tick must run its own session (agent calls: $(ncalls), want 2)"
kill_builds
wait_free "$H/locks/$P.lock" || bad "the lock must be free once the fake builds are killed"

# ---------- 2. a shard's detached build sees neither lock fd -----------------
# The same leak one level down: the shard holds the per-ticket key lock on fd 8,
# so a build it detaches used to keep that key locked and the next tick answered
# "another shard owns this ticket".
reset "RUN board-changed" "$DIFF3"
STUB_SLEEP=4 run
wait_builds 3 || bad "3 shards must each detach a build (recorded: $(nbuilds))"
# Checked HERE, while the three sessions are still in flight: an async shell left
# waiting on the fork holds fd 9 exactly as well as the build does, so wrapping
# the fork the wrong way rebuilds the ceiling with the build itself looking
# innocent. Seconds later the shards are gone and the evidence with them.
held "$H/locks/$P.lock" \
  && bad "nothing the dispatcher forked may hold locks/$P.lock while its shards run" \
  || ok
CLEAN=1
for n in 1 2 3; do
  L=$(build_line "$n")
  case "$L" in
    *fd8=closed*fd9=closed*) ;;
    *) CLEAN=0; [ "$n" = 1 ] && echo "  (first shard build recorded: ${L:-nothing})" ;;
  esac
done
[ "$CLEAN" = 1 ] && ok || bad "a build detached by a shard must see neither the key lock (fd 8) nor the tick lock (fd 9)"
ALIVE=0
for n in 1 2 3; do
  Q=$(pid_of "$(build_line "$n")")
  [ -n "$Q" ] && kill -0 "$Q" 2>/dev/null && ALIVE=$((ALIVE+1))
done
[ "$ALIVE" = 3 ] && ok || bad "the 3 fake builds must still be alive for the key-lock assertion to mean anything (alive: $ALIVE)"
BUSY=1
for i in 1 2 3 4 5 6 7 8 9 10; do
  BUSY=0
  for K in 561 562 563; do held "$H/locks/triage-key-$P-$K.lock" && BUSY=1; done
  [ "$BUSY" = 0 ] && break
  sleep 0.5
done
[ "$BUSY" = 0 ] && ok || bad "no triage-key-$P-<KEY>.lock may still be held once the shards exit, while their builds run"
held "$H/locks/$P.lock" \
  && bad "no build detached by a shard may still hold locks/$P.lock once the shards have exited" \
  || ok
kill_builds
wait_free "$H/locks/$P.lock" || true

# ---------- 3. a foreign holder is NAMED and raises one alert ----------------
reset "RUN board-changed" "$DIFF1"
( exec 9>"$H/locks/$P.lock"; flock 9; exec sleep 30 ) &
FOREIGN=$!
wait_held "$H/locks/$P.lock" || bad "the fixture holder did not take locks/$P.lock"
run env TRIAGE_SHARDS=0
[ "$(ncalls)" = 0 ] && ok || bad "a tick that cannot take the lock must run no session (agent calls: $(ncalls))"
grep -qE "previous run still active \(holder pid=[0-9]+ age=[0-9]+s cmd=sleep" "$H/logs/$P.log" \
  && ok || bad "the skip line must name the holder: 'previous run still active (holder pid=N age=Ns cmd=...), skipping' — got: $(grep 'previous run still active' "$H/logs/$P.log" | tail -1)"
[ "$(grep -c 'triage-lock-leak-project-5' "$ALERT_SINK" 2>/dev/null | tr -d ' ')" = 1 ] \
  && ok || bad "a holder that is not a run-triage.sh process must raise exactly ONE lane-alert line (got $(nalerts) alert calls)"
grep -q "pid=$FOREIGN" "$ALERT_SINK" \
  && ok || bad "the alert must carry the holder's pid ($FOREIGN) so an operator can kill it"
[ -e "$H/state/triage-lock-leak-$P" ] \
  && ok || bad "the open condition must leave state/triage-lock-leak-$P so the next acquire can resolve it"

# ---------- 4. a routine overlap stays a routine skip ------------------------
# A tick genuinely still running is the NEGATIVE: it is named in the log and it
# raises nothing. Its argv is spoofed with exec -a, which is the only part of a
# real tick this assertion depends on.
kill "$FOREIGN" 2>/dev/null; wait "$FOREIGN" 2>/dev/null
wait_free "$H/locks/$P.lock" || bad "the foreign holder did not release the lock when killed"
( exec 9>"$H/locks/$P.lock"; flock 9; exec -a run-triage.sh sleep 30 ) &
ROUTINE=$!
wait_held "$H/locks/$P.lock" || bad "the routine holder did not take locks/$P.lock"
A4=$(nalerts)
run env TRIAGE_SHARDS=0
grep -qE "previous run still active \(holder pid=$ROUTINE age=[0-9]+s cmd=run-triage.sh" "$H/logs/$P.log" \
  && ok || bad "a routine overlap must still name its holder in the skip line"
[ "$(nalerts)" = "$A4" ] \
  && ok || bad "a run-triage.sh holder is a routine skip and must raise NO alert (alert calls went $A4 -> $(nalerts))"

# ---------- 5. the next acquire resolves the condition ----------------------
kill "$ROUTINE" 2>/dev/null; wait "$ROUTINE" 2>/dev/null
wait_free "$H/locks/$P.lock" || bad "the routine holder did not release the lock when killed"
A5=$(nalerts); N5=$(ncalls)
run env TRIAGE_SHARDS=0
[ "$(nalerts)" = "$((A5 + 1))" ] \
  && ok || bad "the first tick that reacquires the lock must make exactly one lane-alert call (alert calls went $A5 -> $(nalerts))"
tail -1 "$ALERT_SINK" | grep -q -- "--resolve" \
  && ok || bad "that call must be the --resolve for triage-lock-leak-$P (got: $(tail -1 "$ALERT_SINK"))"
[ -e "$H/state/triage-lock-leak-$P" ] \
  && bad "the resolve must remove state/triage-lock-leak-$P, or every later tick re-resolves" || ok
[ "$(ncalls)" = "$((N5 + 1))" ] \
  && ok || bad "the tick that reacquired the lock must go on to run its session (agent calls went $N5 -> $(ncalls))"
kill_builds

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
