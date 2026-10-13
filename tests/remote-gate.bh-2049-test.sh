#!/bin/bash
# tests/remote-gate.bh-2049-test.sh — the mkdir lock in bin/remote-gate.sh never
# leaves an owner-less lock dir behind when it races a release or a second
# reclaimer (BH-2049, the flaky F1d in remote-gate.bh-1854-test.sh).
#
# WHY. F1d failed on CI with "the lock dir ... is still there after every gate
# returned". F1 waits every gate pid, and each gate's EXIT trap runs before it
# exits, so the test was not racy: _rg_mlock_try was. Two interleavings leave a
# lock dir with no owner file, which nobody holds and which blocks every cert
# reissue until it is twice one issuer's worst case old:
#   1. a gate's mkdir fails, the holder releases before its [ -d ] look, so it
#      falls into the stale-reclaim path, moves a THIRD gate's brand-new
#      (not-yet-owned) lock to its tomb, and puts the owner-less tomb back
#   2. two reclaimers of one stale lock: the second moves the first's fresh
#      owner-less dir to its tomb and puts it back
#
# WHAT THIS PINS, every case through the real CLI (`bin/remote-gate.sh <dir> --
# true`) with flock HIDDEN from PATH, as in the BH-1854 suite, plus `cat` and
# `mv` shims that fire the race only when a trigger file exists:
#   R1  released-then-retaken lock, valid cert: rc 0, no issue, no lock, no tomb
#   R1b released lock, no cert: the gate takes the freed lock and issues once
#   R1c released before the owner read, then taken by a third gate: the gate
#       does not "reclaim" that gate's fresh lock as stale
#   R2  a stale lock re-taken by another reclaimer during our mv: no lock left
#   R3  a tomb carrying a LIVE owner still goes back, owner unchanged
#   S1  BH2049_ROUNDS (default 10) rounds of four concurrent no-cert gates:
#       one issue, a matching pair, rc 0 x4, no lock, no tomb, every round
#
# Run from anywhere: tests/remote-gate.bh-2049-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
GATE="$DIR/bin/remote-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$GATE" ] || { echo "FAIL: bin/remote-gate.sh does not exist"; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "SKIP: no timeout(1) to bound the gate runs"; exit 0; }

FIX="$T/fix"; mkdir -p "$FIX" "$T/fakebin" "$T/noflock" "$T/wt" "$T/h/flags" "$T/h/logs"
echo "a worktree file" > "$T/wt/file.txt"
: > "$T/h/flags/lane-off-testhost-tick"
LOCKD="$T/key.issue.lock.d"
HOLDERS=()
_cleanup() {
  local p
  for p in $(cat "$FIX/hang-pids" "$FIX/helper-pids" 2>/dev/null) ${HOLDERS[@]+"${HOLDERS[@]}"}; do kill -KILL "$p" 2>/dev/null; done
  # This trap REPLACES tests/lib/scratch.sh's EXIT trap, so run its cleanup too.
  scratch_cleanup 2>/dev/null || true
  return 0
}
trap _cleanup EXIT

# ── a PATH with no flock ─────────────────────────────────────────────────────
# Every command in the system bin dirs, flock excepted. On a merged-/usr host
# /bin and /usr/bin are one dir; the first link wins and the rest are no-ops.
for d in /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b=${f##*/}
    [ "$b" = flock ] && continue
    [ -e "$T/noflock/$b" ] || ln -s "$f" "$T/noflock/$b" 2>/dev/null
  done
done
NOFLOCK_PATH="$T/fakebin:$T/noflock"
if env PATH="$NOFLOCK_PATH" bash -c 'command -v flock' >/dev/null 2>&1; then
  bad "setup: flock is still on the test PATH"
fi

# ── the shims ────────────────────────────────────────────────────────────────
# flyctl ssh issue writes a key and a cert carrying the SAME token (its pid), so
# a torn pair — one issuer's key beside another's cert — is visible.
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
case "$1 ${2:-}" in
  "proxy "*|"proxy") : > "$FIX/proxy-up"; exit 0 ;;
  "ssh issue")
    shift 2
    p="$2"
    if [ -f "$FIX/hang" ]; then
      # a helper flyctl started, then the issue never answers
      sleep 120 </dev/null >/dev/null 2>&1 &   # determinism: ok a helper that outlives flyctl is the defect under test
      echo $! >> "$FIX/helper-pids"
      echo $$ >> "$FIX/hang-pids"
      exec sleep 120                           # determinism: ok a stub that never answers
    fi
    [ -f "$FIX/slow" ] && sleep 2              # determinism: ok a slow issuer is what makes gates overlap
    printf 'key-%s\n' "$$" > "$p"
    [ -f "$FIX/slow" ] && sleep 1              # determinism: ok widen the key-then-cert window
    printf 'cert-%s\n' "$$" > "$p-cert.pub"
    rm -f "$FIX/cert-to"
    exit 0 ;;
esac
exit 0
STUB
cat > "$T/fakebin/nc" <<'STUB'
#!/bin/bash
[ -f "$FIX/proxy-up" ] && exit 0
exit 1
STUB
cat > "$T/fakebin/rsync" <<'STUB'
#!/bin/bash
exit 0
STUB
cat > "$T/fakebin/ssh" <<'STUB'
#!/bin/bash
case "$*" in *"bash -s"*) cat > "$FIX/job"; exit 0 ;; esac
exit 0
STUB
cat > "$T/fakebin/ssh-keygen" <<'STUB'
#!/bin/bash
echo "        Valid: from 2026-01-01T00:00:00 to $(cat "$FIX/cert-to" 2>/dev/null || echo 2099-01-01T00:00:00)"
exit 0
STUB
chmod +x "$T/fakebin"/*
export FIX

KNOB_T=3
gate() {
  env PATH="$NOFLOCK_PATH" HOME="$T" HARNESS="$T/h" \
    TESTHOST_APP=bh-testhost-fixture TESTHOST_PORT=10022 TESTHOST_ORG=fixture-org \
    TESTHOST_KEY="$T/key" REMOTE_GATE_PROXY_WAIT_S=2 \
    REMOTE_GATE_CERT_ISSUE_TIMEOUT_S="$KNOB_T" \
    timeout 40 bash "$GATE" "$T/wt" -- true < /dev/null
}
run() { local s=$SECONDS; OUT=$(gate 2>&1); RC=$?; EL=$((SECONDS - s)); }
reset() {
  local p
  for p in ${HOLDERS[@]+"${HOLDERS[@]}"}; do kill -KILL "$p" 2>/dev/null; done
  HOLDERS=()
  rm -f "$FIX"/fly-calls "$FIX"/job "$FIX"/proxy-up "$FIX"/cert-to "$FIX"/hang "$FIX"/slow \
    "$FIX"/gate-*.out "$T/key" "$T/key-cert.pub" "$T/key.issue.lock"
  scratch_rm "$LOCKD"
  KNOB_T=3
}
date_plus() { # date_plus <minutes> — a LOCAL-time stamp in ssh-keygen's format
  if date -d "$1 minutes" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null; then :   # determinism: ok the expiry under test is relative to now by definition
  else date -v "$1M" '+%Y-%m-%dT%H:%M:%S'; fi                        # determinism: ok same read, BSD date
}
seed_cert() { # seed_cert <minutes left, signed>
  printf 'key\n' > "$T/key"; printf 'cert\n' > "$T/key-cert.pub"
  date_plus "$1" > "$FIX/cert-to"
}
issues() { [ -f "$FIX/fly-calls" ] || { echo 0; return; }; grep -c '^ssh issue' "$FIX/fly-calls"; }
# hold_lock <owner epoch offset in s> — a live holder of the mkdir lock
hold_lock() {
  sleep 60 & HOLDERS+=($!)                     # determinism: ok a live lock holder
  mkdir "$LOCKD"
  echo "$! $(( $(date +%s) + $1 ))" > "$LOCKD/owner"   # determinism: ok the owner stamp is relative to now by definition
}
pair_ok() { # the key and the cert came from ONE issuer
  local k c
  k=$(cat "$T/key" 2>/dev/null); c=$(cat "$T/key-cert.pub" 2>/dev/null)
  [ -n "$k" ] && [ "${k#key-}" = "${c#cert-}" ] && [ "$k" != "$c" ]
}

# ── the race shims ───────────────────────────────────────────────────────────
# cat: reading $LOCKD/owner with $FIX/race-release present, the holder releases
#   right after the read (so the gate's [ -d ] look finds nothing); with
#   $FIX/race-release-early present, it releases just BEFORE the read.
# mv: moving $LOCKD with $FIX/race-take present, a third gate mkdirs the free
#   lock first (and is abandoned before its owner write); with
#   $FIX/race-reclaimed present, another reclaimer re-took it the same way; with
#   $FIX/race-live present, a live gate re-took it and wrote $FIX/live-owner.
# Each trigger fires once. Anything else runs the real binary.
REAL_CAT=$(command -v cat); REAL_MV=$(command -v mv)
export REAL_CAT REAL_MV LOCKD
cat > "$T/fakebin/cat" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "$LOCKD/owner" ] && [ -e "$FIX/race-release" ]; then
  o=$("$REAL_CAT" "$1" 2>/dev/null)
  rm -f "$FIX/race-release"; rm -rf "$LOCKD"
  printf '%s\n' "$o"
  exit 0
fi
if [ "${1:-}" = "$LOCKD/owner" ] && [ -e "$FIX/race-release-early" ]; then
  rm -f "$FIX/race-release-early"; rm -rf "$LOCKD"
fi
exec "$REAL_CAT" "$@"
STUB
cat > "$T/fakebin/mv" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "$LOCKD" ]; then
  if [ -e "$FIX/race-take" ]; then
    rm -f "$FIX/race-take"; mkdir "$LOCKD" 2>/dev/null
  elif [ -e "$FIX/race-reclaimed" ]; then
    rm -f "$FIX/race-reclaimed"; rm -rf "$LOCKD"; mkdir "$LOCKD"
  elif [ -e "$FIX/race-live" ]; then
    rm -f "$FIX/race-live"; rm -rf "$LOCKD"; mkdir "$LOCKD"
    "$REAL_CAT" "$FIX/live-owner" > "$LOCKD/owner"
  fi
fi
exec "$REAL_MV" "$@"
STUB
chmod +x "$T/fakebin/cat" "$T/fakebin/mv"
reset2049() { reset; rm -f "$FIX"/race-* "$FIX"/live-owner; scratch_rm "$T"/key.issue.lock.d.* 2>/dev/null; return 0; }
no_tomb() { ! ls -d "$T"/key.issue.lock.d.* >/dev/null 2>&1; }

# ── R1. the holder releases between our failed mkdir and our look, and a third
#        gate takes the free lock before we would move it: never reclaim ────────
reset2049; seed_cert +60; hold_lock 0; : > "$FIX/race-release"; : > "$FIX/race-take"
run
[ "$RC" = 0 ] && [ "$(issues)" = 0 ] && ok || bad "R1 a released lock with a valid cert gave rc $RC, $(issues) issues (want 0, 0): $OUT"
[ ! -e "$LOCKD" ] && ok || bad "R1 an owner-less lock dir was left behind (owner '$(cat "$LOCKD/owner" 2>/dev/null)'): $OUT"
no_tomb && ok || bad "R1 a reclaim tomb was left: $(ls -d "$T"/key.issue.lock.d.* 2>/dev/null)"

# ── R1b. the same release with NO cert: the waiter takes the freed lock ──────
reset2049; KNOB_T=2; hold_lock 0; : > "$FIX/race-release"; : > "$FIX/race-take"
run
[ "$RC" = 0 ] && [ "$(issues)" = 1 ] && ok || bad "R1b no cert, lock released mid-look gave rc $RC, $(issues) issues after ${EL}s (want 0, 1): $OUT"
pair_ok && ok || bad "R1b the key/cert pair is torn or missing"
[ ! -e "$LOCKD" ] && ok || bad "R1b the lock dir was left behind"
no_tomb && ok || bad "R1b a reclaim tomb was left"

# ── R1c. released before we even read the owner, then taken by a third gate:
#         its fresh dir is not a stale lock to reclaim ──────────────────────
reset2049; seed_cert +60; hold_lock 0; : > "$FIX/race-release-early"; : > "$FIX/race-take"
run
[ "$RC" = 0 ] && [ "$(issues)" = 0 ] && ok || bad "R1c a lock released before the owner read gave rc $RC, $(issues) issues (want 0, 0): $OUT"
case "$OUT" in *"reclaimed a stale"*) bad "R1c a just-released lock was reclaimed as stale (a third gate's fresh lock taken from it): $OUT" ;; *) ok ;; esac
no_tomb && ok || bad "R1c a reclaim tomb was left"

# ── R2. a dead gate's lock, re-taken by another reclaimer during our mv ──────
reset2049; seed_cert +60
sleep 0 & dead=$!; wait "$dead"
mkdir "$LOCKD"; echo "$dead $(date +%s)" > "$LOCKD/owner"   # determinism: ok a fresh stamp, so only the dead pid makes it stale
: > "$FIX/race-reclaimed"
run
[ "$RC" = 0 ] && ok || bad "R2 the reclaim race gave rc $RC (want 0): $OUT"
[ ! -e "$LOCKD" ] && ok || bad "R2 an owner-less lock dir was put back (owner '$(cat "$LOCKD/owner" 2>/dev/null)'): $OUT"
no_tomb && ok || bad "R2 a reclaim tomb was left: $(ls -d "$T"/key.issue.lock.d.* 2>/dev/null)"

# ── R3. a live gate re-took it during our mv: its lock goes back untouched ───
reset2049; seed_cert +60
sleep 0 & dead=$!; wait "$dead"
mkdir "$LOCKD"; echo "$dead $(date +%s)" > "$LOCKD/owner"   # determinism: ok a fresh stamp, so only the dead pid makes it stale
sleep 60 & HOLDERS+=($!)                                      # determinism: ok a live lock holder
live="$! $(date +%s)"                                         # determinism: ok the owner stamp is relative to now by definition
echo "$live" > "$FIX/live-owner"; : > "$FIX/race-live"
run
[ "$RC" = 0 ] && [ "$(issues)" = 0 ] && ok || bad "R3 a live re-take during the reclaim gave rc $RC, $(issues) issues (want 0, 0): $OUT"
[ "$(cat "$LOCKD/owner" 2>/dev/null)" = "$live" ] && ok || bad "R3 the live gate's lock was not put back as it was (owner '$(cat "$LOCKD/owner" 2>/dev/null)', want '$live')"
no_tomb && ok || bad "R3 a reclaim tomb was left"

# ── S1. the F1 race, looped: four concurrent no-cert gates per round ────────
ROUNDS=${BH2049_ROUNDS:-10}
r=1
while [ "$r" -le "$ROUNDS" ]; do
  reset2049; : > "$FIX/slow"; KNOB_T=10
  pids=()
  for i in 1 2 3 4; do gate > "$FIX/gate-$i.out" 2>&1 & pids+=($!); done
  rcs=""
  for p in "${pids[@]}"; do wait "$p"; rcs="$rcs $?"; done
  s1=""
  [ "$(issues)" = 1 ] || s1="$s1 issued $(issues) times;"
  pair_ok || s1="$s1 torn pair;"
  [ "$rcs" = " 0 0 0 0" ] || s1="$s1 rc$rcs;"
  [ ! -e "$LOCKD" ] || s1="$s1 lock dir left (owner '$(cat "$LOCKD/owner" 2>/dev/null)');"
  no_tomb || s1="$s1 tomb left;"
  if [ -z "$s1" ]; then ok; else bad "S1 round $r/$ROUNDS:$s1 $(cat "$FIX"/gate-*.out)"; fi
  r=$((r + 1))
done

echo "remote-gate.bh-2049: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
