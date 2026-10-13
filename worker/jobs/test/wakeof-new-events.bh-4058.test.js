// BH-4058 — the GitHub events the receiver used to drop now land as wake rows.
//
// Every case drives the real worker.fetch with a SIGNED delivery (the same
// deliver()/fakeDB shape as wakes-event-action.bh-1034.test.js), so the route,
// the signature check and wakeOf are all on the path. W1-W11 are the plan's
// acceptance list.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { createHmac } from 'node:crypto';

const WH_SECRET = 'wh-test-secret';
const SECRET = 'test-secret';
const repository = { full_name: 'example-org/cromford' };
const SHA = 'c'.repeat(40);

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

const deliver = (event, payload, { sign = true } = {}) => {
  const raw = JSON.stringify(payload);
  const headers = { 'content-type': 'application/json', 'x-github-event': event };
  if (sign) headers['x-hub-signature-256'] = 'sha256=' + createHmac('sha256', WH_SECRET).update(raw).digest('hex');
  const db = fakeDB();
  const req = new Request('https://jobs.test/webhooks/github', { method: 'POST', headers, body: raw });
  const env = { DB: db, HARNESS_SECRET: SECRET, GITHUB_WEBHOOK_SECRET: WH_SECRET };
  return worker.fetch(req, env).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null), db,
  }));
};
const inserts = (r) => r.db._calls.filter((c) => /INSERT INTO wakes/.test(c.sql));

async function lands(event, payload, kind, key, ev) {
  const r = await deliver(event, payload);
  assert.equal(r.status, 200, `${event}/${payload.action || '-'} should land`);
  assert.deepEqual(
    { kind: r.body.wake.kind, key: r.body.wake.key, event: r.body.wake.event },
    { kind, key, event: ev });
  const ins = inserts(r);
  assert.equal(ins.length, 1);
  assert.equal(ins[0].binds[1], kind);
  assert.equal(ins[0].binds[2], key);
  assert.equal(ins[0].binds[3], ev);
  return r;
}
async function dropped(event, payload, why) {
  const r = await deliver(event, payload);
  assert.equal(r.status, 202, `${why}: expected 202, got ${r.status}`);
  assert.equal(inserts(r).length, 0, `${why}: wrote a row`);
}

const labeled = (name, extra = {}) => ({
  action: 'labeled', repository, issue: { number: 41 },
  ...(name === undefined ? {} : { label: { name } }), ...extra,
});

test('W1: issues.labeled ai-build -> issue row', async () => {
  await lands('issues', labeled('ai-build'), 'issue', '41', 'issues.labeled');
});

test('W2: issues.labeled hotfix and AI-Build (case variant) -> issue row', async () => {
  await lands('issues', labeled('hotfix'), 'issue', '41', 'issues.labeled');
  await lands('issues', labeled('AI-Build'), 'issue', '41', 'issues.labeled');
});

test('W3: issues.labeled with an unrelated label, a near-miss or no label -> no row', async () => {
  await dropped('issues', labeled('bug'), 'bug label');
  await dropped('issues', labeled('ai-build-later'), 'near-miss label');
  await dropped('issues', labeled(undefined), 'no label object');
  await dropped('issues', labeled(''), 'empty label name');
});

test('W4: issues.unlabeled ai-build -> no row', async () => {
  await dropped('issues', { ...labeled('ai-build'), action: 'unlabeled' }, 'unlabeled');
});

test('W5: deployment_status failure/error -> deploy_failed; success stays deploy; pending dropped', async () => {
  const dep = (state) => ({ action: 'created', repository, deployment: { sha: SHA }, deployment_status: { state } });
  await lands('deployment_status', dep('failure'), 'deploy_failed', SHA, 'deployment_status.created');
  await lands('deployment_status', dep('error'), 'deploy_failed', SHA, 'deployment_status.created');
  await lands('deployment_status', dep('success'), 'deploy', SHA, 'deployment_status.created');
  for (const s of ['pending', 'inactive', 'in_progress', 'queued']) {
    await dropped('deployment_status', dep(s), `deployment_status ${s}`);
  }
});

test('W6: check_run.completed -> checks (guard on the arm that was already on main)', async () => {
  await lands('check_run', { action: 'completed', repository, check_run: { head_sha: SHA } },
    'checks', SHA, 'check_run.completed');
  await dropped('check_run', { action: 'created', repository, check_run: { head_sha: SHA } }, 'check_run created');
});

test('W7: status success/failure/error -> checks keyed on the sha; pending and a bad sha dropped', async () => {
  for (const state of ['success', 'failure', 'error']) {
    await lands('status', { repository, sha: SHA, state }, 'checks', SHA, 'status');
  }
  await dropped('status', { repository, sha: SHA, state: 'pending' }, 'status pending');
  await dropped('status', { repository, sha: 'zz', state: 'success' }, 'status bad sha');
});

test('W8: workflow_run.completed -> checks; requested/in_progress dropped', async () => {
  const wr = (action) => ({ action, repository, workflow_run: { head_sha: SHA } });
  await lands('workflow_run', wr('completed'), 'checks', SHA, 'workflow_run.completed');
  await dropped('workflow_run', wr('requested'), 'workflow_run requested');
  await dropped('workflow_run', wr('in_progress'), 'workflow_run in_progress');
});

test('W9: merge_group checks_requested/destroyed -> merge_group; other actions dropped', async () => {
  const mg = (action) => ({ action, repository, merge_group: { head_sha: SHA, head_ref: 'refs/heads/gh-readonly-queue/main/pr-1' } });
  await lands('merge_group', mg('checks_requested'), 'merge_group', SHA, 'merge_group.checks_requested');
  await lands('merge_group', mg('destroyed'), 'merge_group', SHA, 'merge_group.destroyed');
  await dropped('merge_group', mg('created'), 'merge_group other action');
});

test('W10: no payload text reaches a row for any new event', async () => {
  const S = 'SENTINEL4058';
  const cases = [
    ['issues', labeled('ai-build', { issue: { number: 41, title: S, body: S } })],
    ['deployment_status', { action: 'created', repository, deployment: { sha: SHA, description: S }, deployment_status: { state: 'failure', description: S, target_url: S } }],
    ['status', { repository, sha: SHA, state: 'failure', description: S, target_url: S, context: S }],
    ['workflow_run', { action: 'completed', repository, workflow_run: { head_sha: SHA, name: S, head_branch: S } }],
    ['merge_group', { action: 'checks_requested', repository, merge_group: { head_sha: SHA, head_ref: S, base_ref: S } }],
  ];
  for (const [event, payload] of cases) {
    const r = await deliver(event, payload);
    assert.equal(r.status, 200, `${event} should land`);
    const ins = inserts(r);
    assert.equal(ins.length, 1);
    assert.equal(ins[0].binds.length, 6, `${event}: binds are [repo, kind, key, event, minute, at]`);
    for (const b of ins[0].binds) assert.ok(!String(b).includes(S), `${event}: payload text in a bind: ${b}`);
    // The label name decides; it is never stored.
    if (event === 'issues') assert.ok(!ins[0].binds.includes('ai-build'));
  }
});

test('W11: an unsigned status delivery is 401 with no row', async () => {
  const r = await deliver('status', { repository, sha: SHA, state: 'success' }, { sign: false });
  assert.equal(r.status, 401);
  assert.equal(inserts(r).length, 0);
});
