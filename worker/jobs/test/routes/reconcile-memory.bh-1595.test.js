// BH-1610 (BH-1595.3): the reconcile-prs memory routes, driven through the
// REAL worker.fetch on a real SQLite database with schema.sql applied, so the
// monotonic open upsert, the deletes and the all-or-nothing batch are the
// worker's own SQL.
//
// The shared D1 shim runs batch() as independent statements. Real D1 runs a
// batch as ONE transaction, so W5/W6 use a local wrapper that does the same
// (BEGIN … COMMIT, ROLLBACK on a throw). A route that wrote through separate
// run() calls instead of one batch would leave the first row behind in W6.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { openDb, d1 } from '../lib/d1-sqlite.bh-1030.js';

const SECRET = 's';
const PATH = '/api/reconcile-prs/memory';
const call = (DB, method, body) => worker.fetch(
  new Request(`https://jobs.test${PATH}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

// A D1 whose batch is a transaction, as the real one is. `failAt` makes the
// n-th write inside a batch throw (1-based), to prove nothing before it lands.
function txDb(db, opts = {}) {
  let inBatch = false; let n = 0;
  const base = d1(db, {
    beforeRun() {
      if (!inBatch) return;
      n += 1;
      if (opts.failAt && n === opts.failAt) throw new Error('injected: statement failed mid-batch');
    },
  });
  return {
    prepare: base.prepare,
    async batch(stmts) {
      inBatch = true; n = 0;
      db.exec('BEGIN');
      try {
        const out = [];
        for (const s of stmts) out.push(await s.run());
        db.exec('COMMIT');
        return out;
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      } finally { inBatch = false; }
    },
  };
}

async function fresh(t, opts) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  return { db: o.db, DB: txDb(o.db, opts) };
}

const seed = (db, kind, name, value) => db.prepare(
  "INSERT INTO reconcile_memory (kind, name, value, updated_at) VALUES (?, ?, ?, '2026-09-01T00:00:00Z')",
).run(kind, name, value);
const all = (db) => db.prepare('SELECT kind, name, value FROM reconcile_memory ORDER BY kind, name').all()
  .map((r) => ({ ...r }));
const val = (db, kind, name) => {
  const r = db.prepare('SELECT value FROM reconcile_memory WHERE kind=? AND name=?').get(kind, name);
  return r ? r.value : undefined;
};

test('W1 GET answers rows capped at 5000 with a measured truncated flag, ordered by kind,name', async (t) => {
  const o = await fresh(t); if (!o) return;
  const ins = o.db.prepare("INSERT INTO reconcile_memory (kind, name, value, updated_at) VALUES (?, ?, 'v', '2026-09-01T00:00:00Z')");
  o.db.exec('BEGIN');
  for (let i = 0; i < 5001; i += 1) ins.run(['terminal', 'open', 'gone'][i % 3], `n${String(i).padStart(5, '0')}`);
  o.db.exec('COMMIT');
  const r = await call(o.DB, 'GET');
  assert.equal(r.status, 200, JSON.stringify(r).slice(0, 300));
  assert.equal(r.body.rows.length, 5000);
  assert.equal(r.body.truncated, true);
  assert.equal(typeof r.body.as_of, 'string');
  const keys = r.body.rows.map((x) => `${x.kind}\u0000${x.name}`);
  assert.deepEqual(keys, [...keys].sort(), 'rows ordered by kind, name');
  for (const k of ['kind', 'name', 'value', 'updated_at']) assert.ok(k in r.body.rows[0], `row has ${k}`);

  const small = await fresh(t); if (!small) return;
  seed(small.db, 'open', 'a', '2026-09-23T10:00:00Z');
  seed(small.db, 'gone', 'b', '1790000000');
  seed(small.db, 'terminal', 'c', '{"STATE":"MERGED"}');
  const s = await call(small.DB, 'GET');
  assert.equal(s.status, 200);
  assert.equal(s.body.rows.length, 3);
  assert.equal(s.body.truncated, false);
  assert.deepEqual(s.body.rows.map((x) => x.kind), ['gone', 'open', 'terminal']);
});

test('W2 an open upsert never moves the watermark backwards', async (t) => {
  const o = await fresh(t); if (!o) return;
  const up = (value) => call(o.DB, 'PUT', { upserts: [{ kind: 'open', name: 'x', value }] });
  let r = await up('2026-09-23T10:00:00Z');
  assert.equal(r.status, 200, JSON.stringify(r));
  assert.deepEqual(r.body, { ok: true, upserts: 1, deletes: 0 });
  r = await up('2026-09-23T09:00:00Z');
  assert.equal(r.status, 200);
  assert.equal(val(o.db, 'open', 'x'), '2026-09-23T10:00:00Z', 'an older stamp must not win');
  await up('2026-09-23T11:00:00Z');
  assert.equal(val(o.db, 'open', 'x'), '2026-09-23T11:00:00Z', 'a newer stamp moves it');
});

test('W3 terminal and gone are last-writer-wins, even with a smaller value', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, 'terminal', 'p', '{"STATE":"MERGED","z":1}');
  seed(o.db, 'gone', 'r', '1790000000');
  const r = await call(o.DB, 'PUT', { upserts: [
    { kind: 'terminal', name: 'p', value: '{"STATE":"CLOSED"}' },
    { kind: 'gone', name: 'r', value: '1700000000' },
  ] });
  assert.equal(r.status, 200, JSON.stringify(r));
  assert.equal(val(o.db, 'terminal', 'p'), '{"STATE":"CLOSED"}');
  assert.equal(val(o.db, 'gone', 'r'), '1700000000');
});

test('W4 deletes remove only the named (kind,name); an absent key is fine', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, 'terminal', 'k', 't');
  seed(o.db, 'open', 'k', '2026-09-23T10:00:00Z');
  const r = await call(o.DB, 'PUT', { deletes: [{ kind: 'terminal', name: 'k' }, { kind: 'gone', name: 'nope' }] });
  assert.equal(r.status, 200, JSON.stringify(r));
  assert.deepEqual(r.body, { ok: true, upserts: 0, deletes: 2 });
  assert.deepEqual(all(o.db), [{ kind: 'open', name: 'k', value: '2026-09-23T10:00:00Z' }]);
  const empty = await call(o.DB, 'PUT', {});
  assert.deepEqual([empty.status, empty.body], [200, { ok: true, upserts: 0, deletes: 0 }]);
});

test('W5 one bad entry, or too many, is 400 for the whole body and writes nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, 'open', 'keep', '2026-09-23T10:00:00Z');
  const before = all(o.db);
  const good = Array.from({ length: 10 }, (_, i) => ({ kind: 'terminal', name: `g${i}`, value: 'v' }));
  const bodies = {
    'kind failed': { upserts: [...good, { kind: 'failed', name: 'a', value: 'v' }] },
    'name ..': { upserts: [...good, { kind: 'open', name: '..', value: 'v' }] },
    'name .': { deletes: [{ kind: 'open', name: '.' }], upserts: good },
    'name a/b': { upserts: [...good, { kind: 'open', name: 'a/b', value: 'v' }] },
    'name 129': { upserts: [...good, { kind: 'open', name: 'a'.repeat(129), value: 'v' }] },
    'empty name': { upserts: [...good, { kind: 'open', name: '', value: 'v' }] },
    'empty value': { upserts: [...good, { kind: 'gone', name: 'e', value: '' }] },
    'value 4097': { upserts: [...good, { kind: 'gone', name: 'e', value: 'x'.repeat(4097) }] },
    'bad delete kind': { upserts: good, deletes: [{ kind: 'failed', name: 'keep' }] },
    '501 entries': { upserts: Array.from({ length: 300 }, (_, i) => ({ kind: 'open', name: `u${i}`, value: 'v' })),
      deletes: Array.from({ length: 201 }, (_, i) => ({ kind: 'open', name: `d${i}` })) },
    'upserts not an array': { upserts: 'x' },
    'deletes not an array': { deletes: { kind: 'open', name: 'keep' } },
  };
  for (const [label, body] of Object.entries(bodies)) {
    const r = await call(o.DB, 'PUT', body);
    assert.equal(r.status, 400, `${label}: ${JSON.stringify(r)}`);
    assert.equal(typeof r.body.error, 'string', label);
    assert.deepEqual(all(o.db), before, `${label}: nothing may be written on a 400`);
  }
  const at128 = await call(o.DB, 'PUT', { upserts: [{ kind: 'open', name: 'a'.repeat(128), value: 'v' }] });
  assert.equal(at128.status, 200, '128 chars is the limit, not over it');
  const exact500 = await call(o.DB, 'PUT', { upserts: Array.from({ length: 500 }, (_, i) => ({ kind: 'gone', name: `z${i}`, value: '1' })) });
  assert.equal(exact500.status, 200, '500 entries is allowed');
});

test('W6 a statement failing mid-batch leaves nothing behind (one DB.batch, 503 via d1Guarded)', async (t) => {
  const o = await fresh(t, { failAt: 2 }); if (!o) return;
  const r = await call(o.DB, 'PUT', { upserts: [
    { kind: 'terminal', name: 'first', value: 'v1' },
    { kind: 'terminal', name: 'second', value: 'v2' },
  ] });
  assert.equal(r.status, 503, JSON.stringify(r));
  assert.equal(val(o.db, 'terminal', 'first'), undefined, 'the first statement must roll back with the second');
  assert.deepEqual(all(o.db), []);
});
