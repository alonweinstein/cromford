import test from 'node:test';
import assert from 'node:assert/strict';
import { call, worker } from '../lib/harness.js';

test('settings: a write is validated, a missing key is 200 {setting:null}, no bearer no data', async () => {
  // The knob store. Every assertion here is about a VALUE the worker decides:
  // what it refuses, what it stores, and what it answers when the row is not
  // there — because a consumer that reads a threshold every tick must be able
  // to tell "no row, use your fallback" from "the worker is down".
  const bad = [
    { key: 'BAD KEY', value: '1' },
    { key: 'GH_BUDGET', value: '1' },
    { key: 'ok_key', value: '' },
    { key: 'ok_key', value: '   ' },
    { key: 'ok_key' },
    { key: 'ok_key', value: null },
    { key: 'ok_key', value: true },
    { key: 'ok_key', value: {} },
    { key: 'ok_key', value: 'x'.repeat(257) },
    { key: 'a'.repeat(65), value: '1' },
    { value: '1' },
  ];
  for (const body of bad) {
    const r = await call('/api/settings', { method: 'PUT', body });
    assert.equal(r.status, 400, `accepted ${JSON.stringify(body)}`);
    assert.equal(r.db._calls.filter((c) => /INSERT INTO settings/.test(c.sql)).length, 0,
      `wrote a row for ${JSON.stringify(body)}`);
  }

  const ok = await call('/api/settings', {
    method: 'PUT',
    body: { key: 'gh_budget_min_remaining', value: '500', note: 'n' },
    state: { settings: [{ key: 'gh_budget_min_remaining', value: '500', note: 'n' }] }
  });
  assert.equal(ok.status, 200);
  const ins = ok.db._calls.find((c) => /INSERT INTO settings/.test(c.sql));
  assert.deepEqual(ins.binds.slice(0, 3), ['gh_budget_min_remaining', '500', 'n']);
  assert.equal(ins.binds[3], 'api', 'actor defaults to api when the body omits it');
  assert.equal(ok.body.setting.key, 'gh_budget_min_remaining');

  // A JSON number is a legal value — it is STORED as text, because every
  // consumer reads settings.value as a string and "800" must not arrive as 800.
  const num = await call('/api/settings', {
    method: 'PUT', body: { key: 'gh_budget_min_remaining', value: 800, actor: 'box-small' }
  });
  assert.equal(num.status, 200);
  const numIns = num.db._calls.find((c) => /INSERT INTO settings/.test(c.sql));
  assert.equal(numIns.binds[1], '800');
  assert.equal(typeof numIns.binds[1], 'string');
  assert.equal(numIns.binds[3], 'box-small');

  // No row is a REAL answer, not a 404 (the client's 404 branch means "ledger miss").
  const none = await call('/api/settings/nope');
  assert.equal(none.status, 200);
  assert.equal(none.body.setting, null);
  assert.equal(none.body.source, 'none');

  const found = await call('/api/settings/gh_budget_min_remaining', {
    state: { settings: [{ key: 'gh_budget_min_remaining', value: '800' }] }
  });
  assert.equal(found.status, 200);
  assert.equal(found.body.setting.value, '800');
  assert.equal(found.body.source, 'settings');

  const list = await call('/api/settings', {
    state: { settings: [{ key: 'a', value: '1' }, { key: 'b', value: '2' }] }
  });
  assert.equal(list.status, 200);
  assert.equal(list.body.settings.length, 2);

  // A key that can never exist is a caller bug, not "no row".
  const badGet = await call('/api/settings/BAD%20KEY');
  assert.equal(badGet.status, 400);
  assert.equal(badGet.db._calls.filter((c) => /settings/.test(c.sql)).length, 0,
    'an illegal key still queried the settings table');

  // Malformed percent-encoding is the same caller bug wearing a different hat:
  // decodeURIComponent THROWS on it, and an uncaught throw here would be a 500,
  // which every client maps to "the worker is down" and an operator then goes
  // looking for an outage that is really a typo in their own URL.
  const torn = await call('/api/settings/%E0%A4%A');
  assert.equal(torn.status, 400, 'a torn percent-escape did not answer 400');
  assert.match(String(torn.body.error), /^key must match/);
  assert.equal(torn.db._calls.filter((c) => /settings/.test(c.sql)).length, 0,
    'a torn percent-escape still queried the settings table');

  for (const [path, method] of [['/api/settings', 'GET'], ['/api/settings/gh_budget_min_remaining', 'GET'], ['/api/settings', 'PUT']]) {
    const r = await call(path, { method, secret: null, body: method === 'PUT' ? { key: 'ok_key', value: '1' } : undefined });
    assert.equal(r.status, 401, `${method} ${path} answered without a bearer`);
    assert.equal(r.db._calls.length, 0, `${method} ${path} touched the DB without a bearer`);
  }
});
