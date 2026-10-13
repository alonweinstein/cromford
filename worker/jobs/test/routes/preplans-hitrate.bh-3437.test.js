import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';

// BH-3437 — GET /api/preplans/adoption also answers `builds` and `hit_rate`,
// the numbers the pipeline-health 0% alert and the console HIT RATE read.
//
// Driven through the real worker.fetch over the real schema.sql in node:sqlite
// (the bh-2571 harness). builds = adopted + stale + miss: every build that
// looked for a pre-plan. OFF is excluded because it was switched off on
// purpose, not missed. hit_rate = adopted/builds, null (never 0) with no
// builds. rate/bought are unchanged: bin/lib/preplan-cadence.sh reads them.

const SECRET = 'test-secret';
const NOW_MS = Date.parse('2026-09-26T09:00:00Z');

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb();
  if (!env) t.skip('node:sqlite unavailable on this runtime');
  return env;
}

async function get(DB, path) {
  const init = { method: 'GET', headers: { authorization: `Bearer ${SECRET}` } };
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

// One job per verdict row: the aggregate counts distinct jobs.
let seq = 0;
function verdicts(db, project, verdict, count, day = '2026-09-25') {
  for (let i = 0; i < count; i++) {
    const id = `j${++seq}`;
    db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at)
                VALUES (?, ?, ?, 'build', 'box-1', 'plan', 'running', ?, ?)`)
      .run(id, project, `T-${id}`, '2026-09-10T00:00:00Z', '2026-09-10T00:00:00Z');
    db.prepare(`INSERT INTO stage_events (job_id, stage, verdict, actor, detail, created_at)
                VALUES (?, 'preplan', ?, 'box-1', NULL, ?)`)
      .run(id, verdict, `${day}T10:${String(i).padStart(2, '0')}:00Z`);
  }
}

test('H1: 2 ADOPTED, 1 STALE, 5 MISS, 3 OFF is 8 builds at 25%, rate/bought unchanged', async (t) => {
  const env = await open(t); if (!env) return;
  verdicts(env.db, 'p', 'ADOPTED', 2);
  verdicts(env.db, 'p', 'STALE', 1);
  verdicts(env.db, 'p', 'MISS', 5);
  verdicts(env.db, 'p', 'OFF', 3);
  const r = await get(env.DB, '/api/preplans/adoption');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const p = r.body.projects[0];
  assert.equal(p.project, 'p');
  assert.equal(p.builds, 8);
  assert.equal(p.hit_rate, 0.25);
  assert.equal(p.bought, 3);
  assert.equal(p.rate, 2 / 3);
  assert.deepEqual(r.body.days, [{ project: 'p', day: '2026-09-25', adopted: 2, stale: 1, miss: 5, off: 3,
    rate: 2 / 3, builds: 8, hit_rate: 0.25 }]);
});

test('H2: only MISS is a 0 hit rate over n builds, never null', async (t) => {
  const env = await open(t); if (!env) return;
  verdicts(env.db, 'p', 'MISS', 6);
  const r = await get(env.DB, '/api/preplans/adoption');
  const p = r.body.projects[0];
  assert.equal(p.builds, 6);
  assert.equal(p.hit_rate, 0);
  assert.equal(p.rate, null);
  assert.equal(r.body.days[0].builds, 6);
  assert.equal(r.body.days[0].hit_rate, 0);
});

test('H3: only OFF is 0 builds and a null hit rate, per project and per day', async (t) => {
  const env = await open(t); if (!env) return;
  verdicts(env.db, 'p', 'OFF', 4, '2026-09-24');
  verdicts(env.db, 'p', 'OFF', 1, '2026-09-25');
  const r = await get(env.DB, '/api/preplans/adoption');
  const p = r.body.projects[0];
  assert.equal(p.off, 5);
  assert.equal(p.builds, 0);
  assert.equal(p.hit_rate, null);
  assert.equal(r.body.days.length, 2);
  for (const d of r.body.days) {
    assert.equal(d.builds, 0, d.day);
    assert.equal(d.hit_rate, null, d.day);
  }
});
