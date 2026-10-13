import test from 'node:test';
import assert from 'node:assert/strict';
import { RUNNING, TR, call, iso } from '../lib/harness.js';

const LIVE_JOB = 'build-project-3-TK-1-1';

const EV = (id, over) => ({ id, job_id: LIVE_JOB, stage: 'execute', verdict: null,
  detail: `event ${id}`, actor: 'box', created_at: iso(1000 * (100 - id)), ...over });

test('a heartbeat for a job that does not exist is a 404, never a silent create', async () => {
  const r = await call('/api/jobs/ghost/heartbeat', { method: 'POST', body: { box: 'b' } });
  assert.equal(r.status, 404);
});

test('a heartbeat upserts and answers with the server clock', async () => {
  const state = { jobs: [RUNNING({ last_beat_at: iso(600e3) })] };
  const r = await call('/api/jobs/build-project-3-TK-1-1/heartbeat', { method: 'POST', body: { box: 'b', note: 'execute' }, state });
  assert.equal(r.status, 200);
  assert.match(r.body.beat_at, /^\d{4}-\d{2}-\d{2}T/);
  assert.ok(r.db._calls.some((c) => /INSERT INTO job_heartbeats/.test(c.sql)));
});

test('job detail carries its events and ledger rows in one call', async () => {
  const state = {
    jobs: [RUNNING({ last_beat_at: iso(60e3) })],
    events: [{ id: 1, job_id: 'build-project-3-TK-1-1', stage: 'execute', verdict: 'ORPHANED', actor: 'hub' }],
    ledgers: [{ kind: 'merge', key: 'https://github.com/x/pull/1', status: 'merged' }]
  };
  const r = await call('/api/jobs/build-project-3-TK-1-1', { state });
  assert.equal(r.status, 200);
  assert.equal(r.body.job.id, 'build-project-3-TK-1-1');
  assert.equal(r.body.events.length, 1);
  assert.equal(r.body.ledgers.length, 1);
  const missing = await call('/api/jobs/ghost');
  assert.equal(missing.status, 404);
});

test('job detail carries its phases, so the drill-down needs one call', async () => {
  const state = {
    jobs: [RUNNING({ last_beat_at: iso(60e3) })],
    phases: [{ id: 1, job_id: 'build-project-3-TK-1-1', phase: 'plan', status: 'done', rc: 0 }]
  };
  const r = await call('/api/jobs/build-project-3-TK-1-1', { state });
  assert.equal(r.body.phases.length, 1);
  assert.equal(r.body.phases[0].phase, 'plan');
});

test('an artifact rides on the job detail, and the verdict lookup joins PR to job', async () => {
  const artifacts = [
    { job_id: 'build-project-3-TK-1-1', artifact_kind: 'pr_url', artifact_ref: 'https://github.com/o/r/pull/9' },
    { job_id: 'build-project-3-TK-1-1', artifact_kind: 'verdict', artifact_ref: 'APPROVE',
      detail: JSON.stringify({ tier: '2', provenance: 'claude', record: 'project-3-TK-1-1',
                               reviewed_sha: 'cafe1234' }) },
    { job_id: 'build-project-3-TK-1-1', artifact_kind: 'merge_sha', artifact_ref: 'abc123' }
  ];
  const state = { jobs: [RUNNING()], artifacts };
  const d = await call('/api/jobs/build-project-3-TK-1-1', { state });
  assert.equal(d.body.artifacts.length, 3);
  const v = await call('/api/verdict?pr=' + encodeURIComponent('https://github.com/o/r/pull/9'), { state });
  assert.equal(v.status, 200);
  assert.equal(v.body.verdict, 'APPROVE');
  assert.equal(v.body.tier, '2');
  assert.equal(v.body.provenance, 'claude');
  assert.equal(v.body.merge_sha, 'abc123');
  assert.equal(v.body.job_id, 'build-project-3-TK-1-1');
  // SDLC item 1: the head the approval is bound to, so a merge gate on another
  // box can refuse a PR whose head moved after the review.
  assert.equal(v.body.reviewed_sha, 'cafe1234');
  // SDLC item 4: a verdict written before the scope gate existed reports null,
  // and null is NOT MEASURED — a reader that scored it as "in-scope" would
  // report every pre-gate build as having stayed inside its plan.
  assert.equal(v.body.scope, null);
  assert.equal(v.body.scope_counts, null);
});

test('the job detail carries the transcript INDEX and never the bodies', async () => {
  // This response is polled every 20s by an open drill-down. A job with four
  // attempts shipping its bodies would push ~600KB twice a minute to render a
  // heading nobody expanded.
  const r = await call('/api/jobs/build-project-3-TK-1-1', {
    state: { jobs: [RUNNING()], transcripts: [TR(), TR({ attempt: 2, body: 'second' })] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.transcripts.length, 2);
  for (const t of r.body.transcripts) {
    assert.equal(t.body, undefined, 'a transcript body rode along on the detail poll');
    assert.equal(typeof t.bytes, 'number');
  }
});

test('live hands back the job, its phases, ascending events, the spend sum and a cursor', async () => {
  const state = {
    jobs: [RUNNING()],
    phases: [
      { id: 1, job_id: LIVE_JOB, phase: 'plan', runner: 'claude', model: 'sonnet', status: 'done',
        started_at: iso(300e3), finished_at: iso(240e3), rc: 0, spend_usd: 0.5 },
      { id: 2, job_id: LIVE_JOB, phase: 'execute', runner: 'codex', model: 'gpt', status: 'done',
        started_at: iso(240e3), finished_at: iso(120e3), rc: 0, spend_usd: 0.25 },
      { id: 3, job_id: LIVE_JOB, phase: 'review', runner: 'codex', model: 'gpt', status: 'running',
        started_at: iso(120e3), finished_at: null, rc: null, spend_usd: null },
      // A phase whose spend never parsed. Neither null nor garbage may enter
      // the arithmetic: one `Number()` of either turns the whole total into 0
      // or NaN, and a spend readout of NaN is worse than no readout.
      { id: 4, job_id: LIVE_JOB, phase: 'qa', runner: 'codex', model: 'gpt', status: 'running',
        started_at: iso(60e3), finished_at: null, rc: null, spend_usd: 'n/a' }
    ],
    events: [EV(3), EV(1, { stage: 'plan' }), EV(2, { stage: 'tests_red' })]
  };
  const r = await call(`/api/jobs/${LIVE_JOB}/live`, { state });
  assert.equal(r.status, 200);
  assert.equal(r.body.job.id, LIVE_JOB);
  assert.deepEqual(r.body.events.map((e) => e.id), [1, 2, 3]);
  assert.deepEqual(r.body.events.map((e) => e.stage), ['plan', 'tests_red', 'execute']);
  // `created_at AS at` — the field name the screen reads.
  assert.equal(r.body.events[0].at, state.events[1].created_at);
  assert.deepEqual(r.body.phases.map((p) => p.phase), ['plan', 'execute', 'review', 'qa']);
  // A running phase's spend is NOT MEASURED, not zero: it stays null in the row
  // and contributes nothing to the sum.
  assert.equal(r.body.phases[2].spend_usd, null);
  assert.equal(r.body.phases[3].spend_usd, 'n/a', 'an unparseable spend is handed over as-is, not as 0');
  assert.equal(r.body.spend_usd, 0.75);
  assert.ok(Number.isFinite(r.body.spend_usd), 'the spend total is a number, never NaN');
  assert.equal(r.body.cursor, 3);
});

test('since= filters to what the caller has not seen, and holds the cursor when nothing is new', async () => {
  const state = { jobs: [RUNNING()], events: [EV(1), EV(2), EV(3), EV(4)] };
  const some = await call(`/api/jobs/${LIVE_JOB}/live?since=2`, { state });
  assert.equal(some.status, 200);
  assert.deepEqual(some.body.events.map((e) => e.id), [3, 4]);
  assert.equal(some.body.cursor, 4);

  const none = await call(`/api/jobs/${LIVE_JOB}/live?since=4`, { state });
  assert.equal(none.status, 200);
  assert.deepEqual(none.body.events, []);
  assert.equal(none.body.cursor, 4, 'an empty page must not rewind the cursor to 0');

  const beyond = await call(`/api/jobs/${LIVE_JOB}/live?since=999`, { state });
  assert.deepEqual(beyond.body.events, []);
  assert.equal(beyond.body.cursor, 999);
});

test('live on a job that does not exist is a 404, never an empty live view', async () => {
  const r = await call('/api/jobs/ghost/live');
  assert.equal(r.status, 404);
  assert.match(r.body.error, /no such job/);
});

test('a backlog longer than the page drains through the cursor without skipping', async () => {
  const events = Array.from({ length: 201 }, (_, i) => EV(i + 1));
  const state = { jobs: [RUNNING()], events };
  const first = await call(`/api/jobs/${LIVE_JOB}/live`, { state });
  assert.equal(first.body.events.length, 200);
  assert.equal(first.body.events[0].id, 1);
  assert.equal(first.body.events[199].id, 200);
  assert.equal(first.body.cursor, 200);
  const next = await call(`/api/jobs/${LIVE_JOB}/live?since=${first.body.cursor}`, { state });
  assert.deepEqual(next.body.events.map((e) => e.id), [201]);
  assert.equal(next.body.cursor, 201);
});

test('a mangled cursor is a 400 — never a silent replay from zero', async () => {
  const state = { jobs: [RUNNING()], events: [EV(1), EV(2)] };
  for (const bad of ['1e3', '-1', '12345678901234567', 'abc', '1.5', ' 2']) {
    const r = await call(`/api/jobs/${LIVE_JOB}/live?since=${encodeURIComponent(bad)}`, { state });
    assert.equal(r.status, 400, `since=${bad} was not refused`);
    assert.match(r.body.error, /since/);
    assert.equal(r.db._calls.filter((c) => /FROM stage_events/.test(c.sql)).length, 0,
      `since=${bad} still read the event log`);
  }
  // An absent or empty cursor is the first poll, not a bad one.
  for (const ok of ['', '?since=', '?since=0']) {
    const r = await call(`/api/jobs/${LIVE_JOB}/live${ok === '' ? '' : ok}`, { state });
    assert.equal(r.status, 200, `since=${JSON.stringify(ok)}`);
    assert.deepEqual(r.body.events.map((e) => e.id), [1, 2]);
  }
});

test('live is bearer-gated like every other read', async () => {
  const r = await call(`/api/jobs/${LIVE_JOB}/live`, { secret: null, state: { jobs: [RUNNING()] } });
  assert.equal(r.status, 401);
  assert.equal(r.db._calls.length, 0, 'an unauthenticated live poll touched the DB');
});
