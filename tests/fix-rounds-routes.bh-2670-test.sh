#!/bin/bash
# tests/fix-rounds-routes.bh-2670-test.sh — the harness-jobs fix-round job
# routes /api/fix-rounds{,/claim,/finish,/adopt} (BH-2670, slice BH-2530.1).
#
# WHY A SHELL SUITE AS WELL. The routes' behaviour is proved by node --test in
# worker/jobs/test/fix-rounds-routes.bh-2670.test.js (real worker.fetch over
# the real schema.sql in node:sqlite, with real write races). What this file
# adds is what the impact lane and the orphan ratchet can SEE:
#   1. it names the route module by path, and the module is registered at the
#      end of ROUTES in worker/jobs/src/index.js;
#   2. no line of the module builds SQL from a template literal: every filter,
#      LIMIT and CAS operand is a bind;
#   3. it runs the node suite for real when node >= 22 (node:sqlite) is here.
# Run from anywhere: tests/fix-rounds-routes.bh-2670-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

ROUTE="$DIR/worker/jobs/src/routes/fix-rounds.js"
INDEX="$DIR/worker/jobs/src/index.js"
NODE_TEST="$DIR/worker/jobs/test/fix-rounds-routes.bh-2670.test.js"

# --- 1: the module exists and is registered ---------------------------------
if [ -f "$ROUTE" ]; then ok; else bad "missing $ROUTE"; fi
grep -q '^import { routes as fixRounds } from "./routes/fix-rounds.js";$' "$INDEX" && ok \
  || bad "index.js does not import the fix-rounds routes"
grep -q '^  \.\.\.fixRounds,$' "$INDEX" && ok || bad "index.js ROUTES does not spread fixRounds"

# --- 2: no template-literal SQL ---------------------------------------------
# A missing file must fail here too, not pass as "no hits" (D3).
if [ -f "$ROUTE" ]; then
  HITS=$(grep -nE '(SELECT|INSERT|UPDATE|DELETE|LIMIT|WHERE).*\$\{|\$\{.*(SELECT|INSERT|UPDATE|DELETE|LIMIT|WHERE)' "$ROUTE")
  [ -z "$HITS" ] && ok || bad "template-literal SQL in the route: $HITS"
  grep -q 'LIMIT ?5' "$ROUTE" && ok || bad "the list LIMIT is not a bind"
else
  bad "no route module to scan for template-literal SQL"
fi

# --- 3: the node suite --------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "fix-rounds-routes: node suite SKIPPED — node is not installed on this box"
elif [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
  echo "fix-rounds-routes: node suite SKIPPED — node < 22 has no node:sqlite"
elif ! "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1; then
  # worker/jobs imports the git-ignored catalog/lanes.json statically, so it is
  # rendered first, as tests/jobs-worker-test.sh does (BH-1247).
  bad "catalog/lanes.json could not be composed from catalog/lanes.d"
else
  OUT=$(cd "$DIR/worker/jobs" && node --test "$NODE_TEST" 2>&1); RC=$?
  if [ "$RC" -eq 0 ]; then ok; else bad "node suite rc=$RC"; printf '%s\n' "$OUT" | grep -E '^not ok|error:' | head -20; fi
fi

echo "fix-rounds-routes: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
