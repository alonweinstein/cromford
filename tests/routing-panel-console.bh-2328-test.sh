#!/bin/bash
# tests/routing-panel-console.bh-2328-test.sh — the ROUTING section of
# /p/<project> in Mission Control (BH-2328).
#
# WHY A SHELL SUITE AS WELL. The panel is proved by node --test in
# console-ui/tests/routing-panel.bh-2328.test.js (reached through the
# console-ui job). What this file adds is the part the impact lane and the
# orphan ratchet can SEE: it names the two new sources by path, drives the pure
# half and the coord proxy for real, and holds the panel to the rules a
# reviewer would otherwise check by eye (the cost-breaker-console.bh-2331
# pattern).
#
#   1. lib/routing.js, DRIVEN: a failed read is never "not halted"; the write
#      body is {project, halted, reason} only (never builder/pool_app/actor);
#      an UNHALT with a blank reason is blocked and sends nothing; the current
#      halt's who/why comes from the change that SET halted.
#   2. the coord proxy, DRIVEN: a PUT routing forwards builder and pool_app
#      from the worker's row, never the browser's, and refuses a blank UNHALT
#      reason with a 400 before any worker call.
#   3. RoutingPanel.js sorts through the shared SortableTable, confirms through
#      the in-app useConfirm modal with confirm blocked on the reason, is
#      mounted on the Project page, and never calls a native dialog.
#   4. the node suite, run for real when the console-ui deps are installed.
# Run from anywhere: tests/routing-panel-console.bh-2328-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/routing.js"
PANEL="$DIR/console-ui/src/screens/RoutingPanel.js"
PROJECT="$DIR/console-ui/src/screens/Project.js"
PROXY="$DIR/console-ui/functions/api/coord/[[path]].js"

for f in "$LIB" "$PANEL" "$PROJECT" "$PROXY"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "routing-panel-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { routingState, haltBody, haltFormState, currentHalt, haltDisabledReason, changeCells, haltAction,
         ROUTING_CHANGES_LIMIT } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const ROW = { project: 'p', builder: 'pool', pool_app: 'bh-pool-p', halted: 1 };
const on = { data: { setting: { value: 'on' } }, error: null };

eq('limit',          ROUTING_CHANGES_LIMIT, 50);
eq('state-row',      routingState({ data: { routing: ROW }, error: null }, on).kind, 'row');
eq('state-404',      routingState({ data: null, error: { status: 404 } }, on).kind, 'none');
eq('state-500',      routingState({ data: { routing: ROW }, error: { status: 500 } }, on).kind, 'error');
eq('knob-unread',    routingState({ data: { routing: ROW }, error: null }, { data: null, error: { status: 503 } }).rowsOn, null);
eq('disabled-off',   typeof haltDisabledReason({ kind: 'row', row: ROW, rowsOn: false }), 'string');
eq('disabled-live',  haltDisabledReason({ kind: 'row', row: ROW, rowsOn: true }), null);

eq('body-halt',      haltBody(ROW, true, ' '), { project: 'p', halted: 1, reason: 'HALT from Mission Control' });
eq('body-unhalt',    haltBody(ROW, false, ' fixed '), { project: 'p', halted: 0, reason: 'fixed' });
eq('form-halt',      haltFormState(true, '').blocked, false);
eq('form-unhalt',    haltFormState(false, '  ').blocked, true);
eq('form-reason',    haltFormState(false, 'fixed').blocked, false);

const log = { data: { changes: [
  { id: 4, before_builder: 'pool', before_halted: 1, after_halted: 1, actor: 'seed', reason: 'move', at: 't4' },
  { id: 3, before_builder: 'pool', before_halted: 0, after_halted: 1, actor: 'console', reason: 'drill', at: 't3' } ] }, error: null };
eq('halt-who',       currentHalt(log), { found: true, actor: 'console', reason: 'drill', at: 't3' });
eq('halt-unread',    currentHalt({ data: null, error: new Error('x') }).found, false);
eq('cells-move',     changeCells({ before_builder: 'local', after_builder: 'pool', before_halted: 0, after_halted: 0 }).builder, 'local → pool');

const fake = () => {
  const sent = [];
  return { sent, apiObj: {
    routing: async () => { sent.push('GET'); return { routing: { ...ROW, halted: 1 } }; },
    putRouting: async (b) => { sent.push(b); return { routing: { ...ROW, halted: b.halted } }; } } };
};
const blank = fake();
const r1 = await haltAction({ apiObj: blank.apiObj, project: 'p', target: false, reason: '  ' });
eq('unhalt-blank-sends-nothing', [r1.ok, blank.sent.length], [false, 0]);
const good = fake();
const r2 = await haltAction({ apiObj: good.apiObj, project: 'p', target: false, reason: 'fixed' });
eq('unhalt-sends',   [r2.ok, good.sent[1]], [true, { project: 'p', halted: 0, reason: 'fixed' }]);
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

# --- 2: the coord proxy, driven ----------------------------------------------
OUT=$(node --input-type=module -e "
import { onRequest } from '$PROXY';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const seen = [];
globalThis.fetch = async (u, init = {}) => {
  u = String(u);
  if (u.startsWith('https://harness-console.')) return new Response('', { status: 200 });
  const method = init.method || 'GET';
  seen.push({ method, path: new URL(u).pathname, body: init.body });
  if (method === 'GET') return new Response(JSON.stringify({ routing: { project: 'p', builder: 'local', pool_app: null, halted: 1 } }), { status: 200 });
  return new Response(JSON.stringify({ routing: JSON.parse(init.body) }), { status: 200 });
};
let n = 0;
const put = (body) => onRequest({
  request: new Request('https://mc.example/api/coord/routing', {
    method: 'PUT', headers: { cookie: 'dash=s' + (++n), 'content-type': 'application/json' }, body: JSON.stringify(body) }),
  env: { HARNESS_SECRET: 's' }, params: { path: ['routing'] } });

const forged = await put({ project: 'p', builder: 'pool', pool_app: 'evil', halted: 0, reason: 'fixed', actor: 'me' });
eq('forged-status',  forged.status, 200);
eq('forged-calls',   seen.map((s) => s.method + ' ' + s.path), ['GET /api/routing/p', 'PUT /api/routing']);
eq('forged-body',    JSON.parse(seen[1].body), { project: 'p', builder: 'local', pool_app: null, halted: 0, reason: 'fixed', actor: 'console' });
seen.length = 0;
const blank = await put({ project: 'p', halted: 0, reason: '  ' });
eq('blank-unhalt',   [blank.status, seen.length], [400, 0]);
console.log('end');
" 2>&1)
ENDED=0
while IFS= read -r line; do
  case "$line" in
    end) ENDED=1 ;;
    ok\ *) ok ;;
    no\ *) bad "proxy: ${line#no }" ;;
    *) [ -n "$line" ] && bad "proxy: unexpected output: $line" ;;
  esac
done <<< "$OUT"
[ "$ENDED" -eq 1 ] || bad "proxy: the node script did not run to the end"

# --- 3: the panel's shape ---------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$PANEL" && grep -q '<\${SortableTable}' "$PANEL" && ok \
  || bad "RoutingPanel.js must render the shared SortableTable"
grep -q "useConfirm } from '../ui/Modal.js'" "$PANEL" && grep -q 'useConfirm()' "$PANEL" && ok \
  || bad "RoutingPanel.js must confirm through the in-app modal (useConfirm)"
grep -q 'confirmBlocked: haltFormState' "$PANEL" && ok \
  || bad "RoutingPanel.js must hold confirm blocked on the reason (haltFormState)"
grep -q '<\${RoutingPanel} project=' "$PROJECT" && ok || bad "Project.js must mount the ROUTING section"
CODE=$(grep -hvE '^[[:space:]]*//' "$PANEL" "$LIB")
[ -n "$CODE" ] && ok || bad "no code read from the panel and lib"
if [[ "$CODE" =~ (window|globalThis)\.(confirm|alert|prompt)[[:space:]]*\( ]] \
  || [[ "$CODE" =~ (^|[^A-Za-z0-9_.])(alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the ROUTING panel"
else
  ok
fi

# --- 4: the node suite, when deps are installed ------------------------------
if [ -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/routing-panel.bh-2328.test.js 2>&1); then ok
  else bad "console-ui/tests/routing-panel.bh-2328.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
else
  echo "routing-panel-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
fi

echo "routing-panel-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
