#!/bin/bash
# tests/triage-lock-not-inherited-test.sh — the tick's per-project flock must
# never outlive the tick.
#
# WHAT WENT WRONG. bin/run-triage.sh opens the per-project overlap lock with
# `exec 9>"$PLOCK"` and bash does not set FD_CLOEXEC on it, so fd 9 rides into
# every descendant. The SHARD dispatch already closes it (`9>&-`, the lesson of
# PR #310); the SINGLE-SESSION path — the one a full-sweep tick takes, which is
# also the path that launches builds — did not. The triage agent's shell, and
# the `setsid run-build.sh` it starts, therefore held locks/<project>.lock for
# the whole life of the build: on box-small on 2026-09-16 a build
# (pid 23388, parent 1) pinned locks/cromford.lock for 3h+ and every tick
# from 02:23Z to 05:23Z logged "previous run still active, skipping" with 60
# open ai-build issues never offered. A lock that outlives its tick is a queue,
# and we never lock and serialize.
#
# THE PROPERTY, in three parts:
#   A  the real bin/run-triage.sh, driven end to end on the single-session path:
#      the build it launches must not hold the project lock, a second tick must
#      dispatch while that build is alive, and the tick's OWN overlap guard must
#      still work while the tick is running (the negative that stops "fixed"
#      from meaning "deleted").
#   B  bin/run-build.sh's own startup guard, extracted VERBATIM by its markers
#      and run inside a shell that really holds flocks on fds 7, 8 and 9.
#   C  two source pins, supplements to A and B, never the check itself.
#
# Driven, not grepped: the stub build records what it inherited from
# /proc/<pid>/fd, and the recording is the assertion (the
# tests/fly-pool-lock-cloexec-test.sh precedent).
# Run from anywhere: tests/triage-lock-not-inherited-test.sh   (exit 0 = all pass)
set -uo pipefail
# tests/lib/scratch.sh is #459 (PR #609, still open) while #460 already ported
# every suite to source it, so the lib is absent from main today. Source it when
# it is readable and fall back to the prologue #460 replaced otherwise — a suite
# that cannot run at the merge base makes bin/repro-gate.sh's red meaningless,
# and this file needs no edit when #609 lands.
[ -r "$(dirname "$0")/lib/scratch.sh" ] && . "$(dirname "$0")/lib/scratch.sh"
[ -n "${T:-}" ] || { T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; }
chmod 755 "$T" 2>/dev/null || true
# The lib's first act, and non-negotiable here: bin/run-triage.sh resolves
# HARNESS as "${HARNESS:-/root/harness}", so an inherited HARNESS (every build
# agent has one exported) makes the scratch copy drive the LIVE harness — real
# gate, real orphan-reconcile, real logs. Verified the hard way while writing
# this suite.
unset HARNESS H HARNESS_CHECKOUT
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

P=project-5
export FLEET_CONF="$DIR/fleet.conf"
mkdir -p "$T/locks"

# Nothing here is ever deleted: every phase gets its own fixture root, so this
# file carries no recursive rm of its own (checks/tests-scratch-only R2).
mkfixture() { # mkfixture <root> — a scratch harness running the REAL run-triage.sh
  local h="$1"
  mkdir -p "$h/bin/lib" "$h/logs" "$h/state" "$h/locks" "$h/env" "$h/flags" \
           "$h/prompts" "$h/builds" "$h/catalog" "$h/calls" "$h/fixture"
  . "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$h" project-5 || exit 1  # BH-1510.2: lanes read models from model_routes
  : > "$h/env/global.env"
  : > "$h/fd.txt"
  : > "$h/logs/READY-QUEUE.log"
  echo "SOP for $P. Fetch the thread. Do the work." > "$h/prompts/$P.md"

  # the script under test, with only its roots repointed (the
  # tests/triage-shards-test.sh precedent)
  sed -e "s|/root/harness|$h|g" -e "s|/root/repos|$T/repos|g" \
      "$DIR/bin/run-triage.sh" > "$h/bin/run-triage.sh"
  chmod +x "$h/bin/run-triage.sh"
  # ...with its stage files (BH-479): the agent call this suite drives is
  # assembled in bin/lib/rt/launch.sh now, and the driver refuses a tick whose
  # stages it cannot read.
  mkdir -p "$h/bin/lib/rt"
  for s in "$DIR"/bin/lib/rt/*.sh; do
    sed -e "s|/root/harness|$h|g" -e "s|/root/repos|$T/repos|g" "$s" > "$h/bin/lib/rt/$(basename "$s")"
  done
  cp "$DIR/bin/lib/triage-shards-lib.sh" "$h/bin/lib/triage-shards-lib.sh"
  local s
  for s in fleet-conf.sh project-of.sh decision-log.sh queue-line-drop.sh; do
    ln -sf "$DIR/bin/$s" "$h/bin/$s"
  done
  printf '#!/bin/sh\necho box-project-5-1\n' > "$h/bin/box-name.sh"

  # --- stubs: the gate, the console, the model call ---------------------------
  # A full-sweep decision with no scope list: production's DEFAULT shape for the
  # single-session path (tests/triage-shards-test.sh section 7 pins that a
  # scope-less tick stays one session), and the shape that launches builds.
  printf '{"issues":[{"number":561,"state":"OPEN","title":"a"}],"prs":[]}' > "$h/fixture/pending.json"
  cp "$h/fixture/pending.json" "$h/state/$P.gate.json"
  echo "RUN daily-sweep" > "$h/fixture/gate-decision"
  : > "$h/fixture/diff"
  cat > "$h/bin/triage-gate.sh" <<STUB
#!/bin/bash
PJ="\$1"; MODE="\${2:-}"
cp "$h/fixture/pending.json" "$h/state/\$PJ.gate.pending" 2>/dev/null
[ "\$MODE" = "--pending" ] && exit 0
cat "$h/fixture/gate-decision"
exit 0
STUB
  cat > "$h/bin/gate-diff.sh" <<STUB
#!/bin/bash
[ -s "$h/fixture/diff" ] || exit 2
cat "$h/fixture/diff"
STUB
  printf '#!/bin/sh\nexit 0\n' > "$h/bin/unblocked-children.sh"
  printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$h/bin/triage-contract.sh"
  printf '#!/bin/sh\nexit 0\n' > "$h/bin/beat.sh"

  # agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt|@file>
  # Stands in for the triage agent and does the one thing the SOP tells that
  # agent to do with a buildable ticket: setsid a build. What the build INHERITS
  # is the assertion.
  cat > "$h/bin/agent-call.sh" <<'STUB'
#!/bin/bash
D="${CALLDIR:?}"
PR="$6"; case "$PR" in @/*) PR=$(cat "${PR#@}") ;; esac
F=$(mktemp "$D/prompt-XXXXXXXX.txt")
printf '%s' "$PR" > "$F"
setsid "${STUB_BUILD:?}" </dev/null >/dev/null 2>&1 &
echo "tickets=1 done" > "$5"
# STUB_BLOCK keeps the agent — and therefore the tick — alive, which is how the
# tick's own overlap guard can be observed while it is still armed.
if [ -n "${STUB_BLOCK:-}" ]; then
  i=0
  while [ ! -e "${STUB_RELEASE:?}" ] && [ "$i" -lt 240 ]; do i=$((i+1)); sleep 0.25; done
fi
exit 0
STUB
  chmod +x "$h/bin/agent-call.sh" "$h/bin/triage-gate.sh" "$h/bin/gate-diff.sh" \
           "$h/bin/unblocked-children.sh" "$h/bin/triage-contract.sh" \
           "$h/bin/beat.sh" "$h/bin/box-name.sh"
}

# The stand-in for bin/run-build.sh: detached, long-lived, and loud about every
# lock descriptor its launcher handed it.
cat > "$T/stub-build.sh" <<'STUB'
#!/bin/bash
S="${FD_SINK:?}"
for f in /proc/$$/fd/*; do
  t=$(readlink "$f" 2>/dev/null) || continue
  case "$t" in *"/locks/"*) printf 'INHERITED %s -> %s\n' "${f##*/}" "$t" >> "$S" ;; esac
done
printf 'ALIVE %s\n' "$$" >> "$S"
i=0
while [ ! -e "${STUB_RELEASE:?}" ] && [ "$i" -lt 480 ]; do i=$((i+1)); sleep 0.25; done
exit 0
STUB
chmod +x "$T/stub-build.sh"

HR=""   # the fixture the helpers below drive
run() { CALLDIR="$HR/calls" FD_SINK="$HR/fd.txt" STUB_BUILD="$T/stub-build.sh" \
        STUB_RELEASE="$T/rel-a" "$@" "$HR/bin/run-triage.sh" "$P" >/dev/null 2>&1; }
ncalls() { ls "$HR/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }
lock_free() { # 0 when the per-project tick lock is takeable right now
  ( exec 9>"$HR/locks/$P.lock" || exit 1; flock -n 9 ) 2>/dev/null
}
waitfor() { # waitfor <file> <ere> — bounded poll, never a bare sleep
  local i=0
  while [ "$i" -lt 120 ]; do
    grep -qE -- "$2" "$1" 2>/dev/null && return 0
    i=$((i+1)); sleep 0.25
  done
  return 1
}
waitcalls() { # waitcalls <n>
  local i=0
  while [ "$i" -lt 120 ]; do
    [ "$(ncalls)" -ge "$1" ] && return 0
    i=$((i+1)); sleep 0.25
  done
  return 1
}

# ---------- A. the tick's launch path ---------------------------------------
HR="$T/f1"; mkfixture "$HR"
run
waitfor "$HR/fd.txt" '^ALIVE' || true

# A0 — the control: without a build that really launched, A1 would pass vacuously.
grep -q '^ALIVE' "$HR/fd.txt" \
  && ok || bad "the tick's agent never launched a build, so this section proves nothing (fd sink: $(cat "$HR/fd.txt"))"

# A1 — the descriptor itself.
if grep -qE -- "INHERITED .*/locks/$P\.lock" "$HR/fd.txt"; then
  bad "the build the tick launched inherited the per-project tick lock: $(grep INHERITED "$HR/fd.txt" | head -3)"
else ok; fi

# A2 — the ticket's literal acceptance wording: from another process, flock -n
# on the project lock while the stub build is still alive must SUCCEED.
if lock_free; then ok
else bad "locks/$P.lock is still held while the launched build runs — the next tick would skip"; fi

# A3 — the observed symptom, pinned: a second tick launched while the first
# tick's build is alive must dispatch, not skip.
run
waitcalls 2 || true
[ "$(ncalls)" -ge 2 ] && ok \
  || bad "a second tick must make its own agent call while the first tick's build is alive (calls: $(ncalls))"
if grep -q 'previous run still active, skipping' "$HR/logs/$P.log" 2>/dev/null; then
  bad "the second tick logged 'previous run still active, skipping' — the 02:23Z→05:23Z ceiling, rebuilt"
else ok; fi

# A4 — the negative. The tick's OWN process must still hold the lock while it
# runs: closing the descriptor in the CHILD must not disarm the overlap guard.
HR="$T/f2"; mkfixture "$HR"
run env STUB_BLOCK=1 STUB_RELEASE="$T/rel-b" &
TICK=$!
waitcalls 1 || true
if lock_free; then
  bad "the RUNNING tick does not hold locks/$P.lock — the overlap guard was deleted, not fixed"
else ok; fi
touch "$T/rel-b"
wait "$TICK" 2>/dev/null
touch "$T/rel-a"

# ---------- B. bin/run-build.sh's startup guard ------------------------------
# Extracted verbatim by its markers (the tests/no-serialize-test.sh precedent)
# and run for real inside a shell that holds the three flocks.
awk '/^# >>> inherited fd guard/{f=1;next} /^# <<< inherited fd guard/{exit} f' \
  "$RB_ALL" > "$T/guard.sh"
[ -s "$T/guard.sh" ] && ok \
  || bad "bin/run-build.sh carries no '# >>> inherited fd guard' region to extract"

cat > "$T/probe.sh" <<'PROBE'
#!/bin/bash
S="${FD_SINK:?}"
[ -n "${GUARD:-}" ] && . "$GUARD"
for n in 7 8 9; do
  t=$(readlink "/proc/$$/fd/$n" 2>/dev/null) || t=""
  printf 'FD %s -> %s\n' "$n" "$t" >> "$S"
done
PROBE
chmod +x "$T/probe.sh"

probe() { # probe <sink> [guard]
  : > "$1"
  ( exec 7>"$T/locks/l7.lock" 8>"$T/locks/l8.lock" 9>"$T/locks/l9.lock"
    flock -n 7 && flock -n 8 && flock -n 9 || exit 1
    FD_SINK="$1" GUARD="${2:-}" setsid bash "$T/probe.sh" </dev/null >/dev/null 2>&1 )
  local i=0
  while [ "$i" -lt 120 ]; do
    [ "$(grep -c '^FD ' "$1" 2>/dev/null || echo 0)" -ge 3 ] && return 0
    i=$((i+1)); sleep 0.25
  done
  return 1
}

# B2 first: the negative control proves the probe can SEE a leak at all.
probe "$T/b-without.txt" || bad "the no-guard probe never recorded its three descriptors"
if [ "$(grep -c '/locks/' "$T/b-without.txt" 2>/dev/null || echo 0)" = 3 ]; then ok
else bad "the control probe must inherit all three lock fds, else it cannot detect a leak: $(cat "$T/b-without.txt")"; fi

# B1 — the guard itself.
probe "$T/b-with.txt" "$T/guard.sh" || bad "the guarded probe never recorded its three descriptors"
if grep -q '/locks/' "$T/b-with.txt"; then
  bad "run-build.sh's startup guard left a launcher's lock open: $(grep '/locks/' "$T/b-with.txt")"
else ok; fi

# B3 — a cron or Fly build, where none of the three were ever open, is unchanged.
OUT3=$(bash -c 'exec 9>&- 8>&- 7>&-; echo ok' 2>&1); RC3=$?
[ "$RC3" = 0 ] && [ "$OUT3" = ok ] && ok \
  || bad "closing unopened descriptors must be a silent no-op (rc=$RC3 out=$OUT3)"

# ---------- C. source pins (supplement, never the check) ---------------------
AC=$(grep -n 'bin/agent-call\.sh" triage' "$DIR/bin/lib/rt/launch.sh" | head -1)
if [ -z "$AC" ]; then
  bad "no triage agent-call.sh invocation found in bin/lib/rt/launch.sh — this suite is pinning nothing"
else
  # Either spelling closes the fd in the child: a bare `9>&-` (#474) or the
  # BH-651 helper `lock_run_unheld`, whose subshell does `exec 8>&- 9>&-` before
  # it execs the command. Section A above is the check that drives the real
  # script; this pin only refuses a call line that carries neither.
  case "$AC" in
    *'9>&-'*|*lock_run_unheld*) ok ;;
    *) bad "the single-session triage agent call must close fd 9 (9>&- or lock_run_unheld): $AC" ;;
  esac
fi
grep -q '^# >>> inherited fd guard' "$RB_ALL" && ok \
  || bad "bin/run-build.sh lost its '# >>> inherited fd guard' marker"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
