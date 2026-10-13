import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { createHmac } from 'node:crypto';

const WH_SECRET = 'wh-test-secret';
const SECRET = 'test-secret';

// Minimal fake D1 that proves the INSERT binds and the ON CONFLICT path.
function fakeDB(state) {
  const calls = [];
  const stmt = (sql) => ({
    bind: (...binds) => ({
      first: async () => null,
      all: async () => ({ results: [] }),
      run: async () => {
        calls.push({ sql: sql.replace(/\s+/g, ' ').trim(), binds });
        const noop = state.wakesInsertNoop && /INSERT INTO wakes/.test(sql);
        return { meta: { changes: noop ? 0 : 1, last_row_id: 1 } };
      },
    }),
    first: async () => null,
    all: async () => ({ results: [] }),
    run: async () => ({ meta: { changes: 1 } }),
  });
  return { prepare: stmt, _calls: calls };
}

const deliver = (event, payload, { sign = true, state = {}, envSecret = WH_SECRET, tamper = null } = {}) => {
  const raw = typeof payload === 'string' ? payload : JSON.stringify(payload);
  const headers = { 'content-type': 'application/json', 'x-github-event': event };
  if (sign) {
    headers['x-hub-signature-256'] = 'sha256=' + createHmac('sha256', WH_SECRET).update(raw).digest('hex');
  }
  const db = fakeDB(state);
  const req = new Request('https://jobs.test/webhooks/github', {
    method: 'POST', headers, body: tamper === null ? raw : tamper,
  });
  const env = { DB: db, HARNESS_SECRET: SECRET };
  if (envSecret !== null) env.GITHUB_WEBHOOK_SECRET = envSecret;
  return worker.fetch(req, env).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null), db,
  }));
};

test('webhook: pull_request.closed stores event as pull_request.closed', async () => {
  const r = await deliver('pull_request', {
    action: 'closed', number: 272,
    repository: { full_name: 'example-org/cromford' },
    pull_request: { number: 272 },
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.wake.event, 'pull_request.closed');
  const ins = r.db._calls.find((c) => /INSERT INTO wakes/.test(c.sql));
  assert.ok(ins);
  assert.equal(ins.binds[3], 'pull_request.closed');
});

test('webhook: check_suite.completed stores event as check_suite.completed', async () => {
  const r = await deliver('check_suite', {
    action: 'completed',
    repository: { full_name: 'example-org/cromford' },
    check_suite: { head_sha: 'abc1234def' },
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.wake.event, 'check_suite.completed');
  const ins = r.db._calls.find((c) => /INSERT INTO wakes/.test(c.sql));
  assert.equal(ins.binds[3], 'check_suite.completed');
});

test('webhook: push with no action stays push', async () => {
  const r = await deliver('push', {
    ref: 'refs/heads/main', after: 'aaa1111',
    repository: { full_name: 'example-org/cromford' },
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.wake.event, 'push');
  const ins = r.db._calls.find((c) => /INSERT INTO wakes/.test(c.sql));
  assert.equal(ins.binds[3], 'push');
});

test('webhook: deployment_status.created stores event as deployment_status.created', async () => {
  const r = await deliver('deployment_status', {
    action: 'created',
    repository: { full_name: 'example-org/cromford' },
    deployment_status: { state: 'success' },
    deployment: { sha: 'def7890' },
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.wake.event, 'deployment_status.created');
  assert.equal(r.body.wake.kind, 'deploy');
  const ins = r.db._calls.find((c) => /INSERT INTO wakes/.test(c.sql));
  assert.equal(ins.binds[3], 'deployment_status.created');
});

test('webhook: malformed action falls back to bare event', async () => {
  const r = await deliver('deployment_status', {
    action: 'Created',
    repository: { full_name: 'example-org/cromford' },
    deployment_status: { state: 'success' },
    deployment: { sha: 'def7890' },
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.wake.event, 'deployment_status');
  const ins = r.db._calls.find((c) => /INSERT INTO wakes/.test(c.sql));
  assert.equal(ins.binds[3], 'deployment_status');
});

test('webhook: redelivery with same key reports duplicate', async () => {
  const payload = {
    action: 'closed', number: 273,
    repository: { full_name: 'example-org/cromford' },
    pull_request: { number: 273 },
  };
  const first = await deliver('pull_request', payload);
  assert.equal(first.status, 200);
  assert.equal(first.body.duplicate, false);
  const second = await deliver('pull_request', payload, { state: { wakesInsertNoop: true } });
  assert.equal(second.status, 200);
  assert.equal(second.body.duplicate, true);
  assert.equal(second.body.wake.event, 'pull_request.closed');
});
