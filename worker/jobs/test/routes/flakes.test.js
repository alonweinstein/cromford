import test from 'node:test';
import assert from 'node:assert/strict';
import { call, sqlOf } from '../lib/harness.js';

test('a flake row is keyed on the HEAD, and re-scanning never re-dates it', async () => {
  const r = await call('/api/metrics/flakes', {
    method: 'PUT',
    body: { rows: [
      { repo: 'example-org/project-3', workflow: '.github/workflows/ci.yml',
        test: 'queue > drains under load', head: 'abc123', kind: 'flake', day: '2026-09-12' },
      { repo: 'example-org/project-3', workflow: '.github/workflows/ci.yml',
        test: 'job:unit', head: 'def456', kind: 'red', day: '2026-09-12' },
      { repo: 'example-org/project-3', workflow: '.github/workflows/ci.yml', test: 'x' }  // no head: skipped
    ] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.upserted, 2);
  const [w] = sqlOf(r.db, /INSERT INTO ci_flakes/);
  // The head is in the key. A run-keyed ledger would let one bad afternoon of
  // re-runs look like nine independent pieces of evidence about one test.
  assert.match(w.sql, /ON CONFLICT\(repo, workflow, test, head\) DO UPDATE/);
  // Same reason outcome_metrics does not touch it: tomorrow's re-scan of the
  // same window must not make an old flake look like it happened again.
  assert.doesNotMatch(w.sql, /DO UPDATE SET[\s\S]*created_at=/);
  assert.equal(w.binds[4], 'flake');
  assert.equal(sqlOf(r.db, /INSERT INTO ci_flakes/)[1].binds[4], 'red');
});

test('an unknown kind is stored as red, never as flake', async () => {
  // The numerator is the claim that needs evidence; the denominator is the safe
  // default. A client sending nonsense must make the fleet look FLAKIER than it
  // is, never less flaky — less flaky is how a real red gets waved through.
  const r = await call('/api/metrics/flakes', {
    method: 'PUT',
    body: { repo: 'o/r', workflow: 'ci.yml', test: 't', head: 'h', kind: 'probably?' }
  });
  assert.equal(r.status, 200);
  assert.equal(sqlOf(r.db, /INSERT INTO ci_flakes/)[0].binds[4], 'red');
  const none = await call('/api/metrics/flakes', { method: 'PUT', body: { rows: [] } });
  assert.equal(none.status, 400);
});

test('GET /api/metrics/flakes narrows by repo and by since, in SQL', async () => {
  const flakes = [
    { repo: 'o/r',  workflow: 'ci.yml', test: 'a', head: 'h1', kind: 'flake', day: '2026-09-12' },
    { repo: 'o/r',  workflow: 'ci.yml', test: 'b', head: 'h2', kind: 'red',   day: '2026-08-01' },
    { repo: 'o/r2', workflow: 'ci.yml', test: 'c', head: 'h3', kind: 'flake', day: '2026-09-12' }
  ];
  const all = await call('/api/metrics/flakes', { state: { flakes } });
  assert.equal(all.status, 200);
  assert.equal(all.body.flakes.length, 3);
  const scoped = await call('/api/metrics/flakes?repo=o/r&since=2026-09-01', { state: { flakes } });
  assert.equal(scoped.status, 200);
  assert.deepEqual(scoped.body.flakes.map((f) => f.test), ['a']);
  // The filters are bound, not interpolated — the repo arrives from fleet.conf
  // but the since is assembled from a query string.
  const q = sqlOf(scoped.db, /FROM ci_flakes/)[0];
  assert.match(q.sql, /WHERE repo=\?1 AND day>=\?2/);
  assert.deepEqual(q.binds, ['o/r', '2026-09-01']);
});
