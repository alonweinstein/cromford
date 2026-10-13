import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest, closedIssueKeys, _resetClosedCache, _resetHeldCache } from '../functions/api/dash/kanban/pipeline.js';

// BH-2206. closedIssueKeys read ONE page of ledgers(kind=issue_state) — the
// newest 1000 rows — so a closure older than that fell off the set and its dead
// card came back on the board. It now walks the ledger with `before=`, and these
// pin how:
//   - every page is read, and a closure on page 2 or 3 is hidden,
//   - a tie at the page boundary (updated_at is second-resolution, nowIso) does
//     not drop the rows that spilled past the page,
//   - the walk is capped, and hitting the cap says `complete: false`,
//   - a failure on ANY page hides nothing and is not cached,
//   - a walk that cannot make progress stops and says `complete: false`,
//   - one walk per isolate per minute.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const isJobs = (u) => u.startsWith(JOBS);
// The issue_state walk only: the same request also makes one ticket_hold read (BH-2326.2).
const isClosedRead = (u) => u.startsWith(`${JOBS}/api/ledger?kind=issue_state`);
const LIMIT = 1000;
const MAX_PAGES = 10;

// updated_at exactly as the jobs worker writes it (lib/http.js nowIso: seconds,
// no millis), newest first.
const BASE = Date.UTC(2026, 8, 24, 12, 0, 0);
const ts = (i) => new Date(BASE - i * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const row = (key, status, updated_at) => ({ kind: 'issue_state', key, status, updated_at });

// A faithful model of worker/jobs/src/routes/ledger.js: `updated_at < before`
// as a plain string compare, newest first, `limit` rows.
function ledgerAnswer(rows, u) {
  const p = new URL(u).searchParams;
  const before = p.get('before');
  const limit = Number(p.get('limit'));
  return jsonRes({ ledgers: rows.filter((r) => !before || r.updated_at < before).slice(0, limit) });
}

function withFetch(route, fn) {
  const real = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    const a = route(String(url), calls);
    if (a instanceof Error) throw a;
    return a;
  };
  _resetClosedCache();
  _resetHeldCache();
  return Promise.resolve(fn(calls)).finally(() => { globalThis.fetch = real; _resetClosedCache(); _resetHeldCache(); });
}

const jsonRes = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

const req = () => new Request('https://console.example/api/dash/kanban/pipeline', { headers: { cookie: 'dash=tok' } });
const ENV = { HARNESS_SECRET: 's' };

const build = (id, project, ticket, stage = 'plan_blocked') => ({ id, project, ticket, stage, age_min: 60 });
const payload = (dead) => ({
  columns: { queued: [], building: [], merge_queue: [], review: [], merged_deployed: [], dead_failed: dead },
  counts: { queued: 0, building: 0, merge_queue: 0, review: 0, merged_deployed: 0, dead_failed: dead.length },
  building_stale: 0,
  snapshot_age_min: 1
});

// Filler keys never collide with the keys the cards carry.
const filler = (n, at = ts) => Array.from({ length: n }, (_, i) => row(`project-5#${100000 + i}`, 'open', at(i)));

test('A. closures on page 2 and page 3 are hidden through onRequest, walk complete', () => {
  const rows = filler(2500);
  rows[1700] = row('project-5#551', 'closed', ts(1700));
  rows[2400] = row('project-5#900', 'closed', ts(2400));
  const dead = [build(1, 'project-5', 'TK-551'), build(2, 'project-5', 'TK-900'), build(3, 'project-5', 'TK-600')];
  return withFetch((u) => (isJobs(u) ? ledgerAnswer(rows, u) : jsonRes(payload(dead))), async (calls) => {
    const body = await (await onRequest({ request: req(), env: ENV })).json();
    assert.deepEqual(body.columns.dead_failed.map((c) => c.id), [3]);
    assert.equal(body.dead_closed, 2);
    assert.equal(body.dead_closed_known, true);
    assert.equal(body.dead_closed_complete, true);
    const jobs = calls.filter((c) => isClosedRead(c.url));
    assert.equal(jobs.length, 3);
    assert.equal(jobs[0].url, `${JOBS}/api/ledger?kind=issue_state&limit=1000`);
    // Page 2's cursor is page 1's last updated_at, made inclusive.
    assert.equal(new URL(jobs[1].url).searchParams.get('before'), `${ts(999)}~`);
    assert.equal(new URL(jobs[1].url).searchParams.get('limit'), '1000');
    for (const j of jobs) assert.equal(j.init.headers.authorization, 'Bearer s');
  });
});

test('B. cap: a ledger that never ends stops at the page cap and says complete: false', () => {
  const rows = filler(30000);
  return withFetch((u) => ledgerAnswer(rows, u), async (calls) => {
    const out = await closedIssueKeys(ENV);
    assert.equal(out.complete, false);
    assert.equal(calls.length, MAX_PAGES);
    // Every row the capped walk did read still counts.
    assert.ok(out.closed instanceof Set);
  });
});

test('B2. cap reaches the board as dead_closed_complete: false', () => {
  const rows = filler(30000);
  rows[5000] = row('project-5#551', 'closed', ts(5000));
  const dead = [build(1, 'project-5', 'TK-551')];
  return withFetch((u) => (isJobs(u) ? ledgerAnswer(rows, u) : jsonRes(payload(dead))), async (calls) => {
    const body = await (await onRequest({ request: req(), env: ENV })).json();
    assert.equal(body.dead_closed_known, true);
    assert.equal(body.dead_closed_complete, false);
    assert.equal(body.dead_closed, 1);
    assert.equal(calls.filter((c) => isClosedRead(c.url)).length, MAX_PAGES);
  });
});

test('C. tie at the page boundary does not drop a closed key', () => {
  // Rows 998-1003 (1-based) share one second; the page cuts after row 1000 and
  // the closed row is 1002, past the edge.
  const T = ts(997);
  const rows = [...filler(997), ...Array.from({ length: 6 }, (_, i) => row(`project-5#${200000 + i}`, 'open', T))];
  rows[1001] = row('project-5#551', 'closed', T);
  return withFetch((u) => ledgerAnswer(rows, u), async (calls) => {
    const out = await closedIssueKeys(ENV);
    assert.ok(out.closed.has('project-5#551'), 'closure past the tie edge is in the set');
    assert.equal(out.complete, true);
    assert.equal(calls.length, 2);
    assert.equal(new URL(calls[1].url).searchParams.get('before'), `${T}~`);
  });
});

test('C2. tie rows re-read on page 2 are counted once on the board', () => {
  const T = ts(997);
  const rows = [...filler(997), ...Array.from({ length: 6 }, (_, i) => row(`project-5#${200000 + i}`, 'open', T))];
  rows[998] = row('project-5#551', 'closed', T);   // on page 1 AND re-read on page 2
  rows[1001] = row('project-5#900', 'closed', T);  // only on page 2
  const dead = [build(1, 'project-5', 'TK-551'), build(2, 'project-5', 'TK-900'), build(3, 'project-5', 'TK-600')];
  return withFetch((u) => (isJobs(u) ? ledgerAnswer(rows, u) : jsonRes(payload(dead))), async () => {
    const body = await (await onRequest({ request: req(), env: ENV })).json();
    assert.deepEqual(body.columns.dead_failed.map((c) => c.id), [3]);
    assert.equal(body.dead_closed, 2);
    assert.equal(body.counts.dead_failed, 1);
    assert.equal(body.dead_closed_complete, true);
  });
});

for (const [label, answer] of [
  ['500', () => jsonRes({ error: 'x' }, 500)],
  ['a thrown fetch', () => new Error('network')],
  ['{}', () => jsonRes({})]
]) {
  test(`D. page 2 answering ${label} fails open: null, not cached, board hides nothing`, async () => {
    const rows = filler(1500);
    rows[1200] = row('project-5#551', 'closed', ts(1200));
    const page2 = (u) => new URL(u).searchParams.has('before');
    await withFetch((u) => (page2(u) ? answer() : ledgerAnswer(rows, u)), async (calls) => {
      assert.equal(await closedIssueKeys(ENV), null);
      assert.equal(calls.length, 2);
      assert.equal(await closedIssueKeys(ENV), null);
      assert.equal(calls.length, 4, 'a failed walk is not cached');
    });
    const dead = [build(1, 'project-5', 'TK-551'), build(3, 'project-5', 'TK-600')];
    await withFetch((u) => (!isJobs(u) ? jsonRes(payload(dead)) : page2(u) ? answer() : ledgerAnswer(rows, u)), async () => {
      const body = await (await onRequest({ request: req(), env: ENV })).json();
      assert.deepEqual(body.columns.dead_failed.map((c) => c.id), [1, 3]);
      assert.equal(body.dead_closed_known, false);
      assert.equal(body.dead_closed, undefined);
    });
  });
}

test('E. cache: a two-page walk is read once per minute', () =>
  withFetch((u) => ledgerAnswer(filler(1500), u), async (calls) => {
    const a = await closedIssueKeys(ENV);
    const b = await closedIssueKeys(ENV);
    assert.equal(calls.length, 2);
    assert.equal(a, b);
    assert.equal(a.complete, true);
  }));

test('F. no progress: a full page of one second stops and says complete: false', () => {
  const rows = filler(1500, () => ts(0));
  return withFetch((u) => ledgerAnswer(rows, u), async (calls) => {
    const out = await closedIssueKeys(ENV);
    assert.equal(out.complete, false);
    assert.ok(calls.length <= 2, `stopped after ${calls.length} fetches`);
  });
});

test('G. a full page with no updated_at cursor stops and says complete: false', () => {
  const rows = Array.from({ length: 1000 }, (_, i) => ({ kind: 'issue_state', key: `project-5#${i}`, status: 'closed' }));
  return withFetch(() => jsonRes({ ledgers: rows }), async (calls) => {
    const out = await closedIssueKeys(ENV);
    assert.equal(out.complete, false);
    assert.equal(out.closed.size, 1000);
    assert.equal(calls.length, 1);
  });
});

test('H. a key keeps the status of its newest row', () => {
  const rows = [row('project-5#551', 'open', ts(0)), ...filler(1200).slice(1)];
  rows[1100] = row('project-5#551', 'closed', ts(1100));
  return withFetch((u) => ledgerAnswer(rows, u), async () => {
    const out = await closedIssueKeys(ENV);
    assert.equal(out.closed.has('project-5#551'), false);
    assert.equal(out.complete, true);
  });
});
