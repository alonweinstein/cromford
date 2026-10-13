#!/bin/bash
# tests/queue-panel-proxy.bh-2510-test.sh — the contract slice of the Project
# page's QUEUES panel (BH-3150, BH-2510.0).
#
# This slice is wiring only: two worker routes that answer 501, two coord proxy
# WRITES rows, five api.js helpers, a pure lib and three screens that render
# nothing yet. What this file holds (the routing-panel-console.bh-2328 pattern):
#
#   1. every new source exists, named by rooted path so the orphan ratchet sees it.
#   2. the coord proxy, DRIVEN through onRequest with a stubbed fetch:
#      POST queue/action and POST deploy-queue/action forward exactly the row's
#      fields plus the stamped actor (a browser `actor` and `__proto__` are
#      dropped); a blank or whitespace reason is a 400 before any worker call;
#      PATCH queue, POST queue/claim, POST deploy-queue/claim and
#      POST deploy-queue/depart stay 405 from a browser.
#   3. Project.js mounts the three screens in one QUEUES section above ROUTING.
#   4. the node suite, run for real when the console-ui deps are installed.
# Run from anywhere: tests/queue-panel-proxy.bh-2510-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/queue-panel.js"
BUILD_PANEL="$DIR/console-ui/src/screens/BuildQueuePanel.js"
DEPLOY_PANEL="$DIR/console-ui/src/screens/DeployQueuePanel.js"
TRAINS_PANEL="$DIR/console-ui/src/screens/MergeTrainsPanel.js"
PROJECT="$DIR/console-ui/src/screens/Project.js"
PROXY="$DIR/console-ui/functions/api/coord/[[path]].js"
QUEUE_ROUTE="$DIR/worker/jobs/src/routes/queue-actions.js"
DEPLOY_ROUTE="$DIR/worker/jobs/src/routes/deploy-queue-actions.js"

for f in "$LIB" "$BUILD_PANEL" "$DEPLOY_PANEL" "$TRAINS_PANEL" "$PROJECT" "$PROXY" "$QUEUE_ROUTE" "$DEPLOY_ROUTE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "queue-panel-proxy: SKIPPED — node is not installed on this box"; exit 0; }

# --- 2: the coord proxy, driven ----------------------------------------------
OUT=$(node --input-type=module -e "
import { onRequest } from '$PROXY';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const seen = [];
globalThis.fetch = async (u, init = {}) => {
  u = String(u);
  if (u.startsWith('https://harness-console.')) return new Response('', { status: 200 });
  seen.push({ method: init.method || 'GET', path: new URL(u).pathname, body: init.body });
  return new Response(JSON.stringify({ error: 'not implemented', refused: true }), { status: 501 });
};
let n = 0;
const call = (method, segs, raw) => onRequest({
  request: new Request('https://mc.example/api/coord/' + segs.join('/'), {
    method, headers: { cookie: 'dash=s' + (++n), 'content-type': 'application/json' }, body: raw }),
  env: { HARNESS_SECRET: 's' }, params: { path: segs } });

// A browser body with a forged actor and a __proto__ key, as raw JSON so the
// __proto__ arrives as an own key the way a hostile client would send it.
const qRaw = '{\"project\":\"p\",\"key\":\"BH-1\",\"action\":\"hold\",\"reason\":\"dead box\",\"actor\":\"evil\",\"__proto__\":{\"admin\":true},\"extra\":\"x\"}';
const q = await call('POST', ['queue', 'action'], qRaw);
eq('queue-status',   q.status, 501);
eq('queue-calls',    seen.map((s) => s.method + ' ' + s.path), ['POST /api/queue/action']);
const qSent = seen[0] ? JSON.parse(seen[0].body) : null;
eq('queue-body',     qSent, { project: 'p', key: 'BH-1', action: 'hold', reason: 'dead box', actor: 'console' });
eq('queue-keys',     Object.keys(qSent || {}).sort(), ['action', 'actor', 'key', 'project', 'reason']);

seen.length = 0;
const dRaw = '{\"project\":\"p\",\"sha\":\"abc123\",\"action\":\"drop\",\"reason\":\"bad sha\",\"actor\":\"evil\",\"__proto__\":{\"admin\":true}}';
const d = await call('POST', ['deploy-queue', 'action'], dRaw);
eq('deploy-status',  d.status, 501);
eq('deploy-calls',   seen.map((s) => s.method + ' ' + s.path), ['POST /api/deploy-queue/action']);
const dSent = seen[0] ? JSON.parse(seen[0].body) : null;
eq('deploy-body',    dSent, { project: 'p', sha: 'abc123', action: 'drop', reason: 'bad sha', actor: 'console' });
eq('deploy-keys',    Object.keys(dSent || {}).sort(), ['action', 'actor', 'project', 'reason', 'sha']);

seen.length = 0;
const statuses = [];
for (const [segs, body] of [
  [['queue', 'action'], { project: 'p', key: 'BH-1', action: 'hold', reason: '   ' }],
  [['queue', 'action'], { project: 'p', key: 'BH-1', action: 'hold' }],
  [['deploy-queue', 'action'], { project: 'p', sha: 'abc', action: 'drop', reason: '' }],
  [['deploy-queue', 'action'], { project: 'p', sha: 'abc', action: 'drop', reason: 7 }],
]) statuses.push((await call('POST', segs, JSON.stringify(body))).status);
eq('blank-reason-400', statuses, [400, 400, 400, 400]);
eq('blank-reason-no-fetch', seen.length, 0);

const closed = [];
for (const [m, segs] of [['PATCH', ['queue']], ['POST', ['queue', 'claim']],
                         ['POST', ['deploy-queue', 'claim']], ['POST', ['deploy-queue', 'depart']]]) {
  closed.push((await call(m, segs, JSON.stringify({ project: 'p', reason: 'x' }))).status);
}
eq('siblings-405', closed, [405, 405, 405, 405]);
eq('siblings-no-fetch', seen.length, 0);
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

# --- 3: the mount -------------------------------------------------------------
QLINE=$(grep -n 'title="QUEUES"' "$PROJECT" | head -1 | cut -d: -f1)
RLINE=$(grep -n 'title="ROUTING"' "$PROJECT" | head -1 | cut -d: -f1)
if [ -n "$QLINE" ] && [ -n "$RLINE" ] && [ "$QLINE" -lt "$RLINE" ]; then ok
else bad "Project.js must carry a QUEUES section above ROUTING (QUEUES=${QLINE:-none} ROUTING=${RLINE:-none})"
fi
for c in BuildQueuePanel DeployQueuePanel MergeTrainsPanel; do
  grep -q "<\${$c} project=\${project}/>" "$PROJECT" && ok || bad "Project.js must mount $c"
done

# --- 4: the node suite, when deps are installed ------------------------------
if [ -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/queue-panel.bh-2510.test.js 2>&1); then ok
  else bad "console-ui/tests/queue-panel.bh-2510.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
else
  echo "queue-panel-proxy: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
fi

echo "queue-panel-proxy: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
