#!/bin/bash
# tests/conflict-hotspots-fleet-order.bh-5921-test.sh — BH-5921: the
# conflict-hotspots fleet suite must not depend on test order, and a route
# failure must say why in the log.
#
# THE INCIDENT. Merge-queue batch #5917 (run 38056388608, Tests traced shard
# 3/8) failed on tests/conflict-hotspots-fleet.bh-5267-test.sh with only
# "FAIL: worker route suite: not ok 1 - test/conflict-hotspots-route.test.js".
# The suite ran the route test BEFORE it composed the generated, git-ignored
# catalog/lanes.json that worker/jobs core.js imports statically, so a shard
# whose earlier tests had not built that file failed the whole route file at
# import. The suite kept only the `not ok` lines, so the error never reached
# the CI log.
#
# Driven, not grepped: the REAL suite runs over a scratch copy of the checkout
# (the working tree, without .git, node_modules and catalog/lanes.json).
#   O1 catalog/lanes.json absent: the suite passes (it composes the file first).
#   O2 a route test that throws: the suite fails, and its output carries the
#      thrown message, not only `not ok`.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/conflict-hotspots-fleet-order.bh-5921-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
done_() { echo "conflict-hotspots-fleet-order.bh-5921: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "conflict-hotspots-fleet-order: SKIPPED, this node has no node:sqlite"; done_
fi
command -v git >/dev/null 2>&1 || { echo "FAIL: git is required"; exit 1; }

# copy_repo <dest> — the checkout as it is on disk, without .git, node_modules
# or the generated catalog/lanes.json (the state a fresh CI shard starts from).
# A tar of the directory, not a tree listing: this suite is not whole-tree.
copy_repo() {
  mkdir -p "$1" || return 1
  tar -C "$DIR" --exclude=./.git --exclude=node_modules --exclude=./catalog/lanes.json -cf - . 2>/dev/null \
    | tar -C "$1" -xf - || return 1
  git -C "$1" init -q 2>/dev/null; return 0
}

SUITE=tests/conflict-hotspots-fleet.bh-5267-test.sh

# ── O1: no catalog/lanes.json before the suite runs ──
R1="$T/r1"
copy_repo "$R1" || { bad "O1 could not copy the checkout"; done_; }
[ ! -e "$R1/catalog/lanes.json" ] && ok || bad "O1 the copy already has catalog/lanes.json"
OUT=$(HARNESS_TEST_SANDBOX=1 bash "$R1/$SUITE" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "O1 with catalog/lanes.json absent the suite failed (rc=$RC): $(printf '%s\n' "$OUT" | grep -E 'FAIL|passed' | head -5)"

# ── O2: a route test that throws shows its message ──
R2="$T/r2"
copy_repo "$R2" || { bad "O2 could not copy the checkout"; done_; }
cat > "$R2/worker/jobs/test/conflict-hotspots-route.test.js" <<'JS'
import test from 'node:test';
import assert from 'node:assert/strict';
test('forced failure (BH-5921)', () => { assert.equal('BH5921-FORCED-ACTUAL', 'BH5921-FORCED-EXPECTED'); });
JS
OUT=$(HARNESS_TEST_SANDBOX=1 bash "$R2/$SUITE" 2>&1); RC=$?
[ "$RC" != 0 ] && ok || bad "O2 a throwing route test must fail the suite"
grep -q 'BH5921-FORCED-EXPECTED' <<<"$OUT" && ok \
  || bad "O2 the suite output does not carry the assertion: $(printf '%s\n' "$OUT" | grep -E 'FAIL' | head -3)"

done_
