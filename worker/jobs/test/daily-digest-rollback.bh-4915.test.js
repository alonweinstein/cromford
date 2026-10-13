// BH-4915: a deploy-train revert is flagged in Archie's daily factory report.
//
// bin/deploy-rollback-board.sh writes one `deploy_rollback` ledger row per
// reverted merge, keyed "<project> <KEY>@<sha8>" (or "<project> <sha8>" for a
// merge with no ticket). The digest's Tripwires section lists it by created_at,
// through the real worker.fetch over a real schema.sql database.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { dayWindow } from '../src/lib/daily-digest/shape.js';

const SECRET = 'test-secret';
const ANCHOR = Date.now();  // determinism: ok the single anchor; the route's own clock is compared against it
const HOUR = 3600e3;
const DAY = 24 * HOUR;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const YESTERDAY = iso(ANCHOR - DAY).slice(0, 10);
const { from: FROM } = dayWindow(YESTERDAY, new Date(ANCHOR).toISOString());
const IN1 = iso(Date.parse(FROM) + HOUR);
const IN2 = iso(Date.parse(FROM) + 2 * HOUR);
const BEFORE = iso(Date.parse(FROM) - HOUR);

const ledger = (db, kind, key, status, created, updated = created) => db.prepare(
  `INSERT INTO ledgers (kind, key, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`,
).run(kind, key, status, created, updated);

const digest = async (DB) => {
  const res = await worker.fetch(
    new Request(`https://jobs.test/api/metrics/daily-digest?day=${YESTERDAY}`,
      { headers: { authorization: `Bearer ${SECRET}` } }),
    { DB, HARNESS_SECRET: SECRET },
  );
  const body = await res.json().catch(() => null);
  assert.equal(res.status, 200, JSON.stringify(body));
  return body;
};

test('BH-4915 deploy_rollback rows land in the digest tripwires', async (t) => {
  if ((await openDb()) === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  await t.test('an in-window rollback row is listed and counted; yesterday-before is not', async () => {
    const { db, DB } = await openDb();
    ledger(db, 'deploy_rollback', 'project-3 TK-286@abcd1234', 'reopened', IN1);
    ledger(db, 'deploy_rollback', 'project-3 0badc0de', 'flagged', IN2);
    ledger(db, 'deploy_rollback', 'project-3 TK-100@11112222', 'reopened', BEFORE);
    // a later status change of an old row does not bring it back into the window
    ledger(db, 'deploy_rollback', 'project-3 TK-101@33334444', 'commented-unmoved', BEFORE, IN1);

    const d = await digest(DB);
    assert.equal(d.tripwires.ok, true, JSON.stringify(d.tripwires));
    assert.equal(d.tripwires.n, 2);
    assert.deepEqual(d.tripwires.rows, [
      { kind: 'deploy_rollback', project: 'project-3', key: 'TK-286@abcd1234', at: IN1 },
      { kind: 'deploy_rollback', project: 'project-3', key: '0badc0de', at: IN2 },
    ]);
  });
});
