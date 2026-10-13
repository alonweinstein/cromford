// BH-5669 (BH-5008 child 3): merge-queue stage rows, bisect, the waiting line
// and the per-PR stages on GET /api/merge-queue/live.
// Every delivery goes through the REAL worker.fetch, signed, onto the REAL
// schema.sql in node:sqlite, from the contract fixture's builders. The
// assertions are on rows and on the route's JSON, not on SQL text.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import {
  REPO, SECRET, DRAFT, MEMBERS, deliveries, negatives, sendDelivery, prDelivery, checkDelivery, suiteDelivery,
  mergifyBody, FAILED_CHECK,
} from './fixtures/merge-queue-bh-5008.js';
import { queueStageStmt } from '../src/lib/merge-queue-stage.js';

const SETTING_AT = '2026-10-09T00:00:00Z';
const OTHER = 'Example-Org/other-repo';

function txBatch(db) {
  return async (stmts) => {
    db.exec('BEGIN');
    try {
      const out = [];
      for (const s of stmts) out.push(await s.run());
      db.exec('COMMIT');
      return out;
    } catch (e) {
      db.exec('ROLLBACK');
      throw e;
    }
  };
}

async function setup(t, { projects = [] } = {}) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  o.DB.batch = txBatch(o.db);
  o.db.prepare(`INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES (?,?,?,?,?)`)
    .run('merge_queue_repos', `${REPO},${OTHER}`, 'test', 'test', SETTING_AT);
  for (const [project, repo] of projects) {
    o.db.prepare(`INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES (?,?,0,?,?)`)
      .run(project, repo, SETTING_AT, SETTING_AT);
  }
  const env = { DB: o.DB, HARNESS_SECRET: 'bearer', GITHUB_WEBHOOK_SECRET: SECRET };
  const queueRows = (where = '') => o.db.prepare(
    `SELECT number, since, reason, actor FROM pr_state_events WHERE state='queue' ${where} ORDER BY id`
  ).all().map((r) => ({ ...r }));
  const allQueue = () => o.db.prepare(`SELECT * FROM pr_state_events WHERE state='queue' ORDER BY id`).all().map((r) => ({ ...r }));
  const batches = () => o.db.prepare(`SELECT * FROM merge_queue_batches ORDER BY draft_pr`).all().map((r) => ({ ...r }));
  const batch = (draft) => ({ ...o.db.prepare(
    `SELECT bisect_parent, bisect_step, bisect_steps FROM merge_queue_batches WHERE draft_pr=?`
  ).get(draft) });
  const send = (d, opts) => sendDelivery(worker, env, d, opts);
  const sendAll = async (list = deliveries, opts = {}) => {
    const out = [];
    for (const d of list) out.push(await send(d, opts.fresh ? { id: `${d.id}-again` } : {}));
    return out;
  };
  const get = async (path) => {
    const res = await worker.fetch(new Request(`https://jobs.test${path}`, { headers: { authorization: 'Bearer bearer' } }), env);
    return { status: res.status, body: await res.json().catch(() => null) };
  };
  return { ...o, env, queueRows, allQueue, batches, batch, send, sendAll, get };
}

const reasons = (rows) => rows.map((r) => `${r.number} ${r.reason}`);
const draftOpen = (id, number, members, o = {}) => prDelivery(id, {
  number, ref: `mergify/merge-queue/x-${number}`, sha: String(number).repeat(10).slice(0, 40), body: mergifyBody(members), ...o,
});
const draftCheck = (id, number, o = {}) => checkDelivery(id, {
  draft: number, ref: `mergify/merge-queue/x-${number}`, sha: String(number).repeat(10).slice(0, 40), ...o,
});
const failOn = (id, number, name = FAILED_CHECK) => draftCheck(id, number, {
  name, action: 'completed', status: 'completed', conclusion: 'failure',
});
// GitHub's check_suite.completed on a green suite. The contract builder pins
// conclusion 'failure', so this sets the field the real payload carries.
function greenSuite(id, o = {}) {
  const d = suiteDelivery(id, o);
  d.payload.check_suite.conclusion = 'success';
  return d;
}

// ── S1. batched on draft open ───────────────────────────────────────────────
test('S1 a draft open writes batched (#9001) for each member, since batched@9001, actor webhook', async (t) => {
  const c = await setup(t); if (!c) return;
  const r = await c.send(deliveries[0]);
  assert.equal(r.status, 200);
  assert.deepEqual(c.queueRows(), MEMBERS.map((n) => ({
    number: n, since: `batched@${DRAFT}`, reason: `batched (#${DRAFT})`, actor: 'webhook',
  })));
});

// ── S2. checking once per member ────────────────────────────────────────────
test('S2 the 14 check_run.created give exactly one checking (#9001) row per member', async (t) => {
  const c = await setup(t); if (!c) return;
  await c.sendAll(deliveries.slice(0, 15));
  const checking = c.queueRows(`AND reason LIKE 'checking%'`);
  assert.deepEqual(checking.map((r) => [r.number, r.reason, r.since]),
    MEMBERS.map((n) => [n, `checking (#${DRAFT})`, `checking@${DRAFT}`]));
  assert.equal(c.queueRows().length, 6, '3 batched + 3 checking, not 42');
});

test('S2 a check before the draft row exists writes no stage row; the next check does', async (t) => {
  const c = await setup(t); if (!c) return;
  await c.send(checkDelivery('early-1', { name: 'lint' }));
  assert.equal(c.queueRows().length, 0);
  await c.send(deliveries[0]);
  await c.send(checkDelivery('early-2', { name: 'shellcheck' }));
  assert.deepEqual(reasons(c.queueRows(`AND reason LIKE 'checking%'`)), MEMBERS.map((n) => `${n} checking (#${DRAFT})`));
});

// ── S3. replay under NEW ids ────────────────────────────────────────────────
test('S3 every fixture delivery replayed under NEW ids leaves the queue rows and batches identical', async (t) => {
  const c = await setup(t); if (!c) return;
  await c.sendAll();
  const rows = c.allQueue();
  const b = c.batches();
  assert.ok(rows.length > 0);
  // GitHub redelivers later: the worker's clock reads one hour on, so a row
  // keyed on the receive time would be a new row.
  const RealDate = globalThis.Date;
  globalThis.Date = class extends RealDate {
    constructor(...a) { if (a.length) super(...a); else super(RealDate.now() + 3600 * 1000); } // determinism: ok shifts the worker clock for the replay
    static now() { return RealDate.now() + 3600 * 1000; } // determinism: ok shifts the worker clock for the replay
  };
  let again;
  try { again = await c.sendAll(deliveries, { fresh: true }); } finally { globalThis.Date = RealDate; }
  assert.ok(again.every((r) => r.status === 200), 'every replay is accepted');
  assert.equal(c.db.prepare(`SELECT COUNT(*) AS n FROM webhook_deliveries WHERE delivery_id LIKE '%-again'`).get().n, deliveries.length,
    'the replays are new delivery ids');
  assert.deepEqual(c.allQueue(), rows);
  assert.deepEqual(c.batches(), b);
});

// ── S4. merging and merged ──────────────────────────────────────────────────
test('S4 a green check_suite gives merging (#9001); a merged close gives merged (#9001), per member', async (t) => {
  const c = await setup(t); if (!c) return;
  await c.send(deliveries[0]);
  await c.send(greenSuite('s4-1'));
  assert.deepEqual(reasons(c.queueRows(`AND reason LIKE 'merging%'`)), MEMBERS.map((n) => `${n} merging (#${DRAFT})`));
  await c.send(prDelivery('s4-2', { action: 'closed', merged: true, closed_at: '2026-10-09T03:30:00Z' }));
  const merged = c.queueRows(`AND reason LIKE 'merged%'`);
  assert.deepEqual(merged.map((r) => [r.number, r.reason, r.since]), MEMBERS.map((n) => [n, `merged (#${DRAFT})`, `merged@${DRAFT}`]));
});

// ── S5. negatives ───────────────────────────────────────────────────────────
test('S5 a close with merged:false, a failed suite and a non-success suite write no merged/merging row', async (t) => {
  const c = await setup(t); if (!c) return;
  await c.send(deliveries[0]);
  await c.send(suiteDelivery('s5-1'));
  await c.send(prDelivery('s5-2', { action: 'closed', merged: false, closed_at: '2026-10-09T03:30:00Z' }));
  await c.send(prDelivery('s5-3', { action: 'closed', number: 9003, ref: 'mergify/merge-queue/x-9003', merged: 'true' }));
  assert.deepEqual(c.queueRows(`AND (reason LIKE 'merged%' OR reason LIKE 'merging%')`), []);
});

for (const neg of negatives) {
  test(`S5 negative: ${neg.name} writes 0 queue stage rows`, async (t) => {
    const c = await setup(t); if (!c) return;
    await c.send(neg);
    assert.deepEqual(c.allQueue(), []);
  });
}

test('S5 the full fixture plus a merge writes no queued and no deploy_verified row', async (t) => {
  const c = await setup(t); if (!c) return;
  await c.sendAll();
  await c.send(greenSuite('s5-4'));
  await c.send(prDelivery('s5-5', { action: 'closed', merged: true }));
  const words = new Set(c.allQueue().map((r) => r.reason.split(' ')[0]));
  // 9001 has a failed check (Jobs worker), so its green suite is not a merging fact.
  assert.deepEqual([...words].sort(), ['batched', 'checking', 'merged']);
});

// ── S4. one green suite is not a green batch ─────────────────────────────────
test('S4 a green suite after a failed check writes 0 merging rows; the route keeps the PRs off merging', async (t) => {
  const c = await setup(t); if (!c) return;
  await c.send(deliveries[0]);
  await c.send(failOn('s4b-1', DRAFT));
  await c.send(greenSuite('s4b-2'));
  assert.deepEqual(c.queueRows(`AND reason LIKE 'merging%'`), []);
  const r = await c.get('/api/merge-queue/live');
  assert.equal(r.status, 200);
  for (const n of MEMBERS) assert.equal(r.body.prs[`${REPO}#${n}`].stage, 'checking', `#${n} is not at merging`);
});

test('S4 a green suite while a check still runs writes 0 merging rows', async (t) => {
  const c = await setup(t); if (!c) return;
  await c.send(deliveries[0]);
  await c.send(draftCheck('s4b-3', DRAFT, { name: 'still running', action: 'created', status: 'in_progress' }));
  await c.send(greenSuite('s4b-4'));
  assert.deepEqual(c.queueRows(`AND reason LIKE 'merging%'`), []);
});

test('S4 a green suite after every stored check completed green writes merging (#9001)', async (t) => {
  const c = await setup(t); if (!c) return;
  await c.send(deliveries[0]);
  await c.send(draftCheck('s4b-5', DRAFT, { name: 'lint', action: 'completed', status: 'completed', conclusion: 'success' }));
  await c.send(draftCheck('s4b-6', DRAFT, { name: 'shellcheck', action: 'completed', status: 'completed', conclusion: 'success' }));
  await c.send(greenSuite('s4b-7'));
  assert.deepEqual(reasons(c.queueRows(`AND reason LIKE 'merging%'`)), MEMBERS.map((n) => `${n} merging (#${DRAFT})`));
});

// ── S9. a late first delivery after the close ───────────────────────────────
test('S9 a first check_run or green suite after the merged close writes no row; the PR stays merged', async (t) => {
  const c = await setup(t); if (!c) return;
  await c.send(deliveries[0]);
  await c.send(prDelivery('s4c-1', { action: 'closed', merged: true, closed_at: '2026-10-09T03:30:00Z' }));
  const before = c.allQueue();
  await c.send(draftCheck('s4c-2', DRAFT, { name: 'lint', action: 'completed', status: 'completed', conclusion: 'success' }));
  await c.send(greenSuite('s4c-3'));
  assert.deepEqual(c.allQueue(), before);
  const r = await c.get('/api/merge-queue/live');
  assert.equal(r.status, 200);
  for (const n of MEMBERS) assert.equal(r.body.prs[`${REPO}#${n}`].stage, 'merged', `#${n} stays merged`);
});

// ── S6. bisect ──────────────────────────────────────────────────────────────
test('S6 the full fixture: 9002 is the bisect child of 9001, step 1 of 2; 9001 has none', async (t) => {
  const c = await setup(t); if (!c) return;
  await c.sendAll();
  assert.deepEqual(c.batch(9002), { bisect_parent: 9001, bisect_step: 1, bisect_steps: 2 });
  assert.deepEqual(c.batch(9001), { bisect_parent: null, bisect_step: null, bisect_steps: null });
  assert.deepEqual(reasons(c.queueRows(`AND since='batched@9002'`)), ['101 batched (#9002)', '102 batched (#9002)']);
});

// ── S7. not a bisect ────────────────────────────────────────────────────────
test('S7 an overlapping non-subset draft, an equal member set and a subset of a MERGED batch are not bisect', async (t) => {
  const c = await setup(t); if (!c) return;
  await c.sendAll(deliveries.slice(0, -1)); // 9001 with its failing check, no 9002
  await c.send(draftOpen('s7-1', 9010, [102, 104]));
  await c.send(draftOpen('s7-2', 9011, [101, 102, 103]));
  assert.deepEqual(c.batch(9010), { bisect_parent: null, bisect_step: null, bisect_steps: null });
  assert.deepEqual(c.batch(9011), { bisect_parent: null, bisect_step: null, bisect_steps: null });

  const m = await setup(t); if (!m) return;
  await m.send(deliveries[0]);
  await m.send(prDelivery('s7-3', { action: 'closed', merged: true, closed_at: '2026-10-09T03:30:00Z' }));
  await m.send(draftOpen('s7-4', 9012, [101]));
  assert.deepEqual(m.batch(9012), { bisect_parent: null, bisect_step: null, bisect_steps: null });

  // A green open batch is no parent either: nothing failed.
  const g = await setup(t); if (!g) return;
  await g.send(deliveries[0]);
  await g.send(draftOpen('s7-5', 9013, [101]));
  assert.deepEqual(g.batch(9013), { bisect_parent: null, bisect_step: null, bisect_steps: null });
});

// ── S8. bisect of a bisect, and the dequeue ─────────────────────────────────
test('S8 a 1-member draft under failed 9002 is step 2 of 2; its failure dequeues #101 alone', async (t) => {
  const c = await setup(t); if (!c) return;
  await c.sendAll();
  await c.send(failOn('s8-1', 9002)); // 9002 (2 members) fails: no dequeue
  assert.deepEqual(c.queueRows(`AND reason LIKE 'dequeued%'`), []);
  await c.send(draftOpen('s8-2', 9003, [101], { created_at: '2026-10-09T03:40:00Z' }));
  assert.deepEqual(c.batch(9003), { bisect_parent: 9002, bisect_step: 2, bisect_steps: 2 });
  await c.send(failOn('s8-3', 9003, 'tests (3)'));
  const deq = c.queueRows(`AND reason LIKE 'dequeued%'`);
  assert.deepEqual(deq.map((r) => [r.number, r.reason, r.since]), [[101, 'dequeued (tests [3] failed on #101 alone)', 'dequeued@9003']]);
  // The dequeue is the newest queue row for #101.
  const newest = c.db.prepare(`SELECT reason FROM pr_state_events WHERE state='queue' AND number=101 ORDER BY id DESC LIMIT 1`).get();
  assert.equal(newest.reason, 'dequeued (tests [3] failed on #101 alone)');
});

test('S8 a failed 1-member draft with no bisect parent is not a dequeue', async (t) => {
  const c = await setup(t); if (!c) return;
  await c.send(draftOpen('s8-4', 9020, [101]));
  await c.send(failOn('s8-5', 9020));
  assert.deepEqual(c.queueRows(`AND reason LIKE 'dequeued%'`), []);
});

// ── R. the live route ───────────────────────────────────────────────────────
test('R1 observable outcome: the route sets stage, failing, bisect and prs from the rows', async (t) => {
  const c = await setup(t); if (!c) return;
  await c.sendAll();
  c.db.prepare(`INSERT INTO pr_owners (repo, number, project, state, since, key, updated_at) VALUES (?,?,?,?,?,?,?)`)
    .run(REPO, 103, 'example', 'open', SETTING_AT, 'BH-103', SETTING_AT);
  const r = await c.get('/api/merge-queue/live');
  assert.equal(r.status, 200);
  const b1 = r.body.batches.find((b) => b.draft === DRAFT);
  assert.equal(b1.stage, 'failing');
  assert.deepEqual(b1.checks, { done: 10, total: 14 });
  assert.deepEqual(b1.failing, { name: 'Jobs worker', url: `https://github.com/${REPO}/actions/runs/7001/job/${8000 + DRAFT}` });
  assert.equal(b1.bisect, null);
  const b2 = r.body.batches.find((b) => b.draft === 9002);
  assert.deepEqual(b2.bisect, { step: 1, steps: 2, parent: 9001 });
  assert.equal(b2.stage, 'batched');
  assert.equal(b2.failing, null);
  const p103 = r.body.prs[`${REPO}#103`];
  assert.equal(p103.stage, 'checking');
  assert.equal(p103.batch, 9001);
  assert.equal(p103.detail, '#9001');
  assert.equal(p103.key, 'BH-103');
  assert.equal(p103.project, 'example');
  assert.equal(typeof p103.at, 'string');
  assert.deepEqual([r.body.prs[`${REPO}#101`].stage, r.body.prs[`${REPO}#101`].batch], ['batched', 9002]);
  assert.equal(r.body.prs[`${REPO}#101`].key, null);
  assert.deepEqual(r.body.waiting, []);
  assert.equal(r.body.complete, true);
});

test('R1 a closed batch reads merged / failed from its outcome', async (t) => {
  const c = await setup(t); if (!c) return;
  await c.sendAll();
  await c.send(prDelivery('r1-1', { action: 'closed', closed_at: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z') })); // determinism: ok inside the route's 900 s window
  await c.send(draftOpen('r1-2', 9030, [201]));
  await c.send(prDelivery('r1-3', { action: 'closed', number: 9030, ref: 'mergify/merge-queue/x-9030', merged: true }));
  const r = await c.get('/api/merge-queue/live');
  const by = Object.fromEntries(r.body.batches.map((b) => [b.draft, b.stage]));
  assert.equal(by[9001], 'failed');
  assert.equal(by[9030], 'merged');
});

test('R2 ?project= filters prs and waiting to that repo', async (t) => {
  const c = await setup(t, { projects: [['example', REPO], ['other', OTHER]] }); if (!c) return;
  await c.sendAll();
  await c.DB.batch([queueStageStmt(c.DB, { repo: REPO, pr: 301, stage: 'queued (1)', since: 'queued@1', at: new Date().toISOString() })]); // determinism: ok inside the 24 h window
  const other = await c.get('/api/merge-queue/live?project=other');
  assert.deepEqual(other.body.prs, {});
  assert.deepEqual(other.body.waiting, []);
  const mine = await c.get('/api/merge-queue/live?project=example');
  assert.deepEqual(Object.keys(mine.body.prs).sort(), [101, 102, 103, 301].map((n) => `${REPO}#${n}`));
  assert.deepEqual(mine.body.waiting.map((w) => w.pr), [301]);
});

test('R3 waiting is the queued PRs in position order, not insert order', async (t) => {
  const c = await setup(t); if (!c) return;
  const at = new Date().toISOString(); // determinism: ok inside the 24 h window
  const rows = [[201, 3], [202, 1], [203, 2], [204, 10], [205, 9]];
  await c.DB.batch(rows.map(([pr, n]) => queueStageStmt(c.DB, { repo: REPO, pr, stage: `queued (${n})`, since: `queued@${n}`, at, actor: 'test' })));
  const r = await c.get('/api/merge-queue/live');
  assert.deepEqual(r.body.waiting.map((w) => [w.pr, w.position]), [[202, 1], [203, 2], [201, 3], [205, 9], [204, 10]]);
  assert.deepEqual(Object.keys(r.body.waiting[0]).sort(), ['at', 'key', 'position', 'pr', 'repo']);
  assert.equal(r.body.waiting[0].repo, REPO);
  assert.equal(r.body.prs[`${REPO}#202`].stage, 'queued');
});

test('R4 more than 500 PRs with a queue row is complete:false', async (t) => {
  const c = await setup(t); if (!c) return;
  const at = new Date().toISOString(); // determinism: ok inside the 24 h window
  await c.DB.batch(Array.from({ length: 501 }, (_, i) => queueStageStmt(c.DB, {
    repo: REPO, pr: 1000 + i, stage: 'batched (#9001)', since: 'batched@9001', at,
  })));
  const r = await c.get('/api/merge-queue/live');
  assert.equal(Object.keys(r.body.prs).length, 500);
  assert.equal(r.body.complete, false);
});

test('R5 a PR whose newest queue row is older than 24 h is absent from prs', async (t) => {
  const c = await setup(t); if (!c) return;
  const now = Date.now(); // determinism: ok the window is relative to the route's own clock
  const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
  await c.DB.batch([
    queueStageStmt(c.DB, { repo: REPO, pr: 401, stage: 'merged (#8001)', since: 'merged@8001', at: iso(now - 25 * 3600 * 1000) }),
    queueStageStmt(c.DB, { repo: REPO, pr: 402, stage: 'merged (#8002)', since: 'merged@8002', at: iso(now - 23 * 3600 * 1000) }),
  ]);
  const r = await c.get('/api/merge-queue/live');
  assert.deepEqual(Object.keys(r.body.prs), [`${REPO}#402`]);
});
