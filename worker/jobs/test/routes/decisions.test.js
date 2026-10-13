import test from 'node:test';
import assert from 'node:assert/strict';
import { call } from '../lib/harness.js';

test('decisions POST: INSERT OR IGNORE batch, 413 at 201 rows, replay ignored', async () => {
  const missing = await call('/api/decisions', { method: 'POST', body: { project: 'p', rows: [{ stamp: 's' }] } });
  assert.equal(missing.status, 400);
  const noProject = await call('/api/decisions', { method: 'POST', body: { rows: [{ stamp: 's', line: 'l' }] } });
  assert.equal(noProject.status, 400);
  const notArray = await call('/api/decisions', { method: 'POST', body: { project: 'p', rows: 'x' } });
  assert.equal(notArray.status, 400);

  const tooMany = await call('/api/decisions', {
    method: 'POST', body: { project: 'p', rows: new Array(201).fill({ stamp: 's', line: 'l' }) }
  });
  assert.equal(tooMany.status, 413);
  assert.equal(tooMany.db._calls.filter((c) => /INSERT OR IGNORE INTO decisions/.test(c.sql)).length, 0);

  const state = { decisions: [{ project: 'cromford', stamp: '2026-09-01T00:00:00Z', line: 'old' }] };
  const r = await call('/api/decisions', {
    method: 'POST',
    state,
    body: { project: 'cromford', rows: [
      { stamp: '2026-09-01T00:00:00Z', gate: 'g1', scope: 's1', ticket: 'BH-433', line: 'old' },
      { stamp: '2026-09-02T00:00:00Z', gate: 'g2', scope: 's2', ticket: 'BH-433', line: 'new' }
    ] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.inserted, 1);
  assert.equal(r.body.ignored, 1);
  const ins = r.db._calls.find((c) => /INSERT OR IGNORE INTO decisions/.test(c.sql));
  assert.ok(ins, 'must batch insert');
  assert.equal(ins.binds[1], 'cromford');
});

test('decisions POST: an empty rows[] is the idempotent no-op, not an error', async () => {
  const r = await call('/api/decisions', { method: 'POST', body: { project: 'cromford', rows: [] } });
  assert.equal(r.status, 200);
  assert.deepEqual([r.body.inserted, r.body.ignored], [0, 0]);
  assert.equal(r.db._calls.filter((c) => /INSERT OR IGNORE INTO decisions/.test(c.sql)).length, 0);
});

test('decisions POST: a non-object row is a 400, and an over-long dedupe key is refused not truncated', async () => {
  const junk = await call('/api/decisions', { method: 'POST', body: { project: 'cromford', rows: [null] } });
  assert.equal(junk.status, 400);
  assert.equal(junk.db._calls.filter((c) => /INSERT OR IGNORE/.test(c.sql)).length, 0);
  // Cutting `line` to length would dedupe two different lines as one and drop a
  // record with nothing in the answer to say so.
  const long = await call('/api/decisions', {
    method: 'POST',
    body: { project: 'cromford', rows: [{ stamp: '2026-09-01T00:00:00Z', line: 'x'.repeat(4001) }] }
  });
  assert.equal(long.status, 400);
  assert.equal(long.db._calls.filter((c) => /INSERT OR IGNORE/.test(c.sql)).length, 0);
  const ok = await call('/api/decisions', {
    method: 'POST',
    body: { project: 'cromford', rows: [{ stamp: '2026-09-01T00:00:00Z', line: 'x'.repeat(4000) }] }
  });
  assert.equal(ok.status, 200, '4000 chars is still accepted');
});

test('findings POST: INSERT OR IGNORE batch, 413 at 201 rows, replay ignored', async () => {
  const missing = await call('/api/findings', { method: 'POST', body: { project: 'p', rows: [{ stamp: 's' }] } });
  assert.equal(missing.status, 400);
  const noLine = await call('/api/findings', { method: 'POST', body: { project: 'p', rows: [{ stamp: 's', ticket: 't' }] } });
  assert.equal(noLine.status, 400);

  const tooMany = await call('/api/findings', {
    method: 'POST', body: { project: 'p', rows: new Array(201).fill({ stamp: 's', line: 'l' }) }
  });
  assert.equal(tooMany.status, 413);

  const state = { findings: [{ project: 'cromford', stamp: '2026-09-01T00:00:00Z', line: 'old' }] };
  const r = await call('/api/findings', {
    method: 'POST',
    state,
    body: { project: 'cromford', rows: [
      { stamp: '2026-09-01T00:00:00Z', lens: 'l1', ticket: 'BH-433', line: 'old' },
      { stamp: '2026-09-02T00:00:00Z', lens: 'l2', ticket: 'BH-433', line: 'new' }
    ] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.inserted, 1);
  assert.equal(r.body.ignored, 1);
  const ins = r.db._calls.find((c) => /INSERT OR IGNORE INTO findings/.test(c.sql));
  assert.ok(ins);
  assert.equal(ins.binds[1], 'cromford');
});

test('decisions GET requires since and truncates with lim+1', async () => {
  const missing = await call('/api/decisions');
  assert.equal(missing.status, 400);
  const r = await call('/api/decisions?since=2026-09-01T00:00:00Z&limit=2', {
    state: { decisions: [
      { project: 'cromford', stamp: '2026-09-01T00:00:00Z', line: 'a' },
      { project: 'cromford', stamp: '2026-09-02T00:00:00Z', line: 'b' },
      { project: 'cromford', stamp: '2026-09-03T00:00:00Z', line: 'c' }
    ] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.rows.length, 2, 'the contract key is rows');
  assert.equal(r.body.truncated, true);
  assert.ok(r.body.as_of);
  const sql = r.db._calls.find((c) => /FROM decisions/.test(c.sql)).sql;
  assert.match(sql, /stamp>=\?/);
  assert.match(sql, /LIMIT 3/);
  // Several lines share one stamp routinely, so the id tiebreak is what makes
  // paging on `since` stable instead of interleaving a restore.
  assert.match(sql, /ORDER BY stamp ASC, id ASC/);

  const capped = await call('/api/decisions?since=2026-09-01T00:00:00Z&limit=9999');
  assert.match(capped.db._calls.find((c) => /FROM decisions/.test(c.sql)).sql, /LIMIT 5001/, 'limit caps at 5000');
  const filtered = await call('/api/decisions?since=2026-09-01T00:00:00Z&project=cromford');
  assert.match(filtered.db._calls.find((c) => /FROM decisions/.test(c.sql)).sql, /project=\?1/);
});

test('findings GET requires since and truncates with lim+1', async () => {
  const missing = await call('/api/findings');
  assert.equal(missing.status, 400);
  const r = await call('/api/findings?since=2026-09-01T00:00:00Z&limit=2', {
    state: { findings: [
      { project: 'cromford', stamp: '2026-09-01T00:00:00Z', line: 'a' },
      { project: 'cromford', stamp: '2026-09-02T00:00:00Z', line: 'b' },
      { project: 'cromford', stamp: '2026-09-03T00:00:00Z', line: 'c' }
    ] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.rows.length, 2, 'the contract key is rows');
  assert.equal(r.body.truncated, true);
  assert.ok(r.body.as_of);
  const sql = r.db._calls.find((c) => /FROM findings/.test(c.sql)).sql;
  assert.match(sql, /stamp>=\?/);
  assert.match(sql, /LIMIT 3/);
  assert.match(sql, /ORDER BY stamp ASC, id ASC/);
  const capped = await call('/api/findings?since=2026-09-01T00:00:00Z&limit=9999');
  assert.match(capped.db._calls.find((c) => /FROM findings/.test(c.sql)).sql, /LIMIT 5001/, 'limit caps at 5000');
});
