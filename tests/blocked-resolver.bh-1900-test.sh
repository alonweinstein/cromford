#!/bin/bash
# tests/blocked-resolver.bh-1900-test.sh — BH-1900 (BH-1816.3): an EMPTY stamp
# in bin/blocked-resolver.sh is unreadable, not "today".
#
#   THE PROPERTY UNDER TEST: GNU `date -u -d ""` exits 0 and prints today's
#   00:00:00Z, so `ep=$(date -u -d "$at" +%s) || continue` never skips a row
#   whose stamp is empty. In br_already_merged that made a merged PR with no
#   merge time read as newer than any park from before midnight, and the park
#   was resolved RESOLVED_MERGED on a stamp nobody wrote.
#
#   A  the date-empty-stamp lint (BH-1897) reports nothing in the resolver, and
#      the one waiver it carries has a reason.
#   B  the real br_already_merged, lifted out of the shipped script: an empty
#      `at` is skipped (B1), a real newer stamp still resolves (B2), and an
#      unparseable one is still skipped (B3).
#
# determinism: ok-file the stamps below are fixed fixture DATA; this suite reads
# no clock and rolls no dice.
# Run from anywhere: tests/blocked-resolver.bh-1900-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The lifted lib sources its modules and libs out of $HARNESS/bin, so the scratch
# harness carries a copy of the checkout's bin/ and nothing live is read.
H="$T/h"
mkdir -p "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env"
cp -r "$DIR/bin" "$H/" || exit 1
: > "$H/env/global.env"

# ── A. the lint pin ──────────────────────────────────────────────────────────
# HARNESS points at the scratch tree so a box-local flags/determinism-lint.conf
# cannot change the answer. The rc is read unpiped (D6).
OUT=$(HARNESS="$H" bash "$DIR/bin/test-determinism-lint.sh" "$DIR/bin/blocked-resolver.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "A0: the lint exited $RC on bin/blocked-resolver.sh: $OUT"
if grep -q 'date-empty-stamp' <<<"$OUT"; then
  bad "A1: bin/blocked-resolver.sh still has date-empty-stamp findings: $(grep 'date-empty-stamp' <<<"$OUT")"
else ok; fi
if grep -q 'waiver-no-reason' <<<"$OUT"; then
  bad "A2: a determinism waiver in bin/blocked-resolver.sh has no reason: $(grep 'waiver-no-reason' <<<"$OUT")"
else ok; fi

# ── B. br_already_merged, the real function ──────────────────────────────────
awk '/^DONE_KEYS=/{exit} {print}' "$DIR/bin/blocked-resolver.sh" > "$T/br-lib.sh"
[ -s "$T/br-lib.sh" ] && ok || bad "B0: could not lift the resolver's functions out of the script"

# merged <row> -> the function's stdout in $MOUT, its rc in $MRC. The park is at
# epoch 1000, so any real 2026 stamp is newer than it. Only the edges (state,
# search, resolve) are stubbed; the loop that reads the stamp is the shipped one.
merged() {
  MOUT=$(HARNESS="$H" FLEET_CONF="$H/fleet.conf" BRLIB="$T/br-lib.sh" ROW="$1" bash -c '
    L="$BRLIB"; set --; . "$L" >/dev/null 2>&1
    br_cap_key() { echo p-K-1; }
    br_load() { echo "{}"; }
    br_park_time() { echo 1000; }
    br_merged_prs_for() { printf "%s\n" "$ROW"; }
    br_resolve_ticket_merged() { echo "RESOLVED $5"; }
    say() { :; }
    br_already_merged p rk reason - - K-1 o/r' 2>/dev/null); MRC=$?
}

# B1. a merged PR row with no merge time is not this park's answer.
merged 'https://github.com/o/r/pull/9'
{ [ "$MRC" = 1 ] && [ -z "$MOUT" ]; } && ok \
  || bad "B1: an empty merge stamp was read as a real one (rc=$MRC out=$MOUT)"

# B2. control: a real stamp newer than the park still resolves.
merged $'https://github.com/o/r/pull/9\t2026-09-01T00:00:00Z\tticket/k-1'
{ [ "$MRC" = 0 ] && [ "$MOUT" = "RESOLVED https://github.com/o/r/pull/9" ]; } && ok \
  || bad "B2: a real merge newer than the park did not resolve (rc=$MRC out=$MOUT)"

# B3. an unparseable stamp is still skipped.
merged $'https://github.com/o/r/pull/9\tgarbage\tticket/k-1'
{ [ "$MRC" = 1 ] && [ -z "$MOUT" ]; } && ok \
  || bad "B3: an unparseable merge stamp was not skipped (rc=$MRC out=$MOUT)"

echo "blocked-resolver.bh-1900: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
