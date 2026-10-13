// BH-5635.0: pause_flags.value — PUT accepts and audits an optional value, and
// every flags route widens an old table (ensureColumns) before it reads or writes.
import test from 'node:test';
import assert from 'node:assert/strict';
import { call, iso, SECRET, worker } from '../lib/harness.js';

const inserts = (db, re) => db._calls.filter((c) => re.test(c.sql));
const ROW = (over) => ({ name: 'wip-limit-x', active: 1, actor: 'console', reason: null, updated_at: iso(60e3), value: null, ...over });

test('W1: PUT with a value binds it at index 5; W1b: no value binds null', async () => {
  const r = await call('/api/flags', { method: 'PUT', body: { name: 'wip-limit-x', active: 1, value: '5' } });
  assert.equal(r.status, 200);
  const ins = inserts(r.db, /INSERT INTO pause_flags/);
  assert.equal(ins.length, 1);
  assert.equal(ins[0].binds[5], '5');
  const b = await call('/api/flags', { method: 'PUT', body: { name: 'wip-limit-x', active: 1 } });
  assert.equal(b.status, 200);
  assert.equal(inserts(b.db, /INSERT INTO pause_flags/)[0].binds[5], null);
  const e = await call('/api/flags', { method: 'PUT', body: { name: 'wip-limit-x', active: 1, value: '' } });
  assert.equal(e.status, 200);
  assert.equal(inserts(e.db, /INSERT INTO pause_flags/)[0].binds[5], null, 'an empty value is stored as NULL');
});

test('W2: a value outside 64 chars of A-Za-z0-9._- is a 400 and writes nothing', async () => {
  for (const value of ['../x', '5; rm -rf', 'a'.repeat(65), 5, 'a b', ['5']]) {
    const r = await call('/api/flags', { method: 'PUT', body: { name: 'wip-limit-x', active: 1, value } });
    assert.equal(r.status, 400, `accepted ${JSON.stringify(value)}`);
    assert.match(r.body.error, /value must be/);
    assert.equal(inserts(r.db, /INSERT INTO/).length, 0, `wrote for ${JSON.stringify(value)}`);
  }
  const ok = await call('/api/flags', { method: 'PUT', body: { name: 'wip-limit-x', active: 1, value: 'a'.repeat(64) } });
  assert.equal(ok.status, 200, '64 chars is the limit, not past it');
});

test('W3: a value change with the same active writes exactly one audit row', async () => {
  const r = await call('/api/flags', {
    method: 'PUT', body: { name: 'wip-limit-x', active: 1, value: '5', actor: 'console' },
    state: { flags: [ROW({ value: '3' })] },
  });
  assert.equal(r.status, 200);
  const audit = inserts(r.db, /INSERT INTO config_changes/);
  assert.equal(audit.length, 1);
  assert.equal(audit[0].binds[2], '{"active":1,"value":"3"}');
  assert.equal(audit[0].binds[3], '{"active":1,"value":"5"}');
});

test('W4: a same-value write writes no audit row; a value-less write keeps the old audit shape', async () => {
  const same = await call('/api/flags', {
    method: 'PUT', body: { name: 'wip-limit-x', active: 1, value: '5' },
    state: { flags: [ROW({ value: '5' })] },
  });
  assert.equal(same.status, 200);
  assert.equal(inserts(same.db, /INSERT INTO config_changes/).length, 0);
  const plain = await call('/api/flags', {
    method: 'PUT', body: { name: 'paused-x', active: 1 },
    state: { flags: [ROW({ name: 'paused-x', active: 0 })] },
  });
  const audit = inserts(plain.db, /INSERT INTO config_changes/);
  assert.equal(audit.length, 1);
  assert.equal(audit[0].binds[3], '{"active":1}', 'value-less writes keep the BH-2377 after_json byte for byte');
});

test('W5: no bearer is a 401 and writes nothing', async () => {
  const r = await call('/api/flags', { method: 'PUT', secret: null, body: { name: 'wip-limit-x', active: 1, value: '5' } });
  assert.equal(r.status, 401);
  assert.equal(inserts(r.db, /INSERT INTO/).length, 0);
});

// E1 brings its own DB: the shared fake answers no PRAGMA for pause_flags, and
// addedColumnsReady is a WeakMap on the DB object, so each case gets a new one.
function oldTableDB({ alterThrows = false } = {}) {
  const calls = [];
  const stmt = (sql) => {
    const s = { _sql: sql, _binds: [] };
    s.bind = (...b) => { s._binds = b; return s; };
    s.first = async () => { calls.push({ sql, binds: s._binds }); return null; };
    s.all = async () => {
      calls.push({ sql, binds: s._binds });
      if (/PRAGMA table_info\(pause_flags\)/.test(sql)) {
        return { results: ['name', 'active', 'actor', 'reason', 'updated_at'].map((name) => ({ name })) };
      }
      return { results: [] };
    };
    s.run = async () => {
      calls.push({ sql, binds: s._binds });
      if (alterThrows && /ALTER TABLE pause_flags/.test(sql)) throw new Error('D1_ERROR: duplicate column name: value');
      return { meta: { changes: 1 } };
    };
    return s;
  };
  return { prepare: stmt, batch: async (xs) => xs.map(() => ({ meta: { changes: 1 } })), _calls: calls };
}
const get = (db, path) => worker.fetch(
  new Request(`https://jobs.test${path}`, { headers: { authorization: `Bearer ${SECRET}` } }),
  { DB: db, HARNESS_SECRET: SECRET },
);

test('E1: a GET on an old table adds the value column once; a duplicate-column ALTER is not an error', async () => {
  const db = oldTableDB();
  const r = await get(db, '/api/flags/x');
  assert.equal(r.status, 404);
  await get(db, '/api/flags/x');
  const alters = db._calls.filter((c) => /ALTER TABLE/.test(c.sql));
  assert.deepEqual(alters.map((c) => c.sql), ['ALTER TABLE pause_flags ADD COLUMN value TEXT']);
  const list = oldTableDB();
  assert.equal((await get(list, '/api/flags')).status, 200);
  assert.equal(list._calls.filter((c) => /ALTER TABLE pause_flags ADD COLUMN value TEXT/.test(c.sql)).length, 1,
    'the list route widens the table too');
  const dup = oldTableDB({ alterThrows: true });
  const d = await get(dup, '/api/flags/x');
  assert.equal(d.status, 404, 'a duplicate-column race must not turn a read into a 500');
  const put = oldTableDB();
  const w = await worker.fetch(new Request('https://jobs.test/api/flags', {
    method: 'PUT', headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify({ name: 'wip-limit-x', active: 1, value: '5' }),
  }), { DB: put, HARNESS_SECRET: SECRET });
  assert.equal(w.status, 200);
  assert.equal(put._calls.filter((c) => /ALTER TABLE pause_flags ADD COLUMN value TEXT/.test(c.sql)).length, 1,
    'PUT binds value, so it widens the table before its INSERT');
});
