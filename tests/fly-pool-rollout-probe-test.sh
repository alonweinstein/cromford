#!/bin/bash
# tests/fly-pool-rollout-probe-test.sh — bin/fly-pool-rollout.sh: the wave-3
# probe must say WHY it failed, must not spend on an image build for a project
# the registry cannot place, and must not build the same project twice at once.
#
# WHY THIS EXISTS (BH-668, 2026-09-17). Six rollout passes for harness-console
# logged `smoke FAILED (push_ok=0 result='none')` after a full image build each
# time. That line was read as "the pool machine boots and never reports back",
# which is a machine-side channel bug. It was not. bin/fly-envbundle.sh died
# with `no owning box mapping for harness-console` because that project's
# fleet.conf row carried no tailnet_ip, the rollout discarded its stderr, and
# the one number it printed (push_ok=0) could mean any of four different steps.
# The same timeline shows `image build FAILED` and `image built` two seconds
# apart, which one sequential pass cannot produce: two passes were running.
#
# WHAT IS DRIVEN. The real bin/fly-pool-rollout.sh, as shipped, against a
# scratch $HARNESS with flyctl, ssh and sleep as PATH shims and the image build,
# env bundle and beat as script stubs. Every assertion is on an ARTIFACT the run
# left behind — logs/fly-pool-rollout.log, the flags/ files, the stub call logs.
# Nothing here greps the script for a string, and nothing here touches a real
# box, a real Fly org or the live harness.
#
# Run from anywhere: tests/fly-pool-rollout-probe-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# The fixture shims below are quoted heredocs that read $T when they run;
# scratch.sh no longer exports it (#609), so this test does, for its shims only.
export T
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
# The script prepends /root/.fly/bin to PATH itself, so a real flyctl installed
# there would shadow the shim and this suite would drive Fly for real. Refuse
# loudly rather than run a probe that spends money.
[ -x /root/.fly/bin/flyctl ] && { echo "refusing to run: a real flyctl at /root/.fly/bin would shadow the shim"; exit 1; }

H="$T/h"
FAKE="$T/fakebin"
LOG="$H/logs/fly-pool-rollout.log"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/state/fly" "$FAKE"
export HARNESS="$H"
export FLEET_CONF="$H/fleet.conf"

# --- registry fixture: p is placeable, q has no address (the BH-668 row) -----
cat > "$H/fleet.conf" <<'CONF'
# fixture registry
p Acme/p - - 1 box-x 10.9.9.9
q Acme/q - - 2 box-x
CONF

printf 'FLY_ORG=o\nFLY_API_TOKEN_P=t\nFLY_API_TOKEN_Q=t\nFLY_REGION=iad\n' > "$H/env/fly.env"

# --- real helpers the script calls (not under test, but not paraphrased) -----
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$DIR/bin/pool-cap.sh" \
   "$DIR/bin/result-prefix-ok.sh" "$H/bin/"
# scratch-closure-allow: only the tarball lib, on purpose. The full closure adds
# fly-image-row.sh, jobs/*, lane-gate.sh and factory-stop.sh, which reach the
# jobs worker; absent, the rollout takes its fail-open branches and stays offline.
mkdir -p "$H/bin/lib"
cp "$DIR/bin/lib/harness-tarball.sh" "$H/bin/lib/"
# The tree the smoke machine receives (bin/fly-pool.sh ships the same paths).
export HARNESS_CHECKOUT="$T/checkout"
mkdir -p "$HARNESS_CHECKOUT/bin/lib" "$HARNESS_CHECKOUT/prompts" "$HARNESS_CHECKOUT/rules" \
         "$HARNESS_CHECKOUT/catalog" "$HARNESS_CHECKOUT/fly"
printf '#!/bin/bash\n' > "$HARNESS_CHECKOUT/bin/lib/cred-probe.sh"
cp "$H/fleet.conf" "$HARNESS_CHECKOUT/fleet.conf"

# --- script stubs -----------------------------------------------------------
cat > "$H/bin/fly-image-build.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$T/calls.image"
echo "image: registry.fly.io/builder-$1:deployment-1"
exit 0
SH
cat > "$H/bin/fly-envbundle.sh" <<'SH'
#!/bin/bash
# $1 project, $2 outdir. Mode comes from $T/envbundle.mode so one fixture can
# drive both the failure the ticket saw and the success it wants.
printf '%s\n' "$*" >> "$T/calls.envbundle"
MODE=$(cat "$T/envbundle.mode" 2>/dev/null)
if [ "$MODE" = fail ]; then
  echo "fly-envbundle/$1 FATAL: ssh env extract from 10.9.9.9 failed" >&2
  exit 1
fi
mkdir -p "$2"
printf 'HARNESS_SECRET=s\n' > "$2/global.env"
printf 'PROJECT_KEY=k\n'    > "$2/$1.env"
exit 0
SH
cat > "$H/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$T/calls.beat"
exit 0
SH
printf '#!/bin/sh\nexit 0\n' > "$H/bin/harden-state.sh"
chmod +x "$H/bin"/*.sh

# --- PATH shims -------------------------------------------------------------
cat > "$FAKE/flyctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$T/calls.fly"
case "$1" in
  machine)
    case "$2" in
      run)     echo "Machine ID: 0123456789abcd"; exit 0 ;;
      destroy) exit 0 ;;
    esac ;;
  machines) printf '[{"id":"0123456789abcd","state":"started"}]\n'; exit 0 ;;
  ssh)
    # The harness copy fails on demand ($T/sftp.mode), so E can drive it.
    case "$2" in sftp) [ "$(cat "$T/sftp.mode" 2>/dev/null)" = fail ] && exit 1 ;; esac
    # Only the RESULT read answers with anything; every push is a silent ok.
    case "$*" in *"/run/harness/RESULT"*) cat "$T/result.txt" 2>/dev/null ;; esac
    exit 0 ;;
esac
exit 0
SH
cat > "$FAKE/ssh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$T/calls.ssh"
exit 0
SH
# The script waits 30s before the state read and 20s per poll. Real waits would
# make this suite a minute per case and prove nothing about the waiting.
printf '#!/bin/sh\nexit 0\n' > "$FAKE/sleep"
chmod +x "$FAKE"/*

run_rollout() { PATH="$FAKE:$PATH" bash "$DIR/bin/fly-pool-rollout.sh" "$@" >/dev/null 2>&1; }

reset() {
  scratch_rm "$H/logs"; scratch_rm "$H/flags"; scratch_rm "$H/state/fly"
  mkdir -p "$H/logs" "$H/flags" "$H/state/fly"
  scratch_rm "$T/calls.fly"; scratch_rm "$T/calls.image"
  scratch_rm "$T/calls.beat"; scratch_rm "$T/calls.ssh"
  scratch_rm "$T/calls.envbundle"; scratch_rm "$T/sftp.mode"
}

logged()     { grep -qF "$1" "$LOG" 2>/dev/null; }
flycalls()   { grep -c "^$1" "$T/calls.fly" 2>/dev/null || true; }
no_flags()   { # no routing flag may exist for $1
  [ ! -e "$H/flags/fly-pool-app-$1" ] && [ ! -e "$H/flags/fly-pool-$1" ] \
    && [ ! -e "$H/flags/builder-fly-$1" ]
}

# ===========================================================================
# A. preflight — a project the registry cannot place is skipped BEFORE the
#    30-minute image build, and the log names the gap.
# ===========================================================================
reset
printf 'ok\n' > "$T/envbundle.mode"
run_rollout q
logged "[q] no tailnet_ip for q in fleet.conf" \
  && ok || bad "A1 the log must name the missing tailnet_ip for q"
[ ! -e "$T/calls.image" ] \
  && ok || bad "A2 no image may be built for a project with no address (calls.image exists)"
[ "$(flycalls 'machine run')" = 0 ] \
  && ok || bad "A3 no machine may be spawned for q (got $(flycalls 'machine run'))"
no_flags q \
  && ok || bad "A4 no routing flag may be written for q"

# ===========================================================================
# B. the env bundle's own reason reaches the log, and a failed push flips
#    nothing. This is the BH-668 line, with the cause in it.
# ===========================================================================
reset
printf 'fail\n' > "$T/envbundle.mode"
run_rollout p
logged "smoke FAILED (push_ok=0 step=envbundle reason='fly-envbundle/p FATAL: ssh env extract from 10.9.9.9 failed' result='none')" \
  && ok || bad "B1 the smoke FAILED line must carry the failing step and the envbundle's own reason: $(grep -F 'smoke FAILED' "$LOG" 2>/dev/null)"
[ "$(flycalls 'machine destroy')" = 1 ] \
  && ok || bad "B2 the smoke machine must be destroyed exactly once (got $(flycalls 'machine destroy'))"
no_flags p \
  && ok || bad "B3 a failed push must flip no routing flag"
[ ! -e "$T/calls.beat" ] \
  && ok || bad "B4 no wave-3 beat may be sent for a failed probe"

# ===========================================================================
# C. dedupe — a second pass for the same project SKIPS (never queues behind
#    the first) and spends nothing.
# ===========================================================================
reset
printf 'ok\n' > "$T/envbundle.mode"
mkdir -p "$H/locks"
mkfifo "$T/ready.fifo" "$T/hold.fifo"
# Holder: takes the lock, says so, then blocks on a fifo nobody writes to until
# this suite releases it. No wall-clock wait anywhere.
bash -c 'exec 9>"$1"; if flock -n 9; then echo held > "$2"; else echo notheld > "$2"; exit 1; fi; read -r _ < "$3"' \
  _ "$H/locks/fly-pool-rollout-p.lock" "$T/ready.fifo" "$T/hold.fifo" &
HOLDER=$!
read -r HELD < "$T/ready.fifo"
[ "$HELD" = held ] && ok || bad "C0 fixture: the holder failed to take the lock ($HELD)"
run_rollout p
logged "[p] a rollout pass for p is already running" \
  && ok || bad "C1 a pass whose lock is held must log the skip"
[ ! -e "$T/calls.image" ] \
  && ok || bad "C2 a skipped pass must not build an image"
[ "$(flycalls 'machine run')" = 0 ] \
  && ok || bad "C3 a skipped pass must not spawn a machine (got $(flycalls 'machine run'))"
no_flags p \
  && ok || bad "C4 a skipped pass must flip no flag"
echo go > "$T/hold.fifo"
wait "$HOLDER" 2>/dev/null
scratch_rm "$T/ready.fifo"; scratch_rm "$T/hold.fifo"

# ===========================================================================
# D. the happy path, and the fail-closed ORDER it depends on: the probe comes
#    back SMOKE_OK first, the flags follow.
# ===========================================================================
reset
printf 'ok\n' > "$T/envbundle.mode"
printf 'SMOKE_OK claude reachable\n' > "$T/result.txt"
run_rollout p
logged "[p] SMOKE_OK on pool machine 0123456789abcd" \
  && ok || bad "D1 a green probe must be logged with its machine id"
[ "$(cat "$H/flags/fly-pool-app-p" 2>/dev/null)" = "pool-p" ] \
  && ok || bad "D2 flags/fly-pool-app-p must name the dedicated pool app"
[ -e "$H/flags/fly-pool-p" ] && [ ! -s "$H/flags/fly-pool-p" ] \
  && ok || bad "D3 flags/fly-pool-p must exist and be EMPTY (autoscale default)"
[ -e "$H/flags/builder-fly-p" ] \
  && ok || bad "D4 flags/builder-fly-p must be set on the hub"
[ "$(grep -c 'wave3-rollout:p' "$T/calls.beat" 2>/dev/null)" = 1 ] \
  && ok || bad "D5 exactly one wave-3 beat must be sent"
grep -q '10.9.9.9' "$T/calls.ssh" 2>/dev/null \
  && ok || bad "D6 the owning box flag must be pushed to the address the registry gives"
SMOKE_LN=$(grep -n 'SMOKE_OK on pool machine' "$LOG" | head -1 | cut -d: -f1)
WAVE_LN=$(grep -n 'WAVE3 ENABLED' "$LOG" | head -1 | cut -d: -f1)
[ -n "$SMOKE_LN" ] && [ -n "$WAVE_LN" ] && [ "$SMOKE_LN" -lt "$WAVE_LN" ] \
  && ok || bad "D7 the probe must be logged BEFORE the routing is enabled (smoke=$SMOKE_LN wave=$WAVE_LN)"

# D-negative: the push worked and the probe came back bad. The line must say so
# honestly (push_ok=1, no step), and nothing may be routed.
reset
printf 'SMOKE_FAIL claude probe did not return OK\n' > "$T/result.txt"
run_rollout p
logged "smoke FAILED (push_ok=1 step=none reason='' result='SMOKE_FAIL claude probe did not return OK')" \
  && ok || bad "D8 a pushed-but-failed probe must report push_ok=1 and the real result: $(grep -F 'smoke FAILED' "$LOG" 2>/dev/null)"
no_flags p \
  && ok || bad "D9 a SMOKE_FAIL probe must flip no routing flag"

# ===========================================================================
# E. the smoke machine gets the harness tree BEFORE the SMOKE job (BH-2559
#    made "no harness on the volume" a failed smoke; the rollout never copied
#    one, so no rollout smoke passed after 2026-09-27).
# ===========================================================================
reset
printf 'ok\n' > "$T/envbundle.mode"
printf 'SMOKE_OK claude reachable\n' > "$T/result.txt"
run_rollout p
SFTP_LN=$(grep -n '^ssh sftp put -a pool-p --machine 0123456789abcd .*/run/harness/.hsync.tgz' "$T/calls.fly" | head -1 | cut -d: -f1)
TAR_LN=$(grep -n 'xzf.*/run/harness/\.hsync\.tgz.*/data/harness' "$T/calls.fly" | head -1 | cut -d: -f1)
JOB_LN=$(grep -n '/run/harness/job.json' "$T/calls.fly" | head -1 | cut -d: -f1)
[ -n "$SFTP_LN" ] && [ -n "$TAR_LN" ] && [ -n "$JOB_LN" ] && [ "$SFTP_LN" -lt "$TAR_LN" ] && [ "$TAR_LN" -lt "$JOB_LN" ] \
  && ok || bad "E1 the harness tarball must be copied and unpacked on the smoke machine before job.json (sftp=$SFTP_LN tar=$TAR_LN job=$JOB_LN)"
reset
printf 'ok\n' > "$T/envbundle.mode"
printf 'fail\n' > "$T/sftp.mode"
printf 'SMOKE_OK claude reachable\n' > "$T/result.txt"
run_rollout p
logged "smoke FAILED (push_ok=0 step=harness-sync reason='' result='none')" \
  && ok || bad "E2 a failed harness copy must be named as step=harness-sync: $(grep -F 'smoke FAILED' "$LOG" 2>/dev/null)"
[ ! -e "$T/calls.envbundle" ] \
  && ok || bad "E3 no env bundle may be built after the harness copy failed"
no_flags p \
  && ok || bad "E4 a failed harness copy must flip no routing flag"

echo "fly-pool-rollout-probe-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
