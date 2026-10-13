import test from 'node:test';
import assert from 'node:assert/strict';
import { call } from '../lib/harness.js';

test('ledger list accepts optional before cursor', async () => {
  const without = await call('/api/ledger?kind=pr_state');
  assert.equal(without.status, 200);
  const sqlWithout = without.db._calls.find((c) => /FROM ledgers/.test(c.sql)).sql;
  assert.doesNotMatch(sqlWithout, /updated_at<\?/);

  const withBefore = await call('/api/ledger?kind=pr_state&before=2026-09-16T00:00:00Z');
  assert.equal(withBefore.status, 200);
  const sqlWith = withBefore.db._calls.find((c) => /FROM ledgers/.test(c.sql)).sql;
  assert.match(sqlWith, /updated_at<\?/);
  const cursorBind = withBefore.db._calls.find((c) => /FROM ledgers/.test(c.sql)).binds;
  assert.equal(cursorBind[cursorBind.length - 1], '2026-09-16T00:00:00Z');
});
