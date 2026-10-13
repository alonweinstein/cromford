import test from 'node:test';
import assert from 'node:assert/strict';
import { POLICY, call } from '../lib/harness.js';

test('a retry policy write is validated, and its lane resolves on the budget ladder', async () => {
  for (const body of [{ max_attempts: 3 }, { lane: 'x/y/z', max_attempts: 0 }, { lane: 'x/y/z', max_attempts: 'lots' }]) {
    const r = await call('/api/retry-policies', { method: 'PUT', body });
    assert.equal(r.status, 400, `accepted ${JSON.stringify(body)}`);
  }
  const ok = await call('/api/retry-policies', {
    method: 'PUT', body: { lane: 'plan/project-3/*', max_attempts: 2, backoff_seconds: 90, escalate_allowed: true }
  });
  assert.equal(ok.status, 200);
  const ins = ok.db._calls.find((c) => /INSERT INTO retry_policies/.test(c.sql));
  assert.deepEqual(ins.binds.slice(0, 4), ['plan/project-3/*', 2, 90, 1]);
  // A lane with no exact row resolves through the SAME ladder budget_catalog
  // uses, so "this lane has a ceiling" and "this lane may retry" are one lane.
  const resolved = await call('/api/retry-policies/plan%2Fproject-3%2Fclaude', {
    state: { policies: [POLICY({ lane: 'plan/project-3/*' })] }
  });
  assert.equal(resolved.status, 200);
  assert.equal(resolved.body.policy.lane, 'plan/project-3/*');
  const none = await call('/api/retry-policies/qa%2Fproject-4%2Fgrok');
  assert.equal(none.status, 200, 'no policy is a real answer, not a 404 the client reads as a ledger miss');
  assert.equal(none.body.policy, null);
});
