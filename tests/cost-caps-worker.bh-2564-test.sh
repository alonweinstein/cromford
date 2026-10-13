#!/bin/bash
# tests/cost-caps-worker.bh-2564-test.sh — the worker half of the cost-caps
# editor (BH-2564, BH-2511 W1-W3) as the impact lane and the orphan ratchet can
# SEE it.
#
#   F. the new validator lib and the filled route file exist, named here by
#      rooted path.
#   N. the node suite that owns the behaviour: key shapes, value grammar, the
#      three routes, the generic PUT audit and the registry seed's conf.* skip.
# Run from anywhere: tests/cost-caps-worker.bh-2564-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/worker/jobs/src/lib/cost-caps.js"
ROUTES="$DIR/worker/jobs/src/routes/cost-caps.js"
SUITE="$DIR/worker/jobs/test/cost-caps.bh-2564.test.js"

# --- F: the files ------------------------------------------------------------
for f in "$LIB" "$ROUTES" "$SUITE"; do
  [ -f "$f" ] && ok || bad "F: missing $f"
done

command -v node >/dev/null 2>&1 || { echo "cost-caps-worker: SKIPPED the node suite — node is not installed on this box"; echo "cost-caps-worker: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]; exit; }

# --- N: the node suite --------------------------------------------------------
# core.js imports the GENERATED, git-ignored catalog/lanes.json statically, so
# it is rendered into the checkout first (the cost-caps-contract.bh-2563 way).
if [ -x "$DIR/bin/lanes-build.sh" ] && [ -d "$DIR/catalog/lanes.d" ]; then
  "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 \
    || { echo "FAIL: cost-caps-worker: catalog/lanes.json could not be composed from catalog/lanes.d — worker/jobs imports it statically"; exit 1; }
fi
if OUT=$(node --test "$SUITE" 2>&1); then ok
else bad "N: $SUITE failed"; printf '%s\n' "$OUT" | grep -E '^not ok|^# (pass|fail)|AssertionError|Error' | head -40; fi

echo "cost-caps-worker: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
