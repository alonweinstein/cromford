// BH-3705 (BH-3688 slice 3 of 5): the daily-digest state sections.
//
// WHAT IS PINNED
//   Every case goes through the real worker.fetch on GET
//   /api/metrics/daily-digest over a REAL schema.sql database, seeded in the
//   key formats the shell writers produce (build-tripwire.sh, child-plan-
//   tripwire.sh, needs-human/trip.sh, ticket-hold-cmd.sh).
//   W1-state: one row of every source lands in its section, in the contract's
//     row shape (tests/fixtures/daily-digest/fixture-day.json key order).
//   W2-state: an empty DB answers the six state sections of empty-day.json.
//   W6: a missing table fails its own section only.
//   W7: factory_stop absent, all-off active, live fleet pauses only.
//   W8: the review_block_fp trip threshold is >=.
//   N1: every adversarial negative counts 0; window is [from, to).
//   N2: n is counted before the cap.
//   F1: factory_stop value parsing.
//
// The worker's clock is the real one. Every date comes off the ONE anchor below.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { dayWindow, SECTION_KEYS } from '../src/lib/daily-digest/shape.js';

const SECRET = 'test-secret';
const ANCHOR = Date.now();  // determinism: ok the single anchor; the route's own clock is compared against it
const HOUR = 3600e3;
const DAY = 24 * HOUR;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const YESTERDAY = iso(ANCHOR - DAY).slice(0, 10);
const DAYW = dayWindow(YESTERDAY, new Date(ANCHOR).toISOString());
const FROM = DAYW.from;
const TO = DAYW.to;
const IN1 = iso(Date.parse(FROM) + HOUR);
const IN2 = iso(Date.parse(FROM) + 2 * HOUR);
const BEFORE = iso(Date.parse(FROM) - 1000);
const LATER = iso(ANCHOR + DAY);

const fixture = (name) => JSON.parse(readFileSync(
  new URL(`../../../tests/fixtures/daily-digest/${name}`, import.meta.url), 'utf8'));
const EMPTY = fixture('empty-day.json');
const FULL = fixture('fixture-day.json');
const BASIS = 'D1 holds only (console holds, BLOCKED_HUMAN PRs, triage-seen waiting-on-human)';

const call = (DB, path) => worker.fetch(
  new Request(`https://jobs.test${path}`, { headers: { authorization: `Bearer ${SECRET}` } }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
const digest = async (DB, extra = '') => {
  const r = await call(DB, `/api/metrics/daily-digest?day=${YESTERDAY}${extra}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body;
};

// ── seeders, one per source table ────────────────────────────────────────────
const ledger = (db, kind, key, status, created, updated = created) => db.prepare(
  `INSERT INTO ledgers (kind, key, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`,
).run(kind, key, status, created, updated);
const prEvent = (db, repo, number, state, since, reason = null) => db.prepare(
  `INSERT INTO pr_state_events (repo, number, state, since, reason, at) VALUES (?, ?, ?, ?, ?, ?)`,
).run(repo, number, state, since, reason, since);
const triage = (db, project, key, decision, at) => db.prepare(
  `INSERT INTO triage_state (project, ticket_key, last_decision, last_decision_at, updated_at) VALUES (?, ?, ?, ?, ?)`,
).run(project, key, decision, at, at);
const model = (db, vendor, id, status, suggestion, firstSeen) => db.prepare(
  `INSERT INTO model_watch (vendor, model_id, source, status, suggestion, first_seen, updated_at) VALUES (?, ?, 'openrouter', ?, ?, ?, ?)`,
).run(vendor, id, status, suggestion, firstSeen, firstSeen);
let lrrId = 0;
const lrr = (db, repo, pr, sha, status, verdict, updated) => db.prepare(
  `INSERT INTO lead_review_requests (id, repo, pr, head_sha, status, verdict, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
).run(`lrr-${++lrrId}`, repo, pr, sha, status, verdict, updated, updated);
const setting = (db, key, value, actor, at) => db.prepare(
  `INSERT INTO settings (key, value, actor, updated_at) VALUES (?, ?, ?, ?)`,
).run(key, value, actor, at);
const flag = (db, name, active, actor, at) => db.prepare(
  `INSERT INTO pause_flags (name, active, actor, updated_at) VALUES (?, ?, ?, ?)`,
).run(name, active, actor, at);
const pause = (db, scope, what, actor, expires, ended = null) => db.prepare(
  `INSERT INTO pauses (scope, what, reason, actor, created_at, expires_at, ended_at) VALUES (?, ?, 'test', ?, ?, ?, ?)`,
).run(scope, what, actor, FROM, expires, ended);
const SHA = 'a'.repeat(40);
// BH-3793: past_sla is a state section; a fresh, empty stuck-work snapshot (the
// row bin/stuck-work.sh writes) keeps every case's state sections ok and empty.
const SNAP_AT = iso(ANCHOR - 60e3);
const EMPTY_STATE = { ...EMPTY, past_sla: { ...EMPTY.past_sla, as_of: SNAP_AT } };
const openSeeded = async () => {
  const o = await openDb();
  ledger(o.db, 'stuck_work_snapshot', 'latest', 'ok', SNAP_AT);
  o.db.prepare(`UPDATE ledgers SET detail = ? WHERE kind = 'stuck_work_snapshot' AND key = 'latest'`)
    .run(JSON.stringify({ at: Math.floor(ANCHOR / 1000), complete: true, by_state: {}, total: 0 }));
  return o;
};

test('BH-3705 daily-digest state sections on a real schema', async (t) => {
  if ((await openDb()) === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  await t.test('W1-state: one row of every source lands in its section, in the contract shape', async () => {
    const { db, DB } = await openSeeded();
    ledger(db, 'build-tripwire', 'cromford BH-9', 'paused', IN1);
    ledger(db, 'child_plan_tripwire', 'project-5 TK-12', 'fired', IN2);
    ledger(db, 'review_block_fp', 'project-3#212#deadbeef', '2', BEFORE, iso(Date.parse(FROM) + 3 * HOUR));
    ledger(db, 'review_block_fp', 'project-3#213#cafef00d', '1', BEFORE, IN1);
    ledger(db, 'ticket_hold', 'project-4#2101', 'held', BEFORE, IN1);
    prEvent(db, 'example-org/cromford', 3591, 'BLOCKED_HUMAN', IN2, 'needs a human verdict');
    triage(db, 'cromford', 'BH-1', 'skip hold:waiting-on-human BH-1 asked operator', IN1);
    model(db, 'anthropic', 'fixture-model-a', 'suggested', 'try it on stage.review rung 1', IN1);
    model(db, 'openai', 'fixture-model-b', 'new', null, IN2);
    lrr(db, 'example-org/project-5', 1788, SHA, 'done', 'MERGE', IN1);
    setting(db, 'switch.factory-stop', '1', 'operator', IN2);

    const d = await digest(DB, '&trip=2');
    for (const k of SECTION_KEYS.state) assert.equal(d[k].ok, true, `${k}: ${JSON.stringify(d[k])}`);

    assert.equal(d.tripwires.n, 3);
    assert.deepEqual(d.tripwires.rows, [
      { kind: 'build-tripwire', project: 'cromford', key: 'BH-9', at: IN1 },
      { kind: 'child_plan_tripwire', project: 'project-5', key: 'TK-12', at: IN2 },
      { kind: 'review_block_fp', project: 'project-3', key: '212', at: iso(Date.parse(FROM) + 3 * HOUR) },
    ]);

    assert.equal(d.holds.n, 3);
    assert.equal(d.holds.basis, BASIS);
    assert.deepEqual(d.holds.rows, [
      { source: 'ticket_hold', project: 'project-4', key: '#2101', since: IN1 },
      { source: 'waiting-on-human', project: 'cromford', key: 'BH-1', since: IN1 },
      { source: 'BLOCKED_HUMAN', project: 'cromford', key: '#3591', since: IN2 },
    ]);

    assert.equal(d.human_verdict_prs.n, 1);
    assert.deepEqual(d.human_verdict_prs.rows[0], {
      project: 'cromford', repo: 'example-org/cromford', number: 3591,
      reason: 'needs a human verdict', since: IN2,
    });

    assert.deepEqual(d.model_watch.rows,
      [{ vendor: 'anthropic', model_id: 'fixture-model-a', suggestion: 'try it on stage.review rung 1' }]);
    assert.deepEqual(d.spotcheck_candidates.rows,
      [{ repo: 'example-org/project-5', pr: 1788, head_sha: SHA, project: 'project-5' }]);
    assert.deepEqual(d.factory.factory_stop, { set: true, value: '1', actor: 'operator', updated_at: IN2 });

    // D4: every section and every row has the contract's keys in the contract's order.
    for (const k of SECTION_KEYS.state) {
      assert.deepEqual(Object.keys(d[k]), Object.keys(FULL[k]), `${k} keys`);
      if (Array.isArray(FULL[k].rows)) {
        for (const r of d[k].rows) assert.deepEqual(Object.keys(r), Object.keys(FULL[k].rows[0]), `${k} row keys`);
      }
    }
    assert.deepEqual(Object.keys(d.factory.factory_stop), Object.keys(FULL.factory.factory_stop));
    assert.deepEqual(Object.keys(d.factory.all_off), Object.keys(FULL.factory.all_off));
    assert.equal(d.empty, false);
  });

  await t.test('W2-state: an empty DB answers the six empty-day state sections', async () => {
    const { DB } = await openSeeded();
    const d = await digest(DB);
    for (const k of SECTION_KEYS.state) assert.deepEqual(d[k], EMPTY_STATE[k], k);
    assert.equal(d.tripwires.n, 0);
    assert.equal(d.holds.n, 0);
    assert.equal(d.human_verdict_prs.n, 0);
  });

  await t.test('W6: a missing table fails its own section only', async () => {
    const { db, DB } = await openSeeded();
    db.exec('DROP TABLE model_watch');
    const d = await digest(DB);
    assert.equal(d.model_watch.ok, false);
    assert.equal(typeof d.model_watch.error, 'string');
    assert.match(d.model_watch.error, /model_watch/);
    for (const k of SECTION_KEYS.state.filter((k) => k !== 'model_watch')) {
      assert.deepEqual(d[k], EMPTY_STATE[k], k);
    }
    assert.equal(d.empty, false, 'a failed read is never a quiet day');
  });

  await t.test('W7: factory_stop absent, all-off active, live fleet pauses only', async () => {
    const { db, DB } = await openSeeded();
    flag(db, 'all-off', 1, 'operator', IN1);
    flag(db, 'paused-project-3', 1, 'console', IN1);
    pause(db, 'fleet', 'builds', 'operator', LATER);
    pause(db, 'fleet', 'merges', 'operator', iso(ANCHOR - HOUR));          // expired, never swept
    pause(db, 'fleet', 'reviews', 'operator', LATER, iso(ANCHOR - HOUR));  // ended
    pause(db, 'project-3', 'triage', 'operator', LATER);                        // project-scoped
    const d = await digest(DB);
    assert.equal(d.factory.ok, true);
    assert.deepEqual(d.factory.factory_stop, { set: false, value: null, actor: null, updated_at: null });
    assert.deepEqual(d.factory.all_off, { set: true, actor: 'operator', since: IN1 });
    assert.deepEqual(d.factory.fleet_pauses, [{ what: 'builds', expires_at: LATER, actor: 'operator' }]);
    assert.deepEqual(Object.keys(d.factory.fleet_pauses[0]), Object.keys(FULL.factory.fleet_pauses[0]));

    db.prepare(`UPDATE pause_flags SET active=0 WHERE name='all-off'`).run();
    const off = await digest(DB);
    assert.deepEqual(off.factory.all_off, { set: false, actor: null, since: null });
  });

  await t.test('W8: the review_block_fp trip threshold is >= trip', async () => {
    const { db, DB } = await openSeeded();
    ledger(db, 'review_block_fp', 'project-3#212#deadbeef', '2', IN1);
    assert.equal((await digest(DB, '&trip=3')).tripwires.n, 0);
    assert.equal((await digest(DB, '&trip=2')).tripwires.n, 1);
    assert.equal((await digest(DB, '&trip=1')).tripwires.n, 1);
  });

  await t.test('N1: every adversarial negative counts 0, and the window is [from, to)', async () => {
    const { db, DB } = await openSeeded();
    ledger(db, 'review_block_fp', 'project-3#1#fp', '1', IN1);                 // under trip
    ledger(db, 'review_block_fp', 'project-3#2#fp', 'abc', IN1);               // non-numeric
    ledger(db, 'review_block_fp', 'project-3#3#fp', '5', BEFORE);              // updated before the day
    ledger(db, 'review_block_fp', 'project-3#4#fp', '5', IN1, TO);             // updated at `to`
    ledger(db, 'child_plan_tripwire', 'project-5 TK-1', 'cleared', IN1);  // not fired
    ledger(db, 'child_plan_tripwire', 'project-5 TK-2', 'fired', TO);     // at `to`
    ledger(db, 'build-tripwire', 'project-3 TK-1', 'paused', BEFORE, IN1);     // created yesterday
    ledger(db, 'build-tripwire', 'project-3 TK-2', 'paused', TO);              // at `to`
    ledger(db, 'ticket_hold', 'project-3#5', 'released', IN1);
    ledger(db, 'merge', 'project-3 TK-3', 'merged', IN1);                      // other kind
    prEvent(db, 'example-org/project-3', 7, 'BLOCKED_HUMAN', BEFORE);
    prEvent(db, 'example-org/project-3', 7, 'READY', IN1);                    // latest is READY
    triage(db, 'project-3', 'TK-9', 'skip hold:other', IN1);
    model(db, 'openai', 'm-new', 'new', 'x', IN1);
    model(db, 'openai', 'm-adopted', 'adopted', 'x', IN1);
    model(db, 'openai', 'm-ignored', 'ignored', 'x', IN1);
    lrr(db, 'example-org/project-3', 1, SHA, 'done', 'MERGE-WITH-NOTES', IN1);
    lrr(db, 'example-org/project-3', 2, SHA, 'done', 'BLOCK', IN1);
    lrr(db, 'example-org/project-3', 3, SHA, 'running', 'MERGE', IN1);
    lrr(db, 'example-org/project-3', 4, SHA, 'done', 'MERGE', BEFORE);
    lrr(db, 'example-org/project-3', 5, SHA, 'done', 'MERGE', TO);
    flag(db, 'all-off', 0, 'operator', IN1);
    pause(db, 'project-3', 'builds', 'operator', LATER);
    pause(db, 'fleet', 'merges', 'operator', iso(ANCHOR - HOUR));
    pause(db, 'fleet', 'reviews', 'operator', LATER, IN1);
    const neg = await digest(DB, '&trip=2');
    for (const k of SECTION_KEYS.state) assert.deepEqual(neg[k], EMPTY_STATE[k], k);

    // The positive edge: a row exactly at `from` is in the day.
    ledger(db, 'build-tripwire', 'cromford BH-7', 'paused', FROM);
    lrr(db, 'example-org/cromford', 9, SHA, 'done', 'MERGE', FROM);
    const edge = await digest(DB, '&trip=2');
    assert.deepEqual(edge.tripwires.rows, [{ kind: 'build-tripwire', project: 'cromford', key: 'BH-7', at: FROM }]);
    assert.deepEqual(edge.spotcheck_candidates.rows.map((r) => r.pr), [9]);
  });

  await t.test('N2: n is counted before the cap and truncated is carried', async () => {
    const { db, DB } = await openSeeded();
    ledger(db, 'build-tripwire', 'cromford BH-1', 'paused', IN1);
    ledger(db, 'build-tripwire', 'cromford BH-2', 'paused', IN2);
    ledger(db, 'child_plan_tripwire', 'project-5 TK-3', 'fired', FROM);
    const d = await digest(DB, '&limit=1');
    assert.equal(d.tripwires.n, 3);
    assert.equal(d.tripwires.rows.length, 1);
    assert.equal(d.tripwires.truncated, true);
    assert.equal(d.tripwires.rows[0].key, 'TK-3', 'oldest first');
  });

  await t.test('F1: factory_stop value parsing', async () => {
    for (const [value, set] of [[' TRUE ', true], ['true', true], ['1', true], ['yes', false], ['0', false], ['false', false]]) {
      const { db, DB } = await openSeeded();
      setting(db, 'switch.factory-stop', value, 'operator', IN1);
      const d = await digest(DB);
      assert.deepEqual(d.factory.factory_stop, { set, value, actor: 'operator', updated_at: IN1 }, JSON.stringify(value));
    }
  });
});
