#!/bin/bash
# tests/prompt-reap-relaunch.bh-1770-test.sh — the results sweep closes a
# reaped run out and does NOT relaunch it; bin/blocked-resolver.sh does
# (BH-1770 part B2; the operator's decision 2026-09-24: "Never the sweep").
#
# Every sweep SOP that carries the `ABANDONED_TIMEOUT` close-out rule must say
# both halves in that rule: no relaunch from the sweep, and who owns it. A rule
# that only says "post a comment" leaves an agent reading "we stopped the run"
# free to start it again, which is a second launcher racing the resolver's
# capped ladder.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prompt-reap-relaunch.bh-1770-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SOPS=$(grep -al 'ABANDONED_TIMEOUT' "$DIR"/prompts/*.md)
[ "$(grep -c . <<<"$SOPS")" -ge 13 ] && ok \
  || bad "expected at least 13 SOPs carrying the ABANDONED_TIMEOUT rule, found $(grep -c . <<<"$SOPS")"
for P in $SOPS; do
  N=$(basename "$P")
  # The rule is the text from its verdict word to the COMMENTED marker that
  # closes it.
  R=$(awk '{ s = s $0 "\n" } END {
        i = index(s, "`ABANDONED_TIMEOUT <why>`"); if (i == 0) exit
        r = substr(s, i); m = "Then `touch <dir>/COMMENTED`."; j = index(r, m)
        if (j == 0) exit
        print substr(r, 1, j + length(m) - 1) }' "$P")
  [ -n "$R" ] || { bad "$N: the ABANDONED_TIMEOUT rule could not be read"; continue; }
  grep -q 'do NOT relaunch' <<<"$R" && ok || bad "$N: the ABANDONED_TIMEOUT rule must forbid the sweep relaunching the run"
  grep -q 'bin/blocked-resolver.sh' <<<"$R" && ok || bad "$N: the ABANDONED_TIMEOUT rule must name bin/blocked-resolver.sh as the relaunch owner"
done

echo "prompt-reap-relaunch.bh-1770: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
