// BH-1574: the fleet GitHub-call ledger in D1 — every box's hourly aggregates of
// its state/gh-rest-ledger/ rows, pushed by bin/gh-ledger-push.sh and read back
// by bin/gh-quota-report.sh.
//
// WHY (2026-09-23 gh-reads audit). The hub App installation's bucket is shared by
// eight machines and every Fly builder, and bin/gh-quota-report.sh read only the
// files of the box it ran on — so ~5,000/h looked "unaccounted" when most of it
// was simply other boxes' ledgers nobody summed. The rows now live in one table.
//
// WHAT IS PINNED, on a REAL schema.sql database behind the node:sqlite shim and
// through the real worker.fetch (bearer, router and table all under test):
//   1. the belt DDL in core.js builds schema.sql's table, exactly;
//   2. a push is an UPSERT on the aggregate key: the box recomputes a whole hour
//      and re-sends it, so a re-push replaces, never doubles;
//   3. the read sums rows from TWO boxes, grouped the way the report prints;
//   4. validation refuses a row it cannot key, and a missing window;
//   5. retention is the `gh.ledger.retention_days` settings row, code default only
//      when the row is absent or unusable.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { CREATED_TABLES } from '../src/lib/core.js';

const SECRET = 'test-secret';

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

const shapeOf = (db) => db.prepare('PRAGMA table_info(gh_ledger)').all()
  .map((c) => `${c.name} ${c.type} notnull=${c.notnull} pk=${c.pk}`);

// One aggregate row the way bin/gh-ledger-push.sh builds it.
const row = (over = {}) => ({
  hour: '2026-09-23T03', lane: 'merge-conductor', project: 'project-4',
  meter: 'app-161623167', resource: 'graphql', method: 'POST', path_class: 'graphql',
  status: '200', source: 'gh', calls: 10, counted: 10,
  remaining_min: 4100, used_max: 900, limit_max: 5000, reset_max: 1790143200,
  ...over,
});

test('BH-1574 gh_ledger', async (t) => {
  const first = await openDb();
  if (first === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  await t.test('belt DDL == schema.sql table', async () => {
    const fromSchema = shapeOf(first.db);
    assert.ok(fromSchema.length > 0, 'schema.sql must create gh_ledger');
    const { DatabaseSync } = await import('node:sqlite');
    const belt = new DatabaseSync(':memory:');
    const stmts = CREATED_TABLES.gh_ledger;
    assert.ok(Array.isArray(stmts) && stmts.length >= 2, 'CREATED_TABLES.gh_ledger holds the table and its hour index');
    for (const s of stmts) belt.exec(s);
    assert.deepEqual(shapeOf(belt), fromSchema);
    const idx = belt.prepare(
      "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_gh_ledger_hour'"
    ).all();
    assert.equal(idx.length, 1, 'the belt creates idx_gh_ledger_hour');
  });

  await t.test('a fresh D1 self-creates the table on the first push', async () => {
    const fresh = await openDb();
    fresh.db.exec('DROP TABLE IF EXISTS gh_ledger');  // the fresh-D1 state; product code never drops
    const r = await call(fresh.DB, '/api/metrics/gh-ledger', { method: 'POST', body: { box: 'hub', rows: [row()] } });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(fresh.db.prepare('SELECT count(*) AS n FROM gh_ledger').get().n, 1);
  });

  await t.test('a re-push of the same hour REPLACES the aggregate, never doubles it', async () => {
    const { db, DB } = await openDb();
    let r = await call(DB, '/api/metrics/gh-ledger', { method: 'POST', body: { box: 'hub', rows: [row()] } });
    assert.equal(r.status, 200);
    assert.equal(r.body.accepted, 1);
    // The box recomputed the whole hour: more calls, a lower remaining.
    r = await call(DB, '/api/metrics/gh-ledger', {
      method: 'POST', body: { box: 'hub', rows: [row({ calls: 14, counted: 13, remaining_min: 3900 })] },
    });
    assert.equal(r.status, 200);
    const rows = db.prepare('SELECT calls, counted, remaining_min FROM gh_ledger').all();
    assert.equal(rows.length, 1, 'one aggregate key, one row');
    assert.deepEqual({ ...rows[0] }, { calls: 14, counted: 13, remaining_min: 3900 });
  });

  await t.test('the read sums rows from two boxes, per box / bucket / caller', async () => {
    const { DB } = await openDb();
    await call(DB, '/api/metrics/gh-ledger', { method: 'POST', body: { box: 'hub', rows: [
      row(),
      row({ lane: 'merge-sweep', resource: 'core', method: 'GET', path_class: 'repos/o/r/pulls/N', source: 'rest', calls: 5, counted: 4, remaining_min: 6000, used_max: 600, limit_max: 6600 }),
    ] } });
    await call(DB, '/api/metrics/gh-ledger', { method: 'POST', body: { box: 'pool-project-4-abc123', rows: [
      row({ lane: 'run-build.sh', calls: 7, counted: 7, remaining_min: 4000 }),
      // An hour outside the window must not be summed.
      row({ hour: '2026-09-22T20', calls: 1000, counted: 1000 }),
    ] } });
    const r = await call(DB, '/api/metrics/gh-ledger?since=2026-09-23T03&until=2026-09-23T03');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const rows = r.body.rows;
    const sum = (f) => rows.filter(f).reduce((a, x) => a + x.counted, 0);
    assert.equal(sum(() => true), 21, 'hub 10+4 and the pool machine 7');
    assert.equal(sum((x) => x.box === 'hub'), 14);
    assert.equal(sum((x) => x.box === 'pool-project-4-abc123'), 7);
    assert.equal(sum((x) => x.resource === 'graphql'), 17);
    const gq = rows.filter((x) => x.resource === 'graphql');
    assert.equal(Math.min(...gq.map((x) => x.remaining_min)), 4000, 'the lowest remaining seen in the window rides along');
    assert.ok(gq.every((x) => x.meter === 'app-161623167' && x.limit_max === 5000));
    assert.equal(r.body.truncated, false);
    // box filter
    const one = await call(DB, '/api/metrics/gh-ledger?since=2026-09-23T03&box=hub');
    assert.equal(one.body.rows.reduce((a, x) => a + x.counted, 0), 14);
  });

  await t.test('validation', async () => {
    const { DB } = await openDb();
    const noBox = await call(DB, '/api/metrics/gh-ledger', { method: 'POST', body: { rows: [row()] } });
    assert.equal(noBox.status, 400);
    const noRows = await call(DB, '/api/metrics/gh-ledger', { method: 'POST', body: { box: 'hub', rows: [] } });
    assert.equal(noRows.status, 400);
    const badHour = await call(DB, '/api/metrics/gh-ledger', { method: 'POST', body: { box: 'hub', rows: [row({ hour: 'today' })] } });
    assert.equal(badHour.status, 400, 'a row with no real hour is keyless and refused');
    const tooMany = await call(DB, '/api/metrics/gh-ledger', {
      method: 'POST', body: { box: 'hub', rows: new Array(2001).fill(row()) },
    });
    assert.equal(tooMany.status, 400);
    const noWindow = await call(DB, '/api/metrics/gh-ledger');
    assert.equal(noWindow.status, 400, 'an unbounded read of the whole table is refused');
    const badWindow = await call(DB, '/api/metrics/gh-ledger?since=yesterday');  // determinism: ok a malformed window, refused with a 400 before any read
    assert.equal(badWindow.status, 400);
  });

  await t.test('retention is the settings row, the code default only without one', async () => {
    const { db, DB } = await openDb();
    // A push dated 2026-09-23T03 with rows 3 and 40 days older.
    db.prepare("INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('gh.ledger.retention_days','2','test','test','2026-09-23T00:00:00Z')").run();
    const old = row({ hour: '2026-09-20T03', lane: 'old' });
    const older = row({ hour: '2026-08-14T03', lane: 'older' });
    await call(DB, '/api/metrics/gh-ledger', { method: 'POST', body: { box: 'hub', rows: [old, older, row()] } });
    const lanes = () => db.prepare('SELECT lane FROM gh_ledger ORDER BY lane').all().map((x) => x.lane);
    // Retention is measured from the NEWEST hour in the push, never from the wall
    // clock, so this test (and a replayed backlog) cannot pick its own red day.
    assert.deepEqual(lanes(), ['merge-conductor'], 'a 2-day setting keeps only the pushed hour');

    const d2 = await openDb();
    d2.db.prepare("DELETE FROM settings WHERE key='gh.ledger.retention_days'").run();
    await call(d2.DB, '/api/metrics/gh-ledger', { method: 'POST', body: { box: 'hub', rows: [old, older, row()] } });
    const l2 = d2.db.prepare('SELECT lane FROM gh_ledger ORDER BY lane').all().map((x) => x.lane);
    assert.deepEqual(l2, ['merge-conductor', 'old'], 'the 14-day code default keeps 3 days, drops 40');

    const d3 = await openDb();
    d3.db.prepare("INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('gh.ledger.retention_days','abc','test','test','2026-09-23T00:00:00Z')").run();
    await call(d3.DB, '/api/metrics/gh-ledger', { method: 'POST', body: { box: 'hub', rows: [old, older, row()] } });
    const l3 = d3.db.prepare('SELECT lane FROM gh_ledger ORDER BY lane').all().map((x) => x.lane);
    assert.deepEqual(l3, ['merge-conductor', 'old'], 'an unusable row falls back to the default, never to 0');
  });
});
