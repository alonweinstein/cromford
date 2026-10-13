import test from 'node:test';
import assert from 'node:assert/strict';
import { RUNNING, call, iso } from '../lib/harness.js';

const PHASE = (over) => ({
  id: 11, job_id: 'build-project-3-TK-1-1', phase: 'plan', runner: 'claude',
  status: 'running', started_at: iso(600e3), ...over
});

test('a phase cannot be opened on a job that does not exist', async () => {
  const r = await call('/api/jobs/ghost/phases', { method: 'POST', body: { phase: 'plan' } });
  assert.equal(r.status, 404);
});

test('opening a phase never guards - the JOB is the claim, the phase is a child', async () => {
  // The same job, opening a second phase while one is still running. If this
  // ever answers 409 the pipeline would stall between stages on work it has
  // already been granted, which is the failure this whole layer exists to
  // remove, reintroduced one level down.
  const state = {
    jobs: [RUNNING()],
    phases: [{ id: 1, job_id: 'build-project-3-TK-1-1', phase: 'plan', status: 'running', started_at: iso(60e3) }]
  };
  const r = await call('/api/jobs/build-project-3-TK-1-1/phases', {
    method: 'POST', body: { phase: 'execute', runner: 'claude', model: 'stage-model' }, state
  });
  assert.equal(r.status, 201);
  const ins = r.db._calls.find((c) => /INSERT INTO job_phases/.test(c.sql));
  assert.equal(ins.binds[4] !== undefined, true);
  assert.equal(ins.binds[1], 'execute');
  assert.equal(ins.binds[2], 'claude');
});

test('a phase needs a name', async () => {
  const r = await call('/api/jobs/build-project-3-TK-1-1/phases', {
    method: 'POST', body: { runner: 'claude' }, state: { jobs: [RUNNING()] }
  });
  assert.equal(r.status, 400);
});

test('closing a phase stores the REAL rc and stamps finished_at', async () => {
  const state = { phases: [{ id: 7, job_id: 'build-project-3-TK-1-1', phase: 'execute', status: 'running' }] };
  const r = await call('/api/phases/7', {
    method: 'PATCH', body: { status: 'failed', rc: 137, spend_usd: 12.5, note: 'KILL_STOP served by claude' }, state
  });
  assert.equal(r.status, 200);
  const upd = r.db._calls.find((c) => /UPDATE job_phases SET/.test(c.sql));
  assert.match(upd.sql, /finished_at=/);
  assert.ok(upd.binds.includes(137), 'the exit code must be stored as given, never laundered');
  assert.ok(upd.binds.includes(12.5));
});

test('a phase status outside the allowlist is refused rather than rendered as unknown', async () => {
  const r = await call('/api/phases/7', { method: 'PATCH', body: { status: 'kinda-done' } });
  assert.equal(r.status, 400);
  const none = await call('/api/phases/7', { method: 'PATCH', body: {} });
  assert.equal(none.status, 400);
});

test('close-open names the phases it closed, because the caller has to page about them', async () => {
  const state = {
    jobs: [RUNNING()],
    phases: [
      { id: 1, job_id: 'build-project-3-TK-1-1', phase: 'plan', status: 'done' },
      { id: 2, job_id: 'build-project-3-TK-1-1', phase: 'execute', status: 'running' }
    ]
  };
  const r = await call('/api/jobs/build-project-3-TK-1-1/phases/close', {
    method: 'POST', body: { status: 'orphaned', note: 'job orphaned: no heartbeat for 35m' }, state
  });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.phases.map((p) => p.phase), ['execute'],
    'only the OPEN phase is named - a phase that already closed was not judged here');
  const upd = r.db._calls.find((c) => /UPDATE job_phases SET status/.test(c.sql));
  assert.match(upd.sql, /status='running'/);
});

test('close-open refuses a status the console cannot render', async () => {
  const r = await call('/api/jobs/x/phases/close', { method: 'POST', body: { status: 'weird' } });
  assert.equal(r.status, 400);
});

test('with phase_contracts empty a done close is a done close', async () => {
  const state = { jobs: [RUNNING()], phases: [PHASE()], contracts: [] };
  const r = await call('/api/phases/11', { method: 'PATCH', body: { status: 'done', rc: 0 }, state });
  assert.equal(r.status, 200);
  // The stub does not apply writes, so the WRITE is what is asserted here — the
  // row that comes back is the fixture, and asserting on it would prove nothing.
  assert.equal(r.db._calls.find((c) => /UPDATE job_phases SET status=/.test(c.sql)).binds[0], 'done');
});

test('a phase with a contract cannot close done without its artifact', async () => {
  const state = {
    jobs: [RUNNING()], phases: [PHASE()],
    contracts: [{ phase: 'plan', artifact_kind: 'plan_file', pattern: null, note: 'a plan stage must leave a plan' }],
    artifacts: []
  };
  const r = await call('/api/phases/11', { method: 'PATCH', body: { status: 'done', rc: 0 }, state });
  assert.equal(r.status, 409);
  assert.equal(r.body.contract_unmet, true);
  assert.match(r.body.reason, /must record a plan_file artifact/);
  // The row is NOT left open. A phase stuck at `running` forever is the exact
  // silence job_phases exists to remove, so the close lands as contract_unmet.
  const upd = r.db._calls.find((c) => /UPDATE job_phases SET status=/.test(c.sql));
  assert.equal(upd.binds[0], 'contract_unmet');
  assert.match(String(upd.binds[3]), /^CONTRACT_UNMET: /);
  // ...and the rc the stage really exited with survives the downgrade.
  assert.equal(upd.binds[2], 0);
});

test('the artifact satisfies the contract and the phase closes done', async () => {
  const state = {
    jobs: [RUNNING()], phases: [PHASE()],
    contracts: [{ phase: 'plan', artifact_kind: 'plan_file', pattern: null }],
    artifacts: [{ job_id: 'build-project-3-TK-1-1', artifact_kind: 'plan_file', artifact_ref: '/b/plan.md' }]
  };
  const r = await call('/api/phases/11', { method: 'PATCH', body: { status: 'done', rc: 0 }, state });
  assert.equal(r.status, 200);
  assert.equal(r.db._calls.find((c) => /UPDATE job_phases SET status=/.test(c.sql)).binds[0], 'done');
});

test('a blank artifact does not satisfy a contract, and cannot be recorded at all', async () => {
  // Both halves matter: a contract satisfied by an empty string is worse than
  // no contract, because it reads as evidence.
  const state = {
    jobs: [RUNNING()], phases: [PHASE()],
    contracts: [{ phase: 'plan', artifact_kind: 'plan_file', pattern: null }],
    artifacts: [{ job_id: 'build-project-3-TK-1-1', artifact_kind: 'plan_file', artifact_ref: '   ' }]
  };
  const r = await call('/api/phases/11', { method: 'PATCH', body: { status: 'done' }, state });
  assert.equal(r.status, 409);
  const w = await call('/api/jobs/build-project-3-TK-1-1/artifacts', {
    method: 'PUT', body: { artifact_kind: 'plan_file', artifact_ref: '' }, state: { jobs: [RUNNING()] }
  });
  assert.equal(w.status, 400);
});

test('a contract pattern is a substring the ref must contain', async () => {
  const contracts = [{ phase: 'review', artifact_kind: 'verdict', pattern: 'APPROVE' }];
  const base = { jobs: [RUNNING()], phases: [PHASE({ phase: 'review' })], contracts };
  const blocked = await call('/api/phases/11', { method: 'PATCH', body: { status: 'done' },
    state: { ...base, artifacts: [{ job_id: 'build-project-3-TK-1-1', artifact_kind: 'verdict', artifact_ref: 'BLOCK' }] } });
  assert.equal(blocked.status, 409);
  assert.match(blocked.body.reason, /does not contain "APPROVE"/);
  const okd = await call('/api/phases/11', { method: 'PATCH', body: { status: 'done' },
    state: { ...base, artifacts: [{ job_id: 'build-project-3-TK-1-1', artifact_kind: 'verdict', artifact_ref: 'APPROVE' }] } });
  assert.equal(okd.status, 200);
});

test('a contract binds on the pipeline bulk close too, per phase', async () => {
  // run-build.sh's cleanup hook closes every still-open phase. If a contract
  // could be walked around by closing through THAT route, the contract would be
  // a rule about which endpoint you used.
  const state = {
    jobs: [RUNNING()],
    phases: [PHASE({ id: 11, phase: 'plan' }), PHASE({ id: 12, phase: 'execute' })],
    contracts: [{ phase: 'plan', artifact_kind: 'plan_file', pattern: null }],
    artifacts: []
  };
  const r = await call('/api/jobs/build-project-3-TK-1-1/phases/close', {
    method: 'POST', body: { status: 'done' }, state
  });
  assert.equal(r.status, 409);
  assert.equal(r.body.breaches.length, 1, 'only the phase that HAS a contract may breach one');
  assert.equal(r.body.breaches[0].phase, 'plan');
  const writes = r.db._calls.filter((c) => /UPDATE job_phases SET status=/.test(c.sql));
  assert.deepEqual(writes.map((w) => w.binds[1]), ['contract_unmet', 'done'],
    'the uncontracted phase still closes done; only the breaching one is downgraded');
});

test('a non-done close is never held to a contract', async () => {
  // A failed stage produced nothing and says so. Holding a failure to a contract
  // would make an honest failure impossible to record.
  const state = {
    jobs: [RUNNING()], phases: [PHASE()],
    contracts: [{ phase: 'plan', artifact_kind: 'plan_file', pattern: null }], artifacts: []
  };
  const r = await call('/api/phases/11', { method: 'PATCH', body: { status: 'failed', rc: 137 }, state });
  assert.equal(r.status, 200);
  assert.equal(r.db._calls.find((c) => /UPDATE job_phases SET status=/.test(c.sql)).binds[0], 'failed');
});

test('contract_unmet is repairable: record the artifact, close again', async () => {
  const state = {
    jobs: [RUNNING()], phases: [PHASE({ status: 'contract_unmet' })],
    contracts: [{ phase: 'plan', artifact_kind: 'plan_file', pattern: null }],
    artifacts: [{ job_id: 'build-project-3-TK-1-1', artifact_kind: 'plan_file', artifact_ref: '/b/plan.md' }]
  };
  const r = await call('/api/phases/11', { method: 'PATCH', body: { status: 'done' }, state });
  assert.equal(r.status, 200, 'contract_unmet is a phase waiting for evidence, not a terminal failure');
});

test('a phase in done is terminal, and an orphaned one may be corrected', async () => {
  const back = await call('/api/phases/11', {
    method: 'PATCH', body: { status: 'running' }, state: { jobs: [RUNNING()], phases: [PHASE({ status: 'done' })] }
  });
  assert.equal(back.status, 409);
  assert.equal(back.body.error, 'illegal phase transition');
  const fix = await call('/api/phases/11', {
    method: 'PATCH', body: { status: 'failed', rc: 137 },
    state: { jobs: [RUNNING()], phases: [PHASE({ status: 'orphaned' })] }
  });
  assert.equal(fix.status, 200);
});
