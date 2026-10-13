// BH-2632 (BH-2517.1): the audited flake quarantine routes, driven through the
// REAL router (worker.fetch) against a real schema.sql database over
// node:sqlite. The batch shim here runs every statement inside one
// BEGIN/COMMIT and answers [{results}], the way D1's batch does, and counts
// its calls so the one-transaction write is pinned rather than assumed.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { openDb, d1 } from '../lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';

function withBatch(db) {
  const base = d1(db);
  const DB = {
    batches: 0,
    prepare: (sql) => base.prepare(sql),
    async batch(stmts) {
      DB.batches++;
      db.exec('BEGIN');
      try {
        const out = [];
        for (const s of stmts) out.push(await s.all());
        db.exec('COMMIT');
        return out;
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
    },
  };
  return DB;
}

async function open() {
  const o = await openDb();
  if (o === null) return null;
  return { db: o.db, DB: withBatch(o.db) };
}

const call = (DB, path, { method = 'GET', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const put = (DB, body) => call(DB, '/api/metrics/flakes/quarantine', { method: 'PUT', body });
const count = (db, table) => db.prepare(`SELECT count(*) AS n FROM ${table}`).get().n;
const OK = { repo: 'o/r', test: 't1', active: 1, reason: 'flaky on the runner', actor: 'operator' };

test('BH-2632 flake quarantine routes', async (t) => {
  const probe = await open();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('PUT refuses bad input with a 400 and writes nothing', async () => {
    const { db, DB } = await open();
    const cases = [
      [{ ...OK, reason: undefined }, 'no reason'],
      [{ ...OK, reason: '   ' }, 'blank reason'],
      [{ ...OK, reason: 'x'.repeat(513) }, '513-char reason'],
      [{ ...OK, actor: undefined }, 'no actor'],
      [{ ...OK, test: 'job:x' }, 'job: test'],
      [{ ...OK, test: 'workflow:y' }, 'workflow: test'],
      [{ ...OK, test: 'x'.repeat(513) }, '513-char test'],
      [{ ...OK, repo: undefined }, 'no repo'],
      [{ ...OK, active: 'yes' }, 'active "yes"'],
      [{ ...OK, active: '1' }, 'active "1"'],
      [{ ...OK, active: 2 }, 'active 2'],
      [{ ...OK, active: undefined }, 'no active'],
    ];
    for (const [body, why] of cases) {
      const r = await put(DB, body);
      assert.equal(r.status, 400, `${why}: ${JSON.stringify(r.body)}`);
      assert.equal(typeof r.body.error, 'string', why);
    }
    assert.equal(count(db, 'flaky_quarantine'), 0);
    assert.equal(count(db, 'flaky_quarantine_changes'), 0);
    assert.equal(DB.batches, 0);
  });

  await t.test('PUT on, off, same-state: one batch each, audited before/after', async () => {
    const { db, DB } = await open();
    const on = await put(DB, { ...OK, test: '  t1  ' });
    assert.equal(on.status, 200, JSON.stringify(on.body));
    assert.equal(on.body.ok, true);
    assert.equal(on.body.changed, true);
    assert.equal(on.body.row.active, 1);
    assert.equal(on.body.row.test, 't1', 'the test name is trimmed at write');
    assert.equal(on.body.row.actor, 'operator');
    assert.equal(DB.batches, 1);
    let ch = db.prepare('SELECT * FROM flaky_quarantine_changes ORDER BY id').all();
    assert.equal(ch.length, 1);
    assert.equal(ch[0].before_active, null);
    assert.equal(ch[0].after_active, 1);
    assert.equal(ch[0].reason, 'flaky on the runner');

    const off = await put(DB, { ...OK, active: false, reason: 'fixed upstream', actor: 'ops' });
    assert.equal(off.status, 200);
    assert.equal(off.body.changed, true);
    assert.equal(off.body.row.active, 0);
    assert.equal(off.body.row.reason, 'fixed upstream');
    assert.equal(DB.batches, 2);
    ch = db.prepare('SELECT * FROM flaky_quarantine_changes ORDER BY id').all();
    assert.equal(ch.length, 2);
    assert.equal(ch[1].before_active, 1);
    assert.equal(ch[1].after_active, 0);
    assert.equal(ch[1].actor, 'ops');

    const same = await put(DB, { ...OK, active: 0 });
    assert.equal(same.status, 200);
    assert.equal(same.body.changed, false);
    assert.equal(same.body.row.active, 0);
    assert.equal(count(db, 'flaky_quarantine_changes'), 3, 'a same-state toggle is still audited');
    assert.equal(count(db, 'flaky_quarantine'), 1);
  });

  await t.test('GET quarantine filters by repo and active, newest first', async () => {
    const { db, DB } = await open();
    await put(DB, { ...OK, test: 'a' });
    await put(DB, { ...OK, test: 'b', active: 0 });
    await put(DB, { ...OK, repo: 'o/x', test: 'c' });
    db.prepare("UPDATE flaky_quarantine SET updated_at='2026-01-01T00:00:00Z' WHERE test='a'").run();
    await put(DB, { ...OK, test: 'd' });
    const g = await call(DB, '/api/metrics/flakes/quarantine?repo=o/r&active=1');
    assert.equal(g.status, 200);
    assert.deepEqual(g.body.rows.map((r) => r.test), ['d', 'a']);
    assert.equal(g.body.truncated, false);
    const all = await call(DB, '/api/metrics/flakes/quarantine?repo=o/r');
    assert.deepEqual(all.body.rows.map((r) => r.test).sort(), ['a', 'b', 'd']);
    const off = await call(DB, '/api/metrics/flakes/quarantine?active=0');
    assert.deepEqual(off.body.rows.map((r) => r.test), ['b']);
    for (const bad of ['yes', 'true', '2']) {
      const r = await call(DB, `/api/metrics/flakes/quarantine?active=${bad}`);
      assert.equal(r.status, 400, `active=${bad}`);
    }
  });

  await t.test('GET quarantine caps at 2000 and says so', async () => {
    const { db, DB } = await open();
    const ins = db.prepare("INSERT INTO flaky_quarantine VALUES ('o/r', ?, 1, 'a', 'r', ?)");
    db.exec('BEGIN');
    for (let i = 0; i < 2001; i++) ins.run(`t${i}`, `2026-09-26T00:00:${String(i % 60).padStart(2, '0')}Z`);
    db.exec('COMMIT');
    const g = await call(DB, '/api/metrics/flakes/quarantine?repo=o/r&active=1');
    assert.equal(g.status, 200);
    assert.equal(g.body.rows.length, 2000);
    assert.equal(g.body.truncated, true);
    db.prepare("DELETE FROM flaky_quarantine WHERE test='t0'").run();
    const h = await call(DB, '/api/metrics/flakes/quarantine?repo=o/r&active=1');
    assert.equal(h.body.rows.length, 2000);
    assert.equal(h.body.truncated, false);
  });

  await t.test('GET changes is newest first, filters, and honours the limit', async () => {
    const { DB } = await open();
    await put(DB, { ...OK, active: 1 });
    await put(DB, { ...OK, active: 0 });
    await put(DB, { ...OK, active: 1 });
    await put(DB, { ...OK, test: 'other' });
    const two = await call(DB, '/api/metrics/flakes/quarantine/changes?repo=o/r&test=t1&limit=2');
    assert.equal(two.status, 200);
    assert.equal(two.body.changes.length, 2);
    assert.ok(two.body.changes[0].id > two.body.changes[1].id);
    assert.deepEqual(two.body.changes.map((c) => [c.before_active, c.after_active]), [[0, 1], [1, 0]]);
    const def = await call(DB, '/api/metrics/flakes/quarantine/changes');
    assert.equal(def.status, 200);
    assert.equal(def.body.changes.length, 4);
    for (const bad of ['0', '201', 'abc', '2.5']) {
      const r = await call(DB, `/api/metrics/flakes/quarantine/changes?limit=${bad}`);
      assert.equal(r.status, 400, `limit=${bad}`);
    }
  });

  await t.test('GET changes defaults to 50', async () => {
    const { db, DB } = await open();
    const ins = db.prepare("INSERT INTO flaky_quarantine_changes (repo,test,before_active,after_active,actor,reason,at) VALUES ('o/r','t',0,1,'a','r','2026-09-26T00:00:00Z')");
    for (let i = 0; i < 60; i++) ins.run();
    const def = await call(DB, '/api/metrics/flakes/quarantine/changes');
    assert.equal(def.body.changes.length, 50);
    assert.equal(def.body.changes[0].id, 60);
    const max = await call(DB, '/api/metrics/flakes/quarantine/changes?limit=200');
    assert.equal(max.body.changes.length, 60);
  });

  await t.test('an unapplied schema is the house 503', async () => {
    const { DatabaseSync } = await import('node:sqlite');
    const DB = withBatch(new DatabaseSync(':memory:'));
    const p = await put(DB, OK);
    assert.equal(p.status, 503);
    assert.match(p.body.error, /flaky_quarantine schema not applied/);
    const g = await call(DB, '/api/metrics/flakes/quarantine');
    assert.equal(g.status, 503);
    const c = await call(DB, '/api/metrics/flakes/quarantine/changes');
    assert.equal(c.status, 503);
    assert.match(c.body.error, /flaky_quarantine_changes schema not applied/);
  });

  await t.test('GET /api/metrics/flakes is not shadowed', async () => {
    const { DB } = await open();
    const r = await call(DB, '/api/metrics/flakes');
    assert.equal(r.status, 200);
    assert.deepEqual(r.body.flakes, []);
  });
});
