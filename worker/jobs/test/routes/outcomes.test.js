import test from 'node:test';
import assert from 'node:assert/strict';
import { call, sqlOf } from '../lib/harness.js';

test('an outcome is keyed (repo, pr, outcome) and never re-dates itself', async () => {
  const r = await call('/api/metrics/outcomes', {
    method: 'POST',
    body: { rows: [
      { repo: 'project-3', pr: 'https://github.com/x/y/pull/9', outcome: 'reverted', day: '2026-08-29', evidence: 'revert abc' },
      { repo: 'project-3', pr: 'https://github.com/x/y/pull/9', outcome: 'merged_then_red', day: '2026-08-29' },
      { repo: 'project-3', pr: '', outcome: 'reverted' }   // incomplete: skipped
    ] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.upserted, 2);
  const [w] = sqlOf(r.db, /INSERT INTO outcome_metrics/);
  assert.match(w.sql, /ON CONFLICT\(repo, pr, outcome\) DO UPDATE/);
  // created_at is NOT in the SET list. A weekly re-scan that re-reports the same
  // revert must not make it look like it happened again this week.
  assert.doesNotMatch(w.sql, /DO UPDATE SET[\s\S]*created_at=/);
});

test('an outcome carries the build repair count, and an old client cannot blank it', async () => {
  const r = await call('/api/metrics/outcomes', {
    method: 'POST',
    state: { outcomeCols: ['repo', 'pr', 'outcome', 'day', 'evidence', 'repairs', 'created_at'] },
    body: { rows: [
      { repo: 'project-3', pr: 'https://github.com/x/y/pull/9', outcome: 'reverted', day: '2026-09-06', evidence: 'revert abc', repairs: 3 },
      { repo: 'project-3', pr: 'https://github.com/x/y/pull/8', outcome: 'reopened', day: '2026-09-06' },
      { repo: 'project-3', pr: 'https://github.com/x/y/pull/7', outcome: 'reverted', day: '2026-09-06', repairs: 0 }
    ] }
  });
  assert.equal(r.status, 200);
  const writes = sqlOf(r.db, /INSERT INTO outcome_metrics/);
  assert.equal(writes[0].binds[5], 3);
  // An old client omits it -> NULL, and the COALESCE keeps what a newer push
  // wrote. NOT MEASURED and "measured, never repaired" stay different facts.
  assert.equal(writes[1].binds[5], null);
  assert.equal(writes[2].binds[5], 0);
  assert.match(writes[0].sql, /repairs=COALESCE\(\?6, repairs\)/);
  // Columns already present: no ALTER.
  assert.equal(sqlOf(r.db, /ALTER TABLE outcome_metrics/).length, 0);
});

test('the outcome_metrics column add is self-applied, before the write', async () => {
  const r = await call('/api/metrics/outcomes', {
    method: 'POST',
    state: { outcomeCols: ['repo', 'pr', 'outcome', 'day', 'evidence', 'created_at'] },
    body: { rows: [{ repo: 'project-3', pr: 'https://github.com/x/y/pull/9', outcome: 'reverted', repairs: 2 }] }
  });
  assert.equal(r.status, 200);
  assert.deepEqual(sqlOf(r.db, /ALTER TABLE outcome_metrics ADD COLUMN/).map((a) => a.sql), [
    'ALTER TABLE outcome_metrics ADD COLUMN repairs INTEGER'
  ]);
  const order = r.db._calls.map((c) => c.sql);
  assert.ok(order.findIndex((q) => /PRAGMA table_info\(outcome_metrics\)/.test(q))
            < order.findIndex((q) => /INSERT INTO outcome_metrics/.test(q)));
});
