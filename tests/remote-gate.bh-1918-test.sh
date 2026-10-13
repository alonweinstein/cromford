#!/bin/bash
# tests/remote-gate.bh-1918-test.sh — the mkdir reissue lock in bin/remote-gate.sh
# survives signals, torn owner reads and racing reclaimers (BH-1918, the #1910
# review follow-ups to BH-1854).
#
# WHY. Three holes were left in the BH-1854 lock:
#   1. `trap _rg_cleanup EXIT INT TERM` released the lock on INT/TERM and then
#      carried on: a TERM inside the cert issue read as "flyctl exited 143", the
#      gate fell back to its current cert and ran the job UNLOCKED, and the hung
#      flyctl and its helpers lived on.
#   2. An owner read with no space ("12345") or one that did not parse ("x y")
#      was judged stale, so a LIVE lock was stolen.
#   3. The reclaim's per-pid tomb and check-then-act put-back could end with two
#      gates each believing they held the lock.
#
# WHAT THIS PINS, every case through the real CLI (`bin/remote-gate.sh <dir> --
# true`) with flock HIDDEN from PATH and PATH shims for flyctl/ssh/nc/rsync/
# ssh-keygen (the BH-1854 fixture):
#   S1 TERM during a hung issue: rc 143 fast, lock gone, no job sent, the hung
#      flyctl and its helper dead
#   S2 the same for INT, rc 130
#   O1 a live lock whose owner reads "<pid>" (no space) is left alone
#   O2 a young lock whose owner is "x y" is left alone
#   O3 an over-age lock whose owner is "x y" is reclaimed (garbled is not immortal)
#   O4 a live lock whose owner reads "<pid> " (empty epoch) is left alone
#   R1 stress, valid cert (no-wait mode): 6 rounds x 8 gates from a stale lock,
#      never two issuers at once, nothing left behind
#   R2 stress, no cert (wait mode): 3 rounds x 6 gates, the same
# R1/R2 are probabilistic: a green run is evidence, not proof, that the race is
# closed. S1/S2/O1/O2/O4 are deterministic.
#
# Run from anywhere: tests/remote-gate.bh-1918-test.sh   (exit 0 = all pass)
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
  for p in $(cat "$FIX/hang-pids" "$FIX/helper-pids" "$FIX/sig-gate" 2>/dev/null) ${HOLDERS[@]+"${HOLDERS[@]}"}; do kill -KILL "$p" 2>/dev/null; done
  # This trap REPLACES tests/lib/scratch.sh's EXIT trap, so run its cleanup too.
  scratch_cleanup 2>/dev/null || true
  return 0
}
trap _cleanup EXIT

# ── a PATH with no flock ─────────────────────────────────────────────────────
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
# flyctl ssh issue brackets its work with an `inside` dir: two issuers at once
# is an `overlap` line. keep-stale leaves cert-to alone, so the cert stays
# not-fresh and EVERY gate that takes the lock issues.
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
case "$1 ${2:-}" in
  "proxy "*|"proxy") : > "$FIX/proxy-up"; exit 0 ;;
  "ssh issue")
    shift 2
    p="$2"
    if [ -f "$FIX/hang" ]; then
      sleep 120 </dev/null >/dev/null 2>&1 &   # determinism: ok a helper that must die with the gate
      echo $! >> "$FIX/helper-pids"
      echo $$ >> "$FIX/hang-pids"
      exec sleep 120                           # determinism: ok a stub that never answers
    fi
    mkdir "$FIX/inside" 2>/dev/null || echo "overlap $$" >> "$FIX/overlap"
    sleep 0.3                                  # determinism: ok an issue that takes time is what makes gates overlap
    printf 'key-%s\n' "$$" > "$p"
    printf 'cert-%s\n' "$$" > "$p-cert.pub"
    rmdir "$FIX/inside" 2>/dev/null
    [ -f "$FIX/keep-stale" ] || rm -f "$FIX/cert-to"
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
genv() { # $GENV_EXEC=exec makes the env (then bash) replace the caller, so $! is the gate
  ${GENV_EXEC:-} env PATH="$NOFLOCK_PATH" HOME="$T" HARNESS="$T/h" \
    TESTHOST_APP=bh-testhost-fixture TESTHOST_PORT=10022 TESTHOST_ORG=fixture-org \
    TESTHOST_KEY="$T/key" REMOTE_GATE_PROXY_WAIT_S=2 \
    REMOTE_GATE_CERT_ISSUE_TIMEOUT_S="$KNOB_T" "$@"
}
gate() { genv timeout 40 bash "$GATE" "$T/wt" -- true < /dev/null; }
run() { local s=$SECONDS; OUT=$(gate 2>&1); RC=$?; EL=$((SECONDS - s)); }
reset() {
  local p
  for p in ${HOLDERS[@]+"${HOLDERS[@]}"} $(cat "$FIX/hang-pids" "$FIX/helper-pids" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
  for p in ${HOLDERS[@]+"${HOLDERS[@]}"}; do wait "$p" 2>/dev/null; done
  HOLDERS=()
  rm -f "$FIX"/fly-calls "$FIX"/job "$FIX"/proxy-up "$FIX"/cert-to "$FIX"/hang "$FIX"/keep-stale \
    "$FIX"/overlap "$FIX"/hang-pids "$FIX"/helper-pids "$FIX"/sig-gate "$FIX"/gate-*.out \
    "$T/key" "$T/key-cert.pub"
  rmdir "$FIX/inside" 2>/dev/null
  scratch_rm "$LOCKD"
  for p in "$T"/key.issue.lock.d.*; do [ -e "$p" ] && scratch_rm "$p"; done
  KNOB_T=3
}
date_plus() { # date_plus <minutes> — a LOCAL-time stamp in ssh-keygen's format
  if date -d "$1 minutes" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null; then :   # determinism: ok the expiry under test is relative to now by definition
  else date -v "$1M" '+%Y-%m-%dT%H:%M:%S'; fi                        # determinism: ok same read, BSD date
}
age_dir() { # age_dir <minutes ago> <dir> — set a dir's mtime into the past
  local s
  s=$(date -d "-$1 minutes" '+%Y%m%d%H%M' 2>/dev/null || date -v "-$1M" '+%Y%m%d%H%M')   # determinism: ok an age relative to now by definition
  touch -t "$s" "$2"
}
seed_cert() { # seed_cert <minutes left, signed>
  printf 'key\n' > "$T/key"; printf 'cert\n' > "$T/key-cert.pub"
  date_plus "$1" > "$FIX/cert-to"
}
issues() { [ -f "$FIX/fly-calls" ] || { echo 0; return; }; grep -c '^ssh issue' "$FIX/fly-calls"; }
live_holder() { sleep 60 & HOLDERS+=($!); }    # determinism: ok a live lock holder
dead_pid() { sleep 0 & DEAD=$!; wait "$DEAD"; }  # determinism: ok a pid that is gone
leftovers() { ls -d "$T"/key.issue.lock.d.* 2>/dev/null; }

# ── S1/S2. a signal during a hung issue ends the gate ───────────────────────
# The gate runs under `set -m` so it is its own job with INT not ignored (a
# non-interactive shell starts its background children with INT ignored).
sig_case() { # sig_case <name> <signal> <want rc>
  local name=$1 sig=$2 want=$3 gp wd i s rc el alive p
  reset; seed_cert +60; : > "$FIX/hang"; KNOB_T=30
  set -m
  ( GENV_EXEC=exec genv bash "$GATE" "$T/wt" -- true ) </dev/null >"$FIX/gate-sig.out" 2>&1 &
  gp=$!
  set +m
  echo "$gp" > "$FIX/sig-gate"
  for i in $(seq 1 50); do
    [ -s "$FIX/hang-pids" ] && break
    sleep 0.2                                   # determinism: ok a bounded wait for the stub to hang
  done
  [ -s "$FIX/hang-pids" ] || bad "$name setup: the issue never started: $(cat "$FIX/gate-sig.out")"
  sleep 0.3                                     # determinism: ok let the stub reach its exec
  ( sleep 20; kill -KILL "$gp" ) </dev/null >/dev/null 2>&1 &   # determinism: ok a bound on a gate that ignores the signal
  wd=$!
  s=$SECONDS
  kill -"$sig" "$gp"
  wait "$gp"; rc=$?
  el=$((SECONDS - s))
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  [ "$rc" = "$want" ] && [ "$el" -le 5 ] && ok || bad "${name}a $sig mid-issue gave rc $rc after ${el}s (want $want in <=5s): $(cat "$FIX/gate-sig.out")"
  [ ! -e "$LOCKD" ] && ok || bad "${name}b $sig left the lock dir $LOCKD behind"
  [ ! -e "$FIX/job" ] && ! grep -q '^proxy' "$FIX/fly-calls" 2>/dev/null && ok \
    || bad "${name}c the gate carried on after $sig (job sent or proxy started): $(cat "$FIX/fly-calls" 2>/dev/null | tr '\n' '|')"
  sleep 1                                       # determinism: ok let the forwarded signal land before the liveness read
  alive=""
  for p in $(cat "$FIX/hang-pids" "$FIX/helper-pids" 2>/dev/null); do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
  [ -z "$alive" ] && ok || bad "${name}d the hung flyctl or its helper outlived the gate:$alive"
}
sig_case S1 TERM 143
sig_case S2 INT 130

# ── O1-O4. an owner that does not parse is live until the dir is over-age ───
owner_case() { # owner_case <name> <owner line> — a young live lock, left alone
  local name=$1 own=$2
  run
  [ "$RC" = 0 ] && [ "$(issues)" = 0 ] && ok || bad "$name a live lock with owner '$own' was stolen (rc $RC, $(issues) issues): $OUT"
  [ -d "$LOCKD" ] && [ "$(cat "$LOCKD/owner" 2>/dev/null)" = "$own" ] && ok \
    || bad "${name}b the lock with owner '$own' was replaced or removed (now '$(cat "$LOCKD/owner" 2>/dev/null)')"
}
reset; seed_cert +60; live_holder; mkdir "$LOCKD"; echo "${HOLDERS[0]}" > "$LOCKD/owner"
owner_case O1 "${HOLDERS[0]}"
reset; seed_cert +60; mkdir "$LOCKD"; echo "x y" > "$LOCKD/owner"
owner_case O2 "x y"
reset; seed_cert +60; live_holder; mkdir "$LOCKD"; echo "${HOLDERS[0]} " > "$LOCKD/owner"
owner_case O4 "${HOLDERS[0]} "

reset; seed_cert +60; mkdir "$LOCKD"; echo "x y" > "$LOCKD/owner"; age_dir 120 "$LOCKD"
run
[ "$RC" = 0 ] && [ "$(issues)" = 1 ] && ok || bad "O3 an over-age garbled lock was not reclaimed (rc $RC, $(issues) issues): $OUT"
[ ! -e "$LOCKD" ] && [ -z "$(leftovers)" ] && ok || bad "O3b the reclaimed lock or a tomb was left: $(ls -d "$LOCKD"* 2>/dev/null)"

# ── R1/R2. many gates from a stale lock: one issuer at a time ───────────────
stress() { # stress <name> <round> <gates> — launch, wait, check one round
  local name=$1 r=$2 n=$3 i p pids=() rcs="" want=""
  for i in $(seq 1 "$n"); do gate > "$FIX/gate-$r-$i.out" 2>&1 & pids+=($!); want="$want 0"; done
  for p in "${pids[@]}"; do wait "$p"; rcs="$rcs $?"; done
  [ ! -e "$FIX/overlap" ] && ok || bad "$name round $r: two gates issued at once: $(tr '\n' ' ' < "$FIX/overlap")"
  [ "$(issues)" -ge 1 ] && ok || bad "$name round $r: nobody reclaimed the stale lock ($(issues) issues)"
  [ "$rcs" = "$want" ] && ok || bad "$name round $r: rc$rcs (want$want): $(cat "$FIX"/gate-"$r"-*.out)"
  [ ! -e "$LOCKD" ] && [ -z "$(leftovers)" ] && ok || bad "$name round $r: left behind: $(ls -d "$LOCKD"* 2>/dev/null)"
}
for r in 1 2 3 4 5 6; do
  reset; seed_cert +30; : > "$FIX/keep-stale"
  mkdir "$LOCKD"
  case $((r % 3)) in
    1) dead_pid; echo "$DEAD $(date +%s)" > "$LOCKD/owner" ;;             # determinism: ok a fresh stamp, only the dead pid makes it stale
    2) age_dir 120 "$LOCKD" ;;
    0) live_holder; echo "${HOLDERS[0]} $(( $(date +%s) - 600 ))" > "$LOCKD/owner" ;;   # determinism: ok an over-age stamp relative to now
  esac
  stress R1 "$r" 8
done
for r in 1 2 3; do
  reset; KNOB_T=5; : > "$FIX/keep-stale"
  mkdir "$LOCKD"; dead_pid; echo "$DEAD $(date +%s)" > "$LOCKD/owner"   # determinism: ok a fresh stamp, only the dead pid makes it stale
  stress R2 "$r" 6
done

echo "remote-gate.bh-1918: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
