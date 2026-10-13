// BH-2618 (BH-2513.1): the four console-control PUT routes write their
// config_changes audit row (BH-2513's contract, src/lib/config-changes.js).
//
// WHAT IS PINNED, on a REAL schema.sql database behind the node:sqlite shim and
// through the real worker.fetch (bearer, router and handler all under test):
//   R1  each PUT writes exactly one row with its kind, name, before/after and
//       actor/reason; the same body again writes none; a changed value writes
//       a second row whose before_json is the first row's after_json;
//   R2  a 400 writes no audit row;
//   K1  a note-less re-PUT keeps the stored note, so it is not a change;
//   NR  no actor and no reason is a 200 recorded as actor 'api', reason NULL;
//   and PUT /api/review-gate stays unaudited, and a DELETE of an absent rule writes none.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';

const call = (DB, path, { method = 'PUT', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};

const rows = (db, kind) => db.prepare('SELECT * FROM config_changes WHERE kind=? ORDER BY id').all(kind);
const total = (db) => db.prepare('SELECT count(*) AS n FROM config_changes').get().n;

// One case per route: the path, the response key, the kind, the audited name,
// a first body, the `after` it must record, and a changed body.
const CASES = [
  {
    path: '/api/review-gate/thresholds', key: 'threshold', kind: 'review_gate_threshold', name: 'acme/app',
    body: { scope: 'acme/app', window_days: 14, min_merges: 5, tighten_rate: 0.25, clear_rate: 0.1 },
    after: { window_days: 14, min_merges: 5, tighten_rate: 0.25, clear_rate: 0.1, note: null },
    change: { clear_rate: 0.05 },
  },
  {
    path: '/api/rules', key: 'rule', kind: 'concurrency_rule', name: 'repo/execute/project-3/claude/build',
    body: { scope: 'repo', selector: 'execute/project-3/claude', kind: 'build', max_concurrent: 2 },
    after: { scope: 'repo', selector: 'execute/project-3/claude', kind: 'build', max_concurrent: 2, note: null },
    change: { max_concurrent: 3 },
  },
  {
    path: '/api/retry-policies', key: 'policy', kind: 'retry_policy', name: 'plan/acme/*',
    body: { lane: 'plan/acme/*', max_attempts: 2, backoff_seconds: 600, escalate_allowed: true },
    after: { max_attempts: 2, backoff_seconds: 600, escalate_allowed: 1, note: null },
    change: { max_attempts: 3 },
  },
  {
    path: '/api/contracts', key: 'contract', kind: 'phase_contract', name: 'plan',
    body: { phase: 'plan', artifact_kind: 'plan_file', pattern: 'plan.md' },
    after: { artifact_kind: 'plan_file', pattern: 'plan.md', note: null },
    change: { artifact_kind: 'pr_url' },
  },
];

async function withDb(t, fn) {
  const opened = await openDb();
  if (opened === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }
  await fn(opened);
}

for (const c of CASES) {
  test(`R1 ${c.path} writes one ${c.kind} row per change`, (t) => withDb(t, async ({ db, DB }) => {
    const first = await call(DB, c.path, { body: { ...c.body, actor: 'a@x', reason: 'why' } });
    assert.equal(first.status, 200);
    assert.ok(first.body[c.key], `response carries ${c.key}`);
    let r = rows(db, c.kind);
    assert.equal(r.length, 1);
    assert.equal(r[0].name, c.name);
    assert.equal(r[0].before_json, null);
    assert.deepEqual(JSON.parse(r[0].after_json), c.after);
    assert.equal(r[0].actor, 'a@x');
    assert.equal(r[0].reason, 'why');

    const same = await call(DB, c.path, { body: { ...c.body, actor: 'a@x', reason: 'why' } });
    assert.equal(same.status, 200);
    assert.equal(rows(db, c.kind).length, 1, 'an unchanged write is not a row');

    const changed = await call(DB, c.path, { body: { ...c.body, ...c.change, actor: 'b@x', reason: 'again' } });
    assert.equal(changed.status, 200);
    r = rows(db, c.kind);
    assert.equal(r.length, 2);
    assert.equal(r[1].name, c.name);
    assert.equal(r[1].before_json, r[0].after_json);
    assert.deepEqual(JSON.parse(r[1].after_json), { ...c.after, ...c.change });
    assert.equal(r[1].actor, 'b@x');
    assert.equal(total(db), 2, 'only this kind was written');
  }));
}

test('R2 a refused PUT writes no audit row', (t) => withDb(t, async ({ db, DB }) => {
  const bad = [
    ['/api/review-gate/thresholds', { scope: 'acme/app', window_days: 14, min_merges: 5, tighten_rate: 0.25, clear_rate: 0.5 }],
    ['/api/rules', { scope: 'repo', selector: 'x', kind: 'build', max_concurrent: -1 }],
    ['/api/retry-policies', { lane: 'plan/acme/*', max_attempts: 0 }],
    ['/api/contracts', { artifact_kind: 'plan_file' }],
  ];
  for (const [path, body] of bad) {
    const res = await call(DB, path, { body: { ...body, actor: 'a@x', reason: 'why' } });
    assert.equal(res.status, 400, path);
  }
  assert.equal(total(db), 0);
}));

test('K1 a note-less re-PUT keeps the stored note and is not a change', (t) => withDb(t, async ({ db, DB }) => {
  for (const c of [CASES[0], CASES[3]]) {
    assert.equal((await call(DB, c.path, { body: { ...c.body, note: 'n1' } })).status, 200);
    const again = await call(DB, c.path, { body: c.body });
    assert.equal(again.status, 200);
    assert.equal(again.body[c.key].note, 'n1');
    const r = rows(db, c.kind);
    assert.equal(r.length, 1, c.path);
    assert.equal(JSON.parse(r[0].after_json).note, 'n1');
  }
}));

test('NR no actor and no reason is a 200 recorded as api / NULL', (t) => withDb(t, async ({ db, DB }) => {
  const res = await call(DB, '/api/retry-policies', { body: { lane: 'plan/acme/*', max_attempts: 2 } });
  assert.equal(res.status, 200);
  const r = rows(db, 'retry_policy');
  assert.equal(r.length, 1);
  assert.equal(r[0].actor, 'api');
  assert.equal(r[0].reason, null);
  assert.equal(JSON.parse(r[0].after_json).backoff_seconds, 300, 'the defaulted backoff is what was stored');
}));

test('PUT /api/review-gate and DELETE /api/rules write no audit row', (t) => withDb(t, async ({ db, DB }) => {
  const gate = await call(DB, '/api/review-gate', { body: { repo: 'acme/app', tightened: 1, rate: 0.3, actor: 'a@x' } });
  assert.equal(gate.status, 200);
  const del = await call(DB, '/api/rules', { method: 'DELETE', body: { scope: 'repo', selector: 'x', kind: 'build' } });
  assert.equal(del.status, 200);
  assert.equal(total(db), 0);
}));
