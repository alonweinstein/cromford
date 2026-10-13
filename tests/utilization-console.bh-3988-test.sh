#!/bin/bash
# tests/utilization-console.bh-3988-test.sh — the console utilization screen at
# /utilization (BH-4011, slice 4 of BH-3988).
#
# The screen's behaviour is proved by node --test in
# console-ui/tests/utilization.bh-3988.test.js. This file is the part the impact
# lane and the orphan ratchet can SEE (the ci-health-console.bh-2634 pattern):
# it names the two new sources by path, drives the pure half with node, and
# holds the screen to the rules a reviewer would otherwise check by eye.
#
#   1. lib/utilization.js, DRIVEN: one row per fleet project, a project with no
#      snapshot is `no snapshot`, as_of over 2h is stale, an unread bucket is
#      `—` and never 0, a body without rows[] is null (an error, not empty).
#   2. /utilization is routed and in the nav right after /ci, the screen polls
#      every 60 s through the shared SortableTable, neither file calls a native
#      dialog, and no new Pages Function was added (the coord proxy forwards GET).
#   3. the node suite, run for real when the console-ui dependencies are installed.
# Run from anywhere: tests/utilization-console.bh-3988-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/utilization.js"
SCREEN="$DIR/console-ui/src/screens/Utilization.js"
APP="$DIR/console-ui/src/app.js"

for f in "$LIB" "$SCREEN" "$APP"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "utilization-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { utilizationRows, cellText } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const now = Date.parse('2026-10-03T12:00:00Z');
const at = (min) => new Date(now - min * 60000).toISOString();
const snap = (project, min) => ({ project, verdict: 'unknown', as_of: at(min),
  payload: { builds: { running: 1, pool_cap: 3, free_slots: 2 }, basis: { builds: 'measured' } } });
const out = utilizationRows({ rows: [snap('a', 10), snap('c', 121)] }, ['a', 'b', 'c'], now);
const by = Object.fromEntries(out.rows.map((r) => [r.project, r]));
eq('one-row-per-fleet', out.rows.map((r) => r.project), ['a', 'b', 'c']);
eq('no-snapshot',       by.b.verdict, 'no snapshot');
eq('stale',             [by.a.stale, by.c.stale], [false, true]);
eq('builds',            [by.a.running, by.a.cap, by.a.free], [1, 3, 2]);
eq('unshipped-dash',    [by.a.ready, by.a.prReview].map(cellText), ['—', '—']);
eq('zero-stays-zero',   cellText(0), '0');
eq('no-rows-is-null',   utilizationRows({}, ['a'], now), null);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape --------------------------------------------------
grep -q "\['/utilization', UtilizationScreen\]" "$APP" && ok || bad "app.js must route /utilization to UtilizationScreen"
NAVL=$(grep -n "to: '/ci', label: 'CI'" "$APP" | cut -d: -f1)
UTILL=$(grep -n "to: '/utilization', label: 'UTIL'" "$APP" | cut -d: -f1)
if [ -n "$NAVL" ] && [ -n "$UTILL" ] && [ "$UTILL" -gt "$NAVL" ] && [ "$UTILL" -le $((NAVL + 2)) ]; then ok
else bad "app.js must put UTIL in the nav right after CI (ci=$NAVL util=$UTILL)"; fi
grep -q "intervalMs: 60000" "$SCREEN" && ok || bad "Utilization.js must poll every 60 s"
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "Utilization.js must use the shared SortableTable"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (^|[^A-Za-z_.])(window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the utilization screen"
else
  ok
fi
if compgen -G "$DIR/console-ui/functions/api/utilization*" >/dev/null; then
  bad "no new Pages Function: /api/coord/utilization rides the coord proxy"
else
  ok
fi

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "utilization-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/utilization.bh-3988.test.js 2>&1); then ok
  else bad "console-ui/tests/utilization.bh-3988.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "utilization-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
