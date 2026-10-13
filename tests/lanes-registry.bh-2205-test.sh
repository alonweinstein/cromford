#!/bin/bash
# tests/lanes-registry.bh-2205-test.sh — a lane with no cadence really turns
# tests/lanes-registry-test.sh RED.
#
# WHY. §2 read the rendered fleet as `for f in "$(rendered_cron_dir)"/*.cron`.
# When bin/render-cron.sh refused the render, tests/lib/rendered.sh's `exit 1`
# only left the $(...) subshell: the FAIL went to stderr, the loop read nothing,
# and §2 and §4 counted an empty scan as a pass. The suite said "0 failed" with
# its cron checks silently skipped (BH-2205). This file blanks one lane's
# cadence in a COPY of the tree and runs the real suite, plus a clean control.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lanes-registry.bh-2205-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# copy_tree <dest> — the tracked tree, plus the untracked fleet.conf §9/§14 read
copy_tree() {
  mkdir -p "$1"
  git -C "$DIR" ls-files -z | tar -C "$DIR" --null -T - -cf - | tar -C "$1" -xf - \
    || { echo "FAIL: could not copy the tracked tree"; exit 1; }
  [ -f "$DIR/fleet.conf" ] && cp "$DIR/fleet.conf" "$1/fleet.conf"
  return 0
}

# run_suite <tree> <out> — the real suite, as CI runs it; echoes its rc
run_suite() {
  ( cd "$1" && HARNESS_TEST_SANDBOX=1 bash "$1/tests/lanes-registry-test.sh" ) > "$2" 2>&1
  echo $?
}

# --- case M: alert-flush loses its cadence -----------------------------------
copy_tree "$T/m"
LANE="$T/m/catalog/lanes.d/alert-flush.json"
if [ ! -f "$LANE" ] || [ -z "$(jq -r '.cadence // ""' "$LANE")" ]; then
  bad "setup: alert-flush lane moved or already has no cadence — pick another lane"
else
  jq '.cadence=""' "$LANE" > "$LANE.new" && mv "$LANE.new" "$LANE"
  OUT="$T/m.out"; RC=$(run_suite "$T/m" "$OUT")

  # M1 the suite fails at all
  [ "$RC" -ne 0 ] && ok || bad "M1 a lane with no cadence must fail tests/lanes-registry-test.sh (rc $RC)"
  # M2 the refused render is a COUNTED failure on stdout, not only a stderr note
  grep -q '^FAIL: 2 could not render the fleet' "$OUT" && ok \
    || bad "M2 no counted 'FAIL: 2 could not render the fleet' line"
  # M3 the summary reports at least one failure
  K=$(sed -nE 's/^lanes-registry: [0-9]+ passed, ([0-9]+) failed.*/\1/p' "$OUT" | tail -1)
  [ "${K:-0}" -ge 1 ] && ok || bad "M3 summary must report >=1 failed (got '${K:-<no summary>}')"
  # M4 the render's own reason reached the output: the failure is the cadence
  grep -q 'lanes with no cadence: alert-flush' "$OUT" && ok \
    || bad "M4 render-cron's reason 'lanes with no cadence: alert-flush' is not in the output"
fi

# --- case C: the same copy harness on a clean tree stays green ---------------
copy_tree "$T/c"
OUT="$T/c.out"; RC=$(run_suite "$T/c" "$OUT")
# C1
[ "$RC" -eq 0 ] && ok || { bad "C1 an unmodified copy must pass (rc $RC)"; sed 's/^/  | /' "$OUT" | head -20; }
# C2
grep -q 'could not render the fleet' "$OUT" \
  && bad "C2 an unmodified copy reported 'could not render the fleet'" || ok

# ---------------------------------------------------------------------------
echo "lanes-registry.bh-2205-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
