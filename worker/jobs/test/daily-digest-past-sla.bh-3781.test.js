// BH-3793 (BH-3781.4): the daily-digest `past_sla` state section.
//
// WHAT IS PINNED
//   Every route case goes through the real worker.fetch on GET
//   /api/metrics/daily-digest over a REAL schema.sql database, with the
//   stuck_work_snapshot/latest row in the format bin/stuck-work.sh writes
//   (bin/lib/stuck-work/classify.sh header).
//   P1: a fresh snapshot -> {ok:true, total, by_state, as_of, stale:false}.
//   P2: no row -> {ok:false, error:"no stuck-work snapshot"}, never 0.
//   P3: a row 31 min old -> stale:true (30 min -> still fresh).
//   P4: unreadable detail -> ok:false.
//   P5: isEmptyDigest is false when past_sla.total > 0, the key is absent or
//       the snapshot is stale; true on empty-day.json.
//
// The worker's clock is the real one; every date comes off the ONE anchor below.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { isEmptyDigest, SECTION_KEYS } from '../src/lib/daily-digest/shape.js';

const SECRET = 'test-secret';
const ANCHOR = Date.now();  // determinism: ok the single anchor; the route's own clock is compared against it
const MIN = 60e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const YESTERDAY = iso(ANCHOR - 24 * 60 * MIN).slice(0, 10);

const fixture = (name) => JSON.parse(readFileSync(
  new URL(`../../../tests/fixtures/daily-digest/${name}`, import.meta.url), 'utf8'));
const EMPTY = fixture('empty-day.json');
const FULL = fixture('fixture-day.json');
const clone = (o) => JSON.parse(JSON.stringify(o));

const digest = async (DB) => {
  const res = await worker.fetch(
    new Request(`https://jobs.test/api/metrics/daily-digest?day=${YESTERDAY}`,
      { headers: { authorization: `Bearer ${SECRET}` } }),
    { DB, HARNESS_SECRET: SECRET },
  );
  const body = await res.json();
  assert.equal(res.status, 200, JSON.stringify(body));
  return body;
};
const snapshot = (db, detail, updated) => db.prepare(
  `INSERT INTO ledgers (kind, key, status, detail, created_at, updated_at) VALUES ('stuck_work_snapshot', 'latest', 'ok', ?, ?, ?)`,
).run(detail, updated, updated);

test('BH-3793 past_sla is a state section', () => {
  assert.equal(SECTION_KEYS.state.at(-1), 'past_sla');
  assert.deepEqual(Object.keys(FULL.past_sla), ['ok', 'total', 'by_state', 'as_of', 'stale']);
  assert.deepEqual(Object.keys(EMPTY.past_sla), Object.keys(FULL.past_sla));
});

test('BH-3793 past_sla on a real schema', async (t) => {
  if ((await openDb()) === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  await t.test('P1: a fresh snapshot answers its total and by_state', async () => {
    const { db, DB } = await openDb();
    const at = iso(ANCHOR - 5 * MIN);
    snapshot(db, JSON.stringify({ at: 1790000000, complete: true, by_state: { ready: 3, blocked: 1 }, total: 4 }), at);
    const d = await digest(DB);
    assert.deepEqual(d.past_sla, { ok: true, total: 4, by_state: { ready: 3, blocked: 1 }, as_of: at, stale: false });
    assert.deepEqual(Object.keys(d.past_sla), Object.keys(FULL.past_sla));
    assert.equal(d.empty, false);
  });

  await t.test('P2: no snapshot row is ok:false, never 0', async () => {
    const { DB } = await openDb();
    const d = await digest(DB);
    assert.deepEqual(d.past_sla, { ok: false, error: 'no stuck-work snapshot' });
    assert.equal(d.empty, false, 'a missing snapshot is never a quiet day');
    for (const k of SECTION_KEYS.state.filter((k) => k !== 'past_sla')) assert.equal(d[k].ok, true, k);
  });

  await t.test('P3: a snapshot older than 30 min is stale', async () => {
    const old = await openDb();
    snapshot(old.db, JSON.stringify({ at: 1, complete: true, by_state: {}, total: 0 }), iso(ANCHOR - 31 * MIN));
    const d = await digest(old.DB);
    assert.equal(d.past_sla.ok, true);
    assert.equal(d.past_sla.total, 0);
    assert.equal(d.past_sla.stale, true);
    assert.equal(d.empty, false, 'a stale 0 is never a quiet day');

    const fresh = await openDb();
    snapshot(fresh.db, JSON.stringify({ at: 1, complete: true, by_state: {}, total: 0 }), iso(ANCHOR - 29 * MIN));
    assert.equal((await digest(fresh.DB)).past_sla.stale, false);
  });

  await t.test('P4: an unreadable snapshot is ok:false', async () => {
    for (const detail of ['not json', JSON.stringify({ by_state: {} }), JSON.stringify({ total: '4', by_state: {} }),
      JSON.stringify({ total: 4 }), null]) {
      const { db, DB } = await openDb();
      snapshot(db, detail, iso(ANCHOR - MIN));
      const d = await digest(DB);
      assert.equal(d.past_sla.ok, false, `${detail} -> ${JSON.stringify(d.past_sla)}`);
      assert.equal(typeof d.past_sla.error, 'string');
      assert.equal(d.past_sla.total, undefined);
    }
  });
});

test('P5: isEmptyDigest needs a fresh past_sla.total of 0', () => {
  assert.equal(isEmptyDigest(clone(EMPTY)), true);
  const over = clone(EMPTY); over.past_sla.total = 1; over.past_sla.by_state = { ready: 1 };
  assert.equal(isEmptyDigest(over), false, 'total > 0');
  const absent = clone(EMPTY); delete absent.past_sla;
  assert.equal(isEmptyDigest(absent), false, 'key absent');
  const noTotal = clone(EMPTY); delete noTotal.past_sla.total;
  assert.equal(isEmptyDigest(noTotal), false, 'total absent');
  const stale = clone(EMPTY); stale.past_sla.stale = true;
  assert.equal(isEmptyDigest(stale), false, 'stale');
  const failed = clone(EMPTY); failed.past_sla = { ok: false, error: 'no stuck-work snapshot' };
  assert.equal(isEmptyDigest(failed), false, 'ok:false');
});
