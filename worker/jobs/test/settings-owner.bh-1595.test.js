import test from 'node:test';
import assert from 'node:assert/strict';
import { call } from './lib/harness.js';

// BH-1609 (BH-1595.2): PUT /api/settings refuses a reconcile owner that names
// no fleet box, so a typo cannot silently leave every box skipping the lane.
const KEY = 'lane.reconcile-prs.reconcile_prs_owner';
const fleet = { boxStatus: [{ box: 'box-a' }, { box: 'box-b' }] };
const inserts = (r) => r.db._calls.filter((c) => /INSERT INTO settings/.test(c.sql)).length;
const boxReads = (r) => r.db._calls.filter((c) => /FROM box_status/.test(c.sql)).length;
const put = (value, state = fleet, key = KEY) => call('/api/settings', { method: 'PUT', body: { key, value }, state });

test('unknown box with box_status populated -> 400, no write', async () => {
  const r = await put('box-z');
  assert.equal(r.status, 400);
  assert.deepEqual(r.body.known, ['box-a', 'box-b']);
  assert.match(r.body.error, /box-z is not a fleet box/);
  assert.equal(inserts(r), 0);
});

test('hub -> 200', async () => {
  const r = await put('hub');
  assert.equal(r.status, 200);
  assert.equal(inserts(r), 1);
});

test('known box -> 200, stored as sent', async () => {
  const r = await put('box-a');
  assert.equal(r.status, 200);
  assert.equal(r.db._calls.find((c) => /INSERT INTO settings/.test(c.sql)).binds[1], 'box-a');
  assert.equal(r.body.warning, undefined);
});

test('empty box_status -> 200 with warning', async () => {
  const r = await put('box-z', { boxStatus: [] });
  assert.equal(r.status, 200);
  assert.equal(inserts(r), 1);
  assert.match(r.body.warning, /fleet list empty/);
});

test('illegal chars -> 400, no write', async () => {
  const r = await put('box a;rm');
  assert.equal(r.status, 400);
  assert.match(r.body.error, /owner must match/);
  assert.equal(inserts(r), 0);
});

test('other keys are not validated and issue no box_status read', async () => {
  const r = await put('50', fleet, 'lane.reconcile-prs.reconcile_prs_page');
  assert.equal(r.status, 200);
  assert.equal(boxReads(r), 0);
});

test('seed-registry still writes hub for the owner row', async () => {
  const r = await call('/api/settings/seed-registry', { method: 'POST', state: fleet });
  assert.equal(r.status, 200);
  const row = r.db._calls.find((c) => /INSERT INTO settings/.test(c.sql) && c.binds[0] === KEY);
  assert.ok(row, 'owner row not seeded');
  assert.equal(row.binds[1], 'hub');
});
