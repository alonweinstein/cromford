#!/bin/bash
# tests/remote-gate.bh-1854-test.sh — the cert reissue in bin/remote-gate.sh is
# serialized even where `flock` is missing, and its watchdog kills the whole
# issue, helpers included (BH-1854, the #1851 lead-review follow-up).
#
# WHY. The Mac is where lead fix agents run bin/remote-gate.sh, often several at
# once, and a Mac has no flock(1). BH-1836 issued unlocked there. The key and the
# cert move in two separate renames, so two issuers finishing together could
# leave issuer A's key beside issuer B's cert: a pair that reads as valid for
# 72 h and fails every ssh auth. And the watchdog killed only the flyctl pid, so
# any helper flyctl had started lived on past the gate.
#
# WHAT THIS PINS, every case through the real CLI (`bin/remote-gate.sh <dir> --
# true`) with flock HIDDEN from PATH (a symlink farm of the system bin dirs
# without it) and PATH shims for flyctl/ssh/nc/rsync/ssh-keygen:
#   F1 (the ticket's acceptance) four concurrent reissues issue ONCE and leave a
#      matching key/cert pair; the lock dir is gone afterwards
#   F2 a still-valid cert with the lock held by a live gate never waits, never
#      issues
#   F3 no cert with the lock held by a live gate waits a bounded time, then 125
#   F4 a lock left by a dead gate is reclaimed (issue once, lock gone)
#   F5 a lock older than twice one issuer's bound is reclaimed even if its pid lives
#      (a recycled pid, or a wedged holder)
#   F6 a lock dir with no owner file is not stolen while young
#   G1 the watchdog kills the issue's whole process group, not just flyctl
#
# Every gate run is under `timeout 40`, so a hang is a red case, not a suite
# that never ends.
#
# Run from anywhere: tests/remote-gate.bh-1854-test.sh   (exit 0 = all pass)
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

# ── F1. the acceptance: N concurrent reissues, no flock → one issue, one pair ─
reset; : > "$FIX/slow"; KNOB_T=10
pids=()
for i in 1 2 3 4; do gate > "$FIX/gate-$i.out" 2>&1 & pids+=($!); done
rcs=""
for p in "${pids[@]}"; do wait "$p"; rcs="$rcs $?"; done
[ "$(issues)" = 1 ] && ok || bad "F1 four concurrent gates with no flock issued $(issues) times (want 1): $(cat "$FIX/fly-calls" 2>/dev/null)"
pair_ok && ok || bad "F1b the key/cert pair is torn: key='$(cat "$T/key" 2>/dev/null)' cert='$(cat "$T/key-cert.pub" 2>/dev/null)'"
[ "$rcs" = " 0 0 0 0" ] && ok || bad "F1c concurrent gates gave rc$rcs (want 0 0 0 0): $(cat "$FIX"/gate-*.out)"
[ ! -e "$LOCKD" ] && ok || bad "F1d the lock dir $LOCKD is still there after every gate returned"
ls -d "$T"/key.issue.lock.d.* >/dev/null 2>&1 && bad "F1e a reclaim tomb was left: $(ls -d "$T"/key.issue.lock.d.*)" || ok

# ── F2. valid cert, lock held by a live gate: no wait, no issue ─────────────
reset; seed_cert +60; hold_lock 0
run
[ "$RC" = 0 ] && [ "$EL" -lt 3 ] && ok || bad "F2 a valid cert with the lock held gave rc $RC after ${EL}s (want 0 in <3s): $OUT"
[ "$(issues)" = 0 ] && ok || bad "F2b the gate issued while a live gate held the lock"
[ -d "$LOCKD" ] && ok || bad "F2c the gate removed a lock a live gate holds"

# ── F3. no cert, lock held by a live gate: a bounded wait, then 125 ─────────
reset; KNOB_T=2; hold_lock 0
run
[ "$RC" = 125 ] && [ "$EL" -lt 25 ] && ok || bad "F3 no cert with the lock held gave rc $RC after ${EL}s (want 125 in <25s): $OUT"
[ "$(issues)" = 0 ] && ok || bad "F3b the gate issued while a live gate held the lock"

# ── F4. a dead gate's lock is reclaimed ─────────────────────────────────────
reset
sleep 0 & dead=$!; wait "$dead"
mkdir "$LOCKD"; echo "$dead $(date +%s)" > "$LOCKD/owner"   # determinism: ok a fresh stamp, so only the dead pid makes it stale
run
[ "$RC" = 0 ] && [ "$EL" -lt 15 ] && ok || bad "F4 a lock left by dead pid $dead gave rc $RC after ${EL}s (want 0, reclaimed): $OUT"
[ "$(issues)" = 1 ] && ok || bad "F4b want one issue after the reclaim, got $(issues)"
pair_ok && ok || bad "F4c the pair after the reclaim is torn"
[ ! -e "$LOCKD" ] && ok || bad "F4d the reclaimed lock was not released"

# ── F5. a lock older than one issuer's bound is stale even with a live pid ──
reset; KNOB_T=2; hold_lock -600
run
[ "$RC" = 0 ] && [ "$EL" -lt 15 ] && ok || bad "F5 a 10-minute-old lock gave rc $RC after ${EL}s (want 0, reclaimed): $OUT"
[ "$(issues)" = 1 ] && ok || bad "F5b want one issue after the reclaim, got $(issues)"

# ── F6. a young lock with no owner file yet is someone mid-mkdir: not stale ─
reset; seed_cert +60; mkdir "$LOCKD"
run
[ "$RC" = 0 ] && [ "$(issues)" = 0 ] && ok || bad "F6 a young owner-less lock was stolen (rc $RC, $(issues) issues): $OUT"
[ -d "$LOCKD" ] && ok || bad "F6b a young owner-less lock was removed"

# ── G1. the watchdog kills the whole issue, helpers included ────────────────
reset; KNOB_T=2; : > "$FIX/hang"; seed_cert +60
run
[ "$RC" = 0 ] && [ "$EL" -lt 20 ] && ok || bad "G1 a hung issue with a valid cert gave rc $RC after ${EL}s: $OUT"
sleep 1   # determinism: ok let the KILL land before the liveness read
alive=""
for p in $(cat "$FIX/helper-pids" 2>/dev/null); do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
[ -s "$FIX/helper-pids" ] && ok || bad "G1b the stub never started its helper"
[ -z "$alive" ] && ok || bad "G1c the watchdog left the issue's helper running:$alive"
alive=""
for p in $(cat "$FIX/hang-pids" 2>/dev/null); do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
[ -z "$alive" ] && ok || bad "G1d the hung flyctl is still running:$alive"

echo "remote-gate.bh-1854: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
