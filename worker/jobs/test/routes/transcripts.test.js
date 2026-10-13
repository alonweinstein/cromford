import test from 'node:test';
import assert from 'node:assert/strict';
import { RUNNING, TR, call } from '../lib/harness.js';

test('a transcript cannot be written without the bearer', async () => {
  const r = await call('/api/jobs/build-project-3-TK-1-1/transcript', {
    method: 'POST', secret: null, body: { body: 'hello' }
  });
  assert.equal(r.status, 401);
});

test('a transcript on a job that does not exist is a 404, not a stray row', async () => {
  // Same rule as artifacts and phases: a row whose job is absent is invisible on
  // every screen that starts from a job, and the pusher is fail-open so a 404
  // costs the stage nothing.
  const r = await call('/api/jobs/nope/transcript', { method: 'POST', body: { body: 'hello' } });
  assert.equal(r.status, 404);
  assert.equal(r.db._calls.filter((c) => /INSERT INTO job_transcripts/.test(c.sql)).length, 0);
});

test('an empty body is refused rather than stored', async () => {
  const r = await call('/api/jobs/build-project-3-TK-1-1/transcript', {
    method: 'POST', state: { jobs: [RUNNING()] }, body: { body: '   \n ' }
  });
  assert.equal(r.status, 400);
});

test('a transcript stores its provenance and its own address', async () => {
  const r = await call('/api/jobs/build-project-3-TK-1-1/transcript', {
    method: 'POST',
    state: { jobs: [RUNNING()], transcripts: [TR({ phase_id: 7, attempt: 2 })] },
    body: {
      body: 'turn by turn', phase_id: 7, attempt: 2, stage: 'execute',
      runner: 'codex', model: 'gpt-x', source: 'stage_output', redactions: 3, actor: 'box-1'
    }
  });
  assert.equal(r.status, 200);
  const ins = r.db._calls.find((c) => /INSERT INTO job_transcripts/.test(c.sql));
  assert.deepEqual(ins.binds.slice(0, 7),
    ['build-project-3-TK-1-1', 7, 2, 'execute', 'codex', 'gpt-x', 'stage_output']);
  assert.equal(ins.binds[9], 3);              // redactions
  assert.equal(ins.binds[10], 'turn by turn'); // body
});

test('a push with no phase lands at phase_id 0 rather than being refused', async () => {
  // phase_id is part of the primary key and SQLite does not treat NULLs as equal
  // in an upsert conflict target, so 0 is the "no phase row existed" sentinel.
  // Refusing the push instead would lose a real transcript over an absent id.
  const r = await call('/api/jobs/build-project-3-TK-1-1/transcript', {
    method: 'POST', state: { jobs: [RUNNING()] }, body: { body: 'x', phase_id: null }
  });
  assert.equal(r.status, 200);
  const ins = r.db._calls.find((c) => /INSERT INTO job_transcripts/.test(c.sql));
  assert.equal(ins.binds[1], 0);
  assert.equal(ins.binds[2], 1); // attempt defaults to 1
});

test('an over-cap body is TAILED, never refused', async () => {
  // The end of a session is where the failure is. Refusing the push to protect a
  // number would lose the whole thing; the row says truncated=1 instead.
  const big = 'H'.repeat(200000) + 'THE-END';
  const r = await call('/api/jobs/build-project-3-TK-1-1/transcript', {
    method: 'POST', state: { jobs: [RUNNING()] }, body: { body: big }
  });
  assert.equal(r.status, 200);
  const ins = r.db._calls.find((c) => /INSERT INTO job_transcripts/.test(c.sql));
  assert.equal(ins.binds[10].length, 150000);
  assert.ok(ins.binds[10].endsWith('THE-END'), 'the cap kept the head instead of the tail');
  assert.equal(ins.binds[8], 1); // truncated
});

test('the POST answers with the row and NOT with the body it was just handed', async () => {
  // Echoing 150KB back onto a box that is mid-build is pure cost.
  const r = await call('/api/jobs/build-project-3-TK-1-1/transcript', {
    method: 'POST', state: { jobs: [RUNNING()], transcripts: [TR()] }, body: { body: 'x', phase_id: 7, attempt: 1 }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.transcript.body, undefined);
  assert.equal(r.body.transcript.bytes, 1200);
});

test('one body is fetched by phase and attempt', async () => {
  const r = await call('/api/jobs/build-project-3-TK-1-1/transcript?phase_id=7&attempt=2', {
    state: { jobs: [RUNNING()], transcripts: [TR(), TR({ attempt: 2, body: 'the second attempt' })] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.transcript.body, 'the second attempt');
});

test('an attempt with no transcript is a 404, which the console renders as its own empty state', async () => {
  const r = await call('/api/jobs/build-project-3-TK-1-1/transcript?phase_id=7&attempt=9', {
    state: { jobs: [RUNNING()], transcripts: [TR()] }
  });
  assert.equal(r.status, 404);
});

test('the index endpoint lists attempts without their bodies', async () => {
  const r = await call('/api/jobs/build-project-3-TK-1-1/transcripts', {
    state: { jobs: [RUNNING()], transcripts: [TR(), TR({ attempt: 2 })] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.transcripts.length, 2);
  assert.equal(r.body.transcripts[0].body, undefined);
});
