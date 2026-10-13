import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { LLM_SITES, parseSiteStages, siteAttribution } from '../src/lib/llm-sites-catalog.js';

// BH-2553 (BH-2540.0) — the LLM sites contract slice: the pure catalog module
// every sibling imports, and the two stub routes, driven through the real
// worker.fetch (D2) so the route table and the bearer are what answer.

const SECRET = 'test-secret';
const NOW_MS = Date.parse('2026-09-26T09:00:00Z');
const CATALOG = JSON.parse(readFileSync(new URL('../../../catalog/llm-sites.json', import.meta.url), 'utf8'));
const site = (id) => LLM_SITES.find((s) => s.id === id);

test('C1: LLM_SITES is the bundled catalog, id for id', () => {
  assert.ok(CATALOG.sites.length > 0);
  assert.deepEqual(LLM_SITES.map((s) => s.id), CATALOG.sites.map((s) => s.id));
});

test('C2: "*" is all stages; a|b splits and trims', () => {
  assert.deepEqual(parseSiteStages('*'), { all: true, stages: [] });
  assert.deepEqual(parseSiteStages('plan|execute'), { all: false, stages: ['plan', 'execute'] });
  assert.deepEqual(parseSiteStages(' a | b '), { all: false, stages: ['a', 'b'] });
});

test('C3: free-text stage values and absent input carry no attributable stage', () => {
  for (const v of ['$COST_STAGE (default raw)', '(none — no cost row)', '(its own kind, in its own cost row)', '$COST_STAGE', null, undefined, 7]) {
    assert.deepEqual(parseSiteStages(v), { all: false, stages: [] }, JSON.stringify(v));
  }
});

test('C4/C6: siteAttribution over the real catalog — lane, signature, none', () => {
  const rb = siteAttribution(site('rb-plan'));
  assert.equal(rb.attribution, 'lane');
  assert.equal(rb.lane, 'fly-pool');
  assert.deepEqual(rb.stages, ['plan', 'execute', 'review', 'fix', 'qa']);
  assert.equal(rb.all, false);

  const dec = siteAttribution(site('run-decompose'));
  assert.equal(dec.attribution, 'signature');
  assert.equal(dec.lane, null);
  assert.deepEqual(dec.stages, ['decompose']);

  // BH-2562: oauth-refresh now calls through agent-call on stage canary with a
  // null census lane (oauth-refresh is a knob lib, not a registry lane), so it
  // claims every canary row by signature, the lane-probe and claude-auth-check
  // inferences included. Its spend is overstated there, and shared says so.
  const oauth = siteAttribution(site('oauth-refresh'));
  assert.equal(oauth.attribution, 'signature');
  assert.equal(oauth.lane, null);
  assert.deepEqual(oauth.stages, ['canary']);
  assert.equal(oauth.shared, true);

  // BH-2562 dropped fly-builder-smoke (SMOKE asks cred_probe, not a model).
  // greenfield is a real site of the same shape: a lane, no attributable stage.
  const gf = siteAttribution(site('greenfield'));
  assert.equal(gf.attribution, 'none', 'a lane with no stage never claims every row on that lane');
  assert.equal(gf.lane, 'greenfield');
  const smoke = siteAttribution({ id: 'smoke', lane: 'fly-pool', stage: '(none — no cost row)' });
  assert.equal(smoke.attribution, 'none', 'a lane with no stage never claims every row on that lane');
  assert.equal(smoke.lane, 'fly-pool');

  const any = siteAttribution(site('agent-call'));
  assert.equal(any.attribution, 'signature');
  assert.equal(any.all, true);
  assert.equal(any.lane, null);
});

test('C5: shared is true only when another site lists one of the same stages', () => {
  const x = { id: 'x', lane: 'l1', stage: 'review' };
  const y = { id: 'y', lane: 'l2', stage: 'review|fix' };
  const z = { id: 'z', stage: 'mine' };
  const star = { id: 's', stage: '*' };
  const sites = [x, y, z, star];
  assert.equal(siteAttribution(x, sites).shared, true);
  assert.equal(siteAttribution(y, sites).shared, true);
  assert.equal(siteAttribution(z, sites).shared, false, 'a * site does not make another site shared');
  assert.equal(siteAttribution(star, sites).shared, false, 'a * site is never shared itself');
  assert.equal(siteAttribution(site('review-prs')).shared, true);
  assert.equal(siteAttribution(site('rule-miner')).shared, false);
});

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb();
  if (!env) t.skip('node:sqlite unavailable on this runtime');
  return env;
}

async function get(DB, path, { secret = SECRET } = {}) {
  const headers = secret === null ? {} : { authorization: `Bearer ${secret}` };
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, { headers }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

test('W1: GET /api/metrics/llm-sites answers one site per catalog entry with the request clock', async (t) => {
  // BH-2554 filled in the stub this case used to pin; the full shape is
  // pinned in llm-sites.bh-2554.test.js.
  const env = await open(t); if (!env) return;
  const r = await get(env.DB, '/api/metrics/llm-sites');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.as_of, '2026-09-26T09:00:00Z');
  assert.equal(r.body.sites.length, LLM_SITES.length);
  assert.ok(!r.body.incomplete.includes('not-implemented'));
});

test('W2: GET /api/metrics/llm-sites without the bearer is 401', async (t) => {
  const env = await open(t); if (!env) return;
  assert.equal((await get(env.DB, '/api/metrics/llm-sites', { secret: null })).status, 401);
});

test('W3/W4: /rows with an unknown or missing site is 400 unknown site', async (t) => {
  const env = await open(t); if (!env) return;
  for (const q of ['?site=nope', '', '?site=RB-PLAN', '?site=%20rb-plan']) {
    const r = await get(env.DB, `/api/metrics/llm-sites/rows${q}`);
    assert.equal(r.status, 400, q);
    assert.deepEqual(r.body, { error: 'unknown site' }, q);
  }
});

// BH-2555 filled the stub in; on an empty table the contract shape is this.
test('W5: /rows?site=rb-plan answers the contract shape on an empty table', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await get(env.DB, '/api/metrics/llm-sites/rows?site=rb-plan');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body, { site: site('rb-plan'), rows: [], truncated: false, incomplete: [] });
});

test('W6: /rows without the bearer is 401', async (t) => {
  const env = await open(t); if (!env) return;
  assert.equal((await get(env.DB, '/api/metrics/llm-sites/rows?site=rb-plan', { secret: null })).status, 401);
});
