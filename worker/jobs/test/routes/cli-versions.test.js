import test from 'node:test';
import assert from 'node:assert/strict';
import { call, sqlOf } from '../lib/harness.js';

test('a cli-versions push writes the history row (DO NOTHING) and moves box_status forward only', async () => {
  const noRows = await call('/api/metrics/cli-versions', { method: 'POST', body: { rows: [] } });
  assert.equal(noRows.status, 400);
  const badCli = await call('/api/metrics/cli-versions', {
    method: 'POST', body: { rows: [{ box: 'project-9', cli: 'gemini', at: '2026-09-06T05:17:00Z' }] }
  });
  assert.equal(badCli.status, 400);
  const tooMany = await call('/api/metrics/cli-versions', {
    method: 'POST', body: { rows: new Array(501).fill({ box: 'b', cli: 'claude', at: 'x' }) }
  });
  assert.equal(tooMany.status, 400);

  const up = { box: 'project-9', cli: 'claude', at: '2026-09-06T05:17:00Z', source: 'update',
    version_before: '2.1.258', version_after: '2.1.261', method: 'native+npm', ok: '1',
    path: '/usr/bin/claude', note: 'relinked /usr/bin/claude' };
  const missing = { ...up, cli: 'codex', version_before: 'missing', version_after: 'missing', ok: '0', method: 'npm' };
  const keyless = { ...up, at: '' };
  const r = await call('/api/metrics/cli-versions', { method: 'POST', body: { rows: [up, missing, keyless] } });
  assert.equal(r.status, 200);
  assert.equal(r.body.accepted, 2);
  const hist = sqlOf(r.db, /INSERT INTO cli_versions/);
  assert.equal(hist.length, 2);
  assert.match(hist[0].sql, /ON CONFLICT\(box, cli, at, source\) DO NOTHING/);
  assert.deepEqual(hist[0].binds.slice(0, 4), ['project-9', 'claude', '2026-09-06T05:17:00Z', 'update']);
  assert.equal(hist[0].binds[5], '2.1.261');
  assert.equal(hist[0].binds[7], 1);              // ok coerced to an INTEGER
  assert.equal(hist[1].binds[7], 0);
  // box_status: the claude row upserts cli_version; the MISSING codex reading
  // does not touch codex_version (a missing CLI is an alert, not a version).
  const st = sqlOf(r.db, /INTO box_status/);
  assert.equal(st.length, 1);
  assert.match(st[0].sql, /cli_version=CASE WHEN box_status\.cli_checked_at IS NULL OR box_status\.cli_checked_at<=\?4/);
  assert.doesNotMatch(st[0].sql, /codex_version/);
  assert.equal(st[0].binds[2], '2.1.261');
  assert.equal(st[0].binds[3], '2026-09-06T05:17:00Z');
  assert.equal(st[0].binds[4], 'update');
  // A single-row body (no rows[]) is accepted too, and codex lands in codex_version.
  const one = await call('/api/metrics/cli-versions', {
    method: 'POST', body: { box: 'hub', cli: 'codex', at: '2026-09-06T05:40:00Z', source: 'check', version_after: '0.153.4' }
  });
  assert.equal(one.status, 200);
  assert.match(sqlOf(one.db, /INTO box_status/)[0].sql, /codex_version=CASE/);
});

test('GET /api/metrics/cli-versions filters by box and cli; GET /api/boxes lists box_status', async () => {
  const r = await call('/api/metrics/cli-versions?box=project-9&cli=claude&limit=3', {
    state: { cliVersions: [{ box: 'project-9', cli: 'claude', version_after: '2.1.261' }] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.cli_versions.length, 1);
  const [q] = sqlOf(r.db, /FROM cli_versions/);
  assert.deepEqual(q.binds, ['project-9', 'claude']);
  assert.match(q.sql, /ORDER BY at DESC LIMIT 3$/);
  const b = await call('/api/boxes', { state: { boxStatus: [{ box: 'hub', cli_version: '2.1.261' }] } });
  assert.equal(b.status, 200);
  assert.equal(b.body.boxes[0].cli_version, '2.1.261');
  const noAuth = await call('/api/boxes', { secret: null });
  assert.equal(noAuth.status, 401);
});
