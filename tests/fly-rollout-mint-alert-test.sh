#!/bin/bash
# tests/fly-rollout-mint-alert-test.sh — a failed mint is an alert, not a
# whisper, and never a zero exit.
#
# BH-666: `2>/dev/null` on the mint threw away the one sentence that said WHY
# ("Not authorized to access this createLimitedAccessToken"), the skip went to
# the rollout's own log where nobody reads it, and the pass still exited 0. A
# question asked into your own run log is indistinguishable from silence.
# Run from anywhere: tests/fly-rollout-mint-alert-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/fly-rollout-fixture.sh" || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# ---------- 1. flyctl refused, and said why ----------
rollout_reset_knobs
rollout_fixture "$T/a" "$DIR"
export MINT_STDERR='Not authorized to access this createlimitedaccesstoken'
rollout_run "$T/a" proj-x
RC=$?

[ "$(rollout_alerts "$T/a" | grep -cE '\[rollout/proj-x\].*createlimitedaccesstoken')" = 1 ] \
  && ok || bad "1 exactly one ALERT must name the project and carry flyctl's own error (got: $(rollout_alerts "$T/a"))"
rollout_log "$T/a" | grep -q 'mint FAILED' \
  && ok || bad "1 the rollout log must still carry the skip line"
[ "$RC" != 0 ] \
  && ok || bad "1 a failed mint must make the pass exit non-zero (got $RC)"
[ "$(ls "$T/a/h/flags" | wc -l)" = 0 ] \
  && ok || bad "1 a project that never got a token must not be enabled (flags: $(ls "$T/a/h/flags"))"
[ -e "$T/a/machine-run.args" ] \
  && bad "1 a project that never got a token must not spend a smoke machine" || ok
# The ALERT carries the error, never the credential.
grep -q 'FlyV1' <<<"$(rollout_alerts "$T/a")" \
  && bad "1 the ALERT must not echo a token value" || ok

# ---------- 2. flyctl refused and said nothing ----------
rollout_reset_knobs
rollout_fixture "$T/b" "$DIR"
rollout_run "$T/b" proj-x
RC=$?

[ "$(rollout_alerts "$T/b" | grep -cE '\[rollout/proj-x\].*no stderr')" = 1 ] \
  && ok || bad "2 an empty stderr must be reported as such, never as a success (got: $(rollout_alerts "$T/b"))"
[ "$RC" != 0 ] \
  && ok || bad "2 a silent refusal is still a failure (got $RC)"

# ---------- 3. the happy path is still a zero exit ----------
rollout_reset_knobs
rollout_fixture "$T/c" "$DIR"
export MINT_TOKEN='FlyV1 fm2_minted' SMOKE_RESULT=SMOKE_OK
rollout_run "$T/c" proj-x
RC=$?

[ "$RC" = 0 ] \
  && ok || bad "3 a pass that enabled the project must exit 0 (got $RC): $(rollout_log "$T/c" | tail -3)"
[ -e "$T/c/h/logs/ALERTS.log" ] \
  && bad "3 a clean pass must write no ALERT (got: $(rollout_alerts "$T/c"))" || ok

# ---------- 4. two projects, one broken: the failure still counts ----------
rollout_reset_knobs
rollout_fixture "$T/d" "$DIR"
printf 'FLY_API_TOKEN_PROJ_X="FlyV1 fm2_preset"\n' >> "$T/d/h/env/fly.env"
export SMOKE_RESULT=SMOKE_OK MINT_STDERR='org token refused'
rollout_run "$T/d" proj-x proj-y
RC=$?

[ -e "$T/d/h/flags/fly-pool-proj-x" ] \
  && ok || bad "4 the healthy project must still be enabled"
[ "$(rollout_alerts "$T/d" | grep -cE '\[rollout/proj-y\].*org token refused')" = 1 ] \
  && ok || bad "4 the broken project must raise its own ALERT (got: $(rollout_alerts "$T/d"))"
[ "$RC" != 0 ] \
  && ok || bad "4 one skipped project must make the whole pass non-zero (got $RC)"
rollout_log "$T/d" | grep -qE 'rollout pass complete \(1 project' \
  && ok || bad "4 the closing line must count the skips (got: $(rollout_log "$T/d" | tail -1))"

echo "fly-rollout-mint-alert-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
