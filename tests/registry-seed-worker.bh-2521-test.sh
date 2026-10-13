#!/bin/bash
# tests/registry-seed-worker.bh-2521-test.sh — the worker side of the console
# registry-seed apply (BH-2521.2, BH-2676).
#
# WHY A SHELL SUITE AS WELL. The routes are proved by node --test in
# worker/jobs/test/registry-seed-apply.bh-2521.test.js (real worker.fetch over
# real SQLite). What this file adds is the part the impact lane and the orphan
# ratchet can SEE: it names the new source by path, drives its pure half, and
# runs that node suite.
#
#   1. lib/seed-apply.js, DRIVEN: the four exports, the fallback numbers the
#      CLI gate uses, a fingerprint that ignores order, a gate that refuses a
#      stale box and passes a fresh one.
#   2. the node suite, run for real when node is present.
# Run from anywhere: tests/registry-seed-worker.bh-2521-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/worker/jobs/src/lib/seed-apply.js"
[ -f "$LIB" ] && ok || bad "missing $LIB"

command -v node >/dev/null 2>&1 || { echo "registry-seed-worker: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { planFingerprint, fleetGateVerdict, SEED_GATE_TICK_WINDOW_S, SEED_GATE_MAX_AGE_S } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
eq('window', SEED_GATE_TICK_WINDOW_S, 86400);
eq('max-age', SEED_GATE_MAX_AGE_S, 7200);
const a = await planFingerprint({ insert: ['b', 'a'], update: [], prune: ['z', 'y'] });
const b = await planFingerprint({ insert: ['a', 'b'], update: [], prune: ['y', 'z'] });
eq('fp-hex', /^[0-9a-f]{64}\$/.test(a), true);
eq('fp-order', a === b, true);
const nowS = 1800000000, at = (s) => new Date((nowS - s) * 1000).toISOString();
eq('gate-stale', fleetGateVerdict({ ticks: ['x'], boxes: [{ box: 'x', harness_commit: 'c', harness_reported_at: at(7201) }], nowS, maxAgeS: 7200 }).ok, false);
eq('gate-fresh', fleetGateVerdict({ ticks: ['x'], boxes: [{ box: 'x', harness_commit: 'c', harness_reported_at: at(60) }], nowS, maxAgeS: 7200 }), { ok: true, bad: [] });
eq('gate-none', fleetGateVerdict({ ticks: [], boxes: [], nowS, maxAgeS: 7200 }).ok, false);
" 2>&1)
rc=$?
[ "$rc" = 0 ] && ok || bad "seed-apply.js did not import/run (rc=$rc): $OUT"
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "seed-apply.js: ${line#no }" ;;
  esac
done <<< "$OUT"
[ "$(grep -c '^ok ' <<< "$OUT")" = 7 ] && ok || bad "expected 7 driven checks, got: $OUT"

# --- 2: the node suite ------------------------------------------------------
if ! "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1; then
  # worker/jobs imports the git-ignored catalog/lanes.json statically, so it is
  # rendered first, as tests/product-proposals-route.bh-2718-test.sh does (BH-1247).
  bad "catalog/lanes.json could not be composed from catalog/lanes.d"
elif (cd "$DIR/worker/jobs" && node --test test/registry-seed-apply.bh-2521.test.js >/tmp/registry-seed-worker.$$.out 2>&1); then
  ok
else
  bad "node --test test/registry-seed-apply.bh-2521.test.js failed:"; cat /tmp/registry-seed-worker.$$.out
fi
rm -f /tmp/registry-seed-worker.$$.out

echo "registry-seed-worker: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
