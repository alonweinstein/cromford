// BH-1636 item 4: the worker keeps grok's CLI readings.
//
// bin/cli-version-check.sh and bin/cli-update.sh have pushed grok rows since
// BH-1494, and the route's cli allowlist (claude|codex) dropped every one, so
// the fleet's grok versions were recorded nowhere but the hub's own TSV. A grok
// row now lands in cli_versions history. It never touches box_status: that
// table has one column per CLI and none for grok, and the old ternary would
// have written grok's version into codex_version.
import test from 'node:test';
import assert from 'node:assert/strict';
import { call, sqlOf } from '../lib/harness.js';

const grokRow = {
  box: 'project-4', cli: 'grok', at: '2026-09-24T05:40:05Z', source: 'check',
  version_before: '1.0.40', version_after: '1.0.40', method: 'check', ok: '1',
  path: '/root/.grok/bin/grok', note: '',
};

test('G1: a grok row is accepted into history and read back by GET ?cli=grok', async () => {
  const r = await call('/api/metrics/cli-versions', { method: 'POST', body: { rows: [grokRow] } });
  assert.equal(r.status, 200);
  assert.equal(r.body.accepted, 1);
  assert.equal(r.body.inserted, 1);
  const [hist] = sqlOf(r.db, /INSERT INTO cli_versions/);
  assert.deepEqual(hist.binds.slice(0, 6), ['project-4', 'grok', '2026-09-24T05:40:05Z', 'check', '1.0.40', '1.0.40']);
  // Read back what the POST wrote: the stored row is built from its binds.
  const cols = ['box', 'cli', 'at', 'source', 'version_before', 'version_after', 'method', 'ok', 'path', 'note'];
  const stored = Object.fromEntries(cols.map((c, i) => [c, hist.binds[i]]));
  const g = await call('/api/metrics/cli-versions?cli=grok', { state: { cliVersions: [stored] } });
  assert.equal(g.status, 200);
  assert.deepEqual(g.body.cli_versions.map((x) => [x.box, x.cli, x.version_after]), [['project-4', 'grok', '1.0.40']]);
  assert.deepEqual(sqlOf(g.db, /FROM cli_versions/)[0].binds, ['grok']);
});

test('G2: a grok row never writes box_status (no fall-through into codex_version)', async () => {
  const r = await call('/api/metrics/cli-versions', {
    method: 'POST', body: { rows: [{ ...grokRow, box: 'hub', version_after: '1.0.40' }] },
  });
  assert.equal(r.status, 200);
  assert.equal(sqlOf(r.db, /INTO box_status/).length, 0);
  // ...while claude and codex in the same batch still move their own columns.
  const mixed = await call('/api/metrics/cli-versions', {
    method: 'POST', body: { rows: [
      { ...grokRow, box: 'hub' },
      { ...grokRow, box: 'hub', cli: 'codex', version_after: '0.155.1' },
      { ...grokRow, box: 'hub', cli: 'claude', version_after: '2.1.261' },
    ] },
  });
  assert.equal(mixed.status, 200);
  assert.equal(mixed.body.accepted, 3);
  const st = sqlOf(mixed.db, /INTO box_status/);
  assert.equal(st.length, 2);
  assert.match(st[0].sql, /codex_version=CASE/);
  assert.equal(st[0].binds[2], '0.155.1');
  assert.match(st[1].sql, /\bcli_version=CASE/);
  assert.equal(st[1].binds[2], '2.1.261');
  assert.ok(!st.some((s) => s.binds[2] === '1.0.40'), 'grok 1.0.40 reached box_status');
});

test('G3: gemini is still refused, and the 400 names claude, codex and grok', async () => {
  const r = await call('/api/metrics/cli-versions', {
    method: 'POST', body: { rows: [{ ...grokRow, cli: 'gemini' }] },
  });
  assert.equal(r.status, 400);
  assert.match(r.body.error, /claude\|codex\|grok/);
  assert.equal(sqlOf(r.db, /INSERT INTO cli_versions/).length, 0);
});
