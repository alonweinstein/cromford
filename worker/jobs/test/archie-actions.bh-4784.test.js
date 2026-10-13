// BH-4784: the factory-manager ledger's reads for a stack of three, driven
// through the REAL worker.fetch against the REAL schema.sql (the node:sqlite D1
// shim), the way archie-actions.bh-4583.test.js does it. Pinned here: the day
// cap's count by action (count_by=action, N2), one PR's ledger across days
// (repo=&pr=, the grandchild's fork-point read, I2), and the digest's count of
// pushes that ran no local suites (no_local_suites, N4).
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const call = (DB, path) => {
  const req = new Request(`https://jobs.test${path}`, {
    method: 'GET', headers: { authorization: `Bearer ${SECRET}` },
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const get = (DB, qs) => call(DB, `/api/archie/actions?${qs}`);
const D = '2026-10-06';
const PB = 'stacked-parent-merged';

const seeder = (db) => {
  const ins = db.prepare(`INSERT INTO archie_actions (dedupe_key, day, project, repo, pr, playbook, mode, action,
    outcome, why, evidence, attempts, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,1,'archie-fm',?,?)`);
  // key, day, repo, pr, mode, action, outcome, evidence, created_at
  return (k, day, repo, pr, m, a, o, ev, ts) =>
    ins.run(k, day, 'cromford', repo, pr, PB, m, a, o, 'w', JSON.stringify(ev), ts, ts);
};

test('BH-4784 archie ledger reads', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('B1 count_by=action counts the day by action, and only when asked', async () => {
    const { DB, db } = await openDb();
    const put = seeder(db);
    put('c1', D, 'example-org/cromford', 1, 'on', 'restack', 'done', {}, `${D}T01:00:00Z`);
    put('c2', D, 'example-org/cromford', 2, 'on', 'restack', 'failed', {}, `${D}T02:00:00Z`);
    put('c3', D, 'example-org/cromford', 3, 'on', 'noop', 'done', {}, `${D}T03:00:00Z`);
    put('c4', D, 'example-org/cromford', 4, 'on', 'fix_round', 'requested', {}, `${D}T04:00:00Z`);
    put('c5', D, 'example-org/cromford', 5, 'observe', 'would_restack', 'would', {}, `${D}T05:00:00Z`);

    const r = await get(DB, `day=${D}&playbook=${PB}&limit=1&count_by=action`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.count_by, 'action');
    assert.deepEqual(r.body.counts[PB].on, { restack: 2, noop: 1, fix_round: 1 });
    assert.deepEqual(r.body.counts[PB].observe, { would_restack: 1 });
    assert.equal(r.body.actions.length, 1, 'limit=1 shortens the list');
    assert.equal(r.body.truncated, true);

    const plain = await get(DB, `day=${D}&playbook=${PB}&limit=1`);
    assert.equal('count_by' in plain.body, false, 'no echo unless asked');
    assert.deepEqual(plain.body.counts[PB].on, { done: 2, failed: 1, requested: 1 }, 'by outcome, unchanged');
  });

  await t.test('B2 a count_by other than action is a 400', async () => {
    const { DB } = await openDb();
    for (const v of ['junk', 'outcome', '']) {
      const r = await get(DB, `day=${D}&count_by=${v}`);
      assert.equal(r.status, 400, v);
      assert.deepEqual(r.body, { error: 'count_by' }, v);
    }
  });

  await t.test('B3 repo=&pr= reads one PR across days, newest first; both or neither', async () => {
    const { DB, db } = await openDb();
    const put = seeder(db);
    put('p-old', '2026-10-04', 'acme/fixt', 2, 'on', 'restack', 'done', { old_head: 'a' }, '2026-10-04T09:00:00Z');
    put('p-new', D, 'acme/fixt', 2, 'on', 'restack', 'done', { old_head: 'b' }, `${D}T09:00:00Z`);
    put('p-other-pr', D, 'acme/fixt', 3, 'on', 'restack', 'done', {}, `${D}T10:00:00Z`);
    put('p-other-repo', D, 'acme/else', 2, 'on', 'restack', 'done', {}, `${D}T11:00:00Z`);

    const r = await get(DB, `repo=acme/fixt&pr=2&playbook=${PB}&limit=500`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(r.body.actions.map((a) => a.dedupe_key), ['p-new', 'p-old']);
    assert.deepEqual(r.body.actions[1].evidence, { old_head: 'a' });
    assert.equal(r.body.truncated, false);
    const dayToo = await get(DB, `day=${D}&repo=acme/fixt&pr=2`);
    assert.deepEqual(dayToo.body.actions.map((a) => a.dedupe_key), ['p-new'], 'a day narrows it further');

    for (const [qs, field] of [
      ['repo=acme/fixt', 'pr'], ['pr=2', 'repo'], ['repo=acme/fixt&pr=0', 'pr'], ['repo=acme/fixt&pr=abc', 'pr'],
      ['repo=acme/fixt&pr=1234567890', 'pr'], ['repo=bad&pr=2', 'repo'], ['', 'day'], [`project=cromford`, 'day'],
      [`day=${D}&repo=acme/fixt`, 'pr'],
    ]) {
      const b = await get(DB, qs);
      assert.equal(b.status, 400, qs);
      assert.deepEqual(b.body, { error: field }, qs);
    }
  });

  await t.test('B4 summary counts the pushes that ran no local suites', async () => {
    const { DB, db } = await openDb();
    const put = seeder(db);
    put('s1', D, 'acme/fixt', 1, 'on', 'restack', 'done', { local_suites: false }, `${D}T01:00:00Z`);
    put('s2', D, 'acme/fixt', 2, 'on', 'restack', 'done', { local_suites: false }, `${D}T02:00:00Z`);
    put('s3', D, 'acme/fixt', 3, 'on', 'restack', 'done', { local_suites: true }, `${D}T03:00:00Z`);
    put('s4', D, 'acme/fixt', 4, 'on', 'restack', 'done', {}, `${D}T04:00:00Z`);
    put('s5', D, 'acme/fixt', 5, 'on', 'restack', 'deferred', { local_suites: false }, `${D}T05:00:00Z`);
    put('s6', '2026-10-05', 'acme/fixt', 6, 'on', 'restack', 'done', { local_suites: false }, '2026-10-05T05:00:00Z');

    const s = await get(DB, `day=${D}&summary=1`);
    assert.equal(s.status, 200, JSON.stringify(s.body));
    assert.equal(s.body.no_local_suites, 2);
    assert.equal(s.body.restacked, 4);
    const empty = await get(DB, 'day=2020-01-01&summary=1');
    assert.equal(empty.body.no_local_suites, 0);
  });
});
