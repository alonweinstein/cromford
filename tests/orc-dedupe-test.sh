#!/usr/bin/env bash
# orc_dedupe_seen: first sighting passes, a copy inside the window is a duplicate,
# a different key passes, and the same key after the window passes again.
set -euo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/../bin/lib/orc-dedupe.sh"
S="$T/seen.txt"; fail=0
orc_dedupe_seen "$S" k1 120 && { echo "FAIL: first sighting reported as duplicate"; fail=1; }
orc_dedupe_seen "$S" k1 120 || { echo "FAIL: second copy not caught"; fail=1; }
orc_dedupe_seen "$S" k2 120 && { echo "FAIL: different key reported as duplicate"; fail=1; }
# age the k1 entry past the window
sed -i "s/^[0-9]* k1$/$(( $(date +%s) - 200 )) k1/" "$S"
orc_dedupe_seen "$S" k1 120 && { echo "FAIL: expired key still a duplicate"; fail=1; }
# two copies in the same instant: exactly one passes
n=0; for i in 1 2 3 4; do ( orc_dedupe_seen "$S" race 120 || echo pass ) & done | grep -c pass > "$T/n" ; wait; n=$(cat "$T/n")
[ "$n" = 1 ] || { echo "FAIL: $n of 4 simultaneous copies passed (want 1)"; fail=1; }
rm -rf "$T"; [ $fail = 0 ] && echo "orc-dedupe-test OK"; exit $fail
