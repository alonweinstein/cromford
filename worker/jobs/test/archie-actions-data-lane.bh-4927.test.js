// BH-4927 (BH-4920.4): the data-lane playbook's rows in Archie's action ledger,
// driven through the REAL worker.fetch against the REAL schema.sql (the
// node:sqlite D1 shim), as archie-actions.bh-4583.test.js does. Pinned: a
// `data-lane` claim is accepted, `skipped` is a terminal outcome reachable only
// from `started`, junk actions still 400, and summary=1 carries a data_lane
// block that the restack counters never absorb.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const call = (DB, path, { method = 'GET', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const create = (DB, body) => call(DB, '/api/archie/actions', { method: 'POST', body });
const outcome = (DB, body) => call(DB, '/api/archie/actions/outcome', { method: 'POST', body });
const get = (DB, qs) => call(DB, `/api/archie/actions?${qs}`);
const move = (DB, row, body) => outcome(DB, { id: row.id, dedupe_key: row.dedupe_key, expect_updated_at: row.updated_at, ...body });

const DL = {
  dedupe_key: 'data-lane:project-3:42:0123456789ab',
  project: 'project-3',
  repo: 'example-org/project-3',
  pr: 42,
  playbook: 'data-lane',
  mode: 'on',
  action: 'apply',
  outcome: 'started',
  why: 'apply scripts/migrations/0042_x.sql ahead of merge',
  evidence: { build_dir: '/root/harness/builds/project-3-TK-1-x', file: 'scripts/migrations/0042_x.sql' },
  actor: 'archie-fm',
};

test('BH-4927 data-lane rows in the archie action ledger', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('DLW1 a data-lane claim is 201; observe would_apply is 201', async () => {
    const { DB } = await openDb();
    const c = await create(DB, DL);
    assert.equal(c.status, 201, JSON.stringify(c.body));
    assert.equal(c.body.action.playbook, 'data-lane');
    assert.equal(c.body.action.action, 'apply');
    const o = await create(DB, { ...DL, dedupe_key: `${DL.dedupe_key}:observe`, mode: 'observe', action: 'would_apply' });
    assert.equal(o.status, 201, JSON.stringify(o.body));
  });

  await t.test('DLW2 started -> skipped is 200 and skipped is terminal (409)', async () => {
    const { DB } = await openDb();
    const a = (await create(DB, DL)).body.action;
    const s = await move(DB, a, { outcome: 'skipped', action: 'no_path', why: 'no apply path' });
    assert.equal(s.status, 200, JSON.stringify(s.body));
    assert.equal(s.body.action.outcome, 'skipped');
    assert.equal(s.body.action.action, 'no_path');
    const back = await move(DB, s.body.action, { outcome: 'started' });
    assert.equal(back.status, 409);
    assert.equal(back.body.error, 'illegal transition skipped -> started');
    const b = (await create(DB, { ...DL, dedupe_key: 'data-lane:project-3:42:bbbbbbbbbbbb' })).body.action;
    const d = await move(DB, b, { outcome: 'deferred' });
    assert.equal(d.status, 200);
    assert.equal((await move(DB, d.body.action, { outcome: 'skipped' })).status, 409, 'deferred -> skipped is not a move');
  });

  await t.test('DLW3 an unknown action or playbook is still a 400 naming it', async () => {
    const { DB } = await openDb();
    assert.deepEqual((await create(DB, { ...DL, action: 'merge' })).body, { error: 'action' });
    assert.deepEqual((await create(DB, { ...DL, playbook: 'data-lanes' })).body, { error: 'playbook' });
    assert.deepEqual((await create(DB, { ...DL, outcome: 'skip' })).body, { error: 'outcome' });
    assert.equal((await get(DB, 'day=2026-10-06&playbook=data-lane')).status, 200, 'the cap read filters on the new playbook');
  });

  await t.test('DLW4 summary=1 carries data_lane, and data-lane done rows never count as restacked', async () => {
    const { DB, db } = await openDb();
    const ins = db.prepare(`INSERT INTO archie_actions (dedupe_key, day, project, repo, pr, playbook, mode, action,
      outcome, why, evidence, attempts, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,'w','{}',1,'archie-fm',?,?)`);
    const D = '2026-10-06';
    const seed = [
      // key, playbook, mode, action, outcome
      ['d1', 'data-lane', 'on', 'apply', 'done'],
      ['d2', 'data-lane', 'on', 'apply', 'failed'],
      ['d3', 'data-lane', 'on', 'no_path', 'skipped'],
      ['d4', 'data-lane', 'on', 'not_candidate', 'skipped'],
      ['d5', 'data-lane', 'observe', 'would_apply', 'would'],
      ['d6', 'data-lane', 'on', 'apply', 'deferred'],
      ['r1', 'stacked-parent-merged', 'on', 'restack', 'done'],
    ];
    let i = 0;
    for (const [k, pb, m, a, o] of seed) {
      const ts = `${D}T0${i++}:00:00Z`;
      ins.run(k, D, 'project-3', 'example-org/project-3', 1, pb, m, a, o, ts, ts);
    }
    const s = await get(DB, `day=${D}&summary=1`);
    assert.equal(s.status, 200);
    assert.deepEqual(s.body.data_lane, { total: 6, applied: 1, escalated: 2, would: 1 });
    assert.equal(s.body.restacked, 1, 'only the restack row is restacked');
    assert.equal(s.body.total, 7);
    const empty = await get(DB, 'day=2020-01-01&summary=1');
    assert.deepEqual(empty.body.data_lane, { total: 0, applied: 0, escalated: 0, would: 0 });
    const counts = (await get(DB, `day=${D}&playbook=data-lane`)).body.counts;
    assert.deepEqual(counts, { 'data-lane': { on: { done: 1, failed: 1, skipped: 2, deferred: 1 }, observe: { would: 1 } } });
  });
});
