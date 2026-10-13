import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { wakeOf } from '../src/lib/core.js';
import { createHmac } from 'node:crypto';

const WH_SECRET = 'wh-test-secret';
const SECRET = 'test-secret';

function fakeDB() {
  const calls = [];
  const stmt = (sql) => ({
    bind: (...binds) => ({
      first: async () => null,
      all: async () => ({ results: [] }),
      run: async () => {
        calls.push({ sql: sql.replace(/\s+/g, ' ').trim(), binds });
        return { meta: { changes: 1, last_row_id: 1 } };
      },
    }),
    first: async () => null,
    all: async () => ({ results: [] }),
    run: async () => ({ meta: { changes: 1 } }),
  });
  return { prepare: stmt, _calls: calls };
}

const deliver = (event, payload) => {
  const raw = JSON.stringify(payload);
  const headers = {
    'content-type': 'application/json', 'x-github-event': event,
    'x-hub-signature-256': 'sha256=' + createHmac('sha256', WH_SECRET).update(raw).digest('hex'),
  };
  const db = fakeDB();
  const req = new Request('https://jobs.test/webhooks/github', { method: 'POST', headers, body: raw });
  const env = { DB: db, HARNESS_SECRET: SECRET, GITHUB_WEBHOOK_SECRET: WH_SECRET };
  return worker.fetch(req, env).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null), db,
  }));
};

// BH-4055: GitHub's native merge queue `enqueued` / `dequeued` are queue moves
// that make a merge-path alert true or false, so they wake the fleet as pr
// wakes. Every action that already landed still lands unchanged.
const repository = { full_name: 'example-org/cromford' };
const inserts = (r) => r.db._calls.filter((c) => /INSERT INTO wakes/.test(c.sql));

for (const action of ['enqueued', 'dequeued']) {
  test(`W1/W2 webhook: pull_request.${action} is stored as a pr wake`, async () => {
    const r = await deliver('pull_request', { action, number: 3928, repository, pull_request: { number: 3928 } });
    assert.equal(r.status, 200);
    assert.equal(r.body.wake.kind, 'pr');
    assert.equal(r.body.wake.key, '3928');
    assert.equal(r.body.wake.event, `pull_request.${action}`);
    assert.equal(inserts(r).length, 1);
    assert.equal(inserts(r)[0].binds[3], `pull_request.${action}`);
    assert.deepEqual(wakeOf('pull_request', { action, number: 3928 }), { kind: 'pr', key: '3928' });
  });
}

test('W3 webhook: enqueued keyed from pull_request.number alone', async () => {
  const r = await deliver('pull_request', { action: 'enqueued', repository, pull_request: { number: 3928 } });
  assert.equal(r.status, 200);
  assert.equal(r.body.wake.key, '3928');
  assert.deepEqual(wakeOf('pull_request', { action: 'enqueued', pull_request: { number: 3928 } }),
    { kind: 'pr', key: '3928' });
});

test('W4 webhook: labeled queued still lands', async () => {
  const r = await deliver('pull_request', {
    action: 'labeled', number: 3928, label: { name: 'queued' }, repository, pull_request: { number: 3928 },
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.wake.event, 'pull_request.labeled');
  assert.equal(inserts(r).length, 1);
});

test('W5 webhook: assigned, edited, review_requested, unlabeled are ignored', async () => {
  for (const action of ['assigned', 'edited', 'review_requested', 'unlabeled']) {
    const r = await deliver('pull_request', {
      action, number: 3928, label: { name: 'queued' }, repository, pull_request: { number: 3928 },
    });
    assert.equal(r.status, 202, action);
    assert.equal(inserts(r).length, 0, action);
    assert.equal(wakeOf('pull_request', { action, number: 3928, label: { name: 'queued' } }), null, action);
  }
  // A non-queued label stays dropped too.
  assert.equal(wakeOf('pull_request', { action: 'labeled', number: 3928, label: { name: 'bug' } }), null);
});

test('W6 webhook: existing actions land unchanged', async () => {
  for (const action of ['opened', 'synchronize', 'closed', 'ready_for_review', 'reopened']) {
    const r = await deliver('pull_request', { action, number: 3917, repository, pull_request: { number: 3917 } });
    assert.equal(r.status, 200, action);
    assert.equal(r.body.wake.event, `pull_request.${action}`);
    assert.equal(r.body.wake.key, '3917');
    assert.equal(inserts(r).length, 1, action);
    assert.deepEqual(wakeOf('pull_request', { action, number: 3917 }), { kind: 'pr', key: '3917' });
  }
});
