// BH-2996 (BH-2992.2, item 4): DELETE /api/rules writes a concurrency_rule
// config_changes delete row in the same batch as the DELETE.
//
// WHAT IS PINNED, on a REAL schema.sql database behind the node:sqlite shim and
// through the real worker.fetch:
//   D1  PUT then DELETE gives 2 rows; row 2's before_json is row 1's after_json,
//       its after_json is the text 'null', and it carries actor and reason;
//   D2  a second DELETE (the rule is gone) adds no row and answers deleted: 0;
//   D3  a 400 DELETE (bad scope) adds no row and deletes nothing.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';

const call = (DB, path, { method = 'PUT', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};

const rows = (db) => db.prepare("SELECT * FROM config_changes WHERE kind='concurrency_rule' ORDER BY id").all();
const total = (db) => db.prepare('SELECT count(*) AS n FROM config_changes').get().n;
// schema.sql seeds rules of its own, so count only the rule under test.
const nRules = (db) => db.prepare(
  "SELECT count(*) AS n FROM concurrency_rules WHERE scope='repo' AND selector='execute/project-3/claude' AND kind='build'",
).get().n;

async function withDb(t, fn) {
  const opened = await openDb();
  if (opened === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }
  await fn(opened);
}

const RULE = { scope: 'repo', selector: 'execute/project-3/claude', kind: 'build' };
const NAME = 'repo/execute/project-3/claude/build';

test('D1 PUT then DELETE writes a delete row whose before is the last after', (t) => withDb(t, async ({ db, DB }) => {
  const put = await call(DB, '/api/rules', { body: { ...RULE, max_concurrent: 2, note: 'n', actor: 'a@x', reason: 'add' } });
  assert.equal(put.status, 200);
  const del = await call(DB, '/api/rules', { method: 'DELETE', body: { ...RULE, actor: 'b@x', reason: 'unlimited' } });
  assert.equal(del.status, 200);
  assert.equal(del.body.deleted, 1);
  assert.equal(nRules(db), 0);
  const r = rows(db);
  assert.equal(r.length, 2);
  assert.equal(r[1].name, NAME);
  assert.equal(r[1].before_json, r[0].after_json);
  assert.deepEqual(JSON.parse(r[1].before_json),
    { scope: 'repo', selector: 'execute/project-3/claude', kind: 'build', max_concurrent: 2, note: 'n' });
  assert.equal(r[1].after_json, 'null');
  assert.equal(r[1].actor, 'b@x');
  assert.equal(r[1].reason, 'unlimited');
}));

test('D2 a second DELETE adds no row and answers deleted: 0', (t) => withDb(t, async ({ db, DB }) => {
  assert.equal((await call(DB, '/api/rules', { body: { ...RULE, max_concurrent: 2 } })).status, 200);
  assert.equal((await call(DB, '/api/rules', { method: 'DELETE', body: RULE })).body.deleted, 1);
  assert.equal(total(db), 2);
  const again = await call(DB, '/api/rules', { method: 'DELETE', body: { ...RULE, actor: 'a@x', reason: 'again' } });
  assert.equal(again.status, 200);
  assert.equal(again.body.deleted, 0);
  assert.equal(total(db), 2);
}));

test('D3 a 400 DELETE adds no row and deletes nothing', (t) => withDb(t, async ({ db, DB }) => {
  assert.equal((await call(DB, '/api/rules', { body: { ...RULE, max_concurrent: 2 } })).status, 200);
  const bad = await call(DB, '/api/rules', { method: 'DELETE', body: { ...RULE, scope: 'nope', actor: 'a@x', reason: 'x' } });
  assert.equal(bad.status, 400);
  assert.equal(total(db), 1);
  assert.equal(nRules(db), 1);
}));
