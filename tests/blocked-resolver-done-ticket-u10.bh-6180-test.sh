#!/bin/bash
# tests/blocked-resolver-done-ticket-u10.bh-6180-test.sh — BH-6180. Case U10 of
# tests/blocked-resolver-done-ticket.bh-4438-test.sh counted every tmp.* file in
# the shared TMPDIR, so a suite running in parallel made it fail (6 parallel runs
# failed 3 of 6 on 2026-10-12). This suite runs Section U of that suite (cut at
# the U10 assert) in a scratch repo while a noise loop makes tmp.* files in the
# shared TMPDIR, and proves U10 still catches a real leak.
# Run from anywhere: tests/blocked-resolver-done-ticket-u10.bh-6180-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "blocked-resolver-done-ticket-u10.bh-6180-test: SKIPPED — jq is required"; exit 0; }
SUITE=tests/blocked-resolver-done-ticket.bh-4438-test.sh

# mk_repo <dest> — the files Section U reads, and the suite cut after the U10 assert.
mk_repo() {
  scratch_install_closure bin/blocked-resolver.sh "$1" >/dev/null || return 1
  scratch_install_closure tests/lib/scratch.sh "$1" >/dev/null || return 1
  mkdir -p "$1/tests"
  awk '{print} /bad "U10:/{exit}' "$DIR/$SUITE" > "$1/$SUITE"
  printf '%s\n' 'echo "RESULT: $PASS passed, $FAIL failed"' '[ "$FAIL" -eq 0 ]' >> "$1/$SUITE"
}
R="$T/repo"; mk_repo "$R" || { bad "C0: could not build the scratch repo"; exit 1; }
grep -q 'bad "U10:' "$R/$SUITE" && ! grep -q '^RH=' "$R/$SUITE" \
  && ok || bad "C0: the cut suite must end at the U10 assert"

# Noise: tmp.* files in the shared TMPDIR, as a parallel suite makes them.
SH="$T/shared"; mkdir -p "$SH"
noise_start() { rm -f "$T/stop"; ( while [ ! -e "$T/stop" ]; do mktemp "$SH/tmp.XXXXXXXX" >/dev/null; done ) & NOISE=$!; }
noise_stop()  { : > "$T/stop"; wait "$NOISE" 2>/dev/null; }
run_cut() { TMPDIR="$SH" bash "$1/$SUITE" > "$2" 2>&1; }

# C1: U10 under noise in the shared TMPDIR is green.
noise_start; run_cut "$R" "$T/c1.out"; RC=$?; noise_stop
[ "$RC" = 0 ] && ! grep -q 'FAIL: U10' "$T/c1.out" && grep -q 'RESULT: ' "$T/c1.out" \
  && ok || bad "C1: U10 under noise should pass, rc $RC: $(grep FAIL "$T/c1.out" | head -3)"

# C2: 6 parallel runs under noise: 6 of 6 green.
noise_start
PIDS=""
for i in 1 2 3 4 5 6; do run_cut "$R" "$T/c2.$i.out" & PIDS="$PIDS $!"; done
GREEN=0; for p in $PIDS; do wait "$p" && GREEN=$((GREEN+1)); done
noise_stop
[ "$GREEN" = 6 ] && ok || bad "C2: 6 parallel runs under noise should be 6 of 6 green, got $GREEN"

# C3: U10 still catches a real leak — br_board_status with its rm removed.
M="$T/mut"; mk_repo "$M" || { bad "C3: could not build the scratch repo"; exit 1; }
sed -i.bak 's/; rm -f "\$bodyf"$//' "$M/bin/blocked-resolver.sh"; rm -f "$M/bin/blocked-resolver.sh.bak"
if grep -q 'rm -f "\$bodyf"' "$M/bin/blocked-resolver.sh"; then
  bad "C3: the mutation did not apply"
else
  run_cut "$M" "$T/c3.out"
  grep -q 'FAIL: U10' "$T/c3.out" && ok || bad "C3: U10 should fail when br_board_status leaks its temp file"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
