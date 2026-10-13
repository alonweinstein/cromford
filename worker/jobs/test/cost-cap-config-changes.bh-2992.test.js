// BH-2996 (BH-2992.2, item 2): a cost-cap write lands a `cost_cap` config_changes
// row next to its cost_cap_changes row, in the same batch, on BOTH paths that
// write a cap (PUT /api/cost-caps and the PUT /api/settings cap branch, D15).
//
// WHAT IS PINNED, on a REAL schema.sql database behind the node:sqlite shim and
// through the real worker.fetch:
//   C1  a cap PUT gives 1 cost_cap_changes row and 1 cost_cap config_changes row;
//   C2  the same value again gives 0 and 0;
//   C3  PUT /api/settings of a fleet cap key gives 1 and 1;
//   C3b PUT /api/settings of a box-suffixed cap key gives 1 and 1;
//   C4  POST /api/cost-caps/seed gives 0 config_changes rows.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, clearCapSeeds } from './lib/d1-sqlite.bh-1030.js';

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

const cfg = (db) => db.prepare("SELECT * FROM config_changes WHERE kind='cost_cap' ORDER BY id").all();
const nCfg = (db) => db.prepare('SELECT count(*) AS n FROM config_changes').get().n;
const nCap = (db) => db.prepare('SELECT count(*) AS n FROM cost_cap_changes').get().n;

async function withDb(t, fn) {
  const opened = await openDb();
  if (opened === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }
  clearCapSeeds(opened.db); // BH-4155: start from a table with no cap row
  await fn(opened);
}

const K = 'conf.cost-caps.budget.project-5';

test('C1 a cap PUT writes one cost_cap_changes row and one cost_cap config_changes row', (t) => withDb(t, async ({ db, DB }) => {
  const r = await call(DB, '/api/cost-caps', { body: { key: K, value: '250 3', reason: 'r1', actor: 'console' } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(nCap(db), 1);
  assert.equal(nCfg(db), 1);
  let rows = cfg(db);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].name, K);
  assert.equal(rows[0].before_json, null);
  assert.deepEqual(JSON.parse(rows[0].after_json), { value: '250 3' });
  assert.equal(rows[0].actor, 'console');
  assert.equal(rows[0].reason, 'r1');

  const moved = await call(DB, '/api/cost-caps', { body: { key: K, value: '300 3', reason: 'bump', actor: 'operator' } });
  assert.equal(moved.status, 200);
  assert.equal(nCap(db), 2);
  rows = cfg(db);
  assert.equal(rows.length, 2);
  assert.equal(rows[1].before_json, rows[0].after_json);
  assert.deepEqual(JSON.parse(rows[1].after_json), { value: '300 3' });
  assert.equal(rows[1].actor, 'operator');
  assert.equal(rows[1].reason, 'bump');
}));

test('C2 an unchanged cap PUT writes 0 and 0', (t) => withDb(t, async ({ db, DB }) => {
  assert.equal((await call(DB, '/api/cost-caps', { body: { key: K, value: '250 3', reason: 'r1' } })).status, 200);
  const again = await call(DB, '/api/cost-caps', { body: { key: K, value: ' 250 3 ', reason: 'r2' } });
  assert.equal(again.status, 200);
  assert.equal(again.body.unchanged, true);
  assert.equal(nCap(db), 1);
  assert.equal(nCfg(db), 1);
}));

for (const [label, key] of [['C3', 'conf.cost-caps.default'], ['C3b', 'conf.cost-caps.default.hub-1']]) {
  test(`${label} PUT /api/settings of ${key} writes 1 and 1`, (t) => withDb(t, async ({ db, DB }) => {
    const r = await call(DB, '/api/settings', { body: { key, value: '100 5', reason: 'why', actor: 'a@x' } });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(nCap(db), 1);
    assert.equal(nCfg(db), 1);
    const rows = cfg(db);
    assert.equal(rows[0].name, key);
    assert.equal(rows[0].before_json, null);
    assert.equal(rows[0].after_json, '{"value":"100 5"}');
    assert.equal(rows[0].actor, 'a@x');
    assert.equal(rows[0].reason, 'why');

    const same = await call(DB, '/api/settings', { body: { key, value: '100 5', actor: 'a@x' } });
    assert.equal(same.status, 200);
    assert.equal(nCap(db), 1);
    assert.equal(nCfg(db), 1, 'an unchanged settings write is not a row');
  }));
}

test('C4 POST /api/cost-caps/seed writes no config_changes row', (t) => withDb(t, async ({ db, DB }) => {
  const r = await call(DB, '/api/cost-caps/seed', {
    method: 'POST', body: { rows: [{ key: K, value: '100 5' }, { key: 'conf.cost-caps.ceiling', value: '3000' }] },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(nCfg(db), 0);
}));
