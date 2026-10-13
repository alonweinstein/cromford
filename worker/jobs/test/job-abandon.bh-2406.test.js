import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { JOB_TRANSITIONS, checkTransition } from '../src/lib/core.js';

// BH-2406: POST /api/jobs/:id/abandon, the operator's audited move to a
// terminal `abandoned` state, driven through the worker's real fetch handler.
//
// THE FAKE D1 IS STATEFUL AND MODELS THE GUARDS, because the guards are the
// feature: the status write is a compare-and-set on the status the route read,
// the audit event and the queue close only land when that CAS landed, and all
// three ride one batch. A stub that answered "changes: 1" to everything would
// pass a route that wrote an event for a CAS it lost. The SQL itself is proven
// by the deploy's smoke run against real D1, the same split requeue.test.js
// states.

const SECRET = 'test-secret';
const ID = 'build-cromford-BH-9-1';

function fakeDB(state) {
  state.jobs = state.jobs || [];
  state.events = state.events || [];
  state.queue = state.queue || [];
  state.claims = state.claims || [];
  const calls = [];
  const batches = [];
  const norm = (sql) => sql.replace(/\s+/g, ' ').trim();
  const jobById = (id) => state.jobs.find((j) => j.id === id);
  const exec = (sql, b) => {
    const s = norm(sql);
    calls.push({ sql: s, binds: b });
    if (/^SELECT \* FROM jobs WHERE id=\?1$/.test(s)) return { rows: state.jobs.filter((j) => j.id === b[0]) };
    if (/^SELECT status FROM jobs WHERE id=\?1$/.test(s)) return { rows: state.jobs.filter((j) => j.id === b[0]).map((j) => ({ status: j.status })) };
    if (/FROM job_claims WHERE job_id=/.test(s)) return { rows: state.claims.filter((c) => c.job_id === b[0]) };
    if (/^INSERT INTO job_claims/.test(s)) {
      if (state.claimThrows) throw new Error('claim write failed');
      state.claims = state.claims.filter((c) => c.job_id !== b[0]);
      state.claims.push({ job_id: b[0], lane: b[1], reason: b[6] });
      return { changes: 1 };
    }
    // The CAS status write: UPDATE jobs SET status='abandoned', updated_at=?1 WHERE id=?2 AND status=?3
    if (/^UPDATE jobs SET status='abandoned', updated_at=\?1 WHERE id=\?2 AND status=\?3$/.test(s)) {
      const j = jobById(b[1]);
      if (!j || j.status !== b[2]) return { changes: 0 };
      j.status = 'abandoned'; j.updated_at = b[0];
      return { changes: 1 };
    }
    // The audit event, guarded on the CAS having landed and on no prior event.
    if (/^INSERT INTO stage_events .* SELECT \?1, \?2, 'ABANDONED', \?3, \?4, \?5 WHERE EXISTS \(SELECT 1 FROM jobs WHERE id=\?1 AND status='abandoned' AND updated_at=\?5\) AND NOT EXISTS \(SELECT 1 FROM stage_events WHERE job_id=\?1 AND verdict='ABANDONED'\)$/.test(s)) {
      const j = jobById(b[0]);
      const landed = j && j.status === 'abandoned' && j.updated_at === b[4];
      const prior = state.events.some((e) => e.job_id === b[0] && e.verdict === 'ABANDONED');
      if (!landed || prior) return { changes: 0 };
      state.events.push({ job_id: b[0], stage: b[1], verdict: 'ABANDONED', actor: b[2], detail: b[3], created_at: b[4] });
      return { changes: 1 };
    }
    // The queue close: ready/queued rows of this ticket, only when the CAS
    // landed and no NEWER build row exists for the ticket.
    if (/^UPDATE build_queue SET status='failed', reason=\?1, finished_at=\?2, updated_at=\?2 WHERE project=\?3 AND ticket_key=\?4 AND status IN \('ready','queued'\) AND EXISTS \(SELECT 1 FROM jobs WHERE id=\?5 AND status='abandoned' AND updated_at=\?2\) AND NOT EXISTS \(SELECT 1 FROM jobs WHERE project=\?3 AND ticket_id=\?4 AND kind='build' AND created_at > \(SELECT created_at FROM jobs WHERE id=\?5\)\)$/.test(s)) {
      const j = jobById(b[4]);
      const landed = j && j.status === 'abandoned' && j.updated_at === b[1];
      const newer = state.jobs.some((o) => o.project === b[2] && o.ticket_id === b[3] && o.kind === 'build' && j && o.created_at > j.created_at);
      if (!landed || newer) return { changes: 0 };
      let n = 0;
      for (const q of state.queue) {
        if (q.project === b[2] && q.ticket_key === b[3] && (q.status === 'ready' || q.status === 'queued')) {
          q.status = 'failed'; q.reason = b[0]; q.finished_at = b[1]; n += 1;
        }
      }
      return { changes: n };
    }
    // A generic PATCH status write (the side door this ticket closes).
    if (/^UPDATE jobs SET /.test(s)) {
      const j = jobById(b[b.length - 1]);
      if (!j) return { changes: 0 };
      const m = /status=\?(\d+)/.exec(s);
      if (m) j.status = b[Number(m[1]) - 1];
      return { changes: 1 };
    }
    if (/FROM jobs j/.test(s)) return { rows: [] };
    return { rows: [], changes: 0 };
  };
  const bound = (sql, binds) => ({
    _sql: sql, _binds: binds,
    first: async () => (exec(sql, binds).rows || [])[0] || null,
    all: async () => ({ results: exec(sql, binds).rows || [] }),
    run: async () => ({ meta: { changes: exec(sql, binds).changes || 0, last_row_id: 1 } }),
  });
  return {
    prepare: (sql) => ({ ...bound(sql, []), bind: (...binds) => bound(sql, binds) }),
    // D1's batch is one transaction. The fake runs the statements in order
    // and reports each one's changes, which is all the route reads.
    batch: async (stmts) => {
      if (state.beforeBatch) state.beforeBatch();
      batches.push(stmts.map((st) => norm(st._sql)));
      return stmts.map((st) => ({ meta: { changes: exec(st._sql, st._binds).changes || 0 } }));
    },
    _calls: calls, _batches: batches,
  };
}

const call = (path, { method = 'POST', body = {}, state = {} } = {}) => {
  const db = fakeDB(state);
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: method === 'GET' ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB: db, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null), db, state,
  }));
};

const JOB = (over) => ({
  id: ID, project: 'cromford', kind: 'build', stage: 'execute', box: 'hub-1',
  ticket_id: 'BH-9', status: 'running', budget_usd: 150, spent_usd: 3,
  created_at: '2026-09-25T10:00:00Z', updated_at: '2026-09-25T10:00:00Z', ...over,
});
const Q = (over) => ({ project: 'cromford', ticket_key: 'BH-9', status: 'queued', reason: null, ...over });
const writes = (db) => db._calls.filter((c) => /^(UPDATE|INSERT|DELETE)/.test(c.sql));
const abandon = (body, state) => call(`/api/jobs/${ID}/abandon`, { body, state });

// ---- T1: the transition graph -------------------------------------------------
test('T1: abandoned is a known, terminal job status reachable from every non-terminal one', () => {
  for (const from of ['running', 'queued_for_retry', 'parked', 'orphaned', 'failed']) {
    assert.equal(checkTransition(JOB_TRANSITIONS, from, 'abandoned', 'job'), null, `${from} -> abandoned`);
  }
  for (const to of ['running', 'queued_for_retry', 'parked', 'orphaned', 'failed', 'done']) {
    assert.ok(checkTransition(JOB_TRANSITIONS, 'abandoned', to, 'job'), `abandoned -> ${to} must be refused`);
  }
  assert.equal(checkTransition(JOB_TRANSITIONS, 'abandoned', 'abandoned', 'job'), null);
  assert.ok(checkTransition(JOB_TRANSITIONS, 'done', 'abandoned', 'job'), 'done stays terminal');
  assert.ok(checkTransition(JOB_TRANSITIONS, 'budget_stopped', 'abandoned', 'job'), 'budget_stopped stays terminal');
});

// ---- T2: the route ------------------------------------------------------------
for (const status of ['running', 'queued_for_retry', 'parked', 'orphaned', 'failed']) {
  test(`T2: a ${status} job is abandoned, with ONE audited event naming actor and reason`, async () => {
    const r = await abandon({ reason: '  stuck on a dead branch  ', actor: 'console' }, { jobs: [JOB({ status })] });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.decision, 'abandoned');
    assert.equal(r.body.reason, 'stuck on a dead branch');
    assert.equal(r.body.actor, 'console');
    assert.equal(r.state.jobs[0].status, 'abandoned');
    assert.deepEqual(r.state.events.map((e) => [e.job_id, e.verdict, e.actor, e.detail, e.stage]),
      [[ID, 'ABANDONED', 'console', 'stuck on a dead branch', 'execute']]);
    assert.equal(r.db._batches.length, 1, 'status, event and queue close ride ONE batch');
  });
}

test('T2: the ticket\'s ready/queued queue rows are closed FAILED "ABANDONED ...", a claimed row is left to the pool', async () => {
  const state = {
    jobs: [JOB({ status: 'parked' })],
    queue: [Q({ status: 'queued' }), Q({ ticket_key: 'BH-10', status: 'queued' }), Q({ project: 'other', status: 'ready' })],
  };
  const r = await abandon({ reason: 'not worth it', actor: 'console' }, state);
  assert.equal(r.status, 200);
  assert.equal(r.body.queue_rows_closed, 1);
  assert.equal(state.queue[0].status, 'failed');
  assert.match(state.queue[0].reason, /^ABANDONED by console from job build-cromford-BH-9-1: not worth it$/);
  assert.equal(state.queue[1].status, 'queued', 'another ticket untouched');
  assert.equal(state.queue[2].status, 'ready', 'the same key in another project untouched');

  const claimed = { jobs: [JOB({ status: 'orphaned' })], queue: [Q({ status: 'claimed' })] };
  const r2 = await abandon({ reason: 'x', actor: 'console' }, claimed);
  assert.equal(r2.status, 200);
  assert.equal(claimed.queue[0].status, 'claimed', 'a claimed row belongs to the pool\'s reap');
  assert.equal(r2.body.queue_rows_closed, 0);
});

test('T2: abandoning an OLDER row does not close the queue row a NEWER attempt owns', async () => {
  const state = {
    jobs: [JOB({ status: 'failed' }), JOB({ id: 'build-cromford-BH-9-2', status: 'running', created_at: '2026-09-25T12:00:00Z' })],
    queue: [Q({ status: 'queued' })],
  };
  const r = await abandon({ reason: 'old attempt', actor: 'console' }, state);
  assert.equal(r.status, 200);
  assert.equal(state.queue[0].status, 'queued');
});

test('T2: a ticketless job is abandoned with no queue statement at all', async () => {
  const state = { jobs: [JOB({ ticket_id: null, status: 'orphaned' })], queue: [Q({})] };
  const r = await abandon({ reason: 'lane tick', actor: 'console' }, state);
  assert.equal(r.status, 200);
  assert.equal(r.db._batches[0].length, 2);
  assert.equal(state.queue[0].status, 'queued');
});

test('T2: a second abandon answers `already` and writes nothing (one event, ever)', async () => {
  const state = { jobs: [JOB({ status: 'running' })] };
  await abandon({ reason: 'first', actor: 'console' }, state);
  const r = await abandon({ reason: 'second', actor: 'console' }, state);
  assert.equal(r.status, 200);
  assert.equal(r.body.decision, 'already');
  assert.equal(r.body.already, true);
  assert.deepEqual(writes(r.db), []);
  assert.equal(r.db._batches.length, 0);
  assert.equal(state.events.length, 1);
});

for (const status of ['done', 'budget_stopped']) {
  test(`T2: a ${status} job cannot be abandoned: 409, nothing written`, async () => {
    const r = await abandon({ reason: 'x', actor: 'console' }, { jobs: [JOB({ status })] });
    assert.equal(r.status, 409);
    assert.equal(r.body.refused, true);
    assert.deepEqual(writes(r.db), []);
    assert.equal(r.state.jobs[0].status, status);
  });
}

test('T2: no reason, a blank reason, or no actor is a 400 before any write', async () => {
  const cases = [
    [{ actor: 'console' }, 'reason required'],
    [{ reason: '   \n ', actor: 'console' }, 'reason required'],
    [{ reason: null, actor: 'console' }, 'reason required'],
    [{ reason: 'x' }, 'actor required'],
    [{ reason: 'x', actor: '  ' }, 'actor required'],
  ];
  for (const [body, err] of cases) {
    const r = await abandon(body, { jobs: [JOB({})] });
    assert.equal(r.status, 400, JSON.stringify(body));
    assert.equal(r.body.error, err);
    assert.deepEqual(writes(r.db), []);
    assert.equal(r.db._batches.length, 0);
    assert.equal(r.state.jobs[0].status, 'running');
  }
});

test('T2: an unknown job is a 404', async () => {
  const r = await abandon({ reason: 'x', actor: 'console' }, { jobs: [] });
  assert.equal(r.status, 404);
  assert.deepEqual(writes(r.db), []);
});

test('T2: the status moved between the read and the batch: 409, no event, no queue close', async () => {
  const state = { jobs: [JOB({ status: 'running' })], queue: [Q({})] };
  state.beforeBatch = () => { state.jobs[0].status = 'done'; };
  const r = await abandon({ reason: 'x', actor: 'console' }, state);
  assert.equal(r.status, 409);
  assert.equal(r.body.refused, true);
  assert.equal(state.jobs[0].status, 'done');
  assert.deepEqual(state.events, []);
  assert.equal(state.queue[0].status, 'queued');
});

test('T2: a CAS lost to ANOTHER abandon answers `already`, still one event', async () => {
  const state = { jobs: [JOB({ status: 'running' })] };
  state.beforeBatch = () => {
    state.jobs[0].status = 'abandoned'; state.jobs[0].updated_at = '2026-01-01T00:00:00Z';
    state.events.push({ job_id: ID, verdict: 'ABANDONED', actor: 'console', detail: 'the other tab' });
    state.beforeBatch = null;
  };
  const r = await abandon({ reason: 'mine', actor: 'console' }, state);
  assert.equal(r.status, 200);
  assert.equal(r.body.decision, 'already');
  assert.equal(state.events.length, 1);
});

test('T2: the claim reason is best-effort; a failed claim write does not change the answer', async () => {
  const state = { jobs: [JOB({})] };
  const r = await abandon({ reason: 'why', actor: 'console' }, state);
  assert.match(state.claims.find((c) => c.job_id === ID).reason, /abandoned by console: why/);
  const s2 = { jobs: [JOB({})], claimThrows: true };
  const r2 = await abandon({ reason: 'why', actor: 'console' }, s2);
  assert.equal(r.status, 200);
  assert.equal(r2.status, 200);
  assert.equal(r2.body.decision, 'abandoned');
});

// ---- T3: the side door and the ticket filter -------------------------------
test('T3: PATCH {status:"abandoned"} is refused 409 and the row is unchanged', async () => {
  const state = { jobs: [JOB({ status: 'running' })] };
  const r = await call(`/api/jobs/${ID}`, { method: 'PATCH', body: { status: 'abandoned' }, state });
  assert.equal(r.status, 409);
  assert.match(r.body.error, /abandon through POST \/api\/jobs\/:id\/abandon/);
  assert.equal(state.jobs[0].status, 'running');
  assert.deepEqual(writes(r.db), []);
});

test('T3: PATCH to another status still works (regression)', async () => {
  const state = { jobs: [JOB({ status: 'running' })] };
  const r = await call(`/api/jobs/${ID}`, { method: 'PATCH', body: { status: 'done' }, state });
  assert.equal(r.status, 200);
  assert.equal(state.jobs[0].status, 'done');
});

test('T3: an abandoned row refuses every later status write, so a late close cannot revive it', async () => {
  const state = { jobs: [JOB({ status: 'abandoned' })] };
  for (const status of ['done', 'failed', 'running']) {
    const r = await call(`/api/jobs/${ID}`, { method: 'PATCH', body: { status }, state });
    assert.equal(r.status, 409, status);
  }
  assert.equal(state.jobs[0].status, 'abandoned');
});

test('T3: GET /api/jobs binds ticket_id into the WHERE', async () => {
  const r = await call('/api/jobs?project=cromford&ticket_id=BH-9&limit=1', { method: 'GET' });
  assert.equal(r.status, 200);
  const q = r.db._calls.find((c) => /FROM jobs j/.test(c.sql));
  assert.match(q.sql, /j\.project=\?1 AND j\.ticket_id=\?2/);
  assert.deepEqual(q.binds, ['cromford', 'BH-9']);
  assert.match(q.sql, /LIMIT 1$/);
});

// Review of #2481: triage-shard, lead-review, orc-job and migration-autopilot
// open rows under the same ticket key. Only a BUILD row is an attempt at the
// ticket, so only a build row may stand between an abandon and its queue close,
// and the shell's job_ticket_abandoned asks for the newest BUILD row by kind.
test('T2: a NEWER non-build row (triage, lead_review, ...) does not keep the abandoned build\'s queue row open', async () => {
  for (const kind of ['triage', 'lead_review', 'orchestrator', 'migration']) {
    const state = {
      jobs: [JOB({ status: 'parked' }),
        JOB({ id: `${kind}-cromford-BH-9-2`, kind, status: 'running', created_at: '2026-09-25T12:00:00Z' })],
      queue: [Q({ status: 'queued' })],
    };
    const r = await abandon({ reason: 'not worth it', actor: 'console' }, state);
    assert.equal(r.status, 200, kind);
    assert.equal(state.queue[0].status, 'failed', `a newer ${kind} row must not keep the queue row open`);
    assert.equal(r.body.queue_rows_closed, 1, kind);
  }
});

test('T3: GET /api/jobs binds kind into the WHERE (job_ticket_abandoned asks for kind=build)', async () => {
  const r = await call('/api/jobs?project=cromford&ticket_id=BH-9&kind=build&limit=1', { method: 'GET' });
  assert.equal(r.status, 200);
  const q = r.db._calls.find((c) => /FROM jobs j/.test(c.sql));
  assert.match(q.sql, /j\.project=\?1 AND j\.ticket_id=\?2 AND j\.kind=\?3/);
  assert.deepEqual(q.binds, ['cromford', 'BH-9', 'build']);
});
