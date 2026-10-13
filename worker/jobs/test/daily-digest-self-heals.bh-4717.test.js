// BH-4724 (BH-4717.4): the daily digest's self_heals state section.
//
// WHAT IS PINNED
//   Every case goes through the real worker.fetch on GET
//   /api/metrics/daily-digest over a REAL schema.sql database, seeded with the
//   ledger keys bin/lib/self-heal.sh writes (`<source>:<stable-key>`).
//   D1: in-window rows count by source; a row the day before does not; a
//       re-PUT of the same key through PUT /api/ledger on a later day keeps
//       created_at, so it is counted once, on the first day.
//   D2: an empty DB answers empty-day.json's self_heals.
//   D3: a missing ledgers table is ok:false with an error, never n:0, and the
//       non-ledger sections (pr_state, model_watch) still answer.
//   D4: self_heals is a state section but NOT in the quiet-day sum.
//
// The worker's clock is the real one. Every date comes off the ONE anchor below.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { dayWindow, SECTION_KEYS } from '../src/lib/daily-digest/shape.js';

const SECRET = 'test-secret';
const ANCHOR = Date.now();  // determinism: ok the single anchor; the route's own clock is compared against it
const HOUR = 3600e3;
const DAY = 24 * HOUR;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const TODAY = iso(ANCHOR).slice(0, 10);
const YESTERDAY = iso(ANCHOR - DAY).slice(0, 10);
const DAYW = dayWindow(YESTERDAY, new Date(ANCHOR).toISOString());
const FROM = DAYW.from;
const IN1 = iso(Date.parse(FROM) + HOUR);
const IN2 = iso(Date.parse(FROM) + 2 * HOUR);
const BEFORE = iso(Date.parse(FROM) - 1000);

const fixture = (name) => JSON.parse(readFileSync(
  new URL(`../../../tests/fixtures/daily-digest/${name}`, import.meta.url), 'utf8'));
const EMPTY = fixture('empty-day.json');
const FULL = fixture('fixture-day.json');

const call = (DB, path, init = {}) => worker.fetch(
  new Request(`https://jobs.test${path}`, {
    ...init,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
  }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
const digest = async (DB, day = YESTERDAY) => {
  const r = await call(DB, `/api/metrics/daily-digest?day=${day}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body;
};
const ledger = (db, kind, key, status, created, updated = created) => db.prepare(
  `INSERT INTO ledgers (kind, key, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`,
).run(kind, key, status, created, updated);
// A fresh empty stuck-work snapshot keeps past_sla ok (the BH-3793 seeding).
const openSeeded = async () => {
  const o = await openDb();
  ledger(o.db, 'stuck_work_snapshot', 'latest', 'ok', iso(ANCHOR - 60e3));
  o.db.prepare(`UPDATE ledgers SET detail = ? WHERE kind = 'stuck_work_snapshot' AND key = 'latest'`)
    .run(JSON.stringify({ at: Math.floor(ANCHOR / 1000), complete: true, by_state: {}, total: 0 }));
  return o;
};

const CG = 'context-gate:cromford:cromford-BH-3610-202609290110';
const RR = 'review-rescue:project-3/TK-212:project-3-TK-212-202609290300';

test('BH-4724 daily-digest self_heals on a real schema', async (t) => {
  if ((await openDb()) === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  await t.test('D1: in-window self_heal rows count by source, once per key', async () => {
    const { db, DB } = await openSeeded();
    ledger(db, 'self_heal', RR, 'logged', IN2);
    ledger(db, 'self_heal', CG, 'logged', IN1);
    ledger(db, 'self_heal', 'context-gate:cromford:earlier-build', 'logged', BEFORE);
    ledger(db, 'build-tripwire', 'cromford BH-1', 'fired', IN1);   // another kind: not a self-heal
    const d = await digest(DB);
    assert.equal(d.self_heals.ok, true);
    assert.equal(d.self_heals.n, 2);
    assert.deepEqual(d.self_heals.by_source, { 'context-gate': 1, 'review-rescue': 1 });
    assert.deepEqual(d.self_heals.rows, [
      { source: 'context-gate', key: 'cromford:cromford-BH-3610-202609290110', at: IN1 },
      { source: 'review-rescue', key: 'project-3/TK-212:project-3-TK-212-202609290300', at: IN2 },
    ]);
    assert.equal(d.self_heals.truncated, false);
    assert.deepEqual(Object.keys(d.self_heals), Object.keys(FULL.self_heals));
    for (const r of d.self_heals.rows) assert.deepEqual(Object.keys(r), Object.keys(FULL.self_heals.rows[0]));

    // The same event noted again today, through the real PUT route.
    const put = await call(DB, '/api/ledger', {
      method: 'PUT', body: JSON.stringify({ kind: 'self_heal', key: CG, status: 'logged', detail: 'again' }),
    });
    assert.equal(put.status, 200, JSON.stringify(put.body));
    assert.equal(put.body.ledger.created_at, IN1);
    assert.equal((await digest(DB)).self_heals.n, 2, 'the re-put still counts on its first day');
    const today = await digest(DB, TODAY);
    assert.equal(today.self_heals.n, 0, 'a re-put is not a new self-heal today');
  });

  await t.test('D1b: n is counted before the cap, truncated says so', async () => {
    const { db, DB } = await openSeeded();
    for (let i = 0; i < 3; i++) ledger(db, 'self_heal', `context-gate:p:b${i}`, 'logged', IN1);
    const r = await call(DB, `/api/metrics/daily-digest?day=${YESTERDAY}&limit=2`);
    assert.equal(r.body.self_heals.n, 3);
    assert.equal(r.body.self_heals.rows.length, 2);
    assert.equal(r.body.self_heals.truncated, true);
    assert.deepEqual(r.body.self_heals.by_source, { 'context-gate': 3 });
  });

  await t.test('D2: an empty DB answers the empty-day self_heals', async () => {
    const { DB } = await openSeeded();
    const d = await digest(DB);
    assert.deepEqual(d.self_heals, EMPTY.self_heals);
    assert.deepEqual(d.self_heals, { ok: true, n: 0, by_source: {}, rows: [], truncated: false });
  });

  await t.test('D3: a missing ledgers table is ok:false, never 0', async () => {
    const { db, DB } = await openSeeded();
    db.exec('DROP TABLE ledgers');
    const d = await digest(DB);
    assert.equal(d.self_heals.ok, false);
    assert.equal(typeof d.self_heals.error, 'string');
    assert.ok(d.self_heals.error.length > 0);
    assert.equal(d.self_heals.n, undefined);
    assert.equal(d.human_verdict_prs.ok, true);
    assert.equal(d.model_watch.ok, true);
  });

  await t.test('D4: self_heals is a state section but not in the quiet-day sum', async () => {
    assert.ok(SECTION_KEYS.state.includes('self_heals'));
    const { db, DB } = await openSeeded();
    ledger(db, 'self_heal', CG, 'logged', IN1);
    ledger(db, 'self_heal', RR, 'logged', IN2);
    const d = await digest(DB);
    assert.equal(d.self_heals.n, 2);
    assert.equal(d.empty, true, 'self-heals alone do not make a day non-quiet');
  });
});
