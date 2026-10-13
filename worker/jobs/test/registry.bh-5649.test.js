import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-5649 (BH-5633.1): the fleet registry routes, driven through the worker's
// own fetch handler against real SQLite. GET /api/registry is what
// bin/lib/registry.sh reads when REGISTRY_SOURCE=db, and POST
// /api/registry/import is what bin/registry-seed.sh writes through. Red on the
// contract branch: every route 404s.
//
// The shim refuses a statement with more than 100 binds, as D1 does, so W7's
// 300 lane rows only pass if the import chunks its upserts.

const SECRET = 'fixture-secret';
const ADMIN = 'fixture-admin-token';
const NOW_MS = Date.parse('2026-10-09T12:00:00Z');

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb();
  // Visible in TAP as a skip, never a quiet pass on nothing.
  if (!env) t.skip('node:sqlite unavailable on this runtime');
  return env;
}

async function call(env, method, path, { body, bearer = true, admin } = {}) {
  const headers = {};
  if (bearer) headers.authorization = `Bearer ${SECRET}`;
  if (admin !== undefined) headers['x-registry-admin-token'] = admin;
  const init = { method, headers };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), env);
  return { status: res.status, body: await res.json() };
}

const envOf = (DB, over = {}) => ({ DB, HARNESS_SECRET: SECRET, REGISTRY_ADMIN_TOKEN: ADMIN, ...over });
const importIt = (env, body) => call(env, 'POST', '/api/registry/import', { body, admin: ADMIN });
const count = (db, table) => db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;
const counts = (db) => ({
  projects: count(db, 'registry_projects'),
  boxes: count(db, 'registry_boxes'),
  lanes: count(db, 'registry_lane_boxes'),
  accounts: count(db, 'registry_box_accounts'),
  audit: count(db, 'registry_audit'),
  version: db.prepare('SELECT version FROM registry_meta WHERE id=1').get().version,
});

function fixture() {
  return {
    actor: 'registry-seed',
    projects: [
      { project: 'project-1', repo: 'example-org/project-1', prod: 'https://project-1.example.com', board_prefix: '/api/board', cron_offset: 3, box: 'hub-one', position: 0, status: 'active' },
      { project: 'project-2', repo: 'example-org/project-2', prod: '-', board_prefix: '-', cron_offset: 5, box: null, position: 1, status: 'active' },
      { project: 'gone-project', repo: '-', prod: '-', board_prefix: '-', cron_offset: 0, box: 'pool-a', position: 2, status: 'retired' },
    ],
    boxes: [
      { box: 'hub-one', box_id: 'hub', tailnet_ip: '100.0.0.1', cost_box: 'hub', standby_hub_name: null, standby_hub_id: null },
      { box: 'pool-a', box_id: 'pool-a', tailnet_ip: null, cost_box: null, standby_hub_name: 'hub-two', standby_hub_id: 'hub2' },
    ],
    lane_boxes: [
      { lane: 'build', box_id: 'hub' },
      { lane: 'build', box_id: 'pool-a' },
      { lane: 'triage', box_id: 'hub' },
    ],
    box_accounts: [
      { account: 'operator', kind: 'login', box: 'hub-one' },
      { account: 'operator', kind: 'cost_rows', box: 'pool-*' },
      { account: 'fleet', kind: 'jobs', box: 'pool-a' },
    ],
  };
}

// ── W1: the bearer guards every route ──────────────────────────────────────
test('W1: the three routes without a bearer answer 401', async (t) => {
  const { DB } = await open(t);
  const env = envOf(DB);
  for (const [m, p] of [['GET', '/api/registry'], ['GET', '/api/registry/version'], ['POST', '/api/registry/import']]) {
    const r = await call(env, m, p, { bearer: false, admin: ADMIN, body: m === 'POST' ? fixture() : undefined });
    assert.equal(r.status, 401, `${m} ${p}`);
  }
});

// ── W2: a fresh schema reads as version 0 and empty ────────────────────────
test('W2: a fresh schema answers version 0 with empty lists', async (t) => {
  const { DB } = await open(t);
  const env = envOf(DB);
  const g = await call(env, 'GET', '/api/registry');
  assert.equal(g.status, 200);
  assert.equal(g.body.version, 0);
  assert.deepEqual(g.body.projects, []);
  assert.deepEqual(g.body.boxes, []);
  assert.deepEqual(g.body.lane_boxes, []);
  assert.deepEqual(g.body.box_accounts, []);
  assert.equal(g.body.as_of, '2026-10-09T12:00:00Z');
  const v = await call(env, 'GET', '/api/registry/version');
  assert.equal(v.status, 200);
  assert.equal(v.body.version, 0);
  assert.equal(typeof v.body.updated_at, 'string');
});

// ── W3: the admin token gates the write ────────────────────────────────────
test('W3: an import without the right admin token is 403 and writes nothing', async (t) => {
  const { db, DB } = await open(t);
  const env = envOf(DB);
  const none = await call(env, 'POST', '/api/registry/import', { body: fixture() });
  assert.equal(none.status, 403);
  assert.match(none.body.error, /x-registry-admin-token/);
  const wrong = await call(env, 'POST', '/api/registry/import', { body: fixture(), admin: 'not-the-token' });
  assert.equal(wrong.status, 403);
  // Unset token in env is DENIED, whatever the header carries.
  const unsetEnv = envOf(DB, { REGISTRY_ADMIN_TOKEN: undefined });
  const unset = await call(unsetEnv, 'POST', '/api/registry/import', { body: fixture(), admin: ADMIN });
  assert.equal(unset.status, 403);
  const emptyHdr = await call(unsetEnv, 'POST', '/api/registry/import', { body: fixture(), admin: '' });
  assert.equal(emptyHdr.status, 403);
  const emptyEnv = envOf(DB, { REGISTRY_ADMIN_TOKEN: '' });
  const emptyBoth = await call(emptyEnv, 'POST', '/api/registry/import', { body: fixture(), admin: '' });
  assert.equal(emptyBoth.status, 403);
  assert.equal(count(db, 'registry_projects'), 0);
  assert.equal(count(db, 'registry_audit'), 0);
  assert.equal(counts(db).version, 0);
});

// ── W4: a valid import lands and reads back ────────────────────────────────
test('W4: a valid import answers version 1 and GET returns the payload rows', async (t) => {
  const { DB } = await open(t);
  const env = envOf(DB);
  const p = fixture();
  // Send the projects out of position order: GET must sort them.
  const sent = { ...p, projects: [p.projects[2], p.projects[0], p.projects[1]] };
  const r = await importIt(env, sent);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.ok, true);
  assert.equal(r.body.changed, 11);
  assert.equal(r.body.version, 1);
  assert.deepEqual(r.body.stale, []);
  const g = await call(env, 'GET', '/api/registry');
  assert.equal(g.status, 200);
  assert.equal(g.body.version, 1);
  assert.equal(g.body.updated_at, '2026-10-09T12:00:00Z');
  assert.deepEqual(g.body.projects, p.projects);
  assert.deepEqual(g.body.boxes, p.boxes);
  assert.deepEqual(g.body.lane_boxes, p.lane_boxes);
  assert.deepEqual(
    g.body.box_accounts,
    [
      { account: 'fleet', kind: 'jobs', box: 'pool-a' },
      { account: 'operator', kind: 'cost_rows', box: 'pool-*' },
      { account: 'operator', kind: 'login', box: 'hub-one' },
    ],
  );
  const v = await call(env, 'GET', '/api/registry/version');
  assert.equal(v.body.version, 1);
});

test('W4b: an omitted status defaults to active', async (t) => {
  const { DB } = await open(t);
  const env = envOf(DB);
  const p = fixture();
  delete p.projects[0].status;
  const r = await importIt(env, p);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const g = await call(env, 'GET', '/api/registry');
  assert.equal(g.body.projects[0].status, 'active');
});

// ── W5: the same payload twice is a no-op ──────────────────────────────────
test('W5: an identical import changes nothing and does not bump the version', async (t) => {
  const { db, DB } = await open(t);
  const env = envOf(DB);
  assert.equal((await importIt(env, fixture())).status, 200);
  const before = counts(db);
  const r = await importIt(env, fixture());
  assert.equal(r.status, 200);
  assert.equal(r.body.changed, 0);
  assert.equal(r.body.version, 1);
  assert.deepEqual(counts(db), before);
});

// ── W6: each changing import bumps the version once, with an audit row ─────
test('W6: three changing imports give versions 2, 3, 4 with audit rows', async (t) => {
  const { db, DB } = await open(t);
  const env = envOf(DB);
  assert.equal((await importIt(env, fixture())).body.version, 1);

  const steps = [
    { entity: 'box', key: 'hub-one', mutate: (p) => { p.boxes[0].tailnet_ip = '100.0.0.9'; }, old: '100.0.0.1', now: '100.0.0.9', actor: 'registry-seed' },
    { entity: 'project', key: 'project-1', mutate: (p) => { p.projects[0].cron_offset = 7; }, old: '"cron_offset":3', now: '"cron_offset":7', actor: 'operator-console' },
    { entity: 'lane_box', key: 'watch/hub', mutate: (p) => { p.lane_boxes.push({ lane: 'watch', box_id: 'hub' }); }, old: null, now: '"lane":"watch"', actor: 'registry-seed' },
  ];
  const p = fixture();
  let expect = 1;
  let clock = NOW_MS; // the pinned clock, advanced in step with the fake timers
  for (const s of steps) {
    s.mutate(p);
    p.actor = s.actor;
    t.mock.timers.tick(60_000);
    clock += 60_000;
    const r = await importIt(env, p);
    expect += 1;
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.changed, 1);
    assert.equal(r.body.version, expect);
    const g = await call(env, 'GET', '/api/registry');
    const v = await call(env, 'GET', '/api/registry/version');
    assert.equal(g.body.version, expect);
    assert.equal(v.body.version, expect);
    assert.equal(v.body.updated_at, g.body.updated_at);
    const rows = db.prepare('SELECT * FROM registry_audit WHERE version=?').all(expect);
    assert.equal(rows.length, 1);
    const a = rows[0];
    assert.equal(a.entity, s.entity);
    assert.equal(a.key, s.key);
    assert.equal(a.actor, s.actor);
    assert.equal(a.at, new Date(clock).toISOString().replace(/\.\d{3}Z$/, 'Z'));
    if (s.old === null) assert.equal(a.old_value, null);
    else assert.ok(a.old_value.includes(s.old), a.old_value);
    assert.ok(a.new_value.includes(s.now), a.new_value);
  }
  assert.deepEqual((await call(env, 'GET', '/api/registry')).body.boxes[0].tailnet_ip, '100.0.0.9');
});

// ── W7: a large import is chunked under the 100-bind limit ─────────────────
test('W7: 300 lane rows import and all 300 read back', async (t) => {
  const { db, DB } = await open(t);
  const env = envOf(DB);
  const p = fixture();
  p.lane_boxes = [];
  for (let i = 0; i < 300; i += 1) p.lane_boxes.push({ lane: `lane-${String(i).padStart(3, '0')}`, box_id: 'hub' });
  const r = await importIt(env, p);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.version, 1);
  const g = await call(env, 'GET', '/api/registry');
  assert.equal(g.body.lane_boxes.length, 300);
  assert.deepEqual(g.body.lane_boxes, p.lane_boxes);
  assert.equal(count(db, 'registry_audit'), 3 + 2 + 300 + 3);
});

// ── W8: refused payloads name the field and write nothing ──────────────────
test('W8: invalid payloads answer 400 naming the field, with 0 writes', async (t) => {
  const { db, DB } = await open(t);
  const env = envOf(DB);
  assert.equal((await importIt(env, fixture())).status, 200);
  const before = counts(db);
  const cases = [
    ['empty projects', (p) => { p.projects = []; }, /projects/],
    ['bad repo slug', (p) => { p.projects[1].repo = 'not-a-slug'; }, /projects\[1\]\.repo/],
    ['cron_offset 10', (p) => { p.projects[0].cron_offset = 10; }, /projects\[0\]\.cron_offset/],
    ['cron_offset string', (p) => { p.projects[0].cron_offset = '3'; }, /projects\[0\]\.cron_offset/],
    ['duplicate project', (p) => { p.projects[1].project = 'project-1'; }, /projects\[1\]\.project/],
    ['box missing from boxes', (p) => { p.projects[0].box = 'nowhere'; }, /projects\[0\]\.box/],
    ['bad IPv4', (p) => { p.boxes[0].tailnet_ip = '300.1.1.1'; }, /boxes\[0\]\.tailnet_ip/],
    ['whitespace in repo', (p) => { p.projects[0].repo = 'example-org/a b'; }, /projects\[0\]\.repo/],
    ['bad kind', (p) => { p.box_accounts[0].kind = 'admin'; }, /box_accounts\[0\]\.kind/],
    ['bad actor', (p) => { p.actor = 'two words'; }, /actor/],
  ];
  for (const [name, mutate, re] of cases) {
    const p = fixture();
    // Change something real as well, so a 200 here would be a write.
    p.boxes[1].cost_box = 'changed';
    mutate(p);
    const r = await importIt(env, p);
    assert.equal(r.status, 400, `${name}: ${JSON.stringify(r.body)}`);
    assert.match(r.body.error, re, name);
    assert.deepEqual(counts(db), before, name);
  }
});

// ── W9: rows absent from the payload are kept and reported stale ───────────
test('W9: a project dropped from the payload stays and is listed stale', async (t) => {
  const { DB } = await open(t);
  const env = envOf(DB);
  const a = fixture();
  a.projects.push({ project: 'old-one', repo: 'example-org/old-one', prod: '-', board_prefix: '-', cron_offset: 1, box: null, position: 9, status: 'active' });
  assert.equal((await importIt(env, a)).status, 200);
  // B with only the drop: an empty diff, nothing written, old-one reported.
  const same = await importIt(env, fixture());
  assert.equal(same.status, 200);
  assert.equal(same.body.changed, 0);
  assert.deepEqual(same.body.stale, ['project:old-one']);
  // B with the drop AND a real change, so the write batch runs: old-one and a
  // dropped lane must survive that batch too.
  const b = fixture();
  b.boxes[1].cost_box = 'pool';
  b.lane_boxes.pop();
  const r = await importIt(env, b);
  assert.equal(r.status, 200);
  assert.equal(r.body.changed, 1);
  assert.equal(r.body.version, 2);
  assert.deepEqual(r.body.stale, ['lane_box:triage/hub', 'project:old-one']);
  const g = await call(env, 'GET', '/api/registry');
  assert.ok(g.body.projects.some((x) => x.project === 'old-one'));
  assert.ok(g.body.lane_boxes.some((x) => x.lane === 'triage' && x.box_id === 'hub'));
});
