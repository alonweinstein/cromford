#!/bin/bash
# tests/nightly-strict-ratchets-test.sh — the nightly STRICT ratchet pass
# (bin/nightly-strict-ratchets.sh, 2026-09-28).
#
# Diff-based ratchets never see drift that arrived without a diff (a direct
# push, a batch that did not select the ratchet). The nightly run checks them
# in strict mode. Against fake suites in a scratch tree:
#   S1  a listed suite whose tree has no strict mode yet is SKIPPED with a
#       notice, never run and never red (the gate until the ratchet PRs land)
#   S2  a strict suite is run with --strict AND RATCHET_MODE=strict; green is 0
#   S3  a real strict failure is rc 1, and the summary names the suite and line
#   S4  switch-ratchet's "tree BELOW the effective floor, add a .drop" R2 line
#       alone is a NOTE (rc 0): a legitimate conversion must not page nightly
#   S5  that note plus any other failure is still rc 1
#   S6  a list naming a suite that does not exist is rc 1 (a typo checks nothing)
# Run from anywhere: tests/nightly-strict-ratchets-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NSR="$DIR/bin/nightly-strict-ratchets.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

R="$T/root"; mkdir -p "$R/tests"
# A fake strict suite: records how it was called, then prints what $FAKE_OUT says.
mk() { # mk <name> <body-lines...>
  local f="$R/tests/$1"; shift
  { echo '#!/bin/bash'; echo '# strict mode: rd_mode "$@" (RATCHET_MODE=strict)'
    echo 'echo "$* RATCHET_MODE=${RATCHET_MODE:-}" >> "$CALLS"'; printf '%s\n' "$@"; } > "$f"
}
mk green-test.sh 'echo "green: 3 passed, 0 failed"'
mk red-test.sh 'echo "FAIL: A5 blocked-resolver names lane-alert.sh 23 times, pinned 19"' 'exit 1'
mk switch-ratchet.bh-2320-test.sh \
  'echo "FAIL: R2 tree at 37, effective floor 38 (FLOOR 102 less 64 dropped): add tests/switch-ratchet.d/<KEY>.drop holding 1 so one more reader fails R1; never edit FLOOR"' \
  '[ -n "${ALSO_R1:-}" ] && echo "FAIL: R1 40 bare reads over effective floor 38"' 'exit 1'
printf '#!/bin/bash\necho "$* old-shape" >> "$CALLS"\necho "FAIL: absolute count"\nexit 1\n' > "$R/tests/old-shape-test.sh"

run() { # run <list-lines...>
  printf '%s\n' "$@" > "$T/list.txt"; : > "$T/calls"
  OUT=$(CALLS="$T/calls" NSR_ROOT="$R" bash "$NSR" --list "$T/list.txt" --summary "$T/sum.md" 2>&1); RC=$?
  SUM=$(cat "$T/sum.md" 2>/dev/null)
}

run "tests/old-shape-test.sh  why"
{ [ "$RC" = 0 ] && has "SKIP tests/old-shape-test.sh" "$OUT" && ! grep -q old-shape "$T/calls"; } && ok \
  || bad "S1: a suite with no strict mode must be skipped, not run (rc=$RC): $OUT"

run "tests/green-test.sh  why"
[ "$RC" = 0 ] && ok || bad "S2: a green strict suite is rc 0 (rc=$RC): $OUT"
grep -q -- '--strict RATCHET_MODE=strict' "$T/calls" && ok || bad "S2: the suite must get --strict and RATCHET_MODE=strict: $(cat "$T/calls")"

run "tests/green-test.sh  why" "tests/red-test.sh  why"
[ "$RC" = 1 ] && ok || bad "S3: a strict failure is rc 1 (rc=$RC): $OUT"
{ has "tests/red-test.sh" "$SUM" && has "A5 blocked-resolver" "$SUM"; } && ok || bad "S3: the summary must name the suite and its FAIL line: $SUM"
has "tests/green-test.sh" "$SUM" && bad "S3: a green suite is not in the summary: $SUM" || ok

run "tests/switch-ratchet.bh-2320-test.sh  why"
[ "$RC" = 0 ] && ok || bad "S4: below-floor R2 alone is a note, never a page (rc=$RC): $OUT"
has "NOTE" "$OUT" && has ".drop" "$OUT" && ok || bad "S4: the note must say to add a .drop file: $OUT"
[ -z "$SUM" ] && ok || bad "S4: a note files nothing: $SUM"

printf '%s\n' "tests/switch-ratchet.bh-2320-test.sh  why" > "$T/list.txt"; : > "$T/calls"
OUT=$(ALSO_R1=1 CALLS="$T/calls" NSR_ROOT="$R" bash "$NSR" --list "$T/list.txt" --summary "$T/sum.md" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "S5: the note plus a real R1 failure is rc 1 (rc=$RC): $OUT"
grep -q "R1 40 bare reads" "$T/sum.md" && ok || bad "S5: the summary must carry the real failure: $(cat "$T/sum.md")"

run "tests/no-such-test.sh  typo"
[ "$RC" = 1 ] && ok || bad "S6: a listed suite that does not exist is rc 1 (rc=$RC): $OUT"

# The shipped list names suites that exist.
while read -r s _; do
  case "$s" in ''|'#'*) continue ;; esac
  [ -f "$DIR/$s" ] && ok || bad "the shipped catalog/nightly-strict.txt names $s, which does not exist"
done < "$DIR/catalog/nightly-strict.txt"

echo "nightly-strict-ratchets-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
