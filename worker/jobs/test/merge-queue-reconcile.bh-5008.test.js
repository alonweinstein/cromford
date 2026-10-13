// BH-5670 (BH-5008 child 4): GET/POST /api/merge-queue/reconcile, the
// reconciler against Mergify's merge-queue/status answer. Every call goes
// through the REAL worker.fetch onto the REAL schema.sql in node:sqlite, so the
// assertions are on rows. env.DB.batch is wrapped in BEGIN/COMMIT/ROLLBACK
// here, because D1's batch is one transaction and the shim's is not.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { MERGIFY_BATCH_CODES } from '../src/routes/merge-queue-reconcile.js';

const REPO = 'Example-Org/example-repo';
const OTHER = 'Example-Org/other-repo';
const SETTING_AT = '2026-10-09T00:00:00Z';
const isoS = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const NOW = Date.now(); // determinism: ok the 24 h window is relative to the route's own clock
const ago = (h) => isoS(NOW - h * 3600 * 1000);

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

async function setup(t, { settings = {} } = {}) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  o.DB.batch = txBatch(o.db);
  for (const [k, v] of Object.entries(settings)) {
    o.db.prepare(`INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES (?,?,?,?,?)`)
      .run(k, v, 'test', 'test', SETTING_AT);
  }
  const env = { DB: o.DB, HARNESS_SECRET: 'bearer-fixture' };
  const row = (repo, pr, reason, at = ago(1), since = `checks@${pr}`, actor = 'webhook') => o.db.prepare(
    `INSERT INTO pr_state_events (repo, number, state, since, reason, alerted, at, actor) VALUES (?,?,'queue',?,?,'-',?,?)`
  ).run(repo, pr, since, reason, at, actor);
  const batch = (repo, draft, members, { started = ago(1), finished = null } = {}) => o.db.prepare(
    `INSERT INTO merge_queue_batches (repo, draft_pr, members_json, started_at, finished_at, updated_at) VALUES (?,?,?,?,?,?)`
  ).run(repo, draft, JSON.stringify(members), started, finished, started);
  const queue = (where = '') => o.db.prepare(
    `SELECT id, repo, number, since, reason, actor FROM pr_state_events WHERE state='queue' ${where} ORDER BY id`
  ).all().map((r) => ({ ...r }));
  const call = async (method, body, { auth = true } = {}) => {
    const headers = { 'content-type': 'application/json' };
    if (auth) headers.authorization = 'Bearer bearer-fixture';
    const init = { method, headers };
    if (body !== undefined) init.body = typeof body === 'string' ? body : JSON.stringify(body);
    const res = await worker.fetch(new Request('https://jobs.test/api/merge-queue/reconcile', init), env);
    return { status: res.status, body: await res.json().catch(() => null) };
  };
  return { ...o, env, row, batch, queue, call };
}

const status = ({ batches = [], waiting = [] } = {}) => ({
  batches: batches.map(([code, prs, eta]) => ({
    status: { code }, pull_requests: prs.map((n) => ({ number: n })),
    ...(eta === undefined ? {} : { estimated_time_of_merge: eta }),
  })),
  waiting_pull_requests: waiting.map((n) => ({ number: n })),
});

// ── 1. GET lists active repos ───────────────────────────────────────────────
test('1 GET lists the active PR and the open batch; terminal and stale rows are not active', async (t) => {
  const c = await setup(t); if (!c) return;
  c.row(REPO, 101, 'checking (4441)');
  c.batch(REPO, 9001, [101, 102]);
  c.row(REPO, 102, 'checking');
  c.row(REPO, 102, 'merged', ago(0.5), 'merged@9001'); // newest is terminal
  c.row(REPO, 103, 'deploy_verified');
  c.row(REPO, 104, 'dequeued (ci failed)');
  c.row(OTHER, 201, 'checking', ago(30)); // older than 24 h
  const r = await c.call('GET');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.repos.map((x) => x.repo), [REPO]);
  const prs = r.body.repos[0].prs;
  assert.deepEqual(prs.map((p) => [p.pr, p.stage, p.reason]), [[101, 'checking', 'checking (4441)']]);
  assert.equal(r.body.complete, true);

  // an open batch alone makes a repo active
  c.batch(OTHER, 9002, [201]);
  const r2 = await c.call('GET');
  assert.deepEqual(r2.body.repos.map((x) => x.repo), [REPO, OTHER].sort());
  // a finished batch does not
  c.db.prepare(`UPDATE merge_queue_batches SET finished_at=? WHERE draft_pr=9002`).run(ago(0.5));
  const r3 = await c.call('GET');
  assert.deepEqual(r3.body.repos.map((x) => x.repo), [REPO]);
});

// ── 2. GET empty and the cap ────────────────────────────────────────────────
test('2 GET with no rows answers repos:[] and the cap default 10; a settings row sets it', async (t) => {
  const c = await setup(t); if (!c) return;
  const r = await c.call('GET');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.repos, []);
  assert.equal(r.body.cap, 10);
  assert.equal(r.body.cap_source, 'default');
  const s = await setup(t, { settings: { merge_queue_reconcile_repos: '3' } }); if (!s) return;
  const r2 = await s.call('GET');
  assert.equal(r2.body.cap, 3);
  assert.equal(r2.body.cap_source, 'setting');
  const bad = await setup(t, { settings: { merge_queue_reconcile_repos: '0' } }); if (!bad) return;
  assert.equal((await bad.call('GET')).body.cap_source, 'default');
});

// ── 3. corrective row, once ─────────────────────────────────────────────────
test('3 POST: Mergify merged for a checking PR writes one corrective row; a repeat writes none', async (t) => {
  const c = await setup(t); if (!c) return;
  c.row(REPO, 101, 'checking');
  const body = { answers: [{ repo: REPO, status: status({ batches: [['merged', [101]]] }) }] };
  const r = await c.call('POST', body);
  assert.equal(r.status, 200);
  assert.equal(r.body.written, 1);
  const rows = c.queue('AND number=101');
  assert.equal(rows.length, 2);
  assert.equal(rows[1].reason, 'merged (reconcile: was checking)');
  assert.equal(rows[1].actor, 'reconcile');
  assert.equal(rows[1].since, `reconcile:${rows[0].id}`);
  // the PR is no longer active, so the repeat is skipped_inactive and writes 0
  const again = await c.call('POST', body);
  assert.equal(again.status, 200);
  assert.equal(again.body.written, 0);
  assert.equal(c.queue().length, 2);
});

test('3b POST: a non-terminal correction is written once; a repeat with the PR still active writes none', async (t) => {
  const c = await setup(t); if (!c) return;
  c.row(REPO, 101, 'batched');
  const body = { answers: [{ repo: REPO, status: status({ batches: [['running', [101]]] }) }] };
  const r = await c.call('POST', body);
  assert.equal(r.body.written, 1);
  assert.equal(c.queue().at(-1).reason, 'checking (reconcile: was batched)');
  const again = await c.call('POST', body);
  assert.equal(again.status, 200);
  assert.equal(again.body.written, 0);
  assert.equal(again.body.unchanged, 1);
  assert.equal(c.queue().length, 2);
  // a webhook row that already agrees with Mergify's stage gets no row
  const w = await setup(t); if (!w) return;
  w.row(REPO, 101, 'checking (4441)');
  const r2 = await w.call('POST', body);
  assert.equal(r2.body.written, 0);
  assert.equal(w.queue().length, 1);
});

// ── 4. eta_at ───────────────────────────────────────────────────────────────
test('4 POST sets eta_at on the open batch whose members match; a repeat leaves updated_at', async (t) => {
  const c = await setup(t); if (!c) return;
  c.row(REPO, 101, 'checking');
  c.row(REPO, 102, 'checking');
  c.batch(REPO, 9001, [102, 101]);
  c.batch(REPO, 9003, [101]);
  const eta = '2026-10-10T16:00:00.000Z';
  const body = { answers: [{ repo: REPO, status: status({ batches: [['running', [101, 102], eta]] }) }] };
  const r = await c.call('POST', body);
  assert.equal(r.status, 200);
  assert.equal(r.body.eta_set, 1);
  const b = () => ({ ...c.db.prepare(`SELECT eta_at, updated_at FROM merge_queue_batches WHERE draft_pr=9001`).get() });
  const first = b();
  assert.equal(first.eta_at, '2026-10-10T16:00:00Z');
  assert.equal(c.db.prepare(`SELECT eta_at FROM merge_queue_batches WHERE draft_pr=9003`).get().eta_at, null);
  const again = await c.call('POST', body);
  assert.equal(again.body.eta_set, 0);
  assert.deepEqual(b(), first);
  // no matching open batch = no write, counted
  const nb = await c.call('POST', { answers: [{ repo: REPO, status: status({ batches: [['running', [101, 102, 105], eta]] }) }] });
  assert.equal(nb.body.eta_set, 0);
  assert.equal(nb.body.eta_unmatched, 1);
  // an unparseable eta is no write
  const bad = await c.call('POST', { answers: [{ repo: REPO, status: status({ batches: [['running', [101, 102], 'soon']] }) }] });
  assert.equal(bad.body.eta_set, 0);
  assert.equal(b().eta_at, '2026-10-10T16:00:00Z');
});

// ── 5. position refresh ─────────────────────────────────────────────────────
test('5 POST refreshes a waiting position: queued (3) with Mergify index 1 writes queued (2)', async (t) => {
  const c = await setup(t); if (!c) return;
  c.row(REPO, 101, 'queued (3)');
  c.row(REPO, 107, 'queued (1)');
  const body = { answers: [{ repo: REPO, status: status({ waiting: [107, 101] }) }] };
  const r = await c.call('POST', body);
  assert.equal(r.body.written, 1);
  const last = c.queue('AND number=101').at(-1);
  assert.equal(last.reason, 'queued (2)');
  assert.equal(last.actor, 'reconcile');
  assert.equal((await c.call('POST', body)).body.written, 0);
  // a requeue: newest dequeued, Mergify lists it waiting → queued (n)
  c.row(REPO, 108, 'dequeued (ci failed)');
  const rq = await c.call('POST', { answers: [{ repo: REPO, status: status({ waiting: [107, 101, 108] }) }] });
  assert.equal(rq.body.written, 1);
  assert.equal(c.queue('AND number=108').at(-1).reason, 'queued (3)');
  // the batch entry wins over a waiting entry for the same PR
  const dup = await c.call('POST', { answers: [{ repo: REPO, status: status({ waiting: [107], batches: [['running', [107]]] }) }] });
  assert.equal(dup.body.written, 1);
  assert.equal(c.queue('AND number=107').at(-1).reason, 'checking (reconcile: was queued)');
});

// ── 6. negatives ────────────────────────────────────────────────────────────
test('6 negatives: absent, failed, unknown code, newest merged, inactive repo, bad numbers give 0 rows', async (t) => {
  const c = await setup(t); if (!c) return;
  c.row(REPO, 101, 'checking');
  c.row(REPO, 102, 'merged');
  const n0 = c.queue().length;
  const post = async (st, repo = REPO) => c.call('POST', { answers: [{ repo, status: st }] });

  const absent = await post(status({}));
  assert.equal(absent.status, 200);
  assert.equal(absent.body.written, 0);
  assert.equal(absent.body.absent, 1);

  const failed = await post(status({ batches: [['failed', [101]]] }));
  assert.equal(failed.body.written, 0);
  assert.deepEqual(failed.body.unknown_codes, ['failed']);

  const unknown = await post(status({ batches: [['exploded', [101]]] }));
  assert.equal(unknown.body.written, 0);
  assert.deepEqual(unknown.body.unknown_codes, ['exploded']);

  const merged = await post(status({ waiting: [102] }));
  assert.equal(merged.body.written, 0);

  const inactive = await post(status({ batches: [['merged', [301]]] }), OTHER);
  assert.equal(inactive.body.written, 0);
  assert.equal(inactive.body.skipped_inactive, 1);

  const badNums = await post({
    batches: [{ status: { code: 'merged' }, pull_requests: [{ number: 0 }, { number: -3 }, { number: '101' }, null] }],
    waiting_pull_requests: [{ number: 1.5 }, {}],
  });
  assert.equal(badNums.status, 200);
  assert.equal(badNums.body.written, 0);

  const notObject = await post('merged');
  assert.equal(notObject.status, 200);
  assert.equal(notObject.body.written, 0);

  assert.equal(c.queue().length, n0);
  assert.equal(c.queue().filter((r) => r.reason.startsWith('merged') && r.actor === 'reconcile').length, 0);
});

test('6b only the documented codes map, and no unknown code maps to merged', async () => {
  assert.ok(Object.isFrozen(MERGIFY_BATCH_CODES));
  assert.equal(MERGIFY_BATCH_CODES.merged, 'merged');
  assert.equal(Object.entries(MERGIFY_BATCH_CODES).filter(([, v]) => v === 'merged').length, 1);
  assert.equal(Object.hasOwn(MERGIFY_BATCH_CODES, 'failed'), false);
});

test('6c repo slug case: a lower-case answer matches the DB repo and writes with the DB slug', async (t) => {
  const c = await setup(t); if (!c) return;
  c.row(REPO, 101, 'batched');
  const r = await c.call('POST', { answers: [{ repo: REPO.toLowerCase(), status: status({ batches: [['running', [101]]] }) }] });
  assert.equal(r.body.written, 1);
  assert.equal(c.queue().at(-1).repo, REPO);
});

// ── 7. bad bodies and auth ──────────────────────────────────────────────────
test('7 a bad body is 400 with no row; no bearer is 401', async (t) => {
  const c = await setup(t); if (!c) return;
  c.row(REPO, 101, 'checking');
  const n0 = c.queue().length;
  const one = { repo: REPO, status: status({ batches: [['merged', [101]]] }) };
  for (const body of [
    { answers: 'x' },
    {},
    { answers: Array.from({ length: 51 }, () => one) },
    { answers: [{ repo: 'not a slug', status: {} }] },
    { answers: [one, { repo: REPO, status: { batches: 'x' } }] },
    { answers: [{ repo: REPO, status: { waiting_pull_requests: Array.from({ length: 501 }, (_, i) => ({ number: i + 1 })) } }] },
  ]) {
    const r = await c.call('POST', body);
    assert.equal(r.status, 400, JSON.stringify(body).slice(0, 80));
  }
  assert.equal(c.queue().length, n0);
  assert.equal((await c.call('GET', undefined, { auth: false })).status, 401);
  assert.equal((await c.call('POST', { answers: [one] }, { auth: false })).status, 401);
  assert.equal(c.queue().length, n0);
});
