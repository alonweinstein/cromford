import test from 'node:test';
import assert from 'node:assert/strict';
import { RUNNING, call, worker } from '../lib/harness.js';

test('the scope gate verdict and its counts ride out of /api/verdict verbatim', async () => {
  // The only reader the merge sweep will trust, so the handler is executed here
  // rather than grepped: the strings must arrive unparsed and unrounded.
  const state = { jobs: [RUNNING()], artifacts: [
    { job_id: 'build-project-3-TK-1-1', artifact_kind: 'pr_url', artifact_ref: 'https://github.com/o/r/pull/9' },
    { job_id: 'build-project-3-TK-1-1', artifact_kind: 'verdict', artifact_ref: 'APPROVE',
      detail: JSON.stringify({ tier: '2', provenance: 'claude', scope: 'protected',
        scope_counts: 'changed=3 planned=1 unplanned=2 adjacent=0 test=0 spec=0 foreign=2 protected=1' }) }
  ] };
  const r = await call('/api/verdict?pr=' + encodeURIComponent('https://github.com/o/r/pull/9'), { state });
  assert.equal(r.status, 200);
  assert.equal(r.body.scope, 'protected');
  assert.equal(r.body.scope_counts,
    'changed=3 planned=1 unplanned=2 adjacent=0 test=0 spec=0 foreign=2 protected=1');
});

test('a verdict row written before head-binding reports reviewed_sha as null', async () => {
  // Absence is "no claim", never a mismatch: the merge gates fail open on null,
  // which is what stops the day this shipped from parking every open PR.
  const state = { jobs: [RUNNING()], artifacts: [
    { job_id: 'build-project-3-TK-1-1', artifact_kind: 'pr_url', artifact_ref: 'https://github.com/o/r/pull/9' },
    { job_id: 'build-project-3-TK-1-1', artifact_kind: 'verdict', artifact_ref: 'APPROVE',
      detail: JSON.stringify({ tier: '2', provenance: 'claude' }) }
  ] };
  const r = await call('/api/verdict?pr=' + encodeURIComponent('https://github.com/o/r/pull/9'), { state });
  assert.equal(r.status, 200);
  assert.equal(r.body.reviewed_sha, null);
});

test('a PR no job recorded is a 404 - a real answer the sweep maps to scraping', async () => {
  const r = await call('/api/verdict?pr=' + encodeURIComponent('https://github.com/o/r/pull/404'),
    { state: { jobs: [RUNNING()], artifacts: [] } });
  assert.equal(r.status, 404);
});

test('the verdict lookup still filters on the PR url when OTHER PRs are recorded', async () => {
  // BH-1024 turned the pr_url lookup into a ranking (`a LEFT JOIN jobs j`,
  // `a.artifact_ref=?1`), and the fixture above 404s on an EMPTY artifact list —
  // so it stays green against a fake that has stopped filtering, and against a
  // worker that dropped the WHERE. This case is the discriminating one: a PR
  // nobody recorded, asked for while another PR's row sits in the table.
  const r = await call('/api/verdict?pr=' + encodeURIComponent('https://github.com/o/r/pull/404'), {
    state: {
      jobs: [RUNNING()],
      artifacts: [
        { job_id: 'build-project-3-TK-1-1', artifact_kind: 'pr_url', artifact_ref: 'https://github.com/o/r/pull/9' },
        { job_id: 'build-project-3-TK-1-1', artifact_kind: 'verdict', artifact_ref: 'APPROVE', detail: null },
      ],
    },
  });
  assert.equal(r.status, 404,
    "another PR's verdict came back for a PR nobody recorded — the lookup is answering unfiltered rows");
});

test('the build job owns the PR even when a review-verdict row is newer', async () => {
  // The ranking the round-4 query exists for, exercised through the route: the
  // build's row wins on kind, not on time, so a review lane writing the same
  // pr_url cannot become the standing verdict of a build it does not own.
  const state = {
    jobs: [RUNNING(), { ...RUNNING(), id: 'rv-1', kind: 'review-verdict' }],
    artifacts: [
      { job_id: 'rv-1', artifact_kind: 'pr_url', artifact_ref: 'https://github.com/o/r/pull/9',
        updated_at: '2099-01-01T00:00:00Z' },
      { job_id: 'rv-1', artifact_kind: 'verdict', artifact_ref: 'BLOCK', detail: null },
      { job_id: 'build-project-3-TK-1-1', artifact_kind: 'pr_url', artifact_ref: 'https://github.com/o/r/pull/9',
        updated_at: '2026-01-01T00:00:00Z' },
      { job_id: 'build-project-3-TK-1-1', artifact_kind: 'verdict', artifact_ref: 'APPROVE', detail: null },
    ],
  };
  const r = await call('/api/verdict?pr=' + encodeURIComponent('https://github.com/o/r/pull/9'), { state });
  assert.equal(r.status, 200);
  assert.equal(r.body.job_id, 'build-project-3-TK-1-1');
  assert.equal(r.body.verdict, 'APPROVE');
});

test('a verdict whose detail is not JSON still yields its verdict', async () => {
  // Somebody's breadcrumb must not 500 the lookup a merge gate depends on.
  const state = { jobs: [RUNNING()], artifacts: [
    { job_id: 'build-project-3-TK-1-1', artifact_kind: 'pr_url', artifact_ref: 'https://github.com/o/r/pull/9' },
    { job_id: 'build-project-3-TK-1-1', artifact_kind: 'verdict', artifact_ref: 'APPROVE', detail: 'by hand' }
  ] };
  const r = await call('/api/verdict?pr=' + encodeURIComponent('https://github.com/o/r/pull/9'), { state });
  assert.equal(r.status, 200);
  assert.equal(r.body.verdict, 'APPROVE');
  assert.equal(r.body.tier, null);
});
