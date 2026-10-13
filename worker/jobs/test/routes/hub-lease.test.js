import test from 'node:test';
import assert from 'node:assert/strict';
import { call, iso, worker } from '../lib/harness.js';

const LEASE = (over = {}) => ({
  id: 1, holder: 'box-hub', epoch: 4,
  expires_at: iso(-120e3), updated_at: iso(60e3), ...over
});

test('W1 GET hub lease always answers 200, with expiry judged by the server clock', async () => {
  // No row is not a 404: a 404 must uniquely mean "worker not deployed yet".
  const empty = await call('/api/hub/lease');
  assert.equal(empty.status, 200);
  assert.equal(empty.body.lease, null);
  assert.equal(typeof empty.body.as_of, 'string');

  const gone = await call('/api/hub/lease', { state: { hubLease: LEASE({ expires_at: iso(60e3) }) } });
  assert.equal(gone.status, 200);
  assert.equal(gone.body.lease.expired, true);
  assert.equal(gone.body.lease.remaining_s, 0);
  assert.equal(gone.body.lease.holder, 'box-hub');
  assert.equal(gone.body.lease.epoch, 4);

  const live = await call('/api/hub/lease', { state: { hubLease: LEASE() } });
  assert.equal(live.status, 200);
  assert.equal(live.body.lease.expired, false);
  assert.ok(Math.abs(live.body.lease.remaining_s - 120) <= 10,
    `remaining_s ~120 expected, got ${live.body.lease.remaining_s}`);
});

test('W2 a stale epoch cannot renew a live lease', async () => {
  const row = LEASE();
  const before = { ...row };
  const state = { hubLease: row };
  const r = await call('/api/hub/lease/renew', {
    method: 'POST', body: { holder: 'box-hub', epoch: 3 }, state
  });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'lease held');
  assert.equal(r.body.lease.epoch, 4);
  assert.equal(row.epoch, 4, 'the row must not move under a stale epoch');
  assert.equal(row.expires_at, before.expires_at);
  assert.equal(row.updated_at, before.updated_at);

  // Knowing the epoch is not the same as holding the lease: a box that has read
  // the row still may not renew someone else's live lease.
  const other = await call('/api/hub/lease/renew', {
    method: 'POST', body: { holder: 'box-2', epoch: 4 }, state
  });
  assert.equal(other.status, 409, 'the right epoch from the wrong box is still a 409');
  assert.equal(other.body.lease.holder, 'box-hub');
  assert.deepEqual({ ...row }, before, 'a losing renew writes nothing');
});

// BH-2272: the legacy force-promote is RETIRED. It moved the hub with no
// confirm, no epoch, no live-lease check and no audit, and bin/hub-lease.sh
// sent it `{"holder":"--holder"}`. The fencing it used to prove (the old holder
// 409s, the new one renews on the new epoch) is pinned on the guarded route by
// T8 in hub-recovery.bh-1943.test.js.
test('W3 the legacy promote is 410 gone, points at /api/hub/promote, and moves nothing', async () => {
  for (const path of ['/api/hub/lease/promote', '/api/hub-lease/promote']) {
    for (const body of [{ holder: 'box-2' }, { holder: '--holder' }, { holder: '' }, {}]) {
      const row = LEASE({ holder: 'box-hub', epoch: 4 });
      const before = { ...row };
      const r = await call(path, { method: 'POST', body, state: { hubLease: row } });
      const label = `${path} ${JSON.stringify(body)}`;
      assert.equal(r.status, 410, label);
      assert.equal(r.body.error, 'gone', label);
      assert.equal(r.body.use, '/api/hub/promote', label);
      assert.equal(r.db._calls.filter((c) => /hub_lease/.test(c.sql)).length, 0, `${label}: no hub_lease statement`);
      assert.deepEqual({ ...row }, before, `${label}: the row must not move`);
    }
  }
});

test('W4 an expired lease is taken by the next holder and the epoch bumps', async () => {
  const row = LEASE({ holder: 'box-hub', epoch: 4, expires_at: iso(60e3) });
  const state = { hubLease: row };

  const taken = await call('/api/hub/lease/renew', {
    method: 'POST', body: { holder: 'box-2', epoch: 0 }, state
  });
  assert.equal(taken.status, 200);
  assert.equal(taken.body.taken, true);
  assert.equal(taken.body.lease.holder, 'box-2');
  assert.equal(taken.body.lease.epoch, 5);
  assert.equal(taken.body.lease.expired, false);
  assert.equal(row.holder, 'box-2');

  const loser = await call('/api/hub/lease/renew', {
    method: 'POST', body: { holder: 'box-hub', epoch: 4 }, state
  });
  assert.equal(loser.status, 409, 'the previous holder cannot take it back with its cached epoch');
  assert.equal(row.holder, 'box-2');
  assert.equal(row.epoch, 5);
});

test('W5 the first lease ever bootstraps itself', async () => {
  const state = {};
  const r = await call('/api/hub/lease/renew', {
    method: 'POST', body: { holder: 'box-2', epoch: 0 }, state
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.taken, true);
  assert.equal(r.body.lease.holder, 'box-2');
  assert.equal(r.body.lease.epoch, 1);
  assert.equal(r.body.lease.expired, false);
});

test('W6 the lease routes are bearer-gated and refuse a bad holder or epoch', async () => {
  for (const [path, method] of [
    ['/api/hub/lease', 'GET'],
    ['/api/hub/lease/renew', 'POST'],
    ['/api/hub/lease/promote', 'POST']
  ]) {
    const r = await call(path, { method, body: method === 'POST' ? { holder: 'box-hub', epoch: 0 } : undefined, secret: null });
    assert.equal(r.status, 401, `${method} ${path} must be 401`);
  }

  const row = LEASE();
  const before = { ...row };
  for (const [path, body] of [
    ['/api/hub/lease/renew', { holder: 'bad name!', epoch: 0 }],
    ['/api/hub/lease/renew', { holder: 'box-hub', epoch: '4.5' }],
    ['/api/hub/lease/renew', { holder: 'box-hub', epoch: -1 }],
    ['/api/hub/lease/renew', { holder: 'box-hub', epoch: true }],
    ['/api/hub/lease/renew', { holder: 'box-hub' }]
  ]) {
    const r = await call(path, { method: 'POST', body, state: { hubLease: row } });
    assert.equal(r.status, 400, `${path} ${JSON.stringify(body)} must be 400`);
    assert.equal(r.db._calls.filter((c) => /hub_lease/.test(c.sql)).length, 0,
      'a rejected request must not touch the table');
    assert.deepEqual({ ...row }, before, 'a rejected request must not move the row');
  }
});

test('W7 the merged client path spellings hit the same handlers', async () => {
  const read = await call('/api/hub-lease?holder=box-hub', { state: { hubLease: LEASE() } });
  const readSpec = await call('/api/hub/lease', { state: { hubLease: LEASE() } });
  assert.equal(read.status, readSpec.status);
  assert.deepEqual(Object.keys(read.body).sort(), Object.keys(readSpec.body).sort());
  assert.equal(read.body.lease.holder, 'box-hub');
  assert.equal(read.body.lease.expired, false);

  const renewRow = LEASE();
  const renew = await call('/api/hub-lease', {
    method: 'POST', body: { holder: 'box-hub', epoch: 4 }, state: { hubLease: renewRow }
  });
  assert.equal(renew.status, 200);
  assert.equal(renew.body.renewed, true);
  assert.equal(renew.body.lease.epoch, 4);

  // BH-2272: both promote spellings are retired to the same 410 (W3).
  const promote = await call('/api/hub-lease/promote', {
    method: 'POST', body: { holder: 'box-2' }, state: { hubLease: LEASE() }
  });
  const promoteSpec = await call('/api/hub/lease/promote', {
    method: 'POST', body: { holder: 'box-2' }, state: { hubLease: LEASE() }
  });
  assert.equal(promote.status, 410);
  assert.equal(promoteSpec.status, 410);
  assert.deepEqual(promote.body, promoteSpec.body);
});

test('W8 ttl_s is clamped into [60, 900] and defaults to 180', async () => {
  const cases = [[5, 60], [5000, 900], [undefined, 180]];
  for (const [ttl, want] of cases) {
    const body = { holder: 'box-hub', epoch: 0 };
    if (ttl !== undefined) body.ttl_s = ttl;
    const r = await call('/api/hub/lease/renew', { method: 'POST', body, state: {} });
    assert.equal(r.status, 200);
    assert.ok(Math.abs(r.body.lease.remaining_s - want) <= 10,
      `ttl_s ${ttl} should leave ~${want}s, got ${r.body.lease.remaining_s}`);
  }
});

test('W9 the lease aliases did not widen the router', async () => {
  const r = await call('/api/hub/lease/nope', { state: { hubLease: LEASE() } });
  assert.equal(r.status, 404);
  assert.equal(r.body.error, 'unknown endpoint');
});
