// BH-3777: the daily digest counts NEEDS_HUMAN_VERDICT rows in
// human_verdict_prs beside BLOCKED_HUMAN. A PR whose lead-verdict status BH-3683
// withholds waits on a person, and the one beat it got on 2026-09-30 was buried
// among 270 open alerts; the digest is the daily surface that names it.
//
// Driven through the real worker.fetch on GET /api/metrics/daily-digest over a
// REAL schema.sql database (node:sqlite), seeded the way mc_ledger_put writes
// pr_state_events. pr_state is the MAX(id) event per PR.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const ANCHOR = Date.now();  // determinism: ok the single anchor; the route's own clock is compared against it
const DAY = 24 * 3600e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const YESTERDAY = iso(ANCHOR - DAY).slice(0, 10);
const T1 = `${YESTERDAY}T01:00:00Z`;
const T2 = `${YESTERDAY}T02:00:00Z`;
const T3 = `${YESTERDAY}T03:00:00Z`;
const NHV = 'lead-verdict withheld on 0123456789ab: touches protected paths: catalog/switches.d/x-off.json — a human verdict publishes it: bin/lead-verdict.sh post example-org/cromford 3758 0123456789abcdef0123456789abcdef01234567 MERGE --source human';

const prEvent = (db, repo, number, state, since, reason = null) => db.prepare(
  `INSERT INTO pr_state_events (repo, number, state, since, reason, at) VALUES (?, ?, ?, ?, ?, ?)`,
).run(repo, number, state, since, reason, since);
const digest = async (DB) => {
  const res = await worker.fetch(
    new Request(`https://jobs.test/api/metrics/daily-digest?day=${YESTERDAY}`, { headers: { authorization: `Bearer ${SECRET}` } }),
    { DB, HARNESS_SECRET: SECRET },
  );
  const body = await res.json();
  assert.equal(res.status, 200, JSON.stringify(body));
  return body;
};

test('BH-3777 daily digest: NEEDS_HUMAN_VERDICT rows', async (t) => {
  if ((await openDb()) === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  await t.test('a NEEDS_HUMAN_VERDICT row is counted in human_verdict_prs with its reason', async () => {
    const { db, DB } = await openDb();
    prEvent(db, 'example-org/cromford', 3591, 'BLOCKED_HUMAN', T1, 'needs a human verdict');
    prEvent(db, 'example-org/cromford', 3758, 'READY', T1, 'clean, approved, checks green');
    prEvent(db, 'example-org/cromford', 3758, 'NEEDS_HUMAN_VERDICT', T2, NHV);
    const d = await digest(DB);
    assert.equal(d.human_verdict_prs.ok, true, JSON.stringify(d.human_verdict_prs));
    assert.equal(d.human_verdict_prs.n, 2);
    assert.deepEqual(d.human_verdict_prs.rows, [
      { project: 'cromford', repo: 'example-org/cromford', number: 3591, reason: 'needs a human verdict', since: T1 },
      { project: 'cromford', repo: 'example-org/cromford', number: 3758, reason: NHV, since: T2 },
    ]);
  });

  await t.test('a PR that left NEEDS_HUMAN_VERDICT (READY -> QUEUED) is not counted', async () => {
    const { db, DB } = await openDb();
    prEvent(db, 'example-org/cromford', 3758, 'NEEDS_HUMAN_VERDICT', T1, NHV);
    prEvent(db, 'example-org/cromford', 3758, 'READY', T2, 'clean, approved, checks green');
    prEvent(db, 'example-org/cromford', 3758, 'QUEUED', T3, 'enqueued at 01234567');
    const d = await digest(DB);
    assert.equal(d.human_verdict_prs.n, 0);
    assert.deepEqual(d.human_verdict_prs.rows, []);
  });
});
