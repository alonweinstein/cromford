#!/bin/bash
# tests/account-usage-console.bh-1916-test.sh — the console ACCOUNT USAGE
# section on /costs (BH-1916, BH-167.3).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/account-usage.bh-167.test.js (reached through the console-ui
# job). What this file adds is the part the impact lane and the orphan ratchet
# can SEE: it names the two new sources by path, drives the pure half for real,
# and holds the screen to the rules a reviewer would otherwise check by eye
# (the project-accounts-console.bh-1657 pattern).
#
#   1. lib/account-usage.js, DRIVEN: a null usd stays null and reads `—` (never
#      $0.00), a null account is labelled, tokens are formatted, the unpriced
#      banner counts correctly, and the cross-check line reads the gap or the
#      reason.
#   2. AccountUsage.js sorts through the shared SortableTable, links every
#      project cell, is mounted on /costs, and never calls a native dialog.
#   3. the node suite console-ui/tests/account-usage.bh-167.test.js, run for
#      real when the console-ui dependencies are installed.
# Run from anywhere: tests/account-usage-console.bh-1916-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/account-usage.js"
SCREEN="$DIR/console-ui/src/screens/AccountUsage.js"
COSTS="$DIR/console-ui/src/screens/Costs.js"

for f in "$LIB" "$SCREEN" "$COSTS"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "account-usage-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { usageRows, fmtTokens, unpricedBanner, crossCheckLine, USAGE_WINDOWS }
  from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

eq('windows',       USAGE_WINDOWS.map((w) => w.key), ['5h', '7d']);
eq('tok-small',     fmtTokens(950), '950');
eq('tok-k',         fmtTokens(12345), '12.3k');
eq('tok-M',         fmtTokens(4560000), '4.56M');
eq('tok-null',      fmtTokens(null), '—');

const rows = usageRows({ accounts: [
  { account: 'own:a', usd: 50, calls: 2, unpriced_calls: 0, input_toks: 1200,
    projects: [{ project: 'p-a', usd: 50 }, { project: null, usd: null }],
    meter: { session_pct: 42, weekly_pct: null },
    cross_check: { state: 'comparable', meter_delta_usd: 50, rows_usd: 20, gap_pct: 60 } },
  { account: null, usd: null, calls: 1, unpriced_calls: 1,
    projects: [], meter: null, cross_check: { state: 'no-login', reason: 'no login on this box' } } ] });
eq('rows-labels',     rows.map((r) => r.label), ['own:a', 'no account label']);
eq('rows-labelled',   rows.map((r) => r.labelled), [true, false]);
eq('null-usd-stays',  [rows[1].usd, rows[1].usdText], [null, '—']);
eq('usd-text',        rows[0].usdText, '\$50.00');
eq('meter-pct',       [rows[0].sessionText, rows[0].weeklyText], ['42%', '—']);
eq('project-names',   rows[0].projects.map((p) => p.name), ['p-a', '(no project)']);
eq('project-null-usd', rows[0].projects[1].usdText, '—');
eq('cross-gap',       rows[0].cross, 'meter \$50.00 vs rows \$20.00, gap 60%');
eq('cross-reason',    rows[1].cross, 'no login on this box');
eq('cross-missing',   crossCheckLine({}), '—');
eq('no-accounts',     usageRows({}), []);

eq('banner-none',     unpricedBanner({ totals: { unpriced_calls: 0 } }), null);
eq('banner-one',      unpricedBanner({ totals: { unpriced_calls: 1 } }).startsWith('1 call '), true);
eq('banner-many',     unpricedBanner({ totals: { unpriced_calls: 3 } }).startsWith('3 calls '), true);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape --------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "AccountUsage.js must use the shared SortableTable"
grep -q '<\${Link} to=' "$SCREEN" && ok || bad "AccountUsage.js must link every project cell (no dead rows)"
grep -q "AccountUsageSection" "$COSTS" && ok || bad "Costs.js must mount the ACCOUNT USAGE section"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ window\.(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the ACCOUNT USAGE screen"
else
  ok
fi

# --- 3: the node suite, driven -----------------------------------------------
# console-ui/tests/account-usage.bh-167.test.js renders the screen for real
# (preact-render-to-string). Run here too, so this suite is its door as well as
# the console-ui CI job's; without the console deps it says so and skips.
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "account-usage-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/account-usage.bh-167.test.js 2>&1); then ok
  else bad "console-ui/tests/account-usage.bh-167.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "account-usage-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
