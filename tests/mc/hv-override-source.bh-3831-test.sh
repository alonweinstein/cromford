#!/bin/bash
# tests/mc/hv-override-source.bh-3831-test.sh — BH-3831 scope 4: the negative
# test BH-3814 left out. mc_hv_override (bin/lib/mc/classify.sh) lets a lead or
# human MERGE on the exact head out-rank the conductor's own re-review BLOCK.
# A `box` row (HARNESS_SECRET alone writes those) or any source that is not
# exactly lead|human must NOT override, whatever its time. The real lib is
# sourced; only its readers are stubbed, and the time path is set up to pass, so
# the source alone decides.
#   S1 human -> rc 0, MC_HV_SOURCE=human (the control: the setup can override)
#   S2 lead  -> rc 0
#   S3 box   -> rc 1, MC_HV_ID empty
#   S4 bogus -> rc 1
#   S5 empty source (as `-`, and as a truly empty field) -> rc 1
#   S6 HUMAN (case) -> rc 1
#   S7 sticky path (mc_attempt_has rc 0) with box -> rc 1: the source check
#      comes before the sticky return
#   M  mutation: the real lib with the `case "$src" in lead|human)` line deleted
#      gives box rc 0, so S3 bites
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc/hv-override-source.bh-3831-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/mc/classify.sh"
# shellcheck source=bin/lib/mc/classify.sh
. "$LIB" || exit 1
command -v mc_hv_override >/dev/null 2>&1 || { echo "FAIL: mc_hv_override is not defined by $LIB"; exit 1; }

NOW=$(date -u +%s)
BT=$((NOW-1800))
AT=$(date -u -d "@$((NOW-900))" +%Y-%m-%dT%H:%M:%SZ)
HEAD=dddddddd44444444444444444444444444444444
KEY=example-org/cromford#3831
touch "$T/jf"

# The stubs, defined AFTER the lib so they override its readers. LINE, when set,
# is the whole vd_standing line (for the empty-field case); otherwise it is
# built from V and SRC. STICKY=1 makes mc_attempt_has answer "already applied".
# la_decide grants lead authority (BH-3814 asks it for a lead row), so here too
# the source alone decides.
stubs() {
  vd_standing() {
    if [ -n "${LINE:-}" ]; then printf '%s\n' "$LINE"
    else printf '%s\t%s\t7\t%s\t-\t-\n' "$V" "$SRC" "$AT"; fi
    return "${VRC:-0}"
  }
  mc_attempt_has() { [ "${STICKY:-0}" = 1 ]; }
  mc_log() { :; }
  mc_rr_file() { echo "$T/jf"; }
  mc_rr_field() { echo "$BT"; }
  mc_handoff_file() { echo "$T/none"; }
  la_decide() { return 0; }
}
stubs

# run <src> -> RC, and MC_HV_* as the lib left them (called in THIS shell).
run() { SRC="$1"; V="${V:-MERGE}"; RC=0; mc_hv_override "$KEY" "$HEAD" || RC=$?; }

LINE=""; STICKY=0; V=MERGE
run human
[ "$RC" = 0 ] && [ "$MC_HV_SOURCE" = human ] && [ "$MC_HV_ID" = 7 ] && ok || bad "S1 human must override (rc $RC, src '$MC_HV_SOURCE')"
run lead
[ "$RC" = 0 ] && [ "$MC_HV_SOURCE" = lead ] && ok || bad "S2 lead must override (rc $RC)"
run box
[ "$RC" = 1 ] && [ -z "$MC_HV_ID" ] && ok || bad "S3 box must NOT override (rc $RC, id '$MC_HV_ID')"
run bogus
[ "$RC" = 1 ] && ok || bad "S4 bogus must NOT override (rc $RC)"
run -
[ "$RC" = 1 ] && ok || bad "S5 source '-' must NOT override (rc $RC)"
# A truly empty source field. IFS=$'\t' read collapses consecutive tabs (tab is
# IFS whitespace), so every later column shifts left: src reads as the id. It
# must still be refused, whatever lands in src.
LINE=$(printf 'MERGE\t\t7\t%s\t-\t-' "$AT")
run ""
[ "$RC" = 1 ] && ok || bad "S5 an empty source field must NOT override (rc $RC, src '$MC_HV_SOURCE')"
LINE=""
run HUMAN
[ "$RC" = 1 ] && ok || bad "S6 HUMAN (case) must NOT override (rc $RC)"
STICKY=1
run box
[ "$RC" = 1 ] && ok || bad "S7 a sticky hvoverride must not let box through (rc $RC)"
run human
[ "$RC" = 0 ] && ok || bad "S7 control: sticky human is rc 0 (rc $RC)"
STICKY=0

# --- M. the mutant --------------------------------------------------------
# shellcheck disable=SC2016
sed '/case "\$src" in lead|human) ;; \*) return 1 ;; esac/d' "$LIB" > "$T/classify-mut.sh"
N=$(diff "$LIB" "$T/classify-mut.sh" | grep -c '^<')
[ "$N" = 1 ] && ok || bad "M the mutation must delete exactly one line (deleted $N): the source check was reworded, update this test"
(
  # shellcheck source=/dev/null
  . "$T/classify-mut.sh" || exit 9
  stubs
  RC=0; SRC=box; V=MERGE; mc_hv_override "$KEY" "$HEAD" || RC=$?
  exit "$RC"
); MRC=$?
[ "$MRC" = 0 ] && ok || bad "M the mutant (no source check) must let box through, proving S3 bites (rc $MRC)"

echo "hv-override-source: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = 0 ]
