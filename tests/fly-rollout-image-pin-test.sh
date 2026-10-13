#!/bin/bash
# tests/fly-rollout-image-pin-test.sh — the pool may only be enabled on the
# exact image the SMOKE probe passed on.
#
# BH-666: bin/fly-image-build.sh and the rollout both publish
# state/fly/<p>.image BEFORE step 4 probes it, and bin/fly-pool.sh prefers that
# pointer for dispatch as soon as its deployment tag is newer than the live
# pool's. So a probe that failed — or a nightly bin/fly-image-refresh.sh that
# moved the pointer while the probe was running — left live machines on bits
# nothing ever tested. A probe that does not test the bits you ship is not a
# probe.
#
# A: nothing moved — the probed ref is the dispatched ref.
# B: the pointer moved under the probe — REFUSE, alert, leave the pointer to
#    whoever owns it now.
# C: the probe never came back — put the pointer back where it was.
# D: a first-ever rollout has no pointer to restore, so nothing may claim one.
# Run from anywhere: tests/fly-rollout-image-pin-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/fly-rollout-fixture.sh" || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

PROBED='registry.fly.io/builder-proj-x:deployment-01BBBBBBBBBBBBBBBBBBBBBBBB'
MOVED='registry.fly.io/builder-proj-x:deployment-01ZZZZZZZZZZZZZZZZZZZZZZZZ'
PRIOR='registry.fly.io/builder-proj-x:deployment-01AAAAAAAAAAAAAAAAAAAAAAAA'

# ---------- A. the probed ref is the ref that gets dispatched ----------
rollout_reset_knobs
rollout_fixture "$T/a" "$DIR"
export MINT_TOKEN='FlyV1 fm2_minted' SMOKE_RESULT=SMOKE_OK
rollout_run "$T/a" proj-x
RC=$?

[ "$(cat "$T/a/machine-run.args" 2>/dev/null)" = "$PROBED" ] \
  && ok || bad "A the smoke machine must boot the image the build just produced (got: $(cat "$T/a/machine-run.args" 2>/dev/null))"
[ "$(cat "$T/a/h/state/fly/proj-x.image" 2>/dev/null)" = "$PROBED" ] \
  && ok || bad "A the dispatch pointer must hold the probed ref (got: $(cat "$T/a/h/state/fly/proj-x.image" 2>/dev/null))"
[ -e "$T/a/h/flags/fly-pool-proj-x" ] && [ -e "$T/a/h/flags/fly-pool-app-proj-x" ] && [ -e "$T/a/h/flags/builder-fly-proj-x" ] \
  && ok || bad "A all three routing flags must be written (got: $(ls "$T/a/h/flags"))"
rollout_log "$T/a" | grep -q "WAVE3 ENABLED.*$PROBED" \
  && ok || bad "A the enable line must name the proven ref (got: $(rollout_log "$T/a" | tail -1))"
[ "$RC" = 0 ] \
  && ok || bad "A a clean pass must exit 0 (got $RC)"

# ---------- B. the pointer moved while the probe was running ----------
rollout_reset_knobs
rollout_fixture "$T/b" "$DIR"
export MINT_TOKEN='FlyV1 fm2_minted' SMOKE_RESULT=SMOKE_OK MOVE_POINTER_TO="$MOVED"
rollout_run "$T/b" proj-x
RC=$?

[ "$(ls "$T/b/h/flags" | wc -l)" = 0 ] \
  && ok || bad "B the pool must NOT be enabled on bits the probe never tested (flags: $(ls "$T/b/h/flags"))"
[ "$(cat "$T/b/h/state/fly/proj-x.image" 2>/dev/null)" = "$MOVED" ] \
  && ok || bad "B the rollout must leave the pointer to whoever moved it (got: $(cat "$T/b/h/state/fly/proj-x.image" 2>/dev/null))"
ALERTB=$(rollout_alerts "$T/b")
case "$ALERTB" in
  *"$PROBED"*) ok ;;
  *) bad "B the ALERT must name the ref that was probed (got: $ALERTB)" ;;
esac
case "$ALERTB" in
  *"$MOVED"*) ok ;;
  *) bad "B the ALERT must name the ref the pointer holds now (got: $ALERTB)" ;;
esac
[ "$RC" != 0 ] \
  && ok || bad "B a refused flip must exit non-zero (got $RC)"

# ---------- C. the probe never returned a result ----------
rollout_reset_knobs
rollout_fixture "$T/c" "$DIR"
printf '%s\n' "$PRIOR" > "$T/c/h/state/fly/proj-x.image"
export MINT_TOKEN='FlyV1 fm2_minted'
rollout_run "$T/c" proj-x
RC=$?

[ "$(cat "$T/c/h/state/fly/proj-x.image" 2>/dev/null)" = "$PRIOR" ] \
  && ok || bad "C a failed probe must put the pointer back (got: $(cat "$T/c/h/state/fly/proj-x.image" 2>/dev/null))"
rollout_log "$T/c" | grep -q 'image pointer restored' \
  && ok || bad "C the restore must say so in the log (got: $(rollout_log "$T/c" | tail -2))"
[ "$(ls "$T/c/h/flags" | wc -l)" = 0 ] \
  && ok || bad "C a failed probe must enable nothing (flags: $(ls "$T/c/h/flags"))"
[ "$RC" != 0 ] \
  && ok || bad "C a failed probe must exit non-zero (got $RC)"

# ---------- D. a first-ever rollout has no pointer to restore ----------
rollout_reset_knobs
rollout_fixture "$T/d" "$DIR"
export MINT_TOKEN='FlyV1 fm2_minted' MACHINE_STATE=stopped SMOKE_RESULT=SMOKE_OK
rollout_run "$T/d" proj-x
RC=$?

[ "$(cat "$T/d/h/state/fly/proj-x.image" 2>/dev/null)" = "$PROBED" ] \
  && ok || bad "D with no previous pointer the freshly built ref stays (bin/fly-provision.sh reads it) (got: $(cat "$T/d/h/state/fly/proj-x.image" 2>/dev/null))"
grep -q 'image pointer restored' <<<"$(rollout_log "$T/d")" \
  && bad "D there was nothing to restore, so nothing may claim a restore" || ok
[ "$(ls "$T/d/h/flags" | wc -l)" = 0 ] \
  && ok || bad "D a machine that never started must enable nothing (flags: $(ls "$T/d/h/flags"))"
[ "$RC" != 0 ] \
  && ok || bad "D a machine that never started must exit non-zero (got $RC)"

echo "fly-rollout-image-pin-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
