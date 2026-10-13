// BH-4017 (BH-3987.3, 4 of 4): GET /api/metrics/outcome-gap.
//
// WHAT IS PINNED
//   G1-G9 drive the route through the real worker.fetch (bearer auth, ROUTES,
//   matchRoute) on a REAL schema.sql database, seeded with the row shapes the
//   writers produce: cost_rows as cost-rollup pushes them, a jobs row, its
//   job_artifacts pr_url and the merge-sweep's ledgers merge row.
//   G8 also runs the pure foldGap over a cap of 2 to pin `truncated`.
//
// D = 2026-09-29 is a fixed past day, so `to` = 2026-09-30T00:00:00Z.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { foldGap } from '../src/lib/outcome-gap.js';

const SECRET = 'test-secret';
const D = '2026-09-29';
const STAGES = 'plan,preplan,preplan-files,execute,review,fix';
const BASE = `/api/metrics/outcome-gap?day=${D}&stages=${STAGES}`;
const DAYS_BEFORE_TO = (n, h = 0) => new Date(Date.UTC(2026, 8, 30) - n * 86400000 + h * 3600000).toISOString().replace('.000Z', 'Z');

const call = (DB, path) => worker.fetch(
  new Request(`https://jobs.test${path}`, { headers: { authorization: `Bearer ${SECRET}` } }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const prUrl = (n) => `https://github.com/example-org/project-9/pull/${n}`;

function job(db, { id, project, ticket, created = '2026-09-15T00:00:00Z' }) {
  db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at)
              VALUES (?,?,?,?,?,?,?,?,?)`).run(id, project, ticket, 'build', 'hub', 'done', 'done', created, created);
}
function artifact(db, jobId, url) {
  db.prepare(`INSERT INTO job_artifacts (job_id, artifact_kind, artifact_ref, actor, created_at, updated_at)
              VALUES (?, 'pr_url', ?, 'hub', '2026-09-16T00:00:00Z', '2026-09-16T00:00:00Z')`).run(jobId, url);
}
function ledger(db, key, status, at = '2026-09-25T00:00:00Z') {
  db.prepare(`INSERT INTO ledgers (kind, key, status, actor, created_at, updated_at)
              VALUES ('merge', ?, ?, 'hub', ?, ?)`).run(key, status, at, at);
}
let rowN = 0;
function cost(db, { ts, usd, ticket, project = 'project-9', stage = 'execute', jobId = null }) {
  rowN += 1;
  db.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, cost_usd, ticket, job_id, inserted_at)
              VALUES ('hub', ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(`h${rowN}`, rowN, ts, project, stage, usd, ticket, jobId, ts);
}

// The G1 world: one unmerged $20 ticket, one merged $20 ticket, the same key
// merged in another project, and two $50 rows with no project / no ticket.
function seedG1(db) {
  cost(db, { ts: DAYS_BEFORE_TO(10), usd: 12, ticket: 'TK-1', stage: 'execute', jobId: 'j-so1-a' });
  cost(db, { ts: DAYS_BEFORE_TO(10, 2), usd: 8, ticket: 'TK-1', stage: 'review', jobId: 'j-so1-b' });
  job(db, { id: 'j-so2', project: 'project-9', ticket: 'TK-2' });
  artifact(db, 'j-so2', prUrl(2));
  ledger(db, prUrl(2), 'merged');
  cost(db, { ts: DAYS_BEFORE_TO(10), usd: 20, ticket: 'TK-2', jobId: 'j-so2' });
  // TK-1 merged in `other` must not clear project-9/TK-1.
  job(db, { id: 'j-other', project: 'other', ticket: 'TK-1' });
  artifact(db, 'j-other', 'https://github.com/example-org/other/pull/1');
  ledger(db, 'https://github.com/example-org/other/pull/1', 'merged');
  cost(db, { ts: DAYS_BEFORE_TO(10), usd: 50, ticket: null, project: 'project-9' });
  cost(db, { ts: DAYS_BEFORE_TO(10), usd: 50, ticket: 'NP-1', project: null });
}

async function world(seed) {
  const o = await openDb();
  if (!o) return null;
  seed(o.db);
  return o;
}
const proj = (body, name) => body.projects.find((p) => p.project === name);
const tickets = (body, name) => (proj(body, name)?.tickets.rows || []).map((r) => r.ticket);

test('G1 lists the unmerged ticket, omits the merged one, the NULL rows and the cross-project merge', async (t) => {
  const o = await world(seedG1);
  if (!o) return t.skip('node:sqlite unavailable');
  const r = await call(o.DB, BASE);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.ok, true);
  assert.equal(r.body.day, D);
  assert.equal(r.body.to, '2026-09-30T00:00:00Z');
  assert.equal(r.body.from, '2026-08-31T00:00:00Z');
  assert.deepEqual(r.body.projects.map((p) => p.project), ['project-9']);
  const so = proj(r.body, 'project-9');
  assert.deepEqual(so.tickets.rows.map((x) => x.ticket), ['TK-1']);
  assert.equal(so.tickets.rows[0].usd, 20);
  assert.equal(so.tickets.rows[0].last_job_id, 'j-so1-b');
  assert.equal(so.tickets.rows[0].first_ts, DAYS_BEFORE_TO(10));
  assert.equal(so.usd, 20);
  assert.equal(so.tickets_n, 1);
  assert.equal(r.body.tickets_n, 1);
  assert.equal(r.body.total_usd, 20);
});

test('G2 a $3 ticket is under the default threshold and listed at min_usd=2', async (t) => {
  const o = await world((db) => cost(db, { ts: DAYS_BEFORE_TO(10), usd: 3, ticket: 'TK-3' }));
  if (!o) return t.skip('node:sqlite unavailable');
  const a = await call(o.DB, BASE);
  assert.equal(a.status, 200);
  assert.deepEqual(tickets(a.body, 'project-9'), []);
  assert.equal(a.body.tickets_n, 0);
  assert.equal(a.body.min_usd, 5);
  const b = await call(o.DB, `${BASE}&min_usd=2`);
  assert.equal(b.status, 200);
  assert.deepEqual(tickets(b.body, 'project-9'), ['TK-3']);
  assert.equal(b.body.min_usd, 2);
});

test('G3 a ticket whose first priced spend is 2 days old is inside the grace window', async (t) => {
  const o = await world((db) => {
    cost(db, { ts: DAYS_BEFORE_TO(2), usd: 20, ticket: 'TK-4' });
    // An unpriced row older than the window does not start the clock.
    cost(db, { ts: DAYS_BEFORE_TO(12), usd: null, ticket: 'TK-4' });
  });
  if (!o) return t.skip('node:sqlite unavailable');
  const r = await call(o.DB, BASE);
  assert.equal(r.status, 200);
  assert.deepEqual(tickets(r.body, 'project-9'), []);
  // The same ticket with a 1-day grace window is listed.
  const g = await call(o.DB, `/api/metrics/outcome-gap?day=${D}&stages=${STAGES}&days=1`);
  assert.deepEqual(tickets(g.body, 'project-9'), ['TK-4']);
});

test('G4 triage-stage spend is not build spend unless the stage list names it', async (t) => {
  const o = await world((db) => cost(db, { ts: DAYS_BEFORE_TO(10), usd: 20, ticket: 'TK-5', stage: 'triage' }));
  if (!o) return t.skip('node:sqlite unavailable');
  const a = await call(o.DB, BASE);
  assert.deepEqual(tickets(a.body, 'project-9'), []);
  const b = await call(o.DB, `/api/metrics/outcome-gap?day=${D}&stages=triage`);
  assert.equal(b.status, 200);
  assert.deepEqual(tickets(b.body, 'project-9'), ['TK-5']);
  assert.deepEqual(b.body.stages, ['triage']);
});

test('G5 a ticket whose only merge ledger row is closed is listed', async (t) => {
  const o = await world((db) => {
    job(db, { id: 'j-so6', project: 'project-9', ticket: 'TK-6' });
    artifact(db, 'j-so6', prUrl(6));
    ledger(db, prUrl(6), 'closed');
    cost(db, { ts: DAYS_BEFORE_TO(10), usd: 20, ticket: 'TK-6', jobId: 'j-so6' });
  });
  if (!o) return t.skip('node:sqlite unavailable');
  const r = await call(o.DB, BASE);
  assert.deepEqual(tickets(r.body, 'project-9'), ['TK-6']);
});

test('G5b a merge recorded after `to` does not count as of `to`', async (t) => {
  const o = await world((db) => {
    job(db, { id: 'j-so7', project: 'project-9', ticket: 'TK-7' });
    artifact(db, 'j-so7', prUrl(7));
    ledger(db, prUrl(7), 'merged', '2026-10-01T00:00:00Z');
    cost(db, { ts: DAYS_BEFORE_TO(10), usd: 20, ticket: 'TK-7', jobId: 'j-so7' });
  });
  if (!o) return t.skip('node:sqlite unavailable');
  const r = await call(o.DB, BASE);
  assert.deepEqual(tickets(r.body, 'project-9'), ['TK-7']);
});

test('G6 every bad param is a 400 with an error, never clamped', async (t) => {
  const o = await world(() => {});
  if (!o) return t.skip('node:sqlite unavailable');
  const bad = [
    `/api/metrics/outcome-gap?day=${D}&stages=${STAGES}&days=0`,
    `/api/metrics/outcome-gap?day=${D}&stages=${STAGES}&lookback=7&days=7`,
    `/api/metrics/outcome-gap?day=${D}&stages=`,
    `/api/metrics/outcome-gap?day=${D}&stages=,`,
    `/api/metrics/outcome-gap?day=${D}&stages=A`,
    `/api/metrics/outcome-gap?day=${D}&stages=${'a'.repeat(33)}`,
    `/api/metrics/outcome-gap?day=${D}&stages=${Array.from({ length: 21 }, (_, i) => `s${i}`).join(',')}`,
    `/api/metrics/outcome-gap?day=${D}`,
    `${BASE}&min_usd=-1`,
    `${BASE}&min_usd=10001`,
    `${BASE}&min_usd=5.555`,
    `/api/metrics/outcome-gap?day=2026-13-01&stages=${STAGES}`,
    `/api/metrics/outcome-gap?stages=${STAGES}`,
    `${BASE}&limit=0`,
    `${BASE}&limit=101`,
    `${BASE}&lookback=181`,
    `/api/metrics/outcome-gap?day=${D}&stages=${STAGES}&days=1.5`,
  ];
  for (const p of bad) {
    const r = await call(o.DB, p);
    assert.equal(r.status, 400, `${p} -> ${r.status} ${JSON.stringify(r.body)}`);
    assert.equal(typeof r.body.error, 'string', p);
  }
  const ok = await call(o.DB, `/api/metrics/outcome-gap?day=${D}&stages=${STAGES}&min_usd=5.50&days=60&lookback=180&limit=100`);
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.equal(ok.body.min_usd, 5.5);
  // Duplicated stage names are folded once.
  const dup = await call(o.DB, `/api/metrics/outcome-gap?day=${D}&stages=execute,execute`);
  assert.deepEqual(dup.body.stages, ['execute']);
  const noAuth = await worker.fetch(new Request(`https://jobs.test${BASE}`), { DB: o.DB, HARNESS_SECRET: SECRET });
  assert.equal(noAuth.status, 401);
});

test('G7 the route writes nothing', async (t) => {
  const o = await world(seedG1);
  if (!o) return t.skip('node:sqlite unavailable');
  const counts = () => ['cost_rows', 'jobs', 'job_artifacts', 'ledgers']
    .map((tb) => o.db.prepare(`SELECT COUNT(*) AS n FROM ${tb}`).get().n);
  const before = counts();
  const codes = [];
  for (const p of [`/api/metrics/outcome-gap?day=${D}&stages=${STAGES}`, `/api/metrics/outcome-gap?day=${D}&stages=${STAGES}&min_usd=1`, `/api/metrics/outcome-gap?day=${D}&stages=${STAGES}&days=0`]) codes.push((await call(o.DB, p)).status);
  assert.deepEqual(codes, [200, 200, 400]);
  assert.deepEqual(counts(), before);
});

test('G8 totals are the sums over projects, sorted usd desc then name, not truncated', async (t) => {
  const o = await world((db) => {
    seedG1(db);
    cost(db, { ts: DAYS_BEFORE_TO(9), usd: 30, ticket: 'TK-1', project: 'project-5' });
    cost(db, { ts: DAYS_BEFORE_TO(9), usd: 7, ticket: 'TK-2', project: 'project-5' });
    cost(db, { ts: DAYS_BEFORE_TO(9), usd: 20, ticket: 'AA-1', project: 'aa' });
    cost(db, { ts: DAYS_BEFORE_TO(9), usd: 20, ticket: 'TK-9', project: 'project-9' });
  });
  if (!o) return t.skip('node:sqlite unavailable');
  const r = await call(o.DB, `${BASE}&limit=1`);
  assert.equal(r.status, 200);
  const b = r.body;
  assert.equal(b.truncated, false);
  assert.ok(Math.abs(b.total_usd - b.projects.reduce((s, p) => s + p.usd, 0)) < 1e-9);
  assert.equal(b.tickets_n, b.projects.reduce((s, p) => s + p.tickets_n, 0));
  assert.deepEqual(b.projects.map((p) => [p.project, p.usd]), [['project-9', 40], ['project-5', 37], ['aa', 20]]);
  assert.equal(b.tickets_n, 5);
  // limit cuts each project's ticket list; tickets_n stays uncapped.
  const so = proj(b, 'project-9');
  assert.deepEqual(so.tickets.rows.map((x) => x.ticket), ['TK-1']);
  assert.equal(so.tickets.truncated, true);
  assert.equal(so.tickets_n, 2);

  const rows = [
    { project: 'p', ticket: 'A', usd: 9, unpriced_calls: 0, first_ts: 'x', last_job_id: 'j1' },
    { project: 'p', ticket: 'B', usd: 8, unpriced_calls: 0, first_ts: 'x', last_job_id: null },
    { project: 'q', ticket: 'C', usd: 7, unpriced_calls: 0, first_ts: 'x', last_job_id: 'j3' },
  ];
  const f = foldGap(rows, { limit: 20, groupMax: 2 });
  assert.equal(f.truncated, true);
  assert.equal(f.tickets_n, 2);
  assert.equal(f.total_usd, 17);
  assert.equal(foldGap(rows, { limit: 20, groupMax: 3 }).truncated, false);
});

test('G9 an unpriced-only ticket is never listed as $0 and its calls are counted', async (t) => {
  const o = await world((db) => {
    for (let i = 0; i < 3; i += 1) cost(db, { ts: DAYS_BEFORE_TO(10, i), usd: null, ticket: 'TK-U' });
  });
  if (!o) return t.skip('node:sqlite unavailable');
  const r = await call(o.DB, `${BASE}&min_usd=0`);
  assert.equal(r.status, 200);
  assert.deepEqual(tickets(r.body, 'project-9'), []);
  assert.ok(r.body.unpriced_calls >= 3, `unpriced_calls ${r.body.unpriced_calls}`);
});
