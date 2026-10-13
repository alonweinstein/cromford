import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { LLM_SITES } from '../src/lib/llm-sites-catalog.js';

// BH-2555 (BH-2540.2) — GET /api/metrics/llm-sites/rows?site=<id>: one LLM
// site's cost rows, newest first, last 7 days, capped at 200. Driven through
// the real worker.fetch over node:sqlite built from schema.sql (D2), because
// the thing under test is the SQL: which rows a site owns.

const SECRET = 'test-secret';
const NOW_MS = Date.parse('2026-09-26T09:00:00Z');
const at = (ms) => new Date(NOW_MS - ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const H = 3600000, D = 86400000;
const FIELDS = ['ts', 'box', 'project', 'ticket', 'pr', 'stage', 'lane_id', 'runner', 'model',
  'billing_mode', 'rc', 'cost_usd', 'row_source', 'note'];
const site = (id) => LLM_SITES.find((s) => s.id === id);

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb();
  if (!env) t.skip('node:sqlite unavailable on this runtime');
  return env;
}

let n = 0;
function seed(db, o) {
  const r = { box: 'hub', row_hash: `h${++n}`, line_no: n, ts: at(H), host: 'h', project: 'p1',
    stage: 'triage', lane_id: null, runner: 'claude', model: 'm', rc: 0, cost_usd: 1,
    billing_mode: 'cash', row_source: 'transcript', ticket: null, pr: null, note: null,
    inserted_at: at(0), ...o };
  const cols = Object.keys(r);
  db.prepare(`INSERT INTO cost_rows (${cols.join(',')}) VALUES (${cols.map(() => '?').join(',')})`)
    .run(...cols.map((c) => r[c]));
  return r;
}

async function get(DB, path, { secret = SECRET } = {}) {
  const headers = secret === null ? {} : { authorization: `Bearer ${secret}` };
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, { headers }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

const count = (db) => db.prepare('SELECT COUNT(*) AS c FROM cost_rows').get().c;

test('W10: alert-triage gets its own lane and NULL-lane triage rows, newest first, 7d only', async (t) => {
  const env = await open(t); if (!env) return;
  const own = seed(env.db, { ts: at(H), lane_id: 'alert-triage', ticket: 'BH-1', pr: '12', note: 'n1', cost_usd: 0.5 });
  const legacy = seed(env.db, { ts: at(2 * H), lane_id: null, cost_usd: null });
  seed(env.db, { ts: at(30 * 60000), lane_id: 'alerts-medic' });
  seed(env.db, { ts: at(8 * D), lane_id: 'alert-triage' });
  seed(env.db, { ts: at(H), stage: 'review', lane_id: 'alert-triage' });
  const before = count(env.db);

  const r = await get(env.DB, '/api/metrics/llm-sites/rows?site=alert-triage');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.site, site('alert-triage'));
  assert.equal(r.body.truncated, false);
  assert.deepEqual(r.body.incomplete, []);
  assert.ok(!('reason' in r.body), 'a lane site with stages carries no reason');
  assert.deepEqual(r.body.rows.map((x) => x.ts), [own.ts, legacy.ts]);
  for (const x of r.body.rows) assert.deepEqual(Object.keys(x).sort(), [...FIELDS].sort());
  const [a, b] = r.body.rows;
  assert.deepEqual(
    [a.box, a.project, a.ticket, a.pr, a.stage, a.lane_id, a.runner, a.model, a.billing_mode, a.rc, a.cost_usd, a.row_source, a.note],
    ['hub', 'p1', 'BH-1', '12', 'triage', 'alert-triage', 'claude', 'm', 'cash', 0, 0.5, 'transcript', 'n1']);
  assert.equal(b.lane_id, null);
  assert.equal(b.cost_usd, null, 'NULL cost stays null, never 0');

  // W10d: read-only.
  assert.equal(count(env.db), before);
});

test('W10b: run-decompose (no lane) matches on stage alone, any lane_id', async (t) => {
  const env = await open(t); if (!env) return;
  const r0 = seed(env.db, { stage: 'decompose', lane_id: 'whatever', ts: at(3 * H) });
  const r1 = seed(env.db, { stage: 'decompose', lane_id: null, ts: at(H) });
  seed(env.db, { stage: 'triage', lane_id: null, ts: at(H) });
  const r = await get(env.DB, '/api/metrics/llm-sites/rows?site=run-decompose');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows.map((x) => x.ts), [r1.ts, r0.ts]);
  assert.deepEqual(r.body.rows.map((x) => x.lane_id), [null, 'whatever']);
});

test('W10c: agent-call ("*") returns every stage in the window, not the 8d-old row', async (t) => {
  const env = await open(t); if (!env) return;
  const a = seed(env.db, { stage: 'triage', ts: at(H) });
  const b = seed(env.db, { stage: 'review', lane_id: 'review-prs', ts: at(2 * H) });
  seed(env.db, { stage: 'plan', ts: at(8 * D) });
  const before = count(env.db);
  const r = await get(env.DB, '/api/metrics/llm-sites/rows?site=agent-call');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows.map((x) => [x.ts, x.stage]), [[a.ts, 'triage'], [b.ts, 'review']]);
  assert.equal(count(env.db), before);
});

test('W11a: an unknown or case-variant site is 400 unknown site', async (t) => {
  const env = await open(t); if (!env) return;
  for (const q of ['site=nope', 'site=Alert-Triage', 'site=', '']) {
    const r = await get(env.DB, `/api/metrics/llm-sites/rows?${q}`);
    assert.equal(r.status, 400, q);
    assert.deepEqual(r.body, { error: 'unknown site' });
  }
});

test('W11b: 201 matching rows come back capped at 200, truncated, newest first', async (t) => {
  const env = await open(t); if (!env) return;
  for (let i = 0; i < 201; i++) seed(env.db, { lane_id: 'alert-triage', ts: at((i + 1) * 60000) });
  const r = await get(env.DB, '/api/metrics/llm-sites/rows?site=alert-triage');
  assert.equal(r.status, 200, JSON.stringify(r.body).slice(0, 300));
  assert.equal(r.body.rows.length, 200);
  assert.equal(r.body.truncated, true);
  assert.equal(r.body.rows[0].ts, at(60000));
  assert.equal(r.body.rows[199].ts, at(200 * 60000));
});

test('W11c: a site with no cost-row stage answers reason no-stage and no rows', async (t) => {
  const env = await open(t); if (!env) return;
  // BH-2562 moved lane-probe onto stage canary; greenfield still has a lane
  // and no cost-row stage ($COST_STAGE), so a row on its lane stays unclaimed.
  seed(env.db, { stage: 'probe', lane_id: 'greenfield' });
  const r = await get(env.DB, '/api/metrics/llm-sites/rows?site=greenfield');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body, { site: site('greenfield'), rows: [], truncated: false, reason: 'no-stage', incomplete: [] });
});

test('W11d: a quote-bearing stage value matches no site', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db, { stage: "triage' OR '1'='1", lane_id: 'alert-triage' });
  const r = await get(env.DB, '/api/metrics/llm-sites/rows?site=alert-triage');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows, []);
});

test('W12: no bearer is 401', async (t) => {
  const env = await open(t); if (!env) return;
  assert.equal((await get(env.DB, '/api/metrics/llm-sites/rows?site=alert-triage', { secret: null })).status, 401);
});
