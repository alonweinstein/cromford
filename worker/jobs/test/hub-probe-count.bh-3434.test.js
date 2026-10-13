import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { D1_COUNT_SQL } from '../src/routes/hub-probe-count.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-3448 (BH-3434.1): GET /api/hub-probe/count?table=&template= — the d1-count
// probe's one read. The SQL comes ONLY from the frozen D1_COUNT_SQL map; a
// table or template outside it is a 400 before any statement is prepared, and
// no request text ever reaches SQL. Driven through the worker's real fetch
// against node:sqlite running the shipped schema.sql.
const SECRET = 'test-secret';
const COMMON = fileURLToPath(new URL('../../../bin/lib/hub-probes/common.sh', import.meta.url));
const TABLES = ['jobs', 'ledgers', 'split_watchdog_actions', 'hub_probe_requests'];
const TEMPLATES = ['all', 'last-24h'];
const TS_COL = { jobs: 'created_at', ledgers: 'created_at', split_watchdog_actions: 'first_at', hub_probe_requests: 'requested_at' };

// `log` collects every SQL text the worker prepared for this call.
const call = (o, path, log) => {
  const DB = log ? { ...o.DB, prepare: (sql) => { log.push(sql); return o.DB.prepare(sql); } } : o.DB;
  const req = new Request(`https://jobs.test${path}`, { headers: { authorization: `Bearer ${SECRET}` } });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const countUrl = (table, template) => `/api/hub-probe/count?${new URLSearchParams({ table, template })}`;
const isoNoMs = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');

// The route's last-24h window is cut from the worker's real clock, so the
// fixtures are too: every stamp below is an offset from this one read.
const ANCHOR = Date.now();  // determinism: ok the single anchor; every fixture and the cutoff are offsets off it, 1h clear of the window edge

// Two rows per table: one stamped an hour ago, one 25 hours ago.
function seed(o) {
  const recent = isoNoMs(ANCHOR - 3600e3);
  const old = isoNoMs(ANCHOR - 25 * 3600e3);
  o.db.prepare("INSERT INTO jobs (id, project, kind, box, stage, status, created_at, updated_at) VALUES (?, 'p', 'build', 'b', 'plan', 'running', ?, ?)").run('j1', recent, recent);
  o.db.prepare("INSERT INTO jobs (id, project, kind, box, stage, status, created_at, updated_at) VALUES (?, 'p', 'build', 'b', 'plan', 'running', ?, ?)").run('j2', old, old);
  o.db.prepare("INSERT INTO ledgers (kind, key, status, created_at, updated_at) VALUES ('merge', ?, 'merged', ?, ?)").run('k1', recent, recent);
  o.db.prepare("INSERT INTO ledgers (kind, key, status, created_at, updated_at) VALUES ('merge', ?, 'merged', ?, ?)").run('k2', old, old);
  for (const [c, ts] of [['c1', recent], ['c2', old], ['c3', old]]) {
    o.db.prepare("INSERT INTO split_watchdog_actions (project, family, child, step, reason_fp, repeats, first_at, last_at) VALUES ('p', 'f', ?, 's', 'aaaaaaaaaaaa', 1, ?, ?)").run(c, ts, recent);
  }
  for (const [h, ts] of [['h1', recent], ['h2', old]]) {
    o.db.prepare("INSERT INTO hub_probe_requests (project, ticket_key, probe, args_json, args_hash, requested_at) VALUES ('p', 'K', 'd1-count', '{}', ?, ?)").run(h, ts);
  }
}

// Every rejected request from K2-K4, as [table, template].
const REJECTS = [
  ['sqlite_master', 'all'], ['JOBS', 'all'], ['', 'all'], ['jobs', ''], ['settings', 'all'],
  ['jobs', 'last-24h OR 1=1'], ['jobs', 'all--'], ['jobs;DROP TABLE jobs', 'all'], ['jobs', 'all; DROP TABLE jobs'],
  ['__proto__', 'all'], ['constructor', 'all'], ['toString', 'all'], ['hasOwnProperty', 'all'],
  ['jobs', '__proto__'], ['jobs', 'constructor'], ['jobs', 'toString'], ['jobs', 'hasOwnProperty'],
  ['jobs', 'valueOf'],
];

test('(K1) every allowlisted pair answers {count} equal to a direct COUNT; last-24h drops the 25h-old row', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable');
  seed(o);
  const expected = { jobs: [2, 1], ledgers: [2, 1], split_watchdog_actions: [3, 1], hub_probe_requests: [2, 1] };
  for (const table of TABLES) {
    for (const [i, template] of TEMPLATES.entries()) {
      const r = await call(o, countUrl(table, template));
      assert.equal(r.status, 200, `${table}/${template}: ${JSON.stringify(r.body)}`);
      assert.deepEqual(Object.keys(r.body), ['count']);
      const cutoff = isoNoMs(ANCHOR - 86400e3);
      const direct = template === 'all'
        ? o.db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n
        : o.db.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE ${TS_COL[table]} >= ?`).get(cutoff).n;
      assert.equal(r.body.count, direct, `${table}/${template}`);
      assert.equal(r.body.count, expected[table][i], `${table}/${template}`);
    }
  }
});

test('(K2) an unknown table is a 400', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable');
  for (const table of ['sqlite_master', 'JOBS', '', 'settings', 'jobs ']) {
    const r = await call(o, countUrl(table, 'all'));
    assert.equal(r.status, 400, JSON.stringify(table));
    assert.match(r.body.error, /table/);
  }
  assert.equal((await call(o, '/api/hub-probe/count?template=all')).status, 400, 'no table param');
  assert.equal((await call(o, '/api/hub-probe/count?table=jobs')).status, 400, 'no template param');
});

test('(K3) SQL in a template or a table is a 400 and every table is intact', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable');
  seed(o);
  for (const [table, template] of [['jobs', 'last-24h OR 1=1'], ['jobs', 'all--'], ['jobs;DROP TABLE jobs', 'all'], ['jobs', 'all; DROP TABLE jobs']]) {
    const r = await call(o, countUrl(table, template));
    assert.equal(r.status, 400, `${table}/${template}`);
  }
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM jobs').get().n, 2);
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM ledgers').get().n, 2);
});

test('(K4) prototype keys as table or template are a 400', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable');
  for (const k of ['__proto__', 'constructor', 'toString', 'hasOwnProperty', 'valueOf']) {
    assert.equal((await call(o, countUrl(k, 'all'))).status, 400, `table=${k}`);
    assert.equal((await call(o, countUrl('jobs', k))).status, 400, `template=${k}`);
  }
});

test('(K5) no request text reaches SQL; a rejected request prepares nothing', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable');
  const MARK = 'zz_marker_3434';
  for (const [table, template] of REJECTS.map(([a, b]) => [a + (a ? MARK : ''), b]).concat(REJECTS)) {
    const log = [];
    const r = await call(o, countUrl(table, template), log);
    assert.equal(r.status, 400, `${table}/${template}`);
    assert.deepEqual(log, [], `${table}/${template} prepared a statement`);
  }
  for (const table of TABLES) {
    for (const template of TEMPLATES) {
      const log = [];
      const r = await call(o, `${countUrl(table, template)}&extra=${MARK}`, log);
      assert.equal(r.status, 200);
      assert.deepEqual(log, [D1_COUNT_SQL[table][template]], 'the only SQL is the map entry');
      assert.ok(!log.join('\n').includes(MARK));
      assert.ok(!log.join('\n').includes(template), 'the template word itself never reaches SQL');
    }
  }
});

test('(K6) the map is frozen and its keys equal HP_D1_TABLES / HP_D1_TEMPLATES', () => {
  const src = readFileSync(COMMON, 'utf8');
  const words = (name) => {
    const m = src.match(new RegExp(`^${name}="([^"]*)"`, 'm'));
    assert.ok(m, `${name}= is in common.sh`);
    return m[1].split(/\s+/).filter(Boolean).sort();
  };
  const tables = words('HP_D1_TABLES');
  const templates = words('HP_D1_TEMPLATES');
  assert.deepEqual(Object.keys(D1_COUNT_SQL).sort(), tables);
  assert.ok(Object.isFrozen(D1_COUNT_SQL));
  assert.equal(Object.getPrototypeOf(D1_COUNT_SQL), null);
  for (const table of tables) {
    assert.deepEqual(Object.keys(D1_COUNT_SQL[table]).sort(), templates, table);
    assert.ok(Object.isFrozen(D1_COUNT_SQL[table]), table);
    assert.equal(Object.getPrototypeOf(D1_COUNT_SQL[table]), null, table);
  }
});

test('(K7) a missing table answers 503, never a count of 0', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable');
  o.db.exec('DROP TABLE split_watchdog_actions');
  const r = await call(o, countUrl('split_watchdog_actions', 'all'));
  assert.equal(r.status, 503);
  assert.match(r.body.error, /schema not applied/);
});
