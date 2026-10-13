import test from 'node:test';
import assert from 'node:assert/strict';
import { RUNNING, call, iso } from '../lib/harness.js';

const ART = (over) => ({
  job_id: 'build-project-3-TK-77-1', artifact_kind: 'result',
  artifact_ref: 'PR_CREATED https://github.com/o/r/pull/12',
  detail: '{"key":"TK-77"}', actor: 'pool-machine-1',
  updated_at: iso(600e3), ...over
});

test('artifact feed: the JOB is joined on — box above all', async () => {
  // The box column is what lets a sweep skip its OWN builds. Without it the
  // owning box would stage a second close-out for a build whose record is
  // already sitting in builds/ waiting to be swept — a client seeing us answer
  // the same ticket twice.
  const state = {
    jobs: [RUNNING({ id: 'build-project-3-TK-77-1', ticket_id: 'TK-77', box: 'pool-machine-1', status: 'done' })],
    artifacts: [ART()],
  };
  const r = await call('/api/artifacts?kind=result&project=project-3', { state });
  assert.equal(r.status, 200);
  assert.equal(r.body.artifacts.length, 1);
  const a = r.body.artifacts[0];
  assert.equal(a.box, 'pool-machine-1');
  assert.equal(a.project, 'project-3');
  assert.equal(a.ticket_id, 'TK-77');
  assert.equal(a.artifact_ref, 'PR_CREATED https://github.com/o/r/pull/12');
});

test('artifact feed: filters by project, artifact kind and job kind', async () => {
  const state = {
    jobs: [
      RUNNING({ id: 'a', project: 'project-3', kind: 'build', box: 'b1' }),
      RUNNING({ id: 'b', project: 'project-4', kind: 'build', box: 'b2' }),
      RUNNING({ id: 'c', project: 'project-3', kind: 'triage', box: 'b3' }),
    ],
    artifacts: [
      ART({ job_id: 'a', artifact_kind: 'result' }),
      ART({ job_id: 'b', artifact_kind: 'result' }),
      ART({ job_id: 'c', artifact_kind: 'result' }),
      ART({ job_id: 'a', artifact_kind: 'pr_url' }),
    ],
  };
  const mine = await call('/api/artifacts?kind=result&project=project-3', { state });
  assert.deepEqual(mine.body.artifacts.map((x) => x.job_id), ['a', 'c']);
  const builds = await call('/api/artifacts?kind=result&project=project-3&job_kind=build', { state });
  assert.deepEqual(builds.body.artifacts.map((x) => x.job_id), ['a']);
});

test('artifact feed: `since` is a watermark, and it is exclusive', async () => {
  // A sweep asks for "newer than the last updated_at I saw". Inclusive would
  // hand back the row it just processed on every single tick.
  const state = {
    jobs: [RUNNING({ id: 'old', box: 'b1' }), RUNNING({ id: 'new', box: 'b1' })],
    artifacts: [
      ART({ job_id: 'old', updated_at: '2026-09-10T01:00:00Z' }),
      ART({ job_id: 'new', updated_at: '2026-09-10T03:00:00Z' }),
    ],
  };
  const r = await call('/api/artifacts?kind=result&since=2026-09-10T01:00:00Z', { state });
  assert.deepEqual(r.body.artifacts.map((x) => x.job_id), ['new']);
});

test('artifact feed: no bearer, no feed', async () => {
  const r = await call('/api/artifacts', { secret: null });
  assert.equal(r.status, 401);
});
