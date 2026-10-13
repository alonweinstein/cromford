import test from 'node:test';
import assert from 'node:assert/strict';
import { POLICY, RUNNING, call } from '../lib/harness.js';

test('no policy for the lane means orphaned - detection only, exactly as before', async () => {
  const state = { jobs: [RUNNING()], claims: [{ job_id: 'build-project-3-TK-1-1', lane: 'execute/project-3/claude', attempts: 1 }] };
  const r = await call('/api/jobs/build-project-3-TK-1-1/retry', { method: 'POST', body: { detail: 'no heartbeat for 35m' }, state });
  assert.equal(r.status, 200);
  assert.equal(r.body.decision, 'orphaned');
  assert.match(r.body.reason, /no retry policy for lane execute\/project-3\/claude/);
  assert.equal(r.body.next_attempt_at, null);
});

test('within policy the row is QUEUED, with the backoff on it', async () => {
  const state = {
    jobs: [RUNNING()],
    claims: [{ job_id: 'build-project-3-TK-1-1', lane: 'plan/project-3/claude', attempts: 1 }],
    policies: [POLICY()]
  };
  const r = await call('/api/jobs/build-project-3-TK-1-1/retry', { method: 'POST', body: {}, state });
  assert.equal(r.body.decision, 'queued_for_retry');
  assert.equal(r.body.attempts, 1);
  assert.equal(r.body.max_attempts, 3);
  const wait = Date.parse(r.body.next_attempt_at) - Date.parse(r.body.as_of);
  assert.equal(wait, 600000, 'next_attempt_at must be exactly the policy backoff away');
  // The status written is the decision, and it is written ONCE.
  const upd = r.db._calls.filter((c) => /UPDATE jobs SET status/.test(c.sql));
  assert.equal(upd.length, 1);
  assert.ok(upd[0].binds.includes('queued_for_retry'));
});

test('an exhausted policy PARKS the row rather than queueing it forever', async () => {
  const state = {
    jobs: [RUNNING()],
    claims: [{ job_id: 'build-project-3-TK-1-1', lane: 'plan/project-3/claude', attempts: 3 }],
    policies: [POLICY()]
  };
  const r = await call('/api/jobs/build-project-3-TK-1-1/retry', { method: 'POST', body: {}, state });
  assert.equal(r.body.decision, 'parked');
  assert.match(r.body.reason, /retries exhausted \(3 of 3\)/);
  assert.equal(r.body.next_attempt_at, null);
});

test('a KILL_STOP death is TERMINAL even where a policy would allow a retry', async () => {
  // bin/agent-call.sh already serves its own single same-lane retry for these.
  // Retrying the job on top of that is the second attempt paying for the third.
  const state = {
    jobs: [RUNNING()],
    claims: [{ job_id: 'build-project-3-TK-1-1', lane: 'plan/project-3/claude', attempts: 1 }],
    policies: [POLICY()],
    phases: [{ id: 4, job_id: 'build-project-3-TK-1-1', phase: 'execute', status: 'failed',
      rc: 137, note: 'KILL_STOP served by claude' }]
  };
  const r = await call('/api/jobs/build-project-3-TK-1-1/retry', { method: 'POST', body: {}, state });
  assert.equal(r.body.decision, 'orphaned');
  assert.match(r.body.reason, /terminal/);
  assert.match(r.body.reason, /KILL_STOP/);
});

test('a BUDGET_STOPPED job is terminal on its own status', async () => {
  const state = {
    jobs: [RUNNING({ status: 'running' })],
    claims: [{ job_id: 'build-project-3-TK-1-1', lane: 'plan/project-3/claude', attempts: 1 }],
    policies: [POLICY()],
    events: [{ id: 1, job_id: 'build-project-3-TK-1-1', stage: 'execute', verdict: 'BUDGET_STOP' }]
  };
  const r = await call('/api/jobs/build-project-3-TK-1-1/retry', { method: 'POST', body: {}, state });
  assert.equal(r.body.decision, 'orphaned');
  assert.match(r.body.reason, /BUDGET_STOP/);
});

test('judging a row that is no longer running writes nothing and repeats the verdict', async () => {
  // The watchdog can pass over the same row twice. A second judgement that reset
  // a backoff, or counted another attempt, would make the policy meaningless.
  const state = {
    jobs: [RUNNING({ status: 'queued_for_retry' })],
    claims: [{ job_id: 'build-project-3-TK-1-1', lane: 'plan/project-3/claude', attempts: 2,
      max_attempts: 3, next_attempt_at: '2026-08-29T00:10:00Z', reason: 'attempt 2 of 3' }],
    policies: [POLICY()]
  };
  const r = await call('/api/jobs/build-project-3-TK-1-1/retry', { method: 'POST', body: {}, state });
  assert.equal(r.body.already, true);
  assert.equal(r.body.decision, 'queued_for_retry');
  assert.equal(r.body.next_attempt_at, '2026-08-29T00:10:00Z');
  assert.equal(r.db._calls.filter((c) => /UPDATE jobs SET/.test(c.sql)).length, 0);
});

test('judging a job that does not exist is a 404, never an invented row', async () => {
  const r = await call('/api/jobs/ghost/retry', { method: 'POST', body: {} });
  assert.equal(r.status, 404);
});
