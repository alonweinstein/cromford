#!/bin/bash
# tests/lane-switch-readers-build.bh-2439-test.sh — the build-path kill switches
# of BH-2410 (split-chain-off, test-reroute-off, wake-lanes-off) are read
# through lane_switch by the real bin/lib/split-chain.sh split_chain_on,
# bin/lib/test-home-lib.sh th_enabled and bin/lib/wake-lanes.sh
# wake_backstop_skip (BH-2439).
#
#   L1  split_chain_on "$H" prints 0 / 1 / 0 for the fixture's (i)/(ii)/(iii);
#       (iv) a cached row 1 still answers 0 once the worker stops answering
#   L2  th_enabled "$H" gives rc 1 / rc 0 / rc 1
#   L5  wake_backstop_skip review-prs with a fresh stamp and its class flag
#       gives rc 1 / rc 0 (skips) / rc 1
#   L7a each lib copied WITHOUT lane-switch.sh and lane-gate.sh still honours
#       flags/<name>, answers OFF with no file, and says nothing on stderr
#   L7b sourcing a lib alone defines neither lane_switch nor _lg_settings_refresh
#   L7c a `yes please` row, another box's row, the colliding key
#       switch.<name>-extra and a registry-seed row each leave the switch OFF
#   Lnet no /api/flags/<switch> request from any read above (the readers use
#       `file` mode), and repeated reads inside the TTL cost one GET /api/settings
# Run from anywhere: tests/lane-switch-readers-build.bh-2439-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/lane-switch-fixture.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

LIBS="bin/lib/split-chain.sh bin/lib/test-home-lib.sh bin/lib/wake-lanes.sh"
# shellcheck disable=SC2086
lsf_setup $LIBS || { bad "lsf_setup"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }
ALLCALLS="$T/allcalls"; : > "$ALLCALLS"
# The stub client gets a flag_active that records the request flag mode would
# make, so a reader left on the default mode shows up in Lnet.
cat >> "$H/bin/jobs-client.sh" <<'SH'
flag_active() { echo "GET /api/flags/$1" >> "$CALLS"; [ -f "$HARNESS/flags/$1" ]; }
SH

# The probes call the real functions from the copied libs; each one keeps what
# it asked the stub in $ALLCALLS, because lsf_reset empties $CALLS per case.
sc_probe() {
  . "$HARNESS/bin/lib/split-chain.sh"
  split_chain_on "$HARNESS"
  cat "$CALLS" >> "$ALLCALLS"
}
th_probe() {
  unset TEST_REROUTE
  . "$HARNESS/bin/lib/test-home-lib.sh"
  th_enabled "$HARNESS"; echo "$?"
  cat "$CALLS" >> "$ALLCALLS"
}
# lsf_reset clears flags/, so the class flag and the stamp are made here.
wl_probe() {
  . "$HARNESS/bin/lib/wake-lanes.sh"
  flag_active() { [ -f "$HARNESS/flags/$1" ]; }
  touch "$HARNESS/flags/wake-lanes-pr-ci"
  mkdir -p "$HARNESS/state/wake-ran" && date +%s > "$HARNESS/state/wake-ran/review-prs"
  unset WAKE_LAUNCH
  HARNESS="$HARNESS" wake_backstop_skip review-prs "" 1800; echo "$?"
  cat "$CALLS" >> "$ALLCALLS"
}
export ALLCALLS

# L1
out=$(lsf_cases split-chain-off sc_probe 0 1); eq "L1 split_chain_on cases" "$out" ""
lsf_reset; lsf_row split-chain-off 1
got=$(LANE_GATE_NOW=1000000 _lsf_probe sc_probe)
eq "L1 (iv) cache fill" "$got" 0
got=$(UNREACHABLE=1 LANE_GATE_NOW=1000200 _lsf_probe sc_probe)
eq "L1 (iv) worker unreachable, cached row 1" "$got" 0
eq "L1 (iv) the stale cache was refreshed once more (and refused)" \
   "$(grep -c '^GET /api/settings$' "$CALLS")" 2

# L2
out=$(lsf_cases test-reroute-off th_probe 1 0); eq "L2 th_enabled cases" "$out" ""

# L5
out=$(lsf_cases wake-lanes-off wl_probe 1 0); eq "L5 wake_backstop_skip cases" "$out" ""

# Lnet
# wake_backstop_skip's own class-flag read (flag_active wake-lanes-pr-ci) is
# unchanged by this ticket and still asks; it doubles as the proof that the
# stub's flag_active is the one a flag-mode switch read would reach.
eq "Lnet no /api/flags request for a switch" \
   "$(grep -cE '/api/flags/(split-chain-off|test-reroute-off|wake-lanes-off)$' "$ALLCALLS")" 0
grep -q '^GET /api/flags/wake-lanes-pr-ci$' "$ALLCALLS" && ok \
  || bad "Lnet guard: the stub flag_active was never reached, so the check above proves nothing"
lsf_reset
net_probe() {
  . "$HARNESS/bin/lib/split-chain.sh"; . "$HARNESS/bin/lib/test-home-lib.sh"
  split_chain_on "$HARNESS" >/dev/null; th_enabled "$HARNESS"; split_chain_on "$HARNESS" >/dev/null
  grep -c '^GET /api/settings$' "$CALLS"
}
eq "Lnet repeated reads inside the TTL" "$(LANE_GATE_NOW=2000000 _lsf_probe net_probe)" 1

# L7a — no lane-switch.sh, no lane-gate.sh beside the libs.
N="$T/nolib"
mkdir -p "$N/bin/lib" "$N/flags" "$N/state"
touch "$T/nolib.calls"
for l in $LIBS; do cp "$DIR/$l" "$N/$l"; done
# nl_run <lib-probe-fn> -> "<stdout>|<stderr>"
nl_run() {
  local e="$T/nolib.err" o
  o=$(HARNESS="$N" H="$N" CALLS="$T/nolib.calls" ALLCALLS="$T/nolib.calls" "$1" 2>"$e")
  printf '%s|%s' "$o" "$(cat "$e")"
}
for n in split-chain-off test-reroute-off wake-lanes-off; do rm -f "$N/flags/$n"; done
eq "L7a split-chain no file"  "$(nl_run sc_probe)" "1|"
eq "L7a test-reroute no file" "$(nl_run th_probe)" "0|"
eq "L7a wake-lanes no file"   "$(nl_run wl_probe)" "0|"
touch "$N/flags/split-chain-off" "$N/flags/test-reroute-off" "$N/flags/wake-lanes-off"
eq "L7a split-chain file"  "$(nl_run sc_probe)" "0|"
eq "L7a test-reroute file" "$(nl_run th_probe)" "1|"
eq "L7a wake-lanes file"   "$(nl_run wl_probe)" "1|"

# L7b
for l in $LIBS; do
  eq "L7b $l defines no switch reader on source" \
     "$(bash -c '. "$1"; command -v lane_switch; command -v _lg_settings_refresh' _ "$DIR/$l" 2>/dev/null)" ""
done

# L7c — each row alone, no file: the switch stays OFF.
seed_row() {
  jq -c --arg k "switch.$1" '. + [{key:$k,value:"1",actor:"registry-seed"}]' "$ROWS_FILE" > "$ROWS_FILE.new" \
    && mv "$ROWS_FILE.new" "$ROWS_FILE"
}
for spec in "split-chain-off sc_probe 1" "test-reroute-off th_probe 0" "wake-lanes-off wl_probe 0"; do
  set -- $spec; n=$1; p=$2; off=$3
  lsf_reset; lsf_row "$n" "yes please"
  eq "L7c $n 'yes please' row" "$(_lsf_probe "$p")" "$off"
  lsf_reset; lsf_row "$n" 1 other-box
  eq "L7c $n other box's row" "$(LSF_BOX=hub-1 _lsf_probe "$p")" "$off"
  lsf_reset; lsf_row "$n-extra" 1
  eq "L7c $n colliding key $n-extra" "$(_lsf_probe "$p")" "$off"
  lsf_reset; seed_row "$n"
  eq "L7c $n registry-seed row" "$(_lsf_probe "$p")" "$off"
  # guard: the same row from a real actor does turn it ON, so the four above
  # are OFF because of the row's shape, not because rows are never read.
  lsf_reset; lsf_row "$n" 1 hub-1
  [ "$(LSF_BOX=hub-1 _lsf_probe "$p")" != "$off" ] && ok || bad "L7c $n guard: this box's own row 1 did not turn it ON"
done
lsf_reset

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
