import test from 'node:test';
import assert from 'node:assert/strict';
import { call } from '../lib/harness.js';

// BH-1657: a settings row `account.<project>` pins a project to its own Claude
// account by LABEL. The worker PUT is the one path that writes the row (the
// console, harness-ctl and a bearer holder all land here, D15), so this is
// where a token pasted into the value is refused — before any write, and
// without echoing it back.
const inserts = (r) => r.db._calls.filter((c) => /INSERT INTO settings/.test(c.sql));

test('account.<project>: a label is stored', async () => {
  const r = await call('/api/settings', {
    method: 'PUT', body: { key: 'account.project-3', value: 'own:project-3', actor: 'console' },
    state: { settings: [{ key: 'account.project-3', value: 'own:project-3', actor: 'console' }] },
  });
  assert.equal(r.status, 200);
  assert.deepEqual(inserts(r)[0].binds.slice(0, 2), ['account.project-3', 'own:project-3']);
  assert.equal(r.body.setting.value, 'own:project-3');
});

test('account.<project>: `shared` (the explicit unpin) is stored', async () => {
  const r = await call('/api/settings', { method: 'PUT', body: { key: 'account.project-3', value: 'shared' } });
  assert.equal(r.status, 200);
  assert.equal(inserts(r)[0].binds[1], 'shared');
});

test('account.<project>: a token is refused and never echoed', async () => {
  for (const value of ['sk-ant-oat01-xyz', 'sk-ant-api03-' + 'A'.repeat(40), 'sk-proj-abc']) {
    const r = await call('/api/settings', { method: 'PUT', body: { key: 'account.project-3', value } });
    assert.equal(r.status, 400, `accepted ${value}`);
    assert.equal(inserts(r).length, 0, `wrote a row for ${value}`);
    assert.ok(!JSON.stringify(r.body).includes('sk-'), `echoed the value: ${JSON.stringify(r.body)}`);
  }
});

test('account.<project>: a label that walks out of accounts.d is refused', async () => {
  for (const value of ['../x', 'a/b', 'own..project-3', '.hidden', 'own project-3', 'x'.repeat(65)]) {
    const r = await call('/api/settings', { method: 'PUT', body: { key: 'account.project-3', value } });
    assert.equal(r.status, 400, `accepted ${value}`);
    assert.equal(inserts(r).length, 0, `wrote a row for ${value}`);
  }
});

test('a non-account key is not policed by the account rule', async () => {
  const r = await call('/api/settings', { method: 'PUT', body: { key: 'some_note_key', value: 'sk-not-a-label/..' } });
  assert.equal(r.status, 200);
  assert.equal(inserts(r).length, 1);
});
