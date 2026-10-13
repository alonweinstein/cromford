#!/bin/bash
# tests/risk-tiers-console.bh-5022-test.sh — the console's risk tiers (BH-5022):
# the RISK TIERS section on /merge-queue and the RISK TIER fact on /pr/...
#
# WHY A SHELL SUITE AS WELL. The screens are proved by node --test in
# console-ui/tests/risk-tiers.bh-5022.test.js (reached through the console-ui
# job). This file is the part the impact lane and the orphan ratchet can SEE:
# it names the new lib by path, drives its pure half for real, and holds the
# screens to the rules a reviewer would otherwise check by eye (the
# cost-breaker-console.bh-2331 pattern).
#
#   1. lib/risk-tiers.js, DRIVEN: the tier filter, the tier order, the tier
#      normaliser and the live-head pick.
#   2. MergeQueue.js sorts through the shared SortableTable, links every PR
#      cell to /pr/<project>/<n>, marks the filter buttons with aria-pressed,
#      and api.js reads risk-tiers through the coord proxy.
#   3. the node suite, run for real when the console-ui dependencies are installed.
# Run from anywhere: tests/risk-tiers-console.bh-5022-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/risk-tiers.js"
MQ="$DIR/console-ui/src/screens/MergeQueue.js"
PR="$DIR/console-ui/src/screens/PR.js"
API="$DIR/console-ui/src/api.js"

for f in "$LIB" "$MQ" "$PR" "$API"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "risk-tiers-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { riskTierRows, TIER_ORDER, RISK_TIERS, normTier, liveHeadTier } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const A = 'a'.repeat(40), B = 'b'.repeat(40);
const data = { rows: [
  { id: 1, tier: 'low', head_sha: A }, { id: 2, tier: 'high', head_sha: B },
  { id: 3, tier: 'low', head_sha: B }, { id: 4, tier: 'medium', head_sha: A } ], truncated: false };
eq('filter-low',    riskTierRows(data, 'low').map((r) => r.id), [1, 3]);
eq('filter-medium', riskTierRows(data, 'medium').map((r) => r.id), [4]);
eq('filter-all',    riskTierRows(data, 'all').length, 4);
eq('filter-null',   riskTierRows(data, null).length, 4);
eq('filter-nodata', riskTierRows(null, 'low'), []);
eq('filter-norows', riskTierRows({}, null), []);
eq('order',         TIER_ORDER.low < TIER_ORDER.medium && TIER_ORDER.medium < TIER_ORDER.high, true);
eq('tiers',         RISK_TIERS, ['low', 'medium', 'high']);
eq('norm-case',     normTier(' High '), 'high');
eq('norm-junk',     normTier('urgent'), null);
eq('norm-all',      normTier('all'), null);
eq('head-pick',     liveHeadTier(data.rows, B).id, 2);
eq('head-none',     liveHeadTier(data.rows, 'c'.repeat(40)), null);
eq('head-null',     liveHeadTier(data.rows, null), null);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screens' shape --------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$MQ" && ok || bad "MergeQueue.js must use the shared SortableTable"
grep -q "from '../lib/risk-tiers.js'" "$MQ" && ok || bad "MergeQueue.js must shape the RISK TIERS rows through lib/risk-tiers.js"
grep -q 'aria-pressed' "$MQ" && ok || bad "MergeQueue.js must mark the tier filter buttons with aria-pressed"
grep -q "useSearchParam('tier')" "$MQ" && ok || bad "MergeQueue.js must read the tier filter from ?tier="
grep -q "from '../lib/risk-tiers.js'" "$PR" && ok || bad "PR.js must pick the live head's tier through lib/risk-tiers.js"
grep -q "/api/coord/risk-tiers" "$API" && ok || bad "api.js must read risk-tiers through the coord proxy"
CODE=$(grep -hvE '^[[:space:]]*//' "$MQ" "$PR" "$LIB")
if [[ "$CODE" =~ window\.(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the risk-tier screens"
else
  ok
fi

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "risk-tiers-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/risk-tiers.bh-5022.test.js 2>&1); then ok
  else bad "console-ui/tests/risk-tiers.bh-5022.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "risk-tiers-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
