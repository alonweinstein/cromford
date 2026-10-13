#!/bin/bash
# tests/cost-breaker-followups.bh-2397-test.sh — the COST BREAKER card's
# follow-ups from the #2382 review (BH-2397 items 1-3).
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by three node suites; this
# file is the part the impact lane and the orphan ratchet can SEE. It names the
# four changed sources by path, drives the card's pure half for real, and runs
# the node suites when their dependencies are there.
#
#   1. console-ui/src/lib/cost-breaker.js, DRIVEN: CAP HIT follows
#      refused_since_reset (falling back to refused for a worker without the
#      field); the hub-published cost.autohalt.effective row wins over the
#      settings row, and a malformed one is UNKNOWN (null), never ON.
#   2. the node suites, run for real:
#        console-ui/tests/cost-breaker.bh-2397.test.js   (lib + CostBreaker.js render)
#        console-ui/tests/coord-reset-reason.bh-2397.test.js (functions/api/coord/[[path]].js:
#          a blank RESET reason is a 400 with no upstream call)
#        worker/jobs/test/call-guard-reset.bh-2397.test.js (worker/jobs/src/routes/call-guard.js:
#          the GET roll-up's refused_since_reset / reset_at)
#      The console pair needs console-ui/node_modules; without it they say so and
#      skip (the console-ui CI job runs them). The worker suite needs the
#      rendered catalog/lanes.json and skips, saying so, without it.
# The hub publisher in bin/pipeline-health.sh is tests/cost-autohalt-publish.bh-2397-test.sh.
# Run from anywhere: tests/cost-breaker-followups.bh-2397-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/cost-breaker.js"
SCREEN="$DIR/console-ui/src/screens/CostBreaker.js"
PROXY="$DIR/console-ui/functions/api/coord/[[path]].js"
ROUTE="$DIR/worker/jobs/src/routes/call-guard.js"

for f in "$LIB" "$SCREEN" "$PROXY" "$ROUTE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "cost-breaker-followups: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { autohaltState, callGuardRows, AUTOHALT_EFFECTIVE_KEY, AUTOHALT_KEY } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

eq('hub-key', AUTOHALT_EFFECTIVE_KEY, 'cost.autohalt.effective');
const g = callGuardRows({ rows: [
  { project: 'p', stage: 's', fp: 'reset',  refused: 3, refused_since_reset: 0, reset_at: 't1' },
  { project: 'p', stage: 's', fp: 'again',  refused: 3, refused_since_reset: '1', reset_at: 't1' },
  { project: 'p', stage: 's', fp: 'oldwkr', refused: 2 },
  { project: 'p', stage: 's', fp: 'clean',  refused: 0, refused_since_reset: 0 } ] });
eq('cap-since-reset', g.rows.map((r) => r.capHit), [false, true, true, false]);
eq('reset-at',        g.rows.map((r) => r.resetAt), ['t1', 't1', null, null]);
eq('refused-total',   g.rows.map((r) => r.refused), [3, 3, 2, 0]);

const hub = (v) => ({ settings: [{ key: AUTOHALT_KEY, value: '1' }, { key: AUTOHALT_EFFECTIVE_KEY, value: v, updated_at: 'u' }] });
const s = autohaltState(hub('off flag-file'));
eq('hub-off',       [s.on, s.source, s.why, s.asOf], [false, 'hub', 'flag-file', 'u']);
eq('hub-on',        autohaltState(hub('on env')).on, true);
eq('hub-malformed', [autohaltState(hub('sideways')).on, autohaltState(hub('on')).on], [null, null]);
eq('no-hub',        autohaltState({ settings: [{ key: AUTOHALT_KEY, value: '0' }] }).source, 'settings');
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the node suites, driven -------------------------------------------------
# The worker imports the RENDERED catalog/lanes.json by a static path; it is
# git-ignored, so a fresh checkout has none (the worker CI job renders it first).
if [ ! -f "$DIR/catalog/lanes.json" ]; then
  echo "cost-breaker-followups: worker node suite SKIPPED — catalog/lanes.json is not rendered (bin/lanes-build.sh --write; the worker/jobs CI job runs it)"
elif NOUT=$(cd "$DIR/worker/jobs" && node --test test/call-guard-reset.bh-2397.test.js 2>&1); then ok
else bad "worker/jobs/test/call-guard-reset.bh-2397.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "cost-breaker-followups: console node suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
else
  for s in tests/cost-breaker.bh-2397.test.js tests/coord-reset-reason.bh-2397.test.js; do
    if NOUT=$(cd "$DIR/console-ui" && node --test "$s" 2>&1); then ok
    else bad "console-ui/$s failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
    fi
  done
fi

echo "cost-breaker-followups: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
