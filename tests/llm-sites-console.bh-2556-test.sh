#!/bin/bash
# tests/llm-sites-console.bh-2556-test.sh — the console LLM SITES list on
# /llm-sites (BH-2556, part of BH-2540).
#
# The screen is proved by node --test in console-ui/tests/llm-sites.bh-2556.test.js.
# This suite is the part the impact lane and the orphan ratchet can SEE: it
# names the new lib by path, drives its pure half, holds the screen to the
# rules a reviewer would otherwise check by eye, and runs the node suites when
# the console-ui dependencies are installed (the cost-breaker-console pattern).
#
#   1. lib/llm-sites.js, DRIVEN: runner columns come from the data in the fixed
#      preference order, refused reads gate/guard/kill, badges show only an
#      explicit true, drillHref encodes, money never reads $0.00 for absent.
#   2. LlmSites.js sorts through the shared SortableTable, polls every 60 s, and
#      never calls a native dialog; Costs.js links to /llm-sites.
#   3. the node suites, run for real when console-ui/node_modules exists.
# Run from anywhere: tests/llm-sites-console.bh-2556-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/llm-sites.js"
SCREEN="$DIR/console-ui/src/screens/LlmSites.js"
COSTS="$DIR/console-ui/src/screens/Costs.js"

for f in "$LIB" "$SCREEN" "$COSTS"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "llm-sites-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { runnerColumns, refusedText, badges, drillHref, money, cashText } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const w = (o) => ({ by_runner: o, total: null });
eq('runners-order', runnerColumns({ sites: [
  { usd_24h: w({ zeta: 1, openrouter: 1 }), usd_7d: w({ codex: 1, claude: 1, alpha: 1 }) },
  { usd_24h: null, usd_7d: null } ] }), ['claude', 'codex', 'openrouter', 'alpha', 'zeta']);
eq('runners-empty',  runnerColumns({ sites: [] }), []);
eq('refused',        refusedText({ gate: 1, guard: 0, context_kill: 2 }), '1/0/2');
eq('refused-null',   refusedText({ gate: null, guard: 3 }), '—/3/—');
eq('badges-all',     badges({ badges: { no_row: true, no_knob: true, no_kill: true } }), ['no row', 'no knob', 'no kill']);
eq('badges-strict',  badges({ badges: { no_row: 'true', no_knob: 1, no_kill: false } }), []);
eq('badges-missing', badges({}), []);
eq('drill',          drillHref('a/b c'), '/llm-sites/a%2Fb%20c');
eq('money-null',     money(null), '—');
eq('money-tiny',     money(0.004), '<\$0.01');
eq('cash-unknown',   cashText({ cash_7d: 1, notional_7d: 2, unknown_billing_7d: 3 }), '\$1.00 cash · \$2.00 notional · 3 unknown');
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape --------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "LlmSites.js must use the shared SortableTable"
grep -q "intervalMs: 60000" "$SCREEN" && ok || bad "LlmSites.js must poll every 60 s"
grep -q 'to="/llm-sites"' "$COSTS" && ok || bad "Costs.js must link to /llm-sites"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (^|[^A-Za-z_.])(window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the LLM SITES screen"
else
  ok
fi

# --- 3: the node suites, driven ---------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "llm-sites-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/llm-sites.bh-2556.test.js tests/llm-sites.bh-2553.test.js 2>&1); then ok
  else bad "console-ui llm-sites node suites failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "llm-sites-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
