#!/bin/bash
# tests/lanes-registry.bh-1291-test.sh — BH-1291 (I1): a `*_APP` knob is never
# settable from the control plane.
#
# WHY. `bin/testhost-tick.sh` reads TESTHOST_APP and passes it as `-a "$APP"` to
# `flyctl machine list/status/stop/start` and `flyctl ssh console`, under the
# box's own Fly credential. The knob carried no `settable` field, and a missing
# field means settable (bin/lib/lane-gate.sh:507), so one `PUT /api/settings`
# row could re-aim the hub's idle-stop — and its ssh console — at ANY app that
# token reaches. Section 17 of tests/lanes-registry-test.sh is the standing
# guard for exec/host/path/identity names, and its hazard alternation had no
# `APP` arm, so it was green on this knob.
#
# What is proved here:
#   1. the RENDERED registry marks testhost-tick/TESTHOST_APP settable: false;
#   2. the production reader agrees — bin/lib/lane-gate.sh's lane_knob_settable
#      refuses it, and still allows the lane's genuinely tunable minutes knob;
#   3. §17's regex itself refuses an APP-suffixed name, and does NOT drag in
#      GH_APP_ROTATE — a settable rotation switch that merely contains "APP".
# Run from anywhere: tests/lanes-registry.bh-1291-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json is GENERATED and not committed.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

REG=$(rendered_registry)

# --- 1. the rendered registry ------------------------------------------------
# jq -e, so a knob that vanished from the registry FAILS here rather than
# passing on an empty result.
jq -e '.lanes[]|select(.id=="testhost-tick")|.knobs[]|select(.env=="TESTHOST_APP")
       |.settable==false' "$REG" >/dev/null 2>&1 \
  && ok || bad "1a testhost-tick/TESTHOST_APP is not settable:false in the rendered registry"
# and it is a real boolean, not the string "false" that reads as truthy (§17b)
[ "$(jq -r '.lanes[]|select(.id=="testhost-tick")|.knobs[]|select(.env=="TESTHOST_APP")|.settable|type' "$REG")" = boolean ] \
  && ok || bad "1b settable is not a boolean on testhost-tick/TESTHOST_APP"

# --- 2. the production reader ------------------------------------------------
# lane_knob_settable is what bin/harness-ctl.sh, lane_knob and lane_env_apply
# all call; this is the entry point, not a re-implementation of the rule.
settable() {
  env LANE_REGISTRY="$REG" HARNESS="$DIR" bash -c '
    set -uo pipefail
    . "$1/bin/lib/lane-gate.sh"
    lane_knob_settable "$2" "$3"' _ "$DIR" "$1" "$2" >/dev/null 2>&1
  printf '%s' "$?"
}
[ "$(settable testhost-tick TESTHOST_APP)" = 1 ] && ok \
  || bad "2a lane_knob_settable still lets a settings row drive testhost-tick/TESTHOST_APP into flyctl"
[ "$(settable testhost-tick TESTHOST_IDLE_STOP_MIN)" = 0 ] && ok \
  || bad "2b the APP rule reached a knob it should not: TESTHOST_IDLE_STOP_MIN is an operator number"
[ "$(settable testhost-tick TESTHOST_BUSY_WINDOW_MIN)" = 0 ] && ok \
  || bad "2c the APP rule reached a knob it should not: TESTHOST_BUSY_WINDOW_MIN is an operator number"

# --- 3. §17's hazard regex refuses an APP name -------------------------------
# The regex is EVALUATED (through the same jq test() §17 runs it with), never
# grepped as text: deleting the arm has to turn this red.
eval "$(grep -m1 '^HAZ=' "$DIR/tests/lanes-registry-test.sh")"
if [ -z "${HAZ:-}" ]; then
  bad "3a could not read HAZ out of tests/lanes-registry-test.sh — §17's regex moved"
else
  ok
  haz() { jq -rn --arg re "$HAZ" --arg n "$1" '$n|test($re)'; }
  [ "$(haz TESTHOST_APP)" = true ] && ok \
    || bad "3b §17's hazard regex does not match TESTHOST_APP — a future settable APP knob ships unnoticed"
  [ "$(haz SCRATCH_APP)" = true ] && ok \
    || bad "3c §17's hazard regex does not match a new *_APP name"
  [ "$(haz APP)" = true ] && ok \
    || bad "3d §17's hazard regex does not match a bare APP knob"
  # THE ADVERSARIAL NEGATIVE. GH_APP_ROTATE is a settable rotation switch on
  # fly-pool; a substring arm would freeze it, and this ticket did not ask for
  # that. The arm is the `(^|_)APP$` suffix every other arm is written as.
  [ "$(haz GH_APP_ROTATE)" = false ] && ok \
    || bad "3e §17's hazard regex dragged in GH_APP_ROTATE, a settable knob nobody asked to freeze"
fi

echo "lanes-registry.bh-1291: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
