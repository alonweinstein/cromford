import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { onRequest as release } from '../functions/api/merge-pr/release.js';

// BH-4917. The hub poller executes every merge_pr, whatever sent it, and after
// it acks `refused: head moved…` it POSTs the command id here so the row moves
// off `<project>:<ticket>:merge_pr` and the next merge_pr is a new command.
// The write goes through the console's CONSOLE_DB binding, so the hub keeps no
// D1 access (BH-3905). Every case runs the REAL onRequest; CONSOLE_DB is a real
// SQLite table wrapped in D1's prepare/bind/run shape.

const SECRET = 'hs-test-bh4917';
const KEY = 'project-3:TK-467:merge_pr';
const HM = 'refused: head moved since sha 7b840970 — Head branch was modified.';

function world({ throws = false } = {}) {
  const s = new DatabaseSync(':memory:');
  s.exec(`CREATE TABLE commands (id INTEGER PRIMARY KEY, ckey TEXT UNIQUE, type TEXT,
    project TEXT, status TEXT, result TEXT, payload TEXT)`);
  const seed = (id, ckey, type, status, result) => s.prepare(
    'INSERT INTO commands (id, ckey, type, project, status, result, payload) VALUES (?, ?, ?, ?, ?, ?, ?)'
  ).run(id, ckey, type, 'project-3', status, result, '{}');
  seed(7, KEY, 'merge_pr', 'refused', HM);
  seed(3, 'project-3:TK-1:merge_pr:refused:3', 'merge_pr', 'refused', HM);
  seed(4, 'project-3:TK-2:merge_pr', 'merge_pr', 'leased', HM);
  seed(5, 'project-3:TK-3:merge_pr', 'merge_pr', 'refused', 'refused: GitHub would not merge — 405');
  seed(6, 'project-3:TK-4:chat', 'chat', 'refused', HM);
  const db = {
    prepare(sql) {
      if (throws) throw new Error('D1_ERROR: no such table: commands');
      const st = s.prepare(sql);
      return { bind: (...a) => ({ run: async () => ({ success: true, meta: { changes: Number(st.run(...a).changes) } }) }) };
    }
  };
  const ckey = (id) => s.prepare('SELECT ckey FROM commands WHERE id = ?').get(id).ckey;
  return { db, ckey };
}

async function call(env, { method = 'POST', auth = `Bearer ${SECRET}`, body = { id: 7 } } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (auth != null) headers.authorization = auth;
  const init = { method, headers };
  if (method !== 'GET' && method !== 'HEAD') init.body = typeof body === 'string' ? body : JSON.stringify(body);
  const res = await release({ request: new Request('https://pages.example/api/merge-pr/release', init), env });
  return { status: res.status, body: await res.json() };
}

test('a terminal head-moved refusal is renamed off its key and kept', async () => {
  const w = world();
  const r = await call({ HARNESS_SECRET: SECRET, CONSOLE_DB: w.db });
  assert.deepEqual(r, { status: 200, body: { released: 1 } });
  assert.equal(w.ckey(7), `${KEY}:refused:7`);
  assert.deepEqual(await call({ HARNESS_SECRET: SECRET, CONSOLE_DB: w.db }), { status: 200, body: { released: 0 } },
    'a replay changes nothing');
});

test('a string id of digits is accepted; an env secret with a trailing newline still matches', async () => {
  const w = world();
  const r = await call({ HARNESS_SECRET: `${SECRET}\n`, CONSOLE_DB: w.db }, { body: { id: '7' } });
  assert.deepEqual(r, { status: 200, body: { released: 1 } });
});

test('leased rows, other refusals, other types, renamed rows and unknown ids keep their key', async () => {
  const w = world();
  for (const [id, want] of [[3, 'project-3:TK-1:merge_pr:refused:3'], [4, 'project-3:TK-2:merge_pr'],
    [5, 'project-3:TK-3:merge_pr'], [6, 'project-3:TK-4:chat']]) {
    assert.deepEqual(await call({ HARNESS_SECRET: SECRET, CONSOLE_DB: w.db }, { body: { id } }),
      { status: 200, body: { released: 0 } }, `row ${id}`);
    assert.equal(w.ckey(id), want);
  }
  assert.deepEqual(await call({ HARNESS_SECRET: SECRET, CONSOLE_DB: w.db }, { body: { id: 99 } }),
    { status: 200, body: { released: 0 } });
  assert.equal(w.ckey(7), KEY);
});

test('no secret, a wrong one or none at all never touches the row', async () => {
  const w = world();
  for (const auth of [null, '', `Bearer ${SECRET}x`, 'Bearer ', SECRET, `Basic ${SECRET}`]) {
    const r = await call({ HARNESS_SECRET: SECRET, CONSOLE_DB: w.db }, { auth });
    assert.equal(r.status, 401, `auth ${JSON.stringify(auth)}`);
  }
  const r = await call({ CONSOLE_DB: w.db });
  assert.equal(r.status, 503);
  assert.match(r.body.error, /HARNESS_SECRET is not set/);
  assert.equal(w.ckey(7), KEY);
});

test('a missing CONSOLE_DB binding is a 503 naming it, never a 200', async () => {
  const r = await call({ HARNESS_SECRET: SECRET });
  assert.equal(r.status, 503);
  assert.match(r.body.error, /CONSOLE_DB is not bound/);
});

test('only POST, and only a JSON object with a positive whole id', async () => {
  const w = world();
  const env = { HARNESS_SECRET: SECRET, CONSOLE_DB: w.db };
  assert.equal((await call(env, { method: 'GET' })).status, 405);
  for (const body of ['not json', '[7]', { id: 0 }, { id: -7 }, { id: 7.5 }, { id: '7; drop' }, { id: '07' }, {}]) {
    assert.equal((await call(env, { body })).status, 400, JSON.stringify(body));
  }
  assert.equal(w.ckey(7), KEY);
});

test('a D1 error is a 500, never a 200', async () => {
  const r = await call({ HARNESS_SECRET: SECRET, CONSOLE_DB: world({ throws: true }).db });
  assert.equal(r.status, 500);
  assert.match(r.body.error, /d1-error/);
});
