// BH-3156 (BH-2325.1): the merge-queue PATCH and the held-page release each
// write one config_changes row in the same batch as their own write.
//
// Same fixture as conductor-held.bh-1201.test.js and for the same reason: a
// real schema.sql database behind the node:sqlite shim, every request through
// `worker.fetch` with the bearer (D2), and every assertion read back with SQL.
// Deleting either `...configChangeStmts(` spread turns A2 or A6 red.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

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

const audits = (db, kind) => db.prepare(
  'SELECT kind, name, before_json, after_json, actor, reason, at FROM config_changes WHERE kind=? ORDER BY id'
).all(kind);

const seedMq = (db, project, pr, status, reason = 'seeded') => db.prepare(
  `INSERT INTO merge_queue (project, pr, status, repo, reason, enqueued_by, enqueued_at, updated_at)
   VALUES (?, ?, ?, 'example-org/project-3', ?, 'sweep', '2026-09-28T00:00:00Z', '2026-09-28T00:00:00Z')`
).run(project, pr, status, reason);

const mqRow = (db, project, pr) => db.prepare(
  'SELECT * FROM merge_queue WHERE project=? AND pr=?').get(project, pr);

const KEY = {
  repo: 'example-org/cromford',
  number: 3156,
  state: 'WAIT_CI',
  head: 'b'.repeat(40),
  kind: 'STUCK',
};

test('BH-3156 merge-queue PATCH + held-page release audit', async (t) => {
  const opened = await openDb();
  if (opened === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }
  const { db, DB } = opened;

  await t.test('A1: GET /api/config-changes answers both new kinds', async () => {
    for (const kind of ['merge_queue', 'held_page']) {
      const r = await call(DB, `/api/config-changes?kind=${kind}`);
      assert.equal(r.status, 200, `kind=${kind}: ${JSON.stringify(r.body)}`);
      assert.ok(Array.isArray(r.body.changes), `kind=${kind} changes must be an array`);
    }
  });

  await t.test('A2: PATCH writes one merge_queue audit row, response unchanged', async () => {
    seedMq(db, 'project-3', 41, 'queued');
    const before = mqRow(db, 'project-3', 41);
    const r = await call(DB, '/api/merge-queue', {
      method: 'PATCH',
      body: { project: 'project-3', pr: 41, status: 'blocked', reason: 'r', actor: 'a@x' },
    });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const at = r.body.as_of;
    assert.deepEqual(r.body, {
      merge: { ...before, status: 'blocked', reason: 'r', updated_at: at },
      as_of: at,
    });
    const rows = audits(db, 'merge_queue');
    assert.equal(rows.length, 1, JSON.stringify(rows));
    assert.equal(rows[0].name, 'project-3#41');
    assert.deepEqual(JSON.parse(rows[0].before_json), { status: 'queued', reason: 'seeded' });
    assert.deepEqual(JSON.parse(rows[0].after_json), { status: 'blocked', reason: 'r' });
    assert.equal(rows[0].actor, 'a@x');
    assert.equal(rows[0].reason, 'r');
    assert.equal(rows[0].at, at);
    assert.equal(mqRow(db, 'project-3', 41).status, 'blocked');
  });

  await t.test('A2b: PATCH without actor records api', async () => {
    seedMq(db, 'project-3', 42, 'queued');
    const r = await call(DB, '/api/merge-queue', {
      method: 'PATCH', body: { project: 'project-3', pr: 42, status: 'dropped', reason: 'gone' },
    });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const row = audits(db, 'merge_queue').find((a) => a.name === 'project-3#42');
    assert.ok(row, 'an audit row for project-3#42');
    assert.equal(row.actor, 'api');
  });

  await t.test('A3: blocked->queued and dropped->queued are each audited', async () => {
    // project-3#41 is blocked (A2), project-3#42 is dropped (A2b).
    for (const [pr, from] of [[41, 'blocked'], [42, 'dropped']]) {
      const n0 = audits(db, 'merge_queue').length;
      const r = await call(DB, '/api/merge-queue', {
        method: 'PATCH', body: { project: 'project-3', pr, status: 'queued', reason: 'retry', actor: 'op' },
      });
      assert.equal(r.status, 200, JSON.stringify(r.body));
      const rows = audits(db, 'merge_queue');
      assert.equal(rows.length, n0 + 1, `${from}->queued adds one row`);
      const last = rows[rows.length - 1];
      assert.equal(last.name, `project-3#${pr}`);
      assert.equal(JSON.parse(last.before_json).status, from);
      assert.deepEqual(JSON.parse(last.after_json), { status: 'queued', reason: 'retry' });
    }
  });

  await t.test('A4: queued->dropped is audited', async () => {
    const n0 = audits(db, 'merge_queue').length;
    const r = await call(DB, '/api/merge-queue', {
      method: 'PATCH', body: { project: 'project-3', pr: 41, status: 'dropped', reason: 'closed', actor: 'op' },
    });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const rows = audits(db, 'merge_queue');
    assert.equal(rows.length, n0 + 1);
    const last = rows[rows.length - 1];
    assert.deepEqual(JSON.parse(last.before_json), { status: 'queued', reason: 'retry' });
    assert.deepEqual(JSON.parse(last.after_json), { status: 'dropped', reason: 'closed' });
  });

  await t.test('A5: 404, 409 and an unchanged write add no audit row', async () => {
    const n0 = audits(db, 'merge_queue').length;

    const miss = await call(DB, '/api/merge-queue', {
      method: 'PATCH', body: { project: 'project-3', pr: 999, status: 'blocked', reason: 'x' },
    });
    assert.equal(miss.status, 404);
    assert.equal(mqRow(db, 'project-3', 999), undefined);
    assert.equal(audits(db, 'merge_queue').length, n0, '404 writes no audit');

    // landed -> blocked is not in MERGE_TRANSITIONS.
    seedMq(db, 'project-3', 43, 'landed', 'merged');
    const rowBefore = mqRow(db, 'project-3', 43);
    const bad = await call(DB, '/api/merge-queue', {
      method: 'PATCH', body: { project: 'project-3', pr: 43, status: 'blocked', reason: 'x' },
    });
    assert.equal(bad.status, 409, JSON.stringify(bad.body));
    assert.deepEqual(mqRow(db, 'project-3', 43), rowBefore, '409 leaves the row unchanged');
    assert.equal(audits(db, 'merge_queue').length, n0, '409 writes no audit');

    // project-3#42 is queued/'retry' after A3; the same status + reason again.
    const same = await call(DB, '/api/merge-queue', {
      method: 'PATCH', body: { project: 'project-3', pr: 42, status: 'queued', reason: 'retry', actor: 'op' },
    });
    assert.equal(same.status, 200, JSON.stringify(same.body));
    assert.equal(audits(db, 'merge_queue').length, n0, 'unchanged status+reason writes no audit');
  });

  await t.test('A6: release writes one held_page audit row', async () => {
    const put = await call(DB, '/api/conductor/held', {
      method: 'PUT', body: { ...KEY, text: 'stuck 40m', mode: 'merge' },
    });
    assert.equal(put.status, 200, JSON.stringify(put.body));
    const r = await call(DB, '/api/conductor/held/release', {
      method: 'POST', body: { ...KEY, why: 'manual', actor: 'a@x' },
    });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(r.body, { released: 1 });
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM conductor_held_pages').get().n, 0);
    const rows = audits(db, 'held_page');
    assert.equal(rows.length, 1, JSON.stringify(rows));
    assert.equal(rows[0].name, 'example-org/cromford#3156');
    assert.equal(rows[0].after_json, 'null');
    const was = JSON.parse(rows[0].before_json);
    assert.deepEqual(Object.keys(was), ['state', 'head', 'kind', 'text', 'mode', 'first_held_at']);
    assert.equal(was.state, 'WAIT_CI');
    assert.equal(was.head, KEY.head);
    assert.equal(was.text, 'stuck 40m');
    assert.equal(was.mode, 'merge');
    assert.equal(rows[0].reason, 'manual');
    assert.equal(rows[0].actor, 'a@x');
  });

  await t.test('A7: a replayed release is {released:0} with no audit row', async () => {
    const n0 = audits(db, 'held_page').length;
    const r = await call(DB, '/api/conductor/held/release', {
      method: 'POST', body: { ...KEY, why: 'manual', actor: 'a@x' },
    });
    assert.equal(r.status, 200);
    assert.deepEqual(r.body, { released: 0 });
    assert.equal(audits(db, 'held_page').length, n0);
  });

  await t.test('A7b: a blank why is a 400 that deletes and audits nothing', async () => {
    await call(DB, '/api/conductor/held', {
      method: 'PUT', body: { ...KEY, text: 'stuck again', mode: 'merge' },
    });
    const n0 = audits(db, 'held_page').length;
    const r = await call(DB, '/api/conductor/held/release', {
      method: 'POST', body: { ...KEY, why: '', actor: 'a@x' },
    });
    assert.equal(r.status, 400);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM conductor_held_pages').get().n, 1);
    assert.equal(audits(db, 'held_page').length, n0);
  });
});
