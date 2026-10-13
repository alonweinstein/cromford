import test from 'node:test';
import assert from 'node:assert/strict';
import { call, sqlOf } from '../lib/harness.js';

test('a box backup report stores the three raw facts and only ever moves the collection clock forward', async () => {
  const bad = await call('/api/boxes/backup', { method: 'POST', body: { box: 'not a box name' } });
  assert.equal(bad.status, 400);
  const noAuth = await call('/api/boxes/backup', { method: 'POST', body: { box: 'hub' }, secret: null });
  assert.equal(noAuth.status, 401);

  const r = await call('/api/boxes/backup', {
    method: 'POST', body: { box: 'box-project-9-1', ts: '20260921T101500Z', off: '', unconfigured: '' }
  });
  assert.equal(r.status, 200);
  const [w] = sqlOf(r.db, /INTO box_status/);
  assert.match(w.sql, /INSERT INTO box_status \(box, backup_ts, backup_off, backup_unconfigured, backup_reported_at, updated_at\)/);
  assert.equal(w.binds[0], 'box-project-9-1');
  assert.equal(w.binds[1], '20260921T101500Z');
  // EMPTY IS NOT A VERDICT. str() turns "" into null, and null is what "the box
  // answered and there is nothing there" looks like in a column — distinct from
  // the row simply not existing, which is what "the box did not answer" is.
  assert.equal(w.binds[2], null);
  assert.equal(w.binds[3], null);
  // A LATER REPORT ONLY WINS IF IT IS ACTUALLY LATER: a retry that overtakes its
  // own original must not replace a fresh answer with a stale one.
  for (const col of ['backup_ts', 'backup_off', 'backup_unconfigured', 'backup_reported_at']) {
    assert.match(w.sql, new RegExp(`${col}=CASE WHEN box_status\\.backup_reported_at IS NULL OR box_status\\.backup_reported_at<=\\?5`));
  }
  // The ALTERs run before the write — box_status predates these columns in the
  // live database, so the CREATE in schema.sql can never reach it.
  assert.ok(sqlOf(r.db, /ALTER TABLE box_status ADD COLUMN backup_ts/).length
         || sqlOf(r.db, /PRAGMA table_info\(box_status\)/).length,
    'the backup columns must be ensured before the write');

  // A ts THAT WILL NOT PARSE IS STILL STORED. The hub's reader has a state for
  // it (`unknown`, which never pages and never reads as fresh); a 400 here would
  // turn a corrupt stamp into no report at all, which the hub reads as a box
  // that went quiet — a different and louder story.
  const junk = await call('/api/boxes/backup', {
    method: 'POST', body: { box: 'box-project-3-2', ts: 'not-a-timestamp', unconfigured: 'unconfigured' }
  });
  assert.equal(junk.status, 200);
  const [j] = sqlOf(junk.db, /INTO box_status/);
  assert.equal(j.binds[1], 'not-a-timestamp');
  assert.equal(j.binds[3], 'unconfigured');
});
