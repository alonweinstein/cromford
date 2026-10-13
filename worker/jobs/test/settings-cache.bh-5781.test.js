import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { LANES_REGISTRY, registrySeedRows } from '../src/lib/core.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-5781: the per-isolate settings cache. Every case drives worker.fetch over
// schema.sql in an in-memory sqlite, and counts the statements that read the
// `settings` table (setting_sigs reads are not counted). W1 cache hit, W2-W3
// every write invalidates, W4 the TTL sources, W5 lead keys stay live, W6 expiry.

const SECRET = 'test-secret';
const probe = await openDb();
const NO_DB = !probe;

const READS_SETTINGS = /\bfrom\s+settings\b/i;

// A fresh DB per case, behind a Proxy that counts each prepare() of SQL that
// reads the settings table.
async function make(extra = {}) {
  const { db, DB } = await openDb();
  const counter = { n: 0 };
  const counted = new Proxy(DB, {
    get(target, prop, recv) {
      if (prop !== 'prepare') return Reflect.get(target, prop, recv);
      return (sql) => {
        if (READS_SETTINGS.test(sql)) counter.n++;
        return target.prepare(sql);
      };
    },
  });
  return { db, counter, env: { DB: counted, HARNESS_SECRET: SECRET, SETTINGS_CACHE_TTL_S: '30', ...extra } };
}

async function call(env, method, path, body) {
  const headers = { authorization: 'Bearer ' + SECRET };
  const init = { method, headers };
  if (body !== undefined) { headers['content-type'] = 'application/json'; init.body = JSON.stringify(body); }
  const res = await worker.fetch(new Request('https://jobs.test' + path, init), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}

const put = (db, key, value) => db.prepare(
  "INSERT INTO settings (key, value, note, actor, updated_at) VALUES (?,?,NULL,'op','2026-01-01T00:00:00Z') "
  + 'ON CONFLICT(key) DO UPDATE SET value=excluded.value').run(key, value);
const getVal = async (env, key) => {
  const r = await call(env, 'GET', `/api/settings/${key}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body.setting ? r.body.setting.value : null;
};

test('W1: two single-key GETs and a list GET make one settings query', { skip: NO_DB }, async () => {
  const { db, env, counter } = await make();
  put(db, 'deploy_queue_rows', '7');
  assert.equal(await getVal(env, 'deploy_queue_rows'), '7');
  assert.equal(await getVal(env, 'deploy_queue_rows'), '7');
  assert.equal(counter.n, 1);
  const list = await call(env, 'GET', '/api/settings');
  assert.equal(list.status, 200);
  assert.ok(list.body.settings.some((r) => r.key === 'deploy_queue_rows' && r.value === '7'));
  assert.equal(counter.n, 1);
});

test('W2: PUT /api/settings invalidates; the next GET reads the new value', { skip: NO_DB }, async () => {
  const { db, env, counter } = await make();
  put(db, 'deploy_queue_rows', '7');
  assert.equal(await getVal(env, 'deploy_queue_rows'), '7');
  const w = await call(env, 'PUT', '/api/settings', { key: 'deploy_queue_rows', value: '9', actor: 'op' });
  assert.equal(w.status, 200, JSON.stringify(w.body));
  counter.n = 0;
  assert.equal(await getVal(env, 'deploy_queue_rows'), '9');
  assert.equal(counter.n, 1);
});

test('W3: DELETE, both seeds and the cost-caps PUT each invalidate', { skip: NO_DB }, async () => {
  const { db, env } = await make();

  // DELETE /api/settings/<theme key>
  const theme = 'ui.theme.custom.bh5781';
  put(db, theme, '{"a":1}');
  assert.equal(await getVal(env, theme), '{"a":1}');
  const d = await call(env, 'DELETE', `/api/settings/${theme}?actor=op`);
  assert.equal(d.status, 200);
  assert.equal(d.body.deleted, true);
  assert.equal(await getVal(env, theme), null);

  // POST /api/settings/seed-registry
  const seedKey = registrySeedRows(LANES_REGISTRY)[0];
  assert.ok(seedKey, 'the baked registry has at least one seedable knob');
  assert.equal(await getVal(env, seedKey.key), null);
  const s = await call(env, 'POST', '/api/settings/seed-registry', {});
  assert.equal(s.status, 200, JSON.stringify(s.body));
  assert.equal(await getVal(env, seedKey.key), seedKey.value);

  // PUT /api/cost-caps
  // TEST-CHANGE (merged with main): schema.d/0013 (BH-4155) now seeds
  // conf.cost-caps.default = '100 5', so it is not null before the PUT. The
  // read below caches the seeded value; only an invalidating PUT lets the next
  // read see the new one. That proves the invalidation more strictly than a
  // null-before read did.
  const cap = 'conf.cost-caps.default';
  assert.equal(await getVal(env, cap), '100 5');
  const c = await call(env, 'PUT', '/api/cost-caps', { key: cap, value: '120 6', reason: 'bh-5781', actor: 'op' });
  assert.equal(c.status, 200, JSON.stringify(c.body));
  assert.equal(await getVal(env, cap), '120 6');

  // POST /api/cost-caps/seed
  // TEST-CHANGE: conf.lane-caps.lane.medic is seeded by schema.d/0013 too,
  // so the seed writes a lane no schema row has (null before, cached).
  const lane = 'conf.lane-caps.lane.bh5781';
  assert.equal(await getVal(env, lane), null);
  const cs = await call(env, 'POST', '/api/cost-caps/seed', { rows: [{ key: lane, value: '90 40000' }] });
  assert.equal(cs.status, 200, JSON.stringify(cs.body));
  assert.equal(await getVal(env, lane), '90 40000');
});

test('W4: the TTL sources: var unset = off, row 0 = off, bad row = var', { skip: NO_DB }, async () => {
  {
    const { db, env, counter } = await make({ SETTINGS_CACHE_TTL_S: undefined });
    put(db, 'deploy_queue_rows', '7');
    await getVal(env, 'deploy_queue_rows');
    await getVal(env, 'deploy_queue_rows');
    await call(env, 'GET', '/api/settings');
    assert.equal(counter.n, 3, 'no var and no row: every GET queries');
  }
  {
    const { db, env, counter } = await make();
    put(db, 'settings_cache_ttl_s', '0');
    await getVal(env, 'deploy_queue_rows');
    await getVal(env, 'deploy_queue_rows');
    assert.equal(counter.n, 2, 'row 0 turns the cache off over the var');
  }
  {
    const { db, env, counter } = await make();
    put(db, 'settings_cache_ttl_s', 'abc');
    await getVal(env, 'deploy_queue_rows');
    await getVal(env, 'deploy_queue_rows');
    assert.equal(counter.n, 1, 'a non-integer row is ignored and the var applies');
  }
  {
    const { db, env, counter } = await make();
    put(db, 'settings_cache_ttl_s', '61');
    await getVal(env, 'deploy_queue_rows');
    await getVal(env, 'deploy_queue_rows');
    assert.equal(counter.n, 1, 'an out-of-range row is ignored, not clamped');
  }
});

test('W5: a lead_* single-key GET reads D1 every time', { skip: NO_DB }, async () => {
  const { db, env, counter } = await make();
  put(db, 'lead_authority.x', 'human');
  await call(env, 'GET', '/api/settings/lead_authority.x');
  const after1 = counter.n;
  assert.ok(after1 >= 1);
  await call(env, 'GET', '/api/settings/lead_authority.x');
  assert.ok(counter.n > after1, `second lead GET made no settings query (${after1} -> ${counter.n})`);
});

test('W6: a snapshot older than the TTL is read again', { skip: NO_DB }, async (t) => {
  const { db, env, counter } = await make();
  put(db, 'deploy_queue_rows', '7');
  const base = 1_800_000_000_000; // a fixed anchor: Date.now is mocked below
  let now = base;
  t.mock.method(Date, 'now', () => now);
  await getVal(env, 'deploy_queue_rows');
  now = base + 29_000;
  await getVal(env, 'deploy_queue_rows');
  assert.equal(counter.n, 1);
  now = base + 31_000;
  await getVal(env, 'deploy_queue_rows');
  assert.equal(counter.n, 2);
});
