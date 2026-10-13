#!/bin/bash
# tests/standby-console.bh-2641-test.sh — the STANDBY panel on /hub
# (BH-2641 / BH-2519.3).
#
# The panel is proved by node --test in
# console-ui/tests/standby-panel.bh-2641.test.js. This file is the part the
# impact lane and the orphan ratchet can SEE (the restore-lab-console.bh-1946
# pattern): it names the new lib and panel by path, drives the lib for real,
# and holds the panel to the rules a reviewer would otherwise check by eye.
#
#   1. lib/standby.js, DRIVEN: heartbeat rows map to {box, ofHub, snapshot, ok,
#      reportedAt, reportAgeMin, streamAgeMin}; an unparseable stamp (including
#      the calendar-invalid 20261340T000000Z) is a null age, never 0; a missing
#      standbys array is [] only when role.standby is empty, otherwise the
#      standbys_missing marker.
#   2. Standby.js sorts through the shared SortableTable, wide, inside its own
#      overflow-x:auto wrapper, and never calls a native dialog.
#   3. When console-ui's node deps are installed, the node suite runs too.
# Run from anywhere: tests/standby-console.bh-2641-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/standby.js"
PANEL="$DIR/console-ui/src/screens/hub/Standby.js"

for f in "$LIB" "$PANEL"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "standby-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { standbyRows, snapshotAgeMin, reportAgeMin, STANDBY_CONTRACT_ERROR } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const NOW = Date.parse('2026-09-24T15:00:00Z');
const SB1 = { box: 'sb-1', of_hub: 'hub-1', snapshot: '20260924T140000Z', ok: 1, reported_at: '2026-09-24T14:58:00Z' };

eq('row',                standbyRows({ standbys: [SB1] }, NOW),
  [{ box: 'sb-1', ofHub: 'hub-1', snapshot: '20260924T140000Z', ok: true, reportedAt: '2026-09-24T14:58:00Z', reportAgeMin: 2, streamAgeMin: 60 }]);
eq('ok-0-failing',       standbyRows({ standbys: [{ ...SB1, ok: 0 }] }, NOW)[0].ok, false);
eq('ok-string-failing',  standbyRows({ standbys: [{ ...SB1, ok: '1' }] }, NOW)[0].ok, false);
eq('month-13-null',      snapshotAgeMin('20261340T000000Z', NOW), null);
eq('feb-31-null',        snapshotAgeMin('20260231T000000Z', NOW), null);
eq('month-13-day-1-null', snapshotAgeMin('20261301T000000Z', NOW), null);
eq('latest-null',        snapshotAgeMin('latest', NOW), null);
eq('empty-null',         snapshotAgeMin('', NOW), null);
eq('number-null',        snapshotAgeMin(123, NOW), null);
eq('report-garbage',     reportAgeMin('garbage', NOW), null);
eq('report-empty',       reportAgeMin('', NOW), null);
eq('empty-when-none',    standbyRows({ role: { standby: [] } }, NOW), []);
eq('empty-no-role',      standbyRows({}, NOW), []);
eq('marker-undefined',   standbyRows({ role: { standby: ['sb-1'] } }, NOW), { error: STANDBY_CONTRACT_ERROR, standby: ['sb-1'] });
eq('marker-null',        standbyRows({ standbys: null, role: { standby: ['sb-1'] } }, NOW).error, 'standbys_missing');
eq('marker-object',      standbyRows({ standbys: {}, role: { standby: ['sb-1'] } }, NOW).error, 'standbys_missing');
console.log('end');
" 2>&1)
ENDED=0
while IFS= read -r line; do
  case "$line" in
    end) ENDED=1 ;;
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"
[ "$ENDED" -eq 1 ] || bad "lib: the node script did not run to the end"

# --- 2: the panel's shape ---------------------------------------------------
grep -q "from '../../ui/SortableTable.js'" "$PANEL" && grep -q '<\${SortableTable} wide' "$PANEL" && ok \
  || bad "Standby.js must render the shared SortableTable, wide"
grep -q 'overflow-x:auto' "$PANEL" && ok || bad "Standby.js must wrap the table in its own overflow-x:auto container"
grep -q "from './StandbyVerify.js'" "$PANEL" && ok || bad "Standby.js must mount the contract's verify pieces"
CODE=$(grep -hvE '^[[:space:]]*//' "$PANEL" "$LIB")
[ -n "$CODE" ] && ok || bad "no code read from the panel and lib"
if [[ "$CODE" =~ (^|[^A-Za-z0-9_.])(confirm|alert|prompt)[[:space:]]*\( ]] \
  || [[ "$CODE" =~ (window|globalThis)\.(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the STANDBY panel"
else
  ok
fi

# --- 3: the node suite, when deps are installed -----------------------------
if [ -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  LOG=$(mktemp)
  if (cd "$DIR/console-ui" && node --test tests/standby-panel.bh-2641.test.js >"$LOG" 2>&1); then
    ok
  else
    cat "$LOG"; bad "the standby-panel node suite failed"
  fi
  rm -f "$LOG"
else
  echo "standby-console: node suite SKIPPED — console-ui/node_modules is not installed"
fi

echo "standby-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
