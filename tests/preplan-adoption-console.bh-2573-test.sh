#!/bin/bash
# tests/preplan-adoption-console.bh-2573-test.sh — the console PREPLAN ADOPTION
# section on /p/<project> (BH-2573, slice BH-2543.2).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/preplan-adoption.bh-2573.test.js (reached through the
# console-ui job). This file names the two new sources by path for the impact
# lane and the orphan ratchet, drives the pure half for real, and holds the
# screen to the rules a reviewer would otherwise check by eye
# (the cost-breaker-console.bh-2331 pattern).
#
#   1. lib/preplan-adoption.js, DRIVEN: no rate is a dash (never 0%), the
#      cadence rule fires at 4/12 and not at 9/0 or 5/10, an unreadable answer
#      is an error (never empty), and the knobs resolve project row first.
#   2. PreplanAdoption.js sorts through the shared SortableTable, uses the
#      shared Skeleton/Empty/ErrorBox, is mounted on the Project page, and never
#      calls a native dialog.
#   3. the node suite console-ui/tests/preplan-adoption.bh-2573.test.js, run for
#      real when the console-ui dependencies are installed.
# Run from anywhere: tests/preplan-adoption-console.bh-2573-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/preplan-adoption.js"
SCREEN="$DIR/console-ui/src/screens/PreplanAdoption.js"
PROJECT="$DIR/console-ui/src/screens/Project.js"

for f in "$LIB" "$SCREEN" "$PROJECT"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "preplan-adoption-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { rateLabel, underFloor, adoptionState, adoptKnobs, dayBars } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

eq('rate-null',      rateLabel(null), '—');
eq('rate-zero',      rateLabel(0), '0%');
eq('rate-third',     rateLabel(1 / 3), '33%');
eq('floor-thin',     underFloor({ bought: 9, adopted: 0 }, 50, 10), false);
eq('floor-at',       underFloor({ bought: 10, adopted: 5 }, 50, 10), false);
eq('floor-under',    underFloor({ bought: 12, adopted: 4 }, 50, 10), true);
eq('floor-zero',     underFloor({ bought: 12, adopted: 0 }, 0, 10), false);
eq('floor-absent',   underFloor({}, 50, 10), false);
eq('state-odd',      adoptionState({ data: {} }, 'p').kind, 'error');
eq('state-failed',   adoptionState({ error: new Error('http_404') }, 'p').kind, 'error');
eq('state-empty',    adoptionState({ data: { projects: [], days: [], recent: [] } }, 'p').kind, 'empty');
eq('knob-project',   adoptKnobs({ settings: [
  { key: 'lane.preplan-tick.preplan_adopt_floor_pct', value: '30' },
  { key: 'lane.preplan-tick.p.preplan_adopt_floor_pct', value: '70' } ] }, 'p').floorPct, 70);
eq('knob-unread',    adoptKnobs({}, 'p').unreadable, true);
eq('bars-gap',       dayBars([{ day: '2026-09-01', rate: 0.5 }, { day: '2026-09-02', rate: null }],
  { width: 100, height: 10 }).map((b) => b.gap), [false, true]);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape --------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "PreplanAdoption.js must use the shared SortableTable"
grep -q "Skeleton, Empty, ErrorBox } from '../ui/primitives.js'" "$SCREEN" && ok || bad "PreplanAdoption.js must use the shared Skeleton/Empty/ErrorBox"
grep -q '<\${Link} to=\${`/jobs/' "$SCREEN" && ok || bad "PreplanAdoption.js must link rows to /jobs/<job_id> (no dead rows)"
grep -q '<\${PreplanAdoption} project=\${project}/>' "$PROJECT" && ok || bad "Project.js must mount the PREPLAN ADOPTION section"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the PREPLAN ADOPTION screen"
else
  ok
fi

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "preplan-adoption-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/preplan-adoption.bh-2573.test.js 2>&1); then ok
  else bad "console-ui/tests/preplan-adoption.bh-2573.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "preplan-adoption-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
