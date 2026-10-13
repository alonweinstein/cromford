import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-2718 (BH-2531.1) — GET/PUT /api/product-proposals, the rows
// bin/lib/proposal-rows.sh reads and writes.
//
// Driven through the real worker.fetch (D2) over the real schema.sql in
// node:sqlite, so the route table, the bearer, body parsing and the SQL itself
// are what run. The one answer that matters most is the 404: the client reads
// `{"error":"proposal not found"}` as "never posted" and nothing else as that,
// so W4 pins the exact body and W5/W6 pin that a bad request or a missing table
// never produces it.

const SECRET = 'test-secret';
const NOW_MS = Date.parse('2026-09-26T09:00:00Z');

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb();
  if (!env) t.skip('node:sqlite unavailable on this runtime');
  return env;
}

async function call(DB, method, path, body, { secret = SECRET } = {}) {
  const init = { method, headers: {} };
  if (secret !== null) init.headers.authorization = `Bearer ${secret}`;
  if (body !== undefined) {
    init.body = typeof body === 'string' ? body : JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

const put = (DB, b, o) => call(DB, 'PUT', '/api/product-proposals', b, o);
const read = (db, p, s) => db.prepare('SELECT * FROM product_proposals WHERE project=? AND proposal_id=?').get(p, s);

// A DB that counts every prepare, so "refused before any DB call" is measured.
function counting(DB) {
  const c = { n: 0 };
  return { c, DB: { ...DB, prepare(sql) { c.n++; return DB.prepare(sql); } } };
}

test('W1: PUT stores the row and GET one answers it', async (t) => {
  const env = await open(t); if (!env) return;
  const record = { slug: 's-1', title: 'Add CSV export', score: 7, tags: ['a'] };
  const w = await put(env.DB, { project: 'p1', proposal_id: 's-1', status: 'gate_pending', record, actor: 'box-3' });
  assert.equal(w.status, 200, JSON.stringify(w.body));
  assert.equal(w.body.proposal.project, 'p1');
  assert.equal(w.body.proposal.proposal_id, 's-1');
  assert.equal(w.body.proposal.status, 'gate_pending');
  assert.deepEqual(w.body.proposal.record, record);
  assert.equal(w.body.proposal.actor, 'box-3');
  assert.equal(w.body.inserted, undefined, 'inserted rides only on an if_absent put');

  const r = await call(env.DB, 'GET', '/api/product-proposals?project=p1&proposal_id=s-1');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.proposal, w.body.proposal);
  assert.equal(read(env.db, 'p1', 's-1').record, JSON.stringify(record), 'record is stored as JSON text');
});

test('W1b: a record sent as JSON-object text is stored as the object', async (t) => {
  const env = await open(t); if (!env) return;
  const w = await put(env.DB, { project: 'p1', proposal_id: 's-2', status: 'candidate', record: '{"slug":"s-2"}' });
  assert.equal(w.status, 200, JSON.stringify(w.body));
  assert.deepEqual(w.body.proposal.record, { slug: 's-2' });
  assert.equal(w.body.proposal.actor, null);
});

test('W2: a second PUT updates status, keeps created_at and actor, bumps updated_at', async (t) => {
  const env = await open(t); if (!env) return;
  const a = await put(env.DB, { project: 'p1', proposal_id: 's-1', status: 'gate_pending', record: { v: 1 }, actor: 'box-3' });
  assert.equal(a.status, 200);
  t.mock.timers.tick(5000);
  const b = await put(env.DB, { project: 'p1', proposal_id: 's-1', status: 'posted', record: { v: 2 } });
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.equal(b.body.proposal.status, 'posted');
  assert.deepEqual(b.body.proposal.record, { v: 2 });
  assert.equal(b.body.proposal.created_at, a.body.proposal.created_at);
  assert.ok(b.body.proposal.updated_at > a.body.proposal.updated_at,
    `updated_at ${b.body.proposal.updated_at} must move past ${a.body.proposal.updated_at}`);
  assert.equal(b.body.proposal.actor, 'box-3', 'an omitted actor keeps the stored one');
  const row = read(env.db, 'p1', 's-1');
  assert.equal(row.created_at, a.body.proposal.created_at);
  assert.equal(row.status, 'posted');
});

test('W3: GET list is the project only, ordered by proposal_id, with truncated and as_of', async (t) => {
  const env = await open(t); if (!env) return;
  for (const [p, s] of [['p1', 's-b'], ['p1', 's-a'], ['p2', 's-c']]) {
    assert.equal((await put(env.DB, { project: p, proposal_id: s, status: 'candidate', record: { s } })).status, 200);
  }
  const r = await call(env.DB, 'GET', '/api/product-proposals?project=p1');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.proposals.map((x) => x.proposal_id), ['s-a', 's-b']);
  assert.deepEqual(r.body.proposals[0].record, { s: 's-a' }, 'list rows carry record as an object');
  assert.equal(r.body.truncated, false);
  assert.equal(typeof r.body.as_of, 'string');
  assert.match(r.body.as_of, /^\d{4}-\d{2}-\d{2}T/);

  const empty = await call(env.DB, 'GET', '/api/product-proposals?project=p9');
  assert.equal(empty.status, 200, 'a project with no rows is an empty list, never a 404');
  assert.deepEqual(empty.body.proposals, []);
});

test('W4: GET of a missing slug is 404 with the exact client discriminator', async (t) => {
  const env = await open(t); if (!env) return;
  await put(env.DB, { project: 'p1', proposal_id: 's-1', status: 'candidate', record: {} });
  const r = await call(env.DB, 'GET', '/api/product-proposals?project=p1&proposal_id=nope');
  assert.equal(r.status, 404);
  assert.equal(r.body.error, 'proposal not found');
  const other = await call(env.DB, 'GET', '/api/product-proposals?project=p2&proposal_id=s-1');
  assert.equal(other.status, 404, 'a slug is scoped to its project');
  assert.equal(other.body.error, 'proposal not found');
});

test('W5: every malformed request is 400 and never touches the DB', async (t) => {
  const env = await open(t); if (!env) return;
  const { c, DB } = counting(env.DB);
  const ok = { project: 'p1', proposal_id: 's-1', status: 'candidate', record: { a: 1 } };
  const big = { x: 'y'.repeat(32000 - '{"x":""}'.length + 1) };
  assert.equal(JSON.stringify(big).length, 32001);
  const gets = [
    '/api/product-proposals',
    '/api/product-proposals?project=',
    `/api/product-proposals?project=${'p'.repeat(129)}`,
    '/api/product-proposals?project=a%2Fb',
    '/api/product-proposals?project=p1&proposal_id=',
    '/api/product-proposals?project=p1&proposal_id=a%2Fb',
  ];
  for (const g of gets) {
    const r = await call(DB, 'GET', g);
    assert.equal(r.status, 400, `${g} -> ${r.status} ${JSON.stringify(r.body)}`);
    assert.notEqual(r.body.error, 'proposal not found');
  }
  const puts = [
    { ...ok, project: '' },
    { ...ok, project: 'p'.repeat(129) },
    { ...ok, project: 7 },
    { ...ok, proposal_id: 'a/b' },
    { ...ok, proposal_id: undefined },
    { ...ok, status: '' },
    { ...ok, status: 's'.repeat(33) },
    { ...ok, status: 5 },
    { ...ok, record: [1, 2] },
    { ...ok, record: null },
    { ...ok, record: 'x' },
    { ...ok, record: '[1]' },
    { ...ok, record: 42 },
    { ...ok, record: undefined },
    { ...ok, record: big },
  ];
  for (const b of puts) {
    const r = await put(DB, b);
    assert.equal(r.status, 400, `${JSON.stringify(b).slice(0, 80)} -> ${r.status} ${JSON.stringify(r.body)}`);
  }
  const notJson = await put(DB, 'not json');
  assert.equal(notJson.status, 400, `non-JSON body -> ${notJson.status}`);
  assert.equal(c.n, 0, 'a refused request must never reach the database');

  // The bounds are exact: 32000 chars and a 32-char status are accepted.
  const edge = { x: 'y'.repeat(32000 - '{"x":""}'.length) };
  const r = await put(DB, { ...ok, status: 's'.repeat(32), record: edge });
  assert.equal(r.status, 200, JSON.stringify(r.body).slice(0, 200));
  assert.equal(read(env.db, 'p1', 's-1').record.length, 32000, 'stored whole, never truncated');
});

test('W6: without the table every handler answers 503 schema not applied', async (t) => {
  const env = await open(t); if (!env) return;
  env.db.exec('DROP TABLE product_proposals');
  const cases = [
    ['GET', '/api/product-proposals?project=p1'],
    ['GET', '/api/product-proposals?project=p1&proposal_id=s-1'],
    ['PUT', '/api/product-proposals', { project: 'p1', proposal_id: 's-1', status: 'candidate', record: {} }],
    ['PUT', '/api/product-proposals', { project: 'p1', proposal_id: 's-1', status: 'candidate', record: {}, if_absent: true }],
  ];
  for (const [m, p, b] of cases) {
    const r = await call(env.DB, m, p, b);
    assert.equal(r.status, 503, `${m} ${p} -> ${r.status}`);
    assert.equal(r.body.error, 'product_proposals schema not applied');
  }
});

test('W7: no bearer is 401 and writes nothing', async (t) => {
  const env = await open(t); if (!env) return;
  const b = { project: 'p1', proposal_id: 's-1', status: 'candidate', record: {} };
  const r = await put(env.DB, b, { secret: null });
  assert.equal(r.status, 401);
  const wrong = await put(env.DB, b, { secret: 'nope' });
  assert.equal(wrong.status, 401);
  const g = await call(env.DB, 'GET', '/api/product-proposals?project=p1', undefined, { secret: null });
  assert.equal(g.status, 401);
  assert.equal(read(env.db, 'p1', 's-1'), undefined);
});

test('W8: if_absent never touches an existing row; the list cap is real', async (t) => {
  const env = await open(t); if (!env) return;
  await put(env.DB, { project: 'p1', proposal_id: 's-1', status: 'posted', record: { v: 'new' }, actor: 'box-3' });
  const stale = await put(env.DB, { project: 'p1', proposal_id: 's-1', status: 'candidate', record: { v: 'old' }, actor: 'box-9', if_absent: true });
  assert.equal(stale.status, 200, JSON.stringify(stale.body));
  assert.equal(stale.body.inserted, false);
  assert.equal(stale.body.proposal.status, 'posted');
  assert.deepEqual(stale.body.proposal.record, { v: 'new' });
  assert.equal(stale.body.proposal.actor, 'box-3');

  const fresh = await put(env.DB, { project: 'p1', proposal_id: 's-2', status: 'candidate', record: { v: 'bf' }, if_absent: true });
  assert.equal(fresh.status, 200);
  assert.equal(fresh.body.inserted, true);
  assert.equal(read(env.db, 'p1', 's-2').status, 'candidate');

  const ins = env.db.prepare('INSERT INTO product_proposals VALUES (?,?,?,?,?,?,?)');
  for (let i = 0; i < 1001; i++) ins.run('big', `s-${String(i).padStart(4, '0')}`, 'candidate', '{}', null, 't', 't');
  const cut = await call(env.DB, 'GET', '/api/product-proposals?project=big');
  assert.equal(cut.status, 200);
  assert.equal(cut.body.proposals.length, 1000);
  assert.equal(cut.body.truncated, true);
  assert.equal(cut.body.proposals[999].proposal_id, 's-0999');

  env.db.prepare("DELETE FROM product_proposals WHERE project='big' AND proposal_id='s-1000'").run();
  const whole = await call(env.DB, 'GET', '/api/product-proposals?project=big');
  assert.equal(whole.body.proposals.length, 1000);
  assert.equal(whole.body.truncated, false, 'exactly the cap is not truncated');
});
