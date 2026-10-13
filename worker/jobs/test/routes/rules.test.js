import test from 'node:test';
import assert from 'node:assert/strict';
import { RUNNING, call, worker } from '../lib/harness.js';

test('a rule write is validated - a bad scope or a negative cap is refused', async () => {
  for (const body of [
    { scope: 'universe', selector: '*', kind: '*', max_concurrent: 1 },
    { scope: 'repo', selector: '*', kind: '*', max_concurrent: -1 },
    { scope: 'repo', selector: '*', kind: '*', max_concurrent: 1.5 },
    { scope: 'repo', selector: '*', kind: '*' }
  ]) {
    const r = await call('/api/rules', { method: 'PUT', body });
    assert.equal(r.status, 400, `accepted ${JSON.stringify(body)}`);
  }
  const good = await call('/api/rules', {
    method: 'PUT', body: { scope: 'box', selector: 'fly-builder-7', kind: 'build', max_concurrent: 2 }
  });
  assert.equal(good.status, 200);
});

test('DELETE /api/rules removes exactly the addressed row, and no row is unlimited', async () => {
  // The fake never mutates state on a write, so the proof is the statement the
  // worker issued and the answer it gave — the same idiom as every write test here.
  const del = await call('/api/rules', {
    method: 'DELETE', body: { scope: 'repo', selector: 'project-5', kind: 'build' },
    state: { rules: [{ scope: 'repo', selector: 'project-5', kind: 'build', max_concurrent: 20 }] }
  });
  assert.equal(del.status, 200);
  assert.equal(del.body.deleted, 1);
  const stmt = del.db._calls.find((c) => /^DELETE FROM concurrency_rules/.test(c.sql));
  assert.ok(stmt, 'no DELETE was issued against concurrency_rules');
  assert.deepEqual(stmt.binds, ['repo', 'project-5', 'build']);
  assert.match(stmt.sql, /WHERE scope=\?1 AND selector=\?2 AND kind=\?3/);
  // A DELETE without a body still names a row: the wildcard for that scope.
  const wild = await call('/api/rules', { method: 'DELETE', body: { scope: 'box' } });
  assert.equal(wild.status, 200);
  const wstmt = wild.db._calls.find((c) => /^DELETE FROM concurrency_rules/.test(c.sql));
  assert.deepEqual(wstmt.binds, ['box', '*', '*']);
  // An unknown scope is refused before anything is deleted.
  const bad = await call('/api/rules', { method: 'DELETE', body: { scope: 'universe' } });
  assert.equal(bad.status, 400);
  assert.ok(!bad.db._calls.some((c) => /^DELETE/.test(c.sql)), 'a refused scope still deleted something');
  // And the worker's own rule check treats an absent row as no cap at all.
  const claim = await call('/api/jobs', {
    method: 'POST',
    body: { id: 'build-project-5-TK-9-1', project: 'project-5', kind: 'build', stage: 'plan', box: 'pool-1', ticket_id: 'TK-9', budget_usd: 10 },
    state: { rules: [], jobs: Array.from({ length: 30 }, (_, i) => RUNNING({ id: `build-project-5-TK-${i}-1`, project: 'project-5', box: `pool-${i}` })) }
  });
  assert.notEqual(claim.status, 409, `30 running builds and no rule still refused the 31st: ${JSON.stringify(claim.body)}`);
});
