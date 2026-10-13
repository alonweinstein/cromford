import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';

// POST /api/jobs/:id/requeue — the SILENT auto-requeue, driven through the
// worker's real fetch handler.
//
// WHY THIS ROUTE EXISTS. bin/jobs-watchdog.sh has always REPORTED a row that
// never heartbeated and deliberately left it `running`: age is not proof of
// death, and releasing a claim on live work is how one ticket gets built twice.
// The consequence showed up on 2026-09-15 — ten triage rows claimed and
// abandoned inside 24h, each one holding a ticket that was never re-offered,
// because a box only re-offers on its own tick if the ticket is still visible
// on its board. The TTL pass now convicts those rows; this route is what hands
// their tickets back.
//
// WHAT IS PROVEN HERE, given D1 is stubbed by SQL pattern: the decisions. Which
// rows are refused and why (a live sibling, a ticketless lane tick, a row that
// already moved on), that the attempt counter is read from the ledger's own
// stage_events rather than invented, that the cap parks instead of looping, and
// that a refused decision writes NOTHING. The SQL itself is proven by the
// deploy's smoke run against real D1.

const SECRET = 'test-secret';

function fakeDB(state) {
  const calls = [];
  const result = (sql, binds) => {
    calls.push({ sql: sql.replace(/\s+/g, ' ').trim(), binds });
    if (/FROM job_claims WHERE job_id=/.test(sql)) {
      return { rows: (state.claims || []).filter((c) => c.job_id === binds[0]) };
    }
    // The sibling probe. Filtered FOR REAL on every bind, because the whole
    // guarantee is WHICH rows count as a live owner — a stub answering "any
    // job row" would pass on a worker that refused every requeue, and one
    // answering "none" would pass on a worker that had no guard at all.
    if (/FROM jobs WHERE project=\?1 AND ticket_id=\?2 AND status=\?3 AND id<>\?4/.test(sql)) {
      return { rows: (state.jobs || []).filter((j) => j.project === binds[0]
        && j.ticket_id === binds[1] && j.status === binds[2] && j.id !== binds[3]) };
    }
    if (/FROM jobs WHERE id=/.test(sql)) {
      return { rows: (state.jobs || []).filter((j) => j.id === binds[0]) };
    }
    // The attempt counter IS this query. It is filtered on the verdict too, so
    // a worker that counted every event on the row would show up as a job that
    // parks after its first orphan.
    if (/COUNT\(\*\) AS n FROM stage_events WHERE job_id=\?1 AND verdict=\?2/.test(sql)) {
      return { rows: [{ n: (state.events || []).filter((e) => e.job_id === binds[0]
        && e.verdict === binds[1]).length }] };
    }
    return { rows: [] };
  };
  const stmt = (sql) => ({
    _sql: sql,
    bind: (...binds) => ({
      _sql: sql, _binds: binds,
      first: async () => result(sql, binds).rows[0] || null,
      all: async () => ({ results: result(sql, binds).rows }),
      run: async () => { result(sql, binds); return { meta: { changes: 1, last_row_id: 1 } }; }
    }),
    first: async () => result(sql, []).rows[0] || null,
    all: async () => ({ results: result(sql, []).rows }),
    run: async () => { result(sql, []); return { meta: { changes: 1, last_row_id: 1 } }; }
  });
  return { prepare: stmt, _calls: calls };
}

const call = (path, { method = 'POST', body = {}, state = {} } = {}) => {
  const db = fakeDB(state);
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify(body)
  });
  return worker.fetch(req, { DB: db, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null), db
  }));
};

const SILENT = (over) => ({
  id: 'triage-project-5-pr-976', project: 'project-5', kind: 'triage', stage: 'triage',
  box: 'box-project-5-1', ticket_id: 'pr-976', status: 'running',
  budget_usd: 25, spent_usd: 0.4,
  created_at: '2026-09-15T00:59:00Z', updated_at: '2026-09-15T00:59:00Z',
  ...over
});
const writes = (db) => db._calls.filter((c) => /^(UPDATE|INSERT)/.test(c.sql));
const statusWrite = (db) => db._calls.find((c) => /^UPDATE jobs SET status/.test(c.sql));

test('a silent triage row is requeued, and the lane picks it up — not the watchdog', async () => {
  const r = await call('/api/jobs/triage-project-5-pr-976/requeue', {
    body: { detail: '916m running with no heartbeat', max_attempts: 3 },
    state: { jobs: [SILENT()] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.decision, 'queued_for_retry');
  assert.equal(r.body.attempts, 1);
  assert.match(r.body.reason, /916m running with no heartbeat/);
  assert.match(r.body.reason, /lane's own next tick/);
  assert.ok(statusWrite(r.db).binds.includes('queued_for_retry'));
});

test('the attempt counter is the ledger\'s own history, not a number the caller sent', async () => {
  // Two REQUEUED events already on the row: this is the third attempt. The
  // count lives in stage_events on purpose — a hub-local file would forget it
  // on every rebuild, which is exactly when a lane is most likely to be sick.
  const state = {
    jobs: [SILENT()],
    events: [
      { job_id: 'triage-project-5-pr-976', verdict: 'REQUEUED' },
      { job_id: 'triage-project-5-pr-976', verdict: 'REQUEUED' },
      { job_id: 'triage-project-5-pr-976', verdict: 'ORPHANED' },
      { job_id: 'some-other-job', verdict: 'REQUEUED' }
    ]
  };
  const r = await call('/api/jobs/triage-project-5-pr-976/requeue', { body: { max_attempts: 3 }, state });
  assert.equal(r.body.decision, 'queued_for_retry');
  assert.equal(r.body.attempts, 3);
  assert.match(r.body.reason, /auto-requeue 3 of 3/);
});

test('past the cap it PARKS, and the reason carries the count that made it one', async () => {
  const state = {
    jobs: [SILENT()],
    events: Array.from({ length: 3 }, () => ({ job_id: 'triage-project-5-pr-976', verdict: 'REQUEUED' }))
  };
  const r = await call('/api/jobs/triage-project-5-pr-976/requeue', { body: { max_attempts: 3 }, state });
  assert.equal(r.body.decision, 'parked');
  assert.match(r.body.reason, /auto-requeued 3 times already \(cap 3\)/);
  assert.match(r.body.reason, /blocked-resolver/);
  assert.ok(statusWrite(r.db).binds.includes('parked'));
  // The event it writes is the CAPPED one, so a grep for REQUEUED cannot
  // inflate the next pass's count past the cap forever.
  const ev = r.db._calls.find((c) => /INSERT INTO stage_events/.test(c.sql));
  assert.ok(ev.binds.includes('REQUEUE_CAPPED'));
});

test('a ticket with another LIVE row is HELD — a requeue there is a second attempt', async () => {
  const state = { jobs: [
    SILENT(),
    SILENT({ id: 'triage-project-5-pr-976-b', box: 'box-project-5-1' })
  ] };
  const r = await call('/api/jobs/triage-project-5-pr-976/requeue', { body: {}, state });
  assert.equal(r.body.decision, 'held');
  assert.equal(r.body.held_by, 'triage-project-5-pr-976-b');
  assert.match(r.body.reason, /already live as triage-project-5-pr-976-b/);
  assert.equal(writes(r.db).length, 0, 'a held requeue must write nothing at all');
});

test('a ticketless LANE TICK is held — run-triage opens a fresh row every tick', async () => {
  const r = await call('/api/jobs/triage-project-3-noticket/requeue', {
    body: {},
    state: { jobs: [SILENT({ id: 'triage-project-3-noticket', project: 'project-3', ticket_id: null })] }
  });
  assert.equal(r.body.decision, 'held');
  assert.match(r.body.reason, /ticketless lane tick/);
  assert.equal(writes(r.db).length, 0);
});

test('a row that already moved on is reported, never rewritten', async () => {
  // The sweep runs every five minutes and the row may have been closed by its
  // own session in between. Idempotent by construction: say what it is now.
  for (const status of ['done', 'failed', 'parked', 'budget_stopped', 'queued_for_retry']) {
    const r = await call('/api/jobs/triage-project-5-pr-976/requeue', {
      body: {}, state: { jobs: [SILENT({ status })] }
    });
    assert.equal(r.body.decision, 'already', `status ${status} should be reported, not requeued`);
    assert.equal(r.body.status, status);
    assert.equal(writes(r.db).length, 0, `status ${status} was rewritten`);
  }
});

test('an ORPHANED row is still requeuable — that is the whole TTL path', async () => {
  // bin/jobs-watchdog.sh marks the row orphaned and THEN asks for the requeue,
  // so refusing an orphaned row would make the two halves of one sweep
  // disagree and nothing would ever be handed back.
  const r = await call('/api/jobs/triage-project-5-pr-976/requeue', {
    body: {}, state: { jobs: [SILENT({ status: 'orphaned' })] }
  });
  assert.equal(r.body.decision, 'queued_for_retry');
});

test('the cap is bounded, and a missing one defaults rather than parking everything', async () => {
  const none = await call('/api/jobs/triage-project-5-pr-976/requeue', {
    body: {}, state: { jobs: [SILENT()] }
  });
  assert.equal(none.body.max_attempts, 3);
  const huge = await call('/api/jobs/triage-project-5-pr-976/requeue', {
    body: { max_attempts: 5000 }, state: { jobs: [SILENT()] }
  });
  assert.equal(huge.body.max_attempts, 20);
  const zero = await call('/api/jobs/triage-project-5-pr-976/requeue', {
    body: { max_attempts: 0 }, state: { jobs: [SILENT()] }
  });
  assert.equal(zero.body.max_attempts, 3);
});

test('no such job is a 404, and no bearer is a 401', async () => {
  const ghost = await call('/api/jobs/ghost/requeue', { body: {} });
  assert.equal(ghost.status, 404);
  const db = fakeDB({ jobs: [SILENT()] });
  const req = new Request('https://jobs.test/api/jobs/triage-project-5-pr-976/requeue',
    { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
  const res = await worker.fetch(req, { DB: db, HARNESS_SECRET: SECRET });
  assert.equal(res.status, 401);
  assert.equal(writes(db).length, 0);
});
