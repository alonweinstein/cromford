#!/bin/bash
# tests/fly-rollout-mint-env-test.sh — the org-token mint must run on the hub's
# flyctl SESSION auth, not on whatever token env/fly.env happens to export.
#
# BH-666: bin/fly-pool-rollout.sh unset FLY_ACCESS_TOKEN at the mint site but
# left FLY_API_TOKEN — the limited org bootstrap token — in the environment, so
# flyctl authenticated as the limited token and refused createLimitedAccessToken
# on every new project. The assertion is on the environment the flyctl stub
# actually saw, captured to mint.env, and on the environment the LATER calls
# see: dropping both vars at the mint must not cost step 4 its project token.
# Run from anywhere: tests/fly-rollout-mint-env-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/fly-rollout-fixture.sh" || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# ---------- 1 + 2. a mint that has to happen ----------
rollout_reset_knobs
rollout_fixture "$T/a" "$DIR"
export MINT_TOKEN='FlyV1 fm2_minted' SMOKE_RESULT=SMOKE_OK
rollout_run "$T/a" proj-x
RC=$?

[ -s "$T/a/mint.env" ] \
  && ok || bad "1 the rollout must call flyctl tokens create when no project token is set"
grep -q '^FLY_API_TOKEN=' "$T/a/mint.env" \
  && bad "1 the limited FLY_API_TOKEN must NOT reach the mint (got: $(grep -m1 '^FLY_API_TOKEN=' "$T/a/mint.env"))" || ok
grep -q '^FLY_ACCESS_TOKEN=' "$T/a/mint.env" \
  && bad "1 FLY_ACCESS_TOKEN must NOT reach the mint (got: $(grep -m1 '^FLY_ACCESS_TOKEN=' "$T/a/mint.env"))" || ok

# The audit half: every flyctl call AFTER the mint must still run on the
# project token, or the fix would have traded one auth bug for another.
[ -s "$T/a/machine-run.env" ] \
  && ok || bad "2 the smoke machine must have been launched"
[ "$(grep -m1 '^FLY_ACCESS_TOKEN=' "$T/a/machine-run.env")" = 'FLY_ACCESS_TOKEN=FlyV1 fm2_minted' ] \
  && ok || bad "2 the smoke launch must see the freshly minted project token (got: $(grep -m1 '^FLY_ACCESS_TOKEN=' "$T/a/machine-run.env"))"
# bin/fly-image-build.sh re-exports FLY_API_TOKEN for the registry push, so the
# mint must be the only site that drops it.
grep -q '^FLY_API_TOKEN=FlyV1 fm2_limited$' "$T/a/machine-run.env" \
  && ok || bad "2 FLY_API_TOKEN must stay exported for the rest of the pass (the registry push needs it)"
[ "$RC" = 0 ] \
  && ok || bad "2 a clean pass must exit 0 (got $RC): $(rollout_log "$T/a" | tail -3)"

# ---------- 3. a project that already has a token mints nothing ----------
rollout_reset_knobs
rollout_fixture "$T/b" "$DIR"
printf 'FLY_API_TOKEN_PROJ_X="FlyV1 fm2_preset"\n' >> "$T/b/h/env/fly.env"
export SMOKE_RESULT=SMOKE_OK
rollout_run "$T/b" proj-x
RC=$?

[ -e "$T/b/mint.env" ] \
  && bad "3 a project whose token is already set must not call tokens create" || ok
[ -e "$T/b/h/logs/ALERTS.log" ] \
  && bad "3 a pass with nothing to mint must write no ALERT (got: $(rollout_alerts "$T/b"))" || ok
[ "$(grep -m1 '^FLY_ACCESS_TOKEN=' "$T/b/machine-run.env")" = 'FLY_ACCESS_TOKEN=FlyV1 fm2_preset' ] \
  && ok || bad "3 the pre-set project token must be the one the rest of the pass uses"
[ "$RC" = 0 ] \
  && ok || bad "3 a clean pass must exit 0 (got $RC)"

echo "fly-rollout-mint-env-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
