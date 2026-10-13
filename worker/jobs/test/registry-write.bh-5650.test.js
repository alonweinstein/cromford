import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-5650 (BH-5633.2): the per-row registry write routes, driven through the
// worker's own fetch handler against real SQLite and seeded through the
// wave-1 import. Every write is admin-gated, writes one audit row per changed
// row, and bumps the version once. Red on the contract branch: every write
// route 404s.

const SECRET = 'fixture-secret';
const ADMIN = 'fixture-admin-token';
const NOW_MS = Date.parse('2026-10-09T12:00:00Z');

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb();
  if (!env) t.skip('node:sqlite unavailable on this runtime');
  return env;
}

async function call(env, method, path, { body, bearer = true, admin = ADMIN } = {}) {
  const headers = {};
  if (bearer) headers.authorization = `Bearer ${SECRET}`;
  if (admin !== null) headers['x-registry-admin-token'] = admin;
  const init = { method, headers };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), env);
  return { status: res.status, body: await res.json() };
}

const envOf = (DB) => ({ DB, HARNESS_SECRET: SECRET, REGISTRY_ADMIN_TOKEN: ADMIN });
const version = (db) => db.prepare('SELECT version FROM registry_meta WHERE id=1').get().version;
const auditN = (db) => db.prepare('SELECT COUNT(*) AS n FROM registry_audit').get().n;
const auditSince = (db, n) => db.prepare('SELECT entity, key, old_value, new_value, version, actor FROM registry_audit WHERE id > ? ORDER BY id').all(n);
const rows = (db, table, where = '1=1', ...b) => db.prepare(`SELECT * FROM ${table} WHERE ${where}`).all(...b);

function fixture() {
  return {
    actor: 'registry-seed',
    projects: [
      { project: 'project-1', repo: 'example-org/project-1', prod: 'https://project-1.example.com', board_prefix: '/api/board', cron_offset: 3, box: 'box-mk', position: 0, status: 'active' },
      { project: 'project-3', repo: 'example-org/project-3', prod: '-', board_prefix: '-', cron_offset: 5, box: 'box-small', position: 1, status: 'active' },
    ],
    boxes: [
      { box: 'box-mk', box_id: 'mk', tailnet_ip: '192.0.2.1', cost_box: 'mk', standby_hub_name: null, standby_hub_id: null },
      { box: 'box-small', box_id: 'small', tailnet_ip: '192.0.2.2', cost_box: 'small', standby_hub_name: null, standby_hub_id: null },
    ],
    lane_boxes: [
      { lane: 'build', box_id: 'mk' },
      { lane: 'triage', box_id: 'mk' },
      { lane: 'watch', box_id: 'mk' },
      { lane: 'build', box_id: 'small' },
    ],
    box_accounts: [
      { account: 'mk-account', kind: 'cost_rows', box: 'mk' },
      { account: 'mk-account', kind: 'jobs', box: 'box-mk' },
      { account: 'mk-account', kind: 'jobs', box: 'pool-*' },
      { account: 'other', kind: 'login', box: 'box-small' },
    ],
  };
}

async function seeded(t) {
  const opened = await open(t);
  if (!opened) return null;
  const env = envOf(opened.DB);
  const r = await call(env, 'POST', '/api/registry/import', { body: fixture() });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(version(opened.db), 1);
  return { ...opened, env };
}

const PROJ = { project: 'newp', repo: 'Acme/newp', prod: '-', board_prefix: '-', cron_offset: 7, box: 'box-small' };

// ── W1 POST a project ────────────────────────────────────────────────────────
test('W1: POST a project writes one row, one audit row and one version; a repeat is a no-op; a different body is 409', async (t) => {
  const s = await seeded(t); if (!s) return;
  const a0 = auditN(s.db);
  const r = await call(s.env, 'POST', '/api/registry/projects', { body: { ...PROJ, actor: 'w1-actor' } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual([r.body.changed, r.body.version], [1, 2]);
  assert.equal(version(s.db), 2);
  const row = rows(s.db, 'registry_projects', 'project=?', 'newp')[0];
  assert.equal(row.position, 2, 'position omitted = max+1');
  assert.equal(row.status, 'active');
  const au = auditSince(s.db, a0);
  assert.equal(au.length, 1);
  assert.deepEqual([au[0].entity, au[0].key, au[0].old_value, au[0].actor, au[0].version], ['project', 'newp', null, 'w1-actor', 2]);
  assert.deepEqual(JSON.parse(au[0].new_value), { ...PROJ, position: 2, status: 'active' });

  const again = await call(s.env, 'POST', '/api/registry/projects', { body: PROJ });
  assert.equal(again.status, 200);
  assert.deepEqual([again.body.changed, again.body.version], [0, 2]);
  assert.equal(auditN(s.db), a0 + 1);
  assert.equal(version(s.db), 2);

  const diff = await call(s.env, 'POST', '/api/registry/projects', { body: { ...PROJ, cron_offset: 1 } });
  assert.equal(diff.status, 409);
  assert.equal(version(s.db), 2);
  assert.equal(rows(s.db, 'registry_projects', 'project=?', 'newp')[0].cron_offset, 7);
});

// ── W2 PATCH a project ───────────────────────────────────────────────────────
test('W2: PATCH box records old and new; unknown field, "3" and a missing row are refused', async (t) => {
  const s = await seeded(t); if (!s) return;
  const a0 = auditN(s.db);
  const r = await call(s.env, 'PATCH', '/api/registry/projects/project-1', { body: { box: 'box-small' } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.changed, 1);
  const au = auditSince(s.db, a0);
  assert.equal(au.length, 1);
  assert.equal(JSON.parse(au[0].old_value).box, 'box-mk');
  assert.equal(JSON.parse(au[0].new_value).box, 'box-small');
  assert.equal(au[0].actor, 'registry-api');
  assert.equal(rows(s.db, 'registry_projects', 'project=?', 'project-1')[0].box, 'box-small');

  const v = version(s.db); const n = auditN(s.db);
  for (const [body, want] of [
    [{ colour: 'red' }, 400],
    [{ cron_offset: '3' }, 400],
    [{ cron_offset: 10 }, 400],
    [{ box: 'box-nowhere' }, 400],
    [{ repo: 'Acme/x y' }, 400],
    [{}, 400],
  ]) {
    const x = await call(s.env, 'PATCH', '/api/registry/projects/project-1', { body });
    assert.equal(x.status, want, JSON.stringify(body));
  }
  const miss = await call(s.env, 'PATCH', '/api/registry/projects/no-such', { body: { cron_offset: 1 } });
  assert.equal(miss.status, 404);
  assert.equal(version(s.db), v);
  assert.equal(auditN(s.db), n);
});

// ── W3 DELETE a project ──────────────────────────────────────────────────────
test('W3: DELETE a project removes the row and audits new_value null', async (t) => {
  const s = await seeded(t); if (!s) return;
  const a0 = auditN(s.db);
  const r = await call(s.env, 'DELETE', '/api/registry/projects/project-3');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual([r.body.changed, r.body.version], [1, 2]);
  assert.equal(rows(s.db, 'registry_projects', 'project=?', 'project-3').length, 0);
  const au = auditSince(s.db, a0);
  assert.equal(au.length, 1);
  assert.equal(au[0].new_value, null);
  assert.equal(JSON.parse(au[0].old_value).project, 'project-3');
  assert.equal((await call(s.env, 'DELETE', '/api/registry/projects/project-3')).status, 404);
});

// ── W4 POST a box like another ───────────────────────────────────────────────
test('W4: POST a box with like copies lanes and exact account rows in one version', async (t) => {
  const s = await seeded(t); if (!s) return;
  const a0 = auditN(s.db);
  const body = { box: 'box-x', box_id: 'x', tailnet_ip: '192.0.2.13', like: 'mk' };
  const r = await call(s.env, 'POST', '/api/registry/boxes', { body });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const lanes = rows(s.db, 'registry_lane_boxes', 'box_id=?', 'x').map((l) => l.lane).sort();
  assert.deepEqual(lanes, ['build', 'triage', 'watch']);
  const acc = rows(s.db, 'registry_box_accounts', "account='mk-account'").map((a) => `${a.kind}:${a.box}`).sort();
  assert.deepEqual(acc, ['cost_rows:mk', 'cost_rows:x', 'jobs:box-mk', 'jobs:box-x', 'jobs:pool-*']);
  assert.equal(rows(s.db, 'registry_box_accounts', "box LIKE 'pool-%'").length, 1, 'pool-* is never copied');
  assert.equal(rows(s.db, 'registry_boxes', 'box=?', 'box-x')[0].cost_box, 'x');
  const au = auditSince(s.db, a0);
  assert.equal(au.length, 1 + 3 + 2);
  assert.deepEqual([...new Set(au.map((a) => a.version))], [2]);
  assert.equal(au.filter((a) => a.entity === 'box').length, 1);
  assert.equal(r.body.changed, 6);
  assert.equal(version(s.db), 2);

  // A retry of the same add changes nothing.
  const again = await call(s.env, 'POST', '/api/registry/boxes', { body });
  assert.deepEqual([again.status, again.body.changed, again.body.version], [200, 0, 2]);
  assert.equal(auditN(s.db), a0 + 6);

  // Same box, different fields: 409.
  const diff = await call(s.env, 'POST', '/api/registry/boxes', { body: { ...body, tailnet_ip: '192.0.2.14' } });
  assert.equal(diff.status, 409);

  // An unknown like writes nothing at all, not even the box row.
  const unk = await call(s.env, 'POST', '/api/registry/boxes', { body: { box: 'box-y', box_id: 'y', like: 'nope' } });
  assert.equal(unk.status, 404);
  assert.equal(rows(s.db, 'registry_boxes', 'box=?', 'box-y').length, 0);
  assert.equal(version(s.db), 2);
});

// ── W5 PATCH a box ───────────────────────────────────────────────────────────
test('W5: PATCH a box changes its IP; box_id and unknown fields are 400', async (t) => {
  const s = await seeded(t); if (!s) return;
  const r = await call(s.env, 'PATCH', '/api/registry/boxes/box-small', { body: { tailnet_ip: '192.0.2.9' } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(rows(s.db, 'registry_boxes', 'box=?', 'box-small')[0].tailnet_ip, '192.0.2.9');
  const v = version(s.db);
  assert.equal((await call(s.env, 'PATCH', '/api/registry/boxes/box-small', { body: { box_id: 'other' } })).status, 400);
  assert.equal((await call(s.env, 'PATCH', '/api/registry/boxes/box-small', { body: { colour: 'red' } })).status, 400);
  assert.equal((await call(s.env, 'PATCH', '/api/registry/boxes/box-small', { body: { tailnet_ip: '300.1.1.1' } })).status, 400);
  assert.equal((await call(s.env, 'PATCH', '/api/registry/boxes/box-none', { body: { tailnet_ip: '192.0.2.3' } })).status, 404);
  assert.equal(version(s.db), v);
});

// ── W6 DELETE and drain a box ────────────────────────────────────────────────
test('W6: a box in use cannot be deleted or drained; drain after the move removes its lanes; known_lanes keeps them', async (t) => {
  const s = await seeded(t); if (!s) return;
  const v = version(s.db); const n = auditN(s.db);
  const del = await call(s.env, 'DELETE', '/api/registry/boxes/box-mk');
  assert.equal(del.status, 409);
  assert.deepEqual(del.body.projects, ['project-1']);
  const dr = await call(s.env, 'POST', '/api/registry/boxes/box-mk/drain');
  assert.equal(dr.status, 409);
  assert.match(dr.body.error, /project-1/);
  assert.equal(version(s.db), v);
  assert.equal(auditN(s.db), n);

  assert.equal((await call(s.env, 'PATCH', '/api/registry/projects/project-1', { body: { box: 'box-small' } })).status, 200);
  const a1 = auditN(s.db);
  const ok = await call(s.env, 'POST', '/api/registry/boxes/box-mk/drain');
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.equal(ok.body.changed, 3);
  assert.equal(rows(s.db, 'registry_lane_boxes', 'box_id=?', 'mk').length, 0);
  const au = auditSince(s.db, a1);
  assert.equal(au.length, 3);
  assert.ok(au.every((a) => a.entity === 'lane_box' && a.new_value === null));
  assert.equal(new Set(au.map((a) => a.version)).size, 1);

  const g = await call(s.env, 'GET', '/api/registry', { admin: null });
  assert.equal(g.status, 200);
  assert.deepEqual(g.body.known_lanes, ['build', 'triage', 'watch']);
  assert.ok(!g.body.lane_boxes.some((l) => l.lane === 'triage'), 'triage has no rows left');

  // A drained box with no project can now be deleted: its lanes are gone.
  const gone = await call(s.env, 'DELETE', '/api/registry/boxes/box-mk');
  assert.equal(gone.status, 200, JSON.stringify(gone.body));
  assert.equal(rows(s.db, 'registry_boxes', 'box=?', 'box-mk').length, 0);
});

// ── W7 lane membership ───────────────────────────────────────────────────────
test('W7: POST and DELETE a lane membership, with audit', async (t) => {
  const s = await seeded(t); if (!s) return;
  const a0 = auditN(s.db);
  const p = await call(s.env, 'POST', '/api/registry/lane-boxes', { body: { lane: 'triage', box_id: 'small' } });
  assert.deepEqual([p.status, p.body.changed], [200, 1]);
  const d = await call(s.env, 'DELETE', '/api/registry/lane-boxes/triage/small');
  assert.deepEqual([d.status, d.body.changed], [200, 1]);
  const au = auditSince(s.db, a0);
  assert.deepEqual(au.map((a) => [a.entity, a.key, a.old_value === null, a.new_value === null]),
    [['lane_box', 'triage/small', true, false], ['lane_box', 'triage/small', false, true]]);
  assert.equal((await call(s.env, 'DELETE', '/api/registry/lane-boxes/triage/small')).status, 404);
  assert.equal((await call(s.env, 'POST', '/api/registry/lane-boxes', { body: { lane: 'Bad Lane', box_id: 'small' } })).status, 400);
  assert.equal(version(s.db), 3);
});

// ── W8 box accounts ──────────────────────────────────────────────────────────
test('W8: POST and DELETE a box account; a glob box rides URL-encoded', async (t) => {
  const s = await seeded(t); if (!s) return;
  const a0 = auditN(s.db);
  const p = await call(s.env, 'POST', '/api/registry/box-accounts', { body: { account: 'other', kind: 'jobs', box: 'pool-*' } });
  assert.deepEqual([p.status, p.body.changed], [200, 1]);
  const d = await call(s.env, 'DELETE', '/api/registry/box-accounts/other/jobs/pool-%2A');
  assert.deepEqual([d.status, d.body.changed], [200, 1], JSON.stringify(d.body));
  assert.equal(rows(s.db, 'registry_box_accounts', "account='other' AND kind='jobs'").length, 0);
  assert.equal(auditSince(s.db, a0).length, 2);
  assert.equal((await call(s.env, 'POST', '/api/registry/box-accounts', { body: { account: 'other', kind: 'nope', box: 'x' } })).status, 400);
});

// ── W9 the gates ─────────────────────────────────────────────────────────────
const WRITES = [
  ['POST', '/api/registry/projects', PROJ],
  ['PATCH', '/api/registry/projects/project-1', { cron_offset: 1 }],
  ['DELETE', '/api/registry/projects/project-3', undefined],
  ['POST', '/api/registry/boxes', { box: 'box-x', box_id: 'x', like: 'mk' }],
  ['PATCH', '/api/registry/boxes/box-small', { tailnet_ip: '192.0.2.9' }],
  ['DELETE', '/api/registry/boxes/box-small', undefined],
  ['POST', '/api/registry/boxes/box-small/drain', undefined],
  ['POST', '/api/registry/lane-boxes', { lane: 'triage', box_id: 'small' }],
  ['DELETE', '/api/registry/lane-boxes/build/small', undefined],
  ['POST', '/api/registry/box-accounts', { account: 'other', kind: 'jobs', box: 'x' }],
  ['DELETE', '/api/registry/box-accounts/other/login/box-small', undefined],
];

test('W9: every write route without the admin token, or with a wrong or empty one, is 403; without the bearer 401; nothing is written', async (t) => {
  const s = await seeded(t); if (!s) return;
  const v = version(s.db); const n = auditN(s.db);
  for (const [m, p, body] of WRITES) {
    for (const admin of [null, 'not-the-token', '']) {
      const r = await call(s.env, m, p, { body, admin });
      assert.equal(r.status, 403, `${m} ${p} admin=${admin}`);
    }
    assert.equal((await call({ ...s.env, REGISTRY_ADMIN_TOKEN: undefined }, m, p, { body })).status, 403, `${m} ${p} unset env token`);
    assert.equal((await call(s.env, m, p, { body, bearer: false })).status, 401, `${m} ${p} no bearer`);
  }
  assert.equal(version(s.db), v);
  assert.equal(auditN(s.db), n);
  // Non-vacuity: the same calls WITH the token reach the handler.
  const ok = await call(s.env, 'PATCH', '/api/registry/projects/project-1', { body: { cron_offset: 1 } });
  assert.equal(ok.status, 200);
});

// ── W10 the import still never deletes ───────────────────────────────────────
test('W10: a re-import after a write-route delete neither deletes nor errors (deletes:false)', async (t) => {
  const s = await seeded(t); if (!s) return;
  assert.equal((await call(s.env, 'POST', '/api/registry/lane-boxes', { body: { lane: 'extra', box_id: 'small' } })).status, 200);
  assert.equal((await call(s.env, 'DELETE', '/api/registry/lane-boxes/build/small')).status, 200);
  const v = version(s.db);
  const r = await call(s.env, 'POST', '/api/registry/import', { body: fixture() });
  assert.equal(r.status, 200);
  // The import re-adds the row it carries and keeps the one it does not.
  assert.equal(r.body.changed, 1);
  assert.deepEqual(r.body.stale, ['lane_box:extra/small']);
  assert.equal(rows(s.db, 'registry_lane_boxes', "lane='extra'").length, 1);
  assert.equal(version(s.db), v + 1);
});
