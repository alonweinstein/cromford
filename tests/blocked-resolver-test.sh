#!/bin/bash
# tests/blocked-resolver-test.sh — a RUNNER, for one release (BH-1196).
#
# WHAT HAPPENED TO THE SUITE. This file was a 2,342-line monolith: 18 numbered
# sections, 455 assertions, one scratch fixture shared by all of them. It and
# bin/blocked-resolver.sh were two of the five files that produced 40 of one
# day's 53 merge conflicts — two builds touching two unrelated concerns
# conflicted in one file neither ticket was about. So the sections moved, whole
# and verbatim, into one suite per concern, named for the bin/lib/br/ module
# that owns it where there is one:
#
#   tests/br-ladder-test.sh           1.                the classifier
#   tests/br-rebuild-test.sh          2, 2b-2e, 3, 6    rebuild fresh and its edges
#   tests/br-reads-test.sh            6b, 6c            key derivation, RED_TWICE rows
#   tests/br-neighbors-test.sh        4, 5, 7           the contract with the scripts around it
#   tests/br-rungs-test.sh            8, 8f             the ladder, driven end to end
#   tests/br-contested-test.sh        9, 10             contested holds, the two ladder shapes
#   tests/br-rebuild-outcome-test.sh  11 (was a 2nd 9)  what the rebuild came back with
#
# The partition is asserted, not asserted-to: tests/br-suite-partition.bh-1196-test.sh
# re-counts every section's assertion openers against tests/br/expected-sections.tsv,
# which was generated from this file BEFORE a line moved.
#
# WHY THE NAME SURVIVES. Seven verification-map entries, three dated notes and
# docs/MERGE-CONDUCTOR.md name this path. Rather than edit all of them in the
# same diff that moves 2,300 lines, the file keeps its name, its summary line
# and its exit code for one release: it runs every suite the manifest names,
# sums their counts, and fails if any child failed OR printed no summary at all
# (a child that dies before it can count must never read as zero failures).
# Removing it, and repointing what names it, is a follow-up ticket — not filed
# at the time of writing.
#
# It owns no scratch tree of its own (no mktemp, no rm, no trap, no cd): each
# child sources tests/lib/scratch.sh and owns its own. The environment passes
# straight through, so HARNESS_TEST_SANDBOX=1 reaches all seven.
# Run from anywhere: tests/blocked-resolver-test.sh   (exit 0 = all pass)
#                    tests/blocked-resolver-test.sh --list   (the suites it runs)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
MANIFEST="$DIR/tests/br/expected-sections.tsv"

suites() { grep -v '^#' "$MANIFEST" | grep -v '^[[:space:]]*$' | cut -f1 | sort -u; }

# A manifest that is not there would make --list print nothing and the run
# report zero failures over zero suites. Both are silent passes; refuse instead.
[ -s "$MANIFEST" ] || { echo "blocked-resolver-test: no manifest at $MANIFEST — refusing to report a pass" >&2; exit 2; }

if [ "${1:-}" = "--list" ]; then suites; exit 0; fi

command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PASS=0; FAIL=0; RC=0
while IFS= read -r s; do
  OUT=$(bash "$DIR/$s"); CRC=$?
  [ -n "$OUT" ] && printf '%s\n' "$OUT"
  SUM=$(printf '%s\n' "$OUT" | grep -E '^.*: [0-9]+ passed, [0-9]+ failed$' | tail -1)
  if [ -z "$SUM" ]; then
    # D9: no summary is a failure, never a zero.
    echo "blocked-resolver-test: $s printed no summary line (rc $CRC)"
    FAIL=$((FAIL+1)); RC=1; continue
  fi
  PASS=$((PASS + $(printf '%s\n' "$SUM" | awk '{print $(NF-3)}')))
  FAIL=$((FAIL + $(printf '%s\n' "$SUM" | awk '{print $(NF-1)}')))
  [ "$CRC" -eq 0 ] || RC=1
done < <(suites)

echo "blocked-resolver-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && [ "$RC" -eq 0 ]
