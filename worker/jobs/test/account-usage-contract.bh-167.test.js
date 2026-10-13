import test from 'node:test';
import assert from 'node:assert/strict';
import { call } from './lib/harness.js';
import { usageWindow, shapeAccountUsage, EMPTY_TRUNCATED } from '../src/lib/account-usage.js';

// BH-1913 (BH-167.0): the account-usage contract. usageWindow's windows, the
// documented shape for empty input, and the bearer-gated route answering that
// shape over an empty DB. The compute itself is pinned in
// account-usage.bh-167.test.js (BH-1914).

const NOW = Date.parse('2026-09-24T12:00:00Z');  // determinism: ok pure-function anchor, never compared to the wall clock

test('usageWindow 5h is [now-5h, now)', () => {
  assert.deepEqual(usageWindow({ window: '5h', now: NOW }),
    { window: '5h', from: '2026-09-24T07:00:00Z', to: '2026-09-24T12:00:00Z' });
});

test('usageWindow 7d is [now-168h, now)', () => {
  assert.deepEqual(usageWindow({ window: '7d', now: NOW }),
    { window: '7d', from: '2026-09-17T12:00:00Z', to: '2026-09-24T12:00:00Z' });
});

test('usageWindow junk falls back to 5h and echoes the resolved window', () => {
  for (const window of [undefined, null, '', '7D', '30d', 'bogus']) {
    assert.deepEqual(usageWindow({ window, now: NOW }),
      { window: '5h', from: '2026-09-24T07:00:00Z', to: '2026-09-24T12:00:00Z' }, String(window));
  }
});

test('shapeAccountUsage with no rows answers the documented empty shape, fresh each call', () => {
  const expected = {
    window: '7d', from: 'a', to: 'b', accounts: [],
    totals: { calls: 0, usd: null, unpriced_calls: 0, input_toks: 0, output_toks: 0, cache_read: 0, cache_write: 0 },
    truncated: { groups: false, projects: false, snapshots: false },
  };
  const first = shapeAccountUsage({ window: '7d', from: 'a', to: 'b' });
  assert.deepEqual(first, expected);
  assert.equal(first.totals.usd, null);
  assert.deepEqual(EMPTY_TRUNCATED, { groups: false, projects: false, snapshots: false });
  first.accounts.push({ account: 'x' });
  first.truncated.groups = true;
  first.totals.calls = 9;
  assert.deepEqual(shapeAccountUsage({ window: '7d', from: 'a', to: 'b' }), expected);
  assert.deepEqual(EMPTY_TRUNCATED, { groups: false, projects: false, snapshots: false });
});

test('GET /api/metrics/account-usage?window=7d over an empty DB answers the empty shape through worker.fetch', async () => {
  const before = Date.now() - 1000;  // determinism: ok brackets the request's own clock read, 1s slack each side
  const r = await call('/api/metrics/account-usage?window=7d');
  const after = Date.now() + 1000;   // determinism: ok the other half of that bracket
  assert.equal(r.status, 200);
  // the window trails the request: `to` is the request time (second precision)
  assert.ok(Date.parse(r.body.to) >= before && Date.parse(r.body.to) <= after, r.body.to);
  assert.equal(r.body.window, '7d');
  assert.deepEqual(r.body.accounts, []);
  assert.deepEqual(r.body.truncated, { groups: false, projects: false, snapshots: false });
  assert.equal(r.body.totals.usd, null);
  assert.ok(r.body.from < r.body.to, `${r.body.from} < ${r.body.to}`);
  assert.equal(Date.parse(r.body.to) - Date.parse(r.body.from), 168 * 3600e3);
});

test('GET /api/metrics/account-usage with junk window answers 5h', async () => {
  const r = await call('/api/metrics/account-usage?window=bogus');
  assert.equal(r.status, 200);
  assert.equal(r.body.window, '5h');
  assert.equal(Date.parse(r.body.to) - Date.parse(r.body.from), 5 * 3600e3);
});

test('GET /api/metrics/account-usage without a bearer, or a wrong one, is 401', async () => {
  assert.equal((await call('/api/metrics/account-usage?window=7d', { secret: null })).status, 401);
  assert.equal((await call('/api/metrics/account-usage?window=7d', { secret: 'wrong' })).status, 401);
});
