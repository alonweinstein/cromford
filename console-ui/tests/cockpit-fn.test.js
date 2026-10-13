import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/cockpit/[[path]].js';

// The Pages Function's own contract, which no screen test can reach: it must
// fail CLOSED (no session, unreachable console, missing binding are three
// different refusals), it must never write, and its reads must carry the shapes
// the screens destructure. The D1 behind it is stubbed — the real database is
// exercised separately, read-only, with wrangler.

// Every route the function serves, with the row it should hand back. The stub
// matches on a fragment of the SQL rather than the whole statement so a
// whitespace edit does not silently turn a test green on an empty result.
function stubDb(rowsFor = defaultRows) {
  const seenSql = [];
  const seen = [];
  const answer = (sql, binds) => {
    seenSql.push(sql);
    seen.push({ sql, binds });
    for (const [fragment, rows] of Object.entries(rowsFor)) {
      if (sql.includes(fragment)) return typeof rows === 'function' ? rows(binds) : rows;
    }
    return [];
  };
  return {
    seenSql,
    seen,
    prepare(sql) {
      const stmt = { binds: [] };
      stmt.bind = (...b) => { stmt.binds = b; return stmt; };
      stmt.all = async () => ({ results: answer(sql, stmt.binds) });
      stmt.first = async () => answer(sql, stmt.binds)[0] || null;
      return stmt;
    }
  };
}

// ORDER MATTERS: the aggregate statements also contain the plain ones' FROM
// clauses (`... AS failed FROM runs WHERE 1=1`), so the specific fragments have
// to be listed before the generic ones or a COUNT answers with a row of runs.
const defaultRows = {
  'AS alerts,': [{ alerts: 11, commands: 101, builds: 94, proposals: 23 }],
  'AS n, SUM(CASE WHEN rc = 0': [{ n: 8736, failed: 46 }],
  'SUM(merged) AS merged': [{ n: 817, merged: 518 }],
  'AS runs,': [{ runs: 2350, failed: 4, first_run_at: '2026-07-22T15:16:01Z', last_run_at: '2026-08-28T21:16:01Z' }],
  'GROUP BY kind': [{ kind: 'triage', n: 2346 }],
  'GROUP BY stage': [{ stage: 'pr_merged', n: 63 }],
  'FROM company_maps': [{ project: 'project-3', content: '# project-3', updated_at: '2026-08-17T09:10:47Z', bytes: 16752 }],
  'FROM boards': [{ project: 'project-3', paused: 0, automerge: 1, last_run_at: '2026-08-28T21:16:01Z', last_rc: 0, last_summary: 'tickets=1 built=0 [gate=board-changed]', disk: '87% used', mem: '8% mem' }],
  'stage NOT IN': [{ id: 2861, project: 'project-3', ticket_key: 'TK-111', stage: 'qa', tier: 2, merged: 0, updated_at: '2026-08-28T20:30:13Z' }],
  'FROM runs ORDER BY id DESC': [{ id: 8733, project: 'project-3', kind: 'triage', rc: 0, summary: 'tickets=1', started_at: '2026-08-28T21:16:01Z', finished_at: '2026-08-28T21:17:11Z' }],
  'FROM events': [{ id: 221525, ts: '2026-08-28T22:00:04Z', project: 'project-2', type: 'pr_review', detail: 'PR #409 reviewed' }],
  'FROM alerts': [{ id: 4284, akey: 'medic:a:21', ts: '2026-08-28T21:18:49Z', project: 'project-4', line: 'parked' }],
  'FROM commands': [{ id: 6460, ckey: 'k', type: 'run_triage', project: 'project-3', status: 'dead_letter', attempts: 3, result: 'ssh unreachable', created_at: 'x', updated_at: 'y' }],
  'stage IN': [{ id: 2823, project: 'project-4', ticket_key: 'TK-1273', stage: 'pr_created', tier: 2, verdict: 'APPROVE', pr_url: '', merged: 0, updated_at: 'z' }],
  'FROM proposals': [{ pkey: 'prop:project-3:x', project: 'project-3', slug: 'x', title: 'T', score: 128, status: 'gate_pending', updated_at: 'w' }],
  // The history page: two rows when the caller asked for two, so the "a full
  // page hands back a cursor" branch is the one under test.
  'FROM runs WHERE': (binds) => (String(binds[binds.length - 1]) === '2'
    ? [{ id: 8733, project: 'project-3', kind: 'triage', rc: 0, summary: 's', started_at: 'a', finished_at: 'b' },
       { id: 8730, project: 'project-3', kind: 'triage', rc: 1, summary: 's', started_at: 'a', finished_at: 'b' }]
    : [{ id: 8733, project: 'project-3', kind: 'triage', rc: 0, summary: 's', started_at: 'a', finished_at: 'b' }]),
  'FROM builds WHERE': [{ id: 2872, project: 'project-4', ticket_key: 'TK-791', stage: 'executing', tier: null, verdict: '', pr_url: '', merged: 0, updated_at: 'u' }]
};

// The function delegates the session check to the console worker over fetch, so
// the only way to test its refusals is to be that worker.
function withConsole(status, fn) {
  const real = globalThis.fetch;
  globalThis.fetch = async () => new Response('', { status });
  return fn().finally(() => { globalThis.fetch = real; });
}

// The function memoises "is this cookie signed in" for 60s, so every test needs
// its own cookie or the previous test's verdict answers for it.
let cookieSeq = 0;
const freshCookie = () => `dash=t${++cookieSeq}`;

const call = (path, { db = stubDb(), method = 'GET', cookie = freshCookie(), bind = true, search = '' } = {}) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/cockpit/${path}${search}`, {
      method,
      headers: cookie ? { cookie } : {}
    }),
    env: bind ? { CONSOLE_DB: db } : {},
    params: { path: path.split('/').filter(Boolean) }
  });

const body = async (res) => JSON.parse(await res.text());

test('an unbound CONSOLE_DB is a 503 that names the binding, not a 401', async () => {
  // Checked BEFORE the session, on purpose: a misconfigured Pages project must
  // not tell the operator to log in again forever.
  const res = await call('now', { bind: false, cookie: null });
  assert.equal(res.status, 503);
  assert.match((await body(res)).error, /CONSOLE_DB is not bound/);
});

test('no cookie is 403 unauthorized, in the shape src/api.js already handles', async () => {
  const res = await withConsole(200, () => call('now', { cookie: null }));
  assert.equal(res.status, 403);
  assert.deepEqual(await body(res), { error: 'unauthorized' });
});

test('a cookie the console worker rejects is 403, and the read never happens', async () => {
  const db = stubDb();
  const res = await withConsole(403, () => call('now', { db }));
  assert.equal(res.status, 403);
  assert.equal(db.seenSql.length, 0, 'no SQL may run for an unauthenticated caller');
});

test('an unreachable console is a refusal, not a grant', async () => {
  const real = globalThis.fetch;
  globalThis.fetch = async () => { throw new Error('network down'); };
  try {
    const res = await call('now');
    assert.equal(res.status, 403);
  } finally {
    globalThis.fetch = real;
  }
});

test('every write verb is refused — these views cannot mint a command', async () => {
  for (const method of ['POST', 'PUT', 'PATCH', 'DELETE']) {
    const db = stubDb();
    const res = await withConsole(200, () => call('now', { db, method }));
    assert.equal(res.status, 405, method);
    assert.equal(db.seenSql.length, 0, `${method} must not reach the database`);
  }
});

test('/now carries the boards, what is building, the ticks and the feed', async () => {
  const db = stubDb();
  const res = await withConsole(200, () => call('now', { db }));
  assert.equal(res.status, 200);
  const d = await body(res);
  assert.equal(d.boards[0].project, 'project-3');
  assert.equal(d.active_builds[0].stage, 'qa');
  assert.equal(d.recent_runs[0].id, 8733);
  assert.equal(d.events[0].type, 'pr_review');
  assert.deepEqual(d.needs, { alerts: 11, commands: 101, builds: 94, proposals: 23, total: 229 });
  // The feed is filtered, so it has to say what it dropped.
  assert.deepEqual(d.events_excluding, ['flags', 'fleet_status', 'webhook']);
  assert.ok(d.generated_at);
  // Read-only by construction.
  for (const sql of db.seenSql) assert.match(sql.trim(), /^SELECT/, sql.slice(0, 60));
});

test('"building now" excludes the parked stages, or it reports work that is not happening', async () => {
  // 101 builds are unmerged and non-terminal in the real ledger, but 94 of them
  // are parked or sitting on an unmerged PR. Calling those "in flight" would
  // report a fleet doing ten times the work it is, so the exclusion list is
  // asserted on its BINDS, not on the prose of the SQL.
  const db = stubDb();
  await withConsole(200, () => call('now', { db }));
  const inFlight = db.seen.find((q) => q.sql.includes('stage NOT IN'));
  assert.ok(inFlight, 'the in-flight query must exist');
  for (const stage of ['pr_merged', 'tier2_sweep_merged', 'stale', 'plan_blocked', 'plan_deferred', 'plan_stale', 'plan_malformed', 'pr_created']) {
    assert.ok(inFlight.binds.includes(stage), `${stage} must be excluded from "building now"`);
  }
  // And the same stages, minus the finished ones, are what NEEDS collects.
  const counts = db.seen.find((q) => q.sql.includes('AS alerts,'));
  assert.deepEqual(counts.binds, ['plan_blocked', 'plan_deferred', 'plan_stale', 'plan_malformed', 'pr_created']);
});

test('/needs answers four lists plus its own counts', async () => {
  const res = await withConsole(200, () => call('needs'));
  assert.equal(res.status, 200);
  const d = await body(res);
  assert.equal(d.alerts[0].id, 4284);
  assert.equal(d.commands[0].status, 'dead_letter');
  assert.equal(d.builds[0].stage, 'pr_created');
  assert.equal(d.proposals[0].status, 'gate_pending');
  assert.equal(d.counts.total, 229);
  assert.equal(d.project, null);
});

test('/needs?project= scopes every list AND the counts strip above them', async () => {
  // Real D1 caught this: scoped lists under an unscoped strip meant project-3
  // showed 9 rows below a headline of 229, and the bigger number is the one
  // people read.
  const db = stubDb();
  await withConsole(200, () => call('needs', { db, search: '?project=project-3' }));
  const scoped = db.seen.filter((q) => q.sql.includes('project = ?'));
  assert.equal(scoped.length, 6, 'five lists (BH-3569 adds unfinished_builds) plus the counts');
  const counts = db.seen.find((q) => q.sql.includes('AS alerts,'));
  assert.equal((counts.sql.match(/AND project = \?/g) || []).length, 4,
    'each of the four sub-counts must carry the project scope');
  assert.deepEqual(counts.binds,
    ['project-3', 'project-3', 'plan_blocked', 'plan_deferred', 'plan_stale', 'plan_malformed', 'pr_created',
     'project-3', 'project-3']);
});

test('a list that hit the row cap says so, so the table is not read as everything', async () => {
  const many = (n, row) => Array.from({ length: n }, (_, i) => ({ ...row, id: i + 1 }));
  const db = stubDb({
    ...defaultRows,
    'FROM alerts': many(200, { akey: 'a', ts: 'x', project: 'p', line: 'l' }),
    'FROM commands': many(3, { ckey: 'k', type: 't', project: 'p', status: 'failed', result: 'r' })
  });
  const d = await body(await withConsole(200, () => call('needs', { db })));
  assert.equal(d.truncated.alerts, true);
  assert.equal(d.truncated.commands, false);
});

test('an absent limit falls back rather than clamping to one row', async () => {
  // Number(null) is 0, not NaN: before this was checked, /now answered with a
  // single run and a single event, and /history with a single run per page.
  const db = stubDb();
  await withConsole(200, () => call('now', { db }));
  const runs = db.seen.find((q) => q.sql.includes('FROM runs ORDER BY id DESC'));
  assert.deepEqual(runs.binds, [25]);
  const feed = db.seen.find((q) => q.sql.includes('FROM events'));
  assert.equal(feed.binds[feed.binds.length - 1], 40);

  const db2 = stubDb();
  await withConsole(200, () => call('history', { db: db2 }));
  const page = db2.seen.find((q) => q.sql.includes('FROM runs WHERE'));
  assert.equal(page.binds[page.binds.length - 1], 100);
});

test('a limit is still clamped at both ends', async () => {
  for (const [asked, expected] of [['0', 1], ['9999', 500], ['nonsense', 100], ['12', 12]]) {
    const db = stubDb();
    await withConsole(200, () => call('history', { db, search: `?limit=${asked}` }));
    const page = db.seen.find((q) => q.sql.includes('FROM runs WHERE'));
    assert.equal(page.binds[page.binds.length - 1], expected, `limit=${asked}`);
  }
});

test('/history pages on the run id, and its total describes the filter', async () => {
  const db = stubDb();
  const res = await withConsole(200, () => call('history', { db, search: '?project=project-3&limit=2' }));
  assert.equal(res.status, 200);
  const d = await body(res);
  assert.equal(d.total, 8736);
  assert.equal(d.failed, 46);
  // A full page hands back a cursor; the next call settles whether more exist.
  assert.equal(d.next_cursor, 8730);
  assert.ok(db.seenSql.some((s) => s.includes('ORDER BY id DESC')));
  assert.ok(!db.seenSql.some((s) => s.includes('OFFSET')), 'never OFFSET-paginate a growing table');
});

test('a short page reports no cursor rather than looping forever', async () => {
  const res = await withConsole(200, () => call('history', { search: '?limit=50' }));
  assert.equal((await body(res)).next_cursor, null);
});

test('/history/builds is its own route with its own totals', async () => {
  const res = await withConsole(200, () => call('history/builds'));
  assert.equal(res.status, 200);
  const d = await body(res);
  assert.equal(d.total, 817);
  assert.equal(d.merged, 518);
  assert.equal(d.builds[0].ticket_key, 'TK-791');
});

test('/project/<name> carries the whole-ledger totals and the company map', async () => {
  const res = await withConsole(200, () => call('project/project-3'));
  assert.equal(res.status, 200);
  const d = await body(res);
  assert.equal(d.project, 'project-3');
  assert.equal(d.run_stats.runs, 2350);
  assert.equal(d.run_stats.failed, 4);
  assert.deepEqual(d.run_stats.by_kind, [{ kind: 'triage', n: 2346 }]);
  assert.equal(d.company_map.bytes, 16752);
  assert.equal(d.board.project, 'project-3');
});

test('a project with no rows anywhere is a 404, not a project with zero of everything', async () => {
  const res = await withConsole(200, () => call('project/never-existed', { db: stubDb({}) }));
  assert.equal(res.status, 404);
  assert.match((await body(res)).error, /no rows for project/);
});

test('a project name outside the harness character set never reaches a query', async () => {
  for (const bad of ['project-3%20os', "o'brien", 'a/b']) {
    const db = stubDb();
    const res = await withConsole(200, () => call(`project/${bad}`, { db }));
    assert.equal(res.status, bad.includes('/') ? 404 : 400, bad);
    assert.equal(db.seenSql.length, 0, bad);
  }
});

test('a bad filter is a 400, not a silently wider result', async () => {
  const cases = [
    ['history', '?outcome=maybe', /outcome must be ok or failed/],
    ['history', '?before=abc', /before must be a run id/],
    ['history', '?project=bad%20name', /bad project/],
    ['history', '?kind=not a kind', /bad kind/],
    ['history/builds', '?before=-x', /before must be a build id/],
    ['needs', '?project=bad%20name', /bad project/]
  ];
  for (const [path, search, re] of cases) {
    const db = stubDb();
    const res = await withConsole(200, () => call(path, { db, search }));
    assert.equal(res.status, 400, `${path}${search}`);
    assert.match((await body(res)).error, re);
    assert.equal(db.seenSql.length, 0, `${path}${search} must not query`);
  }
});

test('an unknown cockpit route is a 404 naming what was asked for', async () => {
  const res = await withConsole(200, () => call('nonsense'));
  assert.equal(res.status, 404);
  assert.match((await body(res)).error, /no such cockpit route: \/api\/cockpit\/nonsense/);
});

test('a D1 failure is a 502, distinguishable from being signed out', async () => {
  const broken = { prepare() { throw new Error('D1_ERROR: no such table'); } };
  const res = await withConsole(200, () => call('now', { db: broken }));
  assert.equal(res.status, 502);
  assert.match((await body(res)).error, /harness database read failed — D1_ERROR/);
});

test('nothing is cacheable — every answer rides a session', async () => {
  const res = await withConsole(200, () => call('now'));
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.equal(res.headers.get('content-type'), 'application/json');
});
