import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';

// GET /api/metrics/llm-spend — the aggregate the pre-call spend gate reads
// (BH-1141 phase 2), driven through the worker's real fetch handler.
//
// WHY IT IS AN AGGREGATE AND NOT THE EXISTING ROWS ROUTE. bin/lib/llm-gate.sh
// asks "what has this lane spent today" before every model call. The raw-rows
// route caps a page at 2000 rows, so a busy lane's sum would silently come back
// short — and a cap computed from a truncated sum is a cap that never fires,
// which is indistinguishable in every log from no cap at all. SUM() in SQLite
// is one row over the whole window, whatever the window holds.
//
// WHAT IS PROVEN HERE, given D1 is stubbed by SQL pattern: the JavaScript
// decisions — the bearer, which filters reach the WHERE, that `since` defaults
// to the CURRENT UTC DAY rather than to all of history (a cap against
// all-of-history spend would refuse the fleet on day one), that refusals are
// counted separately from billed calls, and that a NULL SUM over an empty
// window answers 0 rather than null (a null would make the gate's numeric
// compare fail open forever without saying so). The SQL is proven by the
// deploy's own smoke run against real D1.

const SECRET = 'test-secret';

function fakeDB(state) {
  const calls = [];
  const result = (sql, binds) => {
    calls.push({ sql: sql.replace(/\s+/g, ' ').trim(), binds });
    if (/PRAGMA table_info\(cost_rows\)/.test(sql)) {
      const cols = state.costRowsCols || [
        'box', 'row_hash', 'line_no', 'ts', 'host', 'project', 'stage', 'runner', 'model',
        'rc', 'duration_s', 'input_toks', 'output_toks', 'cache_read', 'cache_write',
        'cost_usd', 'billing_mode', 'auth_fp', 'auth_account',
        'session_id', 'row_source', 'result_usd', 'ticket', 'job_id', 'pr', 'run_id',
        'inserted_at'];
      return { rows: cols.map((name) => ({ name })) };
    }
    if (/FROM cost_rows/.test(sql)) return { rows: state.agg ? [state.agg] : [] };
    return { rows: [] };
  };
  const stmt = (sql) => ({
    bind: (...binds) => ({
      first: async () => result(sql, binds).rows[0] || null,
      all: async () => ({ results: result(sql, binds).rows }),
      run: async () => { result(sql, binds); return { meta: { changes: 1 } }; }
    }),
    first: async () => result(sql, []).rows[0] || null,
    all: async () => ({ results: result(sql, []).rows }),
    run: async () => { result(sql, []); return { meta: { changes: 1 } }; }
  });
  return { prepare: stmt, batch: async (s) => s, _calls: calls };
}

const call = async (path, { state = {}, secret = SECRET } = {}) => {
  const db = fakeDB(state);
  const headers = {};
  if (secret) headers.authorization = `Bearer ${secret}`;
  const res = await worker.fetch(new Request(`https://w.example${path}`, { headers }),
    { DB: db, HARNESS_SECRET: SECRET });
  let body = null;
  try { body = await res.json(); } catch { body = null; }
  return { status: res.status, body, db };
};

const sqlOf = (db, re) => db._calls.filter((c) => re.test(c.sql));

test('GET /api/metrics/llm-spend sums the day and counts refusals separately', async () => {
  const r = await call('/api/metrics/llm-spend?stage=triage&project=alert-triage',
    { state: { agg: { usd: 12.5, calls: 9, refused: 2 } } });
  assert.equal(r.status, 200);
  assert.equal(r.body.usd, 12.5);
  assert.equal(r.body.calls, 9);
  // A refusal is a zero-cost row, so it lands in `calls` too — but a lane being
  // STOPPED and a lane being quiet are different events, and an operator has to
  // be able to tell them apart from this one number.
  assert.equal(r.body.refused, 2);

  const [q] = sqlOf(r.db, /SUM\(COALESCE\(cost_usd,0\)\)/);
  assert.ok(q, 'the route must SUM cost_usd, not page through rows');
  assert.match(q.sql, /FROM cost_rows/);
  assert.match(q.sql, /stage=\?1/);
  assert.match(q.sql, /project=\?2/);
  assert.match(q.sql, /ts>=\?3/);
  assert.equal(q.binds[0], 'triage');
  assert.equal(q.binds[1], 'alert-triage');
  // `since` defaults to THIS UTC day's midnight. A cap compared against
  // all-of-history spend refuses every lane the day it is set.
  assert.match(q.binds[2], /^\d{4}-\d{2}-\d{2}T00:00:00Z$/);
  assert.equal(r.body.since, q.binds[2]);
});

test('an explicit since/until window is honoured, and the filters are optional', async () => {
  const r = await call('/api/metrics/llm-spend?since=2026-09-01T00:00:00Z&until=2026-09-02T00:00:00Z',
    { state: { agg: { usd: 1, calls: 1, refused: 0 } } });
  assert.equal(r.status, 200);
  const [q] = sqlOf(r.db, /SUM\(COALESCE\(cost_usd,0\)\)/);
  assert.deepEqual(q.binds, ['2026-09-01T00:00:00Z', '2026-09-02T00:00:00Z']);
  assert.match(q.sql, /ts>=\?1/);
  assert.match(q.sql, /ts<=\?2/);
  assert.doesNotMatch(q.sql, /stage=/);
});

test('an empty window answers 0, never null', async () => {
  // SUM() over no rows is NULL in SQLite. The gate compares this number and
  // treats anything non-numeric as "not known" — which fails OPEN. A route that
  // returns null for a quiet lane would therefore disable the cap on exactly
  // the lanes it is cheapest to guard, silently.
  const r = await call('/api/metrics/llm-spend?stage=triage',
    { state: { agg: { usd: null, calls: 0, refused: null } } });
  assert.equal(r.status, 200);
  assert.equal(r.body.usd, 0);
  assert.equal(r.body.calls, 0);
  assert.equal(r.body.refused, 0);
});

test('a row_source filter narrows to the refusals themselves', async () => {
  const r = await call('/api/metrics/llm-spend?row_source=refused',
    { state: { agg: { usd: 0, calls: 4, refused: 4 } } });
  assert.equal(r.status, 200);
  const [q] = sqlOf(r.db, /SUM\(COALESCE\(cost_usd,0\)\)/);
  assert.match(q.sql, /row_source=\?1/);
  assert.equal(q.binds[0], 'refused');
});

test('llm-spend is behind the same bearer as every other metrics route', async () => {
  const r = await call('/api/metrics/llm-spend', { secret: null });
  assert.equal(r.status, 401);
});
