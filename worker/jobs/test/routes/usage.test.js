import test from 'node:test';
import assert from 'node:assert/strict';
import { call, sqlOf } from '../lib/harness.js';

test('an extra-usage snapshot is keyed (box, ts) — two boxes are two facts', async () => {
  const missing = await call('/api/metrics/extra-usage', { method: 'POST', body: { ts: '2026-08-29T23:45:24Z' } });
  assert.equal(missing.status, 400);

  const body = {
    box: 'hub', ts: '2026-08-29T23:45:24Z', session_pct: '14', weekly_pct: '71',
    weekly_resets_at: '2026-09-03T03:59:59Z', extra_enabled: '1',
    extra_used_usd: '19792.21', spend_limit_reached: '0', in_overage: '0'
  };
  const r = await call('/api/metrics/extra-usage', {
    method: 'POST', state: { snapshots: [{ box: 'hub', ts: body.ts }] }, body
  });
  assert.equal(r.status, 200);
  const [w] = sqlOf(r.db, /INSERT INTO extra_usage_snapshots/);
  assert.match(w.sql, /ON CONFLICT\(box, ts\) DO UPDATE/);
  assert.equal(w.binds[0], 'hub');
  assert.equal(w.binds[1], body.ts);
  assert.equal(w.binds[5], 1);   // extra_enabled, "1" -> 1
  assert.equal(w.binds[8], 0);   // in_overage, "0" -> 0 and NOT truthy-1
});

test('a poll that FAILED posts a row with a status and no numbers', async () => {
  // 2026-09-14: six boxes hold a credential that can never read this endpoint
  // (a setup-token answers 429 forever). They used to report that by writing
  // nothing, which in this table is indistinguishable from a box whose cron is
  // dead — and only one of the two is fixed by provisioning a login.
  const r = await call('/api/metrics/extra-usage', {
    method: 'POST',
    state: { snapshotCols: ['box', 'ts'] },
    body: { box: 'project-2', ts: '2026-09-14T19:00:00Z', extra_used_usd: '', status: 'no-login' }
  });
  assert.equal(r.status, 200);
  const [w] = sqlOf(r.db, /INSERT INTO extra_usage_snapshots/);
  assert.equal(w.binds[6], null);          // extra_used_usd: absent, NOT 0
  assert.equal(w.binds[11], 'no-login');
  // The four columns are added to an already-deployed table before the write,
  // so a deploy IS the migration here (the same mechanism pr_costs uses).
  // BH-3985 made it four: error_body.
  const alters = sqlOf(r.db, /ALTER TABLE extra_usage_snapshots/);
  assert.equal(alters.length, 4);
  assert.ok(alters.some((a) => /ADD COLUMN error_body TEXT/.test(a.sql)), alters.map((a) => a.sql).join(' | '));
});

test('status defaults to ok only when the row actually carries a reading', async () => {
  // An older client posts nine arguments and no status. Calling its real polls
  // "ok" is true; calling a row with no numbers "ok" would not be.
  const ok = await call('/api/metrics/extra-usage', {
    method: 'POST',
    state: { snapshotCols: ['box', 'ts', 'extra_limit_usd', 'extra_pct', 'status', 'error_body'] },
    body: { box: 'hub', ts: '2026-09-14T19:00:00Z', extra_used_usd: '19792.21' }
  });
  assert.equal(sqlOf(ok.db, /INSERT INTO extra_usage_snapshots/)[0].binds[11], 'ok');
  assert.equal(sqlOf(ok.db, /ALTER TABLE extra_usage_snapshots/).length, 0);
  const blind = await call('/api/metrics/extra-usage', {
    method: 'POST',
    state: { snapshotCols: ['box', 'ts', 'extra_limit_usd', 'extra_pct', 'status', 'error_body'] },
    body: { box: 'hub', ts: '2026-09-14T19:15:00Z' }
  });
  assert.equal(sqlOf(blind.db, /INSERT INTO extra_usage_snapshots/)[0].binds[11], null);
});

test('a reconciliation row is keyed (account, window_key, window_end)', async () => {
  const r = await call('/api/metrics/reconcile', {
    method: 'POST',
    body: { rows: [
      { account: 'project-6-account', window_key: '1h', window_start: '2026-09-14T19:00:00Z',
        window_end: '2026-09-14T20:00:00Z', state: 'metered', meter_delta_usd: 100,
        rows_usd: '40', gap_usd: 60, gap_pct: '60', rows_count: '2', alerted: 1 },
      { account: 'hub-gmail', window_key: '1h', window_start: '2026-09-14T19:00:00Z',
        window_end: '2026-09-14T20:00:00Z', state: 'credits-covered', note: 'weekly 71%' },
      { account: 'nope', window_key: '1h', state: 'metered' }   // no window_end: skipped
    ] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.accepted, 2);
  const writes = sqlOf(r.db, /INSERT INTO cost_reconciliation/);
  assert.equal(writes.length, 2);
  // The hourly cadence re-runs the SAME window after a fix; it must correct the
  // row rather than append a second opinion of it.
  assert.match(writes[0].sql, /ON CONFLICT\(account, window_key, window_end\) DO UPDATE/);
  assert.equal(writes[0].binds[0], 'project-6-account');
  assert.equal(writes[0].binds[8], 40);     // rows_usd, a CSV-ish string -> number
  assert.equal(writes[0].binds[11], 2);     // rows_count, an INTEGER column
  assert.equal(writes[0].binds[19], 1);     // alerted
  // credits-covered carries no dollar comparison, and NULL is how it says so —
  // a 0 here would be read as "the two agreed exactly".
  assert.equal(writes[1].binds[13], null);  // gap_usd
  assert.equal(writes[1].binds[14], null);  // gap_pct
});

test('a reconciliation row without a state is refused, not stored blank', async () => {
  // state is the whole honesty of this table: metered, credits-covered,
  // no-login, no-meter and meter-reset are five different claims about the same
  // dollar figure, and a row that does not say which is unreadable.
  const none = await call('/api/metrics/reconcile', {
    method: 'POST', body: { rows: [{ account: 'a', window_key: '1h', window_end: 'x' }] } });
  assert.equal(none.status, 400);
  const empty = await call('/api/metrics/reconcile', { method: 'POST', body: { rows: [] } });
  assert.equal(empty.status, 400);
  const tooMany = await call('/api/metrics/reconcile', {
    method: 'POST', body: { rows: new Array(501).fill({ account: 'a', window_key: '1h', window_end: 'x', state: 'metered' }) } });
  assert.equal(tooMany.status, 400);
  // A single row without rows[] is accepted — one account, by hand, is a
  // legitimate caller.
  const one = await call('/api/metrics/reconcile', {
    method: 'POST',
    body: { account: 'a', window_key: '1h', window_start: 's', window_end: 'e', state: 'no-login' } });
  assert.equal(one.status, 200);
  assert.equal(one.body.accepted, 1);
});

test('the reconciliation read narrows by account, state and since', async () => {
  const state = { reconciliations: [
    { account: 'project-6-account', window_key: '24h', window_end: '2026-09-14T00:00:00Z', state: 'metered' },
    { account: 'project-6-account', window_key: '24h', window_end: '2026-09-10T00:00:00Z', state: 'metered' },
    { account: 'project-3', window_key: '24h', window_end: '2026-09-14T00:00:00Z', state: 'no-login' }
  ] };
  const r = await call('/api/metrics/reconcile?account=project-6-account&since=2026-09-13T00:00:00Z', { state });
  assert.equal(r.status, 200);
  assert.equal(r.body.reconciliations.length, 1);
  const byState = await call('/api/metrics/reconcile?state=no-login', { state });
  assert.equal(byState.body.reconciliations.length, 1);
  assert.equal(byState.body.reconciliations[0].account, 'project-3');
  // The limit is clamped: this is a read a dashboard makes.
  const [q] = sqlOf((await call('/api/metrics/reconcile?limit=99999', { state })).db, /FROM cost_reconciliation/);
  assert.match(q.sql, /LIMIT 1000$/);
});
