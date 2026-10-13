import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { CLAIM, SECRET, call, fakeDB, worker } from '../lib/harness.js';

const WH_SECRET = 'wh-test-secret';

const deliver = (event, payload, {
  secret = WH_SECRET, sign = true, state = {}, method = 'POST',
  envSecret = WH_SECRET, tamper = null,
} = {}) => {
  const raw = typeof payload === 'string' ? payload : JSON.stringify(payload);
  const headers = { 'content-type': 'application/json', 'x-github-event': event };
  if (sign) {
    headers['x-hub-signature-256'] = 'sha256=' + createHmac('sha256', secret).update(raw).digest('hex');
  }
  const db = fakeDB({ jobs: [], ...state });
  const req = new Request('https://jobs.test/webhooks/github', {
    method, headers, body: method === 'POST' ? (tamper === null ? raw : tamper) : undefined,
  });
  const env = { DB: db, HARNESS_SECRET: SECRET };
  if (envSecret !== null) env.GITHUB_WEBHOOK_SECRET = envSecret;
  return worker.fetch(req, env).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null), db,
  }));
};

const PR_OPENED = {
  action: 'opened', number: 272,
  repository: { full_name: 'example-org/cromford' },
  pull_request: { number: 272, title: 'anything at all', merged: true },
};

test('webhook: an UNSIGNED delivery writes nothing', async () => {
  const r = await deliver('pull_request', PR_OPENED, { sign: false });
  assert.equal(r.status, 401);
  // The REASON matters: a 401 from the bearer check would also read as 401, and
  // this test has to fail on a worker that never grew the route at all.
  assert.equal(r.body.error, 'bad signature');
  assert.ok(!r.db._calls.some((c) => /INSERT INTO wakes/.test(c.sql)),
    'no row may be written for an unsigned delivery');
});

test('webhook: a WRONGLY-signed delivery writes nothing', async () => {
  const r = await deliver('pull_request', PR_OPENED, { secret: 'not-the-secret' });
  assert.equal(r.status, 401);
  assert.equal(r.body.error, 'bad signature');
  assert.ok(!r.db._calls.some((c) => /INSERT INTO wakes/.test(c.sql)));
});

test('webhook: a body altered AFTER signing is rejected', async () => {
  // The signature covers the RAW bytes. This is the assertion that would fail
  // on a receiver that re-serialised the parsed object before verifying.
  const r = await deliver('pull_request', PR_OPENED, {
    tamper: JSON.stringify({ ...PR_OPENED, number: 999 }) });
  assert.equal(r.status, 401);
  assert.equal(r.body.error, 'bad signature');
  assert.ok(!r.db._calls.some((c) => /INSERT INTO wakes/.test(c.sql)));
});

test('webhook: with NO secret configured the receiver is inert, never open', async () => {
  const r = await deliver('pull_request', PR_OPENED, { envSecret: null });
  assert.equal(r.status, 503, 'an unarmed receiver must refuse, not accept');
  assert.ok(!r.db._calls.some((c) => /INSERT INTO wakes/.test(c.sql)));
});

test('webhook: the BEARER does not open it and it does not open the bearer routes', async () => {
  // GET is refused outright…
  const g = await deliver('pull_request', PR_OPENED, { method: 'GET', sign: true });
  assert.equal(g.status, 405);
  // …and a bearer-authed route still needs the bearer, unchanged by all this.
  const j = await call('/api/wakes', { secret: null });
  assert.equal(j.status, 401);
});

test('webhook: a correctly signed PR event writes ONE identifier-only row', async () => {
  const r = await deliver('pull_request', PR_OPENED);
  assert.equal(r.status, 200);
  assert.equal(r.body.wake.kind, 'pr');
  assert.equal(r.body.wake.key, '272');
  assert.equal(r.body.wake.repo, 'example-org/cromford');
  const ins = r.db._calls.find((c) => /INSERT INTO wakes/.test(c.sql));
  assert.ok(ins, 'a verified delivery must write a row');
  // NOTHING from the payload beyond identifiers. The title and the `merged`
  // claim are the two most tempting fields in a PR payload and neither may
  // survive the receiver — a lane that believed them would act on a lie.
  const stored = JSON.stringify(ins.binds);
  assert.ok(!/anything at all/.test(stored), `payload text leaked into a row: ${stored}`);
  assert.ok(!/true/.test(stored), `a payload CLAIM leaked into a row: ${stored}`);
});

test('webhook: the insert is idempotent on (repo, kind, key, minute)', async () => {
  const r = await deliver('pull_request', PR_OPENED);
  const ins = r.db._calls.find((c) => /INSERT INTO wakes/.test(c.sql));
  assert.match(ins.sql, /ON CONFLICT\(repo, kind, key, minute\) DO NOTHING/);
  // The minute bucket must be the truncated server clock, not the full stamp,
  // or every redelivery inside a minute becomes its own row.
  const minute = ins.binds.find((b) => /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00Z$/.test(String(b)));
  assert.ok(minute, `the minute bucket must be bound: ${JSON.stringify(ins.binds)}`);
});

test('webhook: a redelivery reports duplicate rather than a second wake', async () => {
  // SQLite changed nothing because the unique index held. The receiver has to
  // SAY so, because the loop's log line is the only place a redelivery storm
  // would ever be visible.
  const r = await deliver('pull_request', PR_OPENED, { state: { wakesInsertNoop: true } });
  assert.equal(r.status, 200);
  assert.equal(r.body.duplicate, true);
});

test('webhook: ping answers 200 and writes nothing', async () => {
  const r = await deliver('ping', { zen: 'x', repository: { full_name: 'example-org/cromford' } });
  assert.equal(r.status, 200);
  assert.equal(r.body.pong, true);
  assert.ok(!r.db._calls.some((c) => /INSERT INTO wakes/.test(c.sql)));
});

test('webhook: each event class lands on the lane that owns it', async () => {
  const repository = { full_name: 'example-org/project-3' };
  const sha = 'a'.repeat(40);
  const cases = [
    ['check_suite', { action: 'completed', repository, check_suite: { head_sha: sha } }, 'checks', sha],
    ['check_run', { action: 'completed', repository, check_run: { head_sha: sha } }, 'checks', sha],
    ['pull_request_review', { action: 'submitted', repository, pull_request: { number: 12 } }, 'pr', '12'],
    ['push', { ref: 'refs/heads/main', after: sha, repository }, 'push', sha],
    ['deployment_status', { repository, deployment: { sha }, deployment_status: { state: 'success' } }, 'deploy', sha],
    ['issues', { action: 'opened', repository, issue: { number: 7 } }, 'issue', '7'],
    ['issue_comment', { action: 'created', repository, issue: { number: 8 } }, 'issue', '8'],
    // A comment on a PR is a PR event: the conductor owns it, not the board.
    ['issue_comment', { action: 'created', repository, issue: { number: 9, pull_request: { url: 'x' } } }, 'pr', '9'],
  ];
  for (const [event, payload, kind, key] of cases) {
    const r = await deliver(event, payload);
    assert.equal(r.status, 200, `${event} should be accepted`);
    assert.equal(r.body.wake.kind, kind, `${event} -> kind`);
    assert.equal(r.body.wake.key, key, `${event} -> key`);
  }
});

test('webhook: events nobody owns are accepted and dropped, never rows', async () => {
  const repository = { full_name: 'example-org/project-3' };
  const sha = 'b'.repeat(40);
  const ignored = [
    // A push to a feature branch must never wake the deploy train.
    ['push', { ref: 'refs/heads/feature/x', after: sha, repository }],
    // An in-flight check suite is not a completed one.
    ['check_suite', { action: 'requested', repository, check_suite: { head_sha: sha } }],
    // A deployment still in flight is not a deployment to QA. (A FAILED one is
    // a deploy_failed row since BH-4058, never a deploy: wakeof-new-events.bh-4058.)
    ['deployment_status', { repository, deployment: { sha }, deployment_status: { state: 'pending' } }],
    // A label change on a PR moves nothing the conductor watches.
    ['pull_request', { action: 'labeled', number: 3, repository, pull_request: { number: 3 } }],
    ['star', { action: 'created', repository }],
  ];
  for (const [event, payload] of ignored) {
    const r = await deliver(event, payload);
    assert.equal(r.status, 202, `${event} should be accepted-and-dropped, not failed`);
    assert.ok(!r.db._calls.some((c) => /INSERT INTO wakes/.test(c.sql)), `${event} wrote a row`);
  }
});

test('webhook: a malformed identifier is dropped, not stored', async () => {
  const repository = { full_name: 'example-org/project-3' };
  const bad = [
    ['pull_request', { action: 'opened', number: '12; rm -rf /', repository, pull_request: {} }],
    ['push', { ref: 'refs/heads/main', after: 'not-a-sha', repository }],
    ['issues', { action: 'opened', repository, issue: { number: -1 } }],
  ];
  for (const [event, payload] of bad) {
    const r = await deliver(event, payload);
    assert.equal(r.status, 202, `${event} with a bad identifier must not be stored`);
    assert.ok(!r.db._calls.some((c) => /INSERT INTO wakes/.test(c.sql)));
  }
  // And a delivery with no repository slug at all.
  const noRepo = await deliver('pull_request', { action: 'opened', number: 1 });
  assert.equal(noRepo.status, 202);
});

test('new routes require bearer auth', async () => {
  for (const [path, method] of [
    ['/api/pr-owners?repo=x', 'GET'],
    ['/api/pr-owners', 'PUT'],
    ['/api/decisions', 'GET'],
    ['/api/decisions', 'POST'],
    ['/api/findings', 'GET'],
    ['/api/findings', 'POST'],
    ['/api/telegram-topics', 'GET'],
    ['/api/telegram-topics', 'PUT'],
    ['/api/ledger?kind=pr_state', 'GET']
  ]) {
    const r = await call(path, { method, secret: null });
    assert.equal(r.status, 401, `${method} ${path} must be 401`);
  }
});
