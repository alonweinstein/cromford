#!/bin/bash
# tests/projects-control.bh-4082-test.sh — the console Projects form (BH-4082,
# slice C0 of BH-3979.8) as the impact lane and the orphan ratchet can SEE it.
#
#   F. the new worker route file and its suites exist, named here by rooted path.
#   N. the worker node suite (projects table, audited PUT, validation, no DELETE),
#      driven through worker.fetch on a real schema.sql database.
#   C. the two console node suites (coord proxy allowlist row, the projects
#      control kind rendered by the real Controls screen), run when
#      console-ui's dependencies are installed.
# Run from anywhere: tests/projects-control.bh-4082-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

ROUTES="$DIR/worker/jobs/src/routes/projects.js"
SUITE="$DIR/worker/jobs/test/routes/projects.bh-4082.test.js"
PROXY_SUITE="$DIR/console-ui/tests/coord-projects-allowlist.bh-4082.test.js"
VIEW_SUITE="$DIR/console-ui/tests/controls-projects.bh-4082.test.js"

# --- F: the files ------------------------------------------------------------
for f in "$ROUTES" "$SUITE" "$PROXY_SUITE" "$VIEW_SUITE"; do
  [ -f "$f" ] && ok || bad "F: missing $f"
done

command -v node >/dev/null 2>&1 || { echo "projects-control: SKIPPED the node suites — node is not installed on this box"; echo "projects-control: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]; exit; }

# --- N: the worker suite ------------------------------------------------------
# core.js imports the GENERATED, git-ignored catalog/lanes.json statically, so
# it is rendered into the checkout first (the cost-caps-worker.bh-2564 way).
if [ -x "$DIR/bin/lanes-build.sh" ] && [ -d "$DIR/catalog/lanes.d" ]; then
  "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 \
    || { echo "FAIL: projects-control: catalog/lanes.json could not be composed from catalog/lanes.d — worker/jobs imports it statically"; exit 1; }
fi
if OUT=$(node --test "$SUITE" 2>&1); then ok
else bad "N: $SUITE failed"; printf '%s\n' "$OUT" | grep -E '^not ok|^# (pass|fail)|AssertionError|Error' | head -40; fi

# --- C: the console suites ------------------------------------------------------
if [ -d "$DIR/console-ui/node_modules/preact" ]; then
  if OUT=$(cd "$DIR/console-ui" && node --test "$PROXY_SUITE" "$VIEW_SUITE" 2>&1); then ok
  else bad "C: console suites failed"; printf '%s\n' "$OUT" | grep -E '^not ok|^# (pass|fail)|AssertionError|Error' | head -40; fi
else
  echo "projects-control: SKIPPED the console suites — console-ui/node_modules is not installed (npm ci in console-ui)"
fi

echo "projects-control: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
