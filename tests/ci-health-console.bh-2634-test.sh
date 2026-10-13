#!/bin/bash
# tests/ci-health-console.bh-2634-test.sh — the console CI health screen at /ci
# (BH-2634, slice 3 of BH-2517).
#
# The screen's behaviour is proved by node --test in
# console-ui/tests/ci-health.bh-2634.test.js. This file is the part the impact
# lane and the orphan ratchet can SEE (the cost-breaker-console.bh-2331
# pattern): it names the two new sources by path, drives the pure half with
# node, and holds the screen to the rules a reviewer would otherwise check by eye.
#
#   1. lib/ci-health.js, DRIVEN: absent / unread is null never 0, the flake
#      rate counts distinct heads, job:/workflow: names are not toggleable, a
#      blank reason blocks, and the toggle sends nothing without a reason and
#      exactly {repo,test,active,reason} with one.
#   2. /ci is routed and in the nav, the screen uses the shared SortableTable
#      and the useConfirm modal, and neither file calls a native dialog.
#   3. the node suite, run for real when the console-ui dependencies are installed.
# Run from anywhere: tests/ci-health-console.bh-2634-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/ci-health.js"
SCREEN="$DIR/console-ui/src/screens/CiHealth.js"
APP="$DIR/console-ui/src/app.js"

for f in "$LIB" "$SCREEN" "$APP"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "ci-health-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { ciHealthRows, flakeRows, quarantineFormState, makeQuarantineAction } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const f = (repo, test, head, kind = 'flake') => ({ repo, workflow: 'ci', test, head, kind, day: '2026-09-25' });

const h = ciHealthRows({ rows: [
  { repo: 'a', metric: 'minutes', payload: { unread: true } },
  { repo: 'a', metric: 'runners', payload: { unreadable: true } },
  { repo: 'b', metric: 'minutes', payload: { est_24h: 7 } },
  { repo: 'b', metric: 'runners', payload: { online: 1, total: 2 } } ] },
  { flakes: [f('c', 't', 'A'), f('c', 'u', 'A'), f('c', 't', 'B'), f('c', 'job:x', 'B', 'red'), f('c', 'job:x', 'C', 'red')] },
  { rows: [{ repo: 'd', test: 't', active: 1 }] }).rows;
const by = Object.fromEntries(h.map((r) => [r.repo, r]));
eq('repos-union',    h.map((r) => r.repo).sort(), ['a', 'b', 'c', 'd']);
eq('unread-null',    [by.a.minutes24h, by.a.minutesState, by.a.runners, by.a.runnersState], [null, 'unread', null, 'unread']);
eq('ok-values',      [by.b.minutes24h, by.b.minutesState, by.b.runners], [7, 'ok', { online: 1, total: 2 }]);
eq('absent-null',    [by.c.minutes24h, by.c.minutesState, by.c.runners, by.c.runnersState], [null, 'absent', null, 'absent']);
eq('distinct-heads', [by.c.flakes7d, by.c.reds7d, by.c.flakeRate], [2, 2, 2 / 3]);
eq('no-heads-null',  by.d.flakeRate, null);
eq('health-failed',  ciHealthRows(null, { flakes: [f('c', 't', 'A')] }, null).rows[0].minutesState, 'unread');
eq('flakes-failed',  ciHealthRows({ rows: [{ repo: 'b', metric: 'minutes', payload: { est_24h: 1 } }] }, null, null).rows[0].flakes7d, null);

const fr = flakeRows({ flakes: [f('c', 't', 'A'), f('c', 'job:x', 'B'), f('c', 'workflow:.github/y.yml', 'B'), f('c', 'r', 'C', 'red')] }, { rows: [] }, 'c').rows;
eq('flake-tests',    fr.map((r) => r.test).sort(), ['job:x', 't', 'workflow:.github/y.yml']);
eq('toggleable',     fr.map((r) => r.test + '=' + r.toggleable).sort(), ['job:x=false', 't=true', 'workflow:.github/y.yml=false']);

eq('form-blank',     quarantineFormState({ reason: '   ' }).blocked, true);
eq('form-reason',    quarantineFormState({ reason: 'flaky on arm' }).blocked, false);

const row = { test: 't', quarantined: false, toggleable: true };
const run = async (reason) => {
  const sent = []; const msgs = [];
  await makeQuarantineAction({
    confirm: async (o) => { o.form.reason = reason; return true; },
    put: async (b) => { sent.push(b); return { ok: true }; },
    reload: () => {}, onMsg: (m) => msgs.push(m)
  })('c', row);
  return { sent, msgs };
};
const blank = await run('  ');
eq('toggle-blank-sends-nothing', [blank.sent.length, blank.msgs[0].ok], [0, false]);
const good = await run(' flaky on arm ');
eq('toggle-sends',   good.sent, [{ repo: 'c', test: 't', active: 1, reason: 'flaky on arm' }]);
eq('toggle-reports', good.msgs[0].ok, true);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape --------------------------------------------------
grep -q "\['/ci', CiHealthScreen\]" "$APP" && ok || bad "app.js must route /ci to CiHealthScreen"
grep -q "to: '/ci', label: 'CI'" "$APP" && ok || bad "app.js must put CI in the nav"
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "CiHealth.js must use the shared SortableTable"
grep -q "useConfirm" "$SCREEN" && ok || bad "CiHealth.js must confirm the toggle through the in-app useConfirm modal"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (^|[^A-Za-z_.])(window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the CI health screen"
else
  ok
fi

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "ci-health-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/ci-health.bh-2634.test.js 2>&1); then ok
  else bad "console-ui/tests/ci-health.bh-2634.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "ci-health-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
