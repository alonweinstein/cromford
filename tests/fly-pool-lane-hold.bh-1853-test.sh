#!/bin/bash
# tests/fly-pool-lane-hold.bh-1853-test.sh — one exhausted account is not a
# project-wide outage while another account can serve (BH-1853 item 2).
#
# After #1850, a RUNNER_EXHAUSTED reap cooled the leased account and then held
# EVERY spawn and reuse for the project for POOL_LANE_FAIL_HOLD_S (1800 s),
# destroying live machines, even when a healthy account was right there for the
# next lease. Pinned here, driven through the real bin/fly-pool.sh:
#   H1  exhausted claude + verified cooling + another account can serve: no
#       hold; only the exhausted machine is destroyed; the requeued job spawns
#       this tick with a fresh lease; the ALERTS line says there was no hold
#   H2  no other account can serve: the hold stands, nothing spawns
#   H3  class=auth (nothing was cooled): the hold stands
#   H4  exhausted=openrouter only (nothing was cooled): the hold stands
#   H4b the cooldown could not be verified: the hold stands
#   H5  a second live machine with an ordinary result the same tick is reused,
#       not destroyed by a hold
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/pool-reap-fixture.sh" || exit 1
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
prf_setup
cp "$DIR/bin/alert-line.sh" "$H/bin/"
HF="$H/state/pool/project-5/_spawn-hold"
LANE_EX="BUILD_DEFERRED execute session ended RUNNER_EXHAUSTED class=account-exhausted(quota) seen=account-exhausted runner=claude rc=1 exhausted=claude resets_at=$RESET"
calls() { tr '\n' '|' < "$T/acct-calls"; }

# ── H1 ────────────────────────────────────────────────────────────────────
{
  prf_reset
  write_fly_stub "m-exh=$LANE_EX"
  machine_json m-exh BH-1016 2 max3
  queue_job BH-1018   # work the exhausted machine could otherwise be handed
  prf_run_pool OTHERS_OK=1 COOLING=1
  [ -e "$HF" ] && bad "H1: a project hold was set although another account can serve: $(cat "$HF")" || ok
  grep -qx "cooldown max3 pool-project-5-BH-1016 $RESET" "$T/acct-calls" && ok || bad "H1: the account was not cooled ($(calls))"
  grep -qx "others_ok max3" "$T/acct-calls" && ok || bad "H1: the reap never asked whether another account can serve ($(calls))"
  # The requeued job is spawned this same tick, so its count rides the new
  # machine's json rather than the queue file.
  KDEF=$(jq -r 'select(.key=="BH-1016") | .deferrals' "$H/state/fly-pool/project-5"/*.json "$H/state/build-queue/project-5"/*.json 2>/dev/null | sort -u | tr '\n' ' ')
  [ "$KDEF" = "2 " ] && ok || bad "H1: deferrals must be unchanged (2), got '$KDEF'"
  [ "$(destroyed m-exh)" -ge 1 ] && ok || bad "H1: the machine carrying the exhausted account was not destroyed"
  [ "$(pushed_job m-exh)" = 0 ] && ok || bad "H1: a job was pushed onto the machine whose account just ran out"
  [ "$(spawned)" -ge 1 ] && ok || bad "H1: nothing was spawned this tick, so the ticket waits on a hold that should not exist"
  grep -q 'no project hold' "$H/logs/ALERTS.log" && ok || bad "H1: the ALERTS line does not say no hold was set: $(cat "$H/logs/ALERTS.log")"
  grep -q 'RUNNER LANE failed' "$H/logs/ALERTS.log" && bad "H1: the ALERTS line still claims a hold" || ok
}

# ── H2: no alternative ────────────────────────────────────────────────────
{
  prf_reset
  write_fly_stub "m-exh=$LANE_EX"
  machine_json m-exh BH-1016 2 max3
  prf_run_pool OTHERS_OK=0 COOLING=1
  [ -s "$HF" ] && ok || bad "H2: no account can serve and no hold was set"
  [ "$(spawned)" = 0 ] && ok || bad "H2: $(spawned) machine(s) spawned with no account to serve"
  grep -q 'no project hold' "$H/logs/ALERTS.log" && bad "H2: the no-hold line printed while a hold stands" || ok
}

# ── H3: class=auth ────────────────────────────────────────────────────────
{
  prf_reset
  write_fly_stub "m-auth=BUILD_DEFERRED execute session ended RUNNER_ERROR class=auth(credential) seen=auth runner=claude rc=1"
  machine_json m-auth BH-1016 1 max3
  prf_run_pool OTHERS_OK=1 COOLING=1
  [ -s "$HF" ] && ok || bad "H3: class=auth cooled nothing, yet no hold was set"
  grep -q '^cooldown' "$T/acct-calls" && bad "H3: class=auth cooled an account ($(calls))" || ok
}

# ── H4: only OpenRouter ran out ───────────────────────────────────────────
{
  prf_reset
  write_fly_stub "m-or=BUILD_DEFERRED execute session ended RUNNER_EXHAUSTED class=account-exhausted(credits) seen=account-exhausted runner=openrouter rc=1 exhausted=openrouter"
  machine_json m-or BH-1016 0 max4
  prf_run_pool OTHERS_OK=1 COOLING=1
  [ -s "$HF" ] && ok || bad "H4: exhausted=openrouter cooled nothing, yet no hold was set"
  grep -q '^cooldown' "$T/acct-calls" && bad "H4: exhausted=openrouter cooled the claude account" || ok
}

# ── H4b: cooling not verified ─────────────────────────────────────────────
{
  prf_reset
  write_fly_stub "m-exh=$LANE_EX"
  machine_json m-exh BH-1016 2 max3
  prf_run_pool OTHERS_OK=1 COOLING=0
  [ -s "$HF" ] && ok || bad "H4b: the cooldown was not verified and the hold was skipped anyway"
}

# ── H5: a healthy machine is reused the same tick ─────────────────────────
{
  prf_reset
  write_fly_stub "m-exh=$LANE_EX" "m-ok=BUILD_DEFERRED wip-limit 2 reached"
  machine_json m-exh BH-1016 2 max3
  machine_json m-ok BH-1017 0 max1
  prf_run_pool OTHERS_OK=1 COOLING=1 POOL_SPAWN=0
  [ -e "$HF" ] && bad "H5: a hold was set: $(cat "$HF")" || ok
  [ "$(pushed_job m-ok)" -ge 1 ] && ok || bad "H5: the healthy machine m-ok was not handed a queued job"
  [ "$(destroyed m-ok)" = 0 ] && ok || bad "H5: the healthy machine m-ok was destroyed"
  [ "$(destroyed m-exh)" -ge 1 ] && ok || bad "H5: the exhausted machine m-exh was not destroyed"
}

echo "fly-pool-lane-hold: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
