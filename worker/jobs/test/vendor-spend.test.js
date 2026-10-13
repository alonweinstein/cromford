import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';

// POST/GET /api/metrics/vendor-spend — the non-Anthropic half of the bill
// (bin/vendor-spend-pull.sh, cost fix 5).
//
// ITS OWN FILE, and self-contained, because index.test.js is 150KB that five
// lanes are editing this week. Same stub shape as dora.test.js.
//
// WHAT IS PINNED HERE, and why each one is a SILENT failure if it breaks:
//   * an unmeasured vendor must land as NULL, never 0 — "we could not read it"
//     and "it cost nothing" are indistinguishable once one is spelled 0.00, and
//     it is always the first one that hides a bill;
//   * kind and status are a closed set, because they are the only thing telling
//     a reader whether a number is the invoice or our arithmetic;
//   * the write is an upsert on (vendor, ts) — an hourly producer that retries
//     must not double-count;
//   * the row's own vendor/ts are the key, never the server clock;
//   * the route sits behind the same bearer as every other metrics route.

const SECRET = 'test-secret';

function fakeDB(state) {
  const calls = [];
  const result = (sql, binds) => {
    calls.push({ sql: sql.replace(/\s+/g, ' ').trim(), binds });
    if (/FROM vendor_spend/.test(sql)) {
      let rows = state.vendorSpend || [];
      // The stub filters the way the route's SQL says it does, so a route that
      // stopped binding `vendor`/`since` cannot pass by handing back everything.
      if (/vendor=\?/.test(sql)) rows = rows.filter((r) => r.vendor === binds[0]);
      if (/ts>=\?/.test(sql)) rows = rows.filter((r) => String(r.ts) >= String(binds[binds.length - 1]));
      return { rows };
    }
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
  return { prepare: stmt, batch: async (xs) => xs, _calls: calls };
}

const call = (path, { method = 'GET', body, secret = SECRET, state = {} } = {}) => {
  const db = fakeDB(state);
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: {
      ...(secret === null ? {} : { authorization: `Bearer ${secret}` }),
      ...(body ? { 'content-type': 'application/json' } : {})
    },
    ...(body ? { body: JSON.stringify(body) } : {})
  });
  return worker.fetch(req, { DB: db, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null), db }));
};

const sqlOf = (db, re) => db._calls.filter((c) => re.test(c.sql));
const ROW = { vendor: 'openrouter', ts: '2026-09-14T13:00:00Z' };

test('a vendor spend row is keyed on the row itself, and needs both halves', async () => {
  assert.equal((await call('/api/metrics/vendor-spend', { method: 'POST', body: { ts: ROW.ts } })).status, 400);
  assert.equal((await call('/api/metrics/vendor-spend', { method: 'POST', body: { vendor: 'fly' } })).status, 400);

  const r = await call('/api/metrics/vendor-spend', {
    method: 'POST',
    state: { vendorSpend: [{ ...ROW, usd: 12.5 }] },
    body: { ...ROW, window_start: '2026-09-14T12:00:00Z', window_end: ROW.ts,
            usd: '12.5', kind: 'metered', status: 'ok', balance_usd: '281.23',
            cumulative_usd: '6868.77', note: 'credits endpoint', raw: '{"a":1}', actor: 'hub' }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.vendor_spend.usd, 12.5);
  const [w] = sqlOf(r.db, /INSERT INTO vendor_spend/);
  assert.match(w.sql, /ON CONFLICT\(vendor, ts\) DO UPDATE/);
  assert.equal(w.binds[0], 'openrouter');
  assert.equal(w.binds[1], ROW.ts);
  assert.equal(w.binds[4], 12.5);       // usd, coerced off a CSV cell
  assert.equal(w.binds[7], 281.23);     // balance_usd
});

test('a vendor we could not measure binds NULL, never 0', async () => {
  // THE ONE THAT MATTERS. xAI publishes no billing route; the row that says so
  // must not arrive as $0.00 of spend, which is also what a silent outage looks
  // like and is the shape nobody ever goes back and checks.
  const r = await call('/api/metrics/vendor-spend', {
    method: 'POST',
    body: { vendor: 'xai', ts: ROW.ts, usd: '', balance_usd: '', cumulative_usd: '',
            kind: 'computed', status: 'no-spend-endpoint', note: 'no billing route' }
  });
  assert.equal(r.status, 200);
  const [w] = sqlOf(r.db, /INSERT INTO vendor_spend/);
  assert.equal(w.binds[4], null);
  assert.equal(w.binds[7], null);
  assert.equal(w.binds[8], null);
  // ...and a genuine zero still stores as zero.
  const z = await call('/api/metrics/vendor-spend', {
    method: 'POST', body: { vendor: 'fly', ts: ROW.ts, usd: '0', kind: 'computed', status: 'ok' }
  });
  assert.equal(sqlOf(z.db, /INSERT INTO vendor_spend/)[0].binds[4], 0);
});

test('kind and status are a closed set', async () => {
  for (const bad of [{ kind: 'estimated' }, { kind: 'guess' }, { status: 'fine' }, { status: 'FAILED' }]) {
    const r = await call('/api/metrics/vendor-spend', { method: 'POST', body: { ...ROW, ...bad } });
    assert.equal(r.status, 400, `${JSON.stringify(bad)} was accepted`);
  }
  // Omitting them is allowed — an old producer must not start failing — and so
  // is every spelling the puller actually writes.
  for (const good of [{}, { kind: 'metered', status: 'ok' }, { kind: 'computed', status: 'no-spend-endpoint' },
                      { status: 'auth-failed' }, { status: 'error' }]) {
    const r = await call('/api/metrics/vendor-spend', { method: 'POST', body: { ...ROW, ...good } });
    assert.equal(r.status, 200, `${JSON.stringify(good)} was rejected`);
  }
});

test('an 8KB cap on raw survives a vendor that changes its mind', async () => {
  const r = await call('/api/metrics/vendor-spend', {
    method: 'POST', body: { ...ROW, raw: 'x'.repeat(200000) }
  });
  assert.equal(r.status, 200);
  assert.equal(sqlOf(r.db, /INSERT INTO vendor_spend/)[0].binds[10].length, 8192);
});

test('the readout filters by vendor and by since', async () => {
  const state = { vendorSpend: [
    { vendor: 'openrouter', ts: '2026-09-14T13:00:00Z', usd: 12.5 },
    { vendor: 'fly', ts: '2026-09-14T13:00:00Z', usd: 3.1 },
    { vendor: 'openrouter', ts: '2026-09-10T13:00:00Z', usd: 40 }
  ] };
  const all = await call('/api/metrics/vendor-spend', { state });
  assert.equal(all.body.vendor_spend.length, 3);

  const one = await call('/api/metrics/vendor-spend?vendor=openrouter', { state });
  assert.deepEqual(one.body.vendor_spend.map((r) => r.vendor), ['openrouter', 'openrouter']);

  const since = await call('/api/metrics/vendor-spend?vendor=openrouter&since=2026-09-14T00:00:00Z', { state });
  assert.equal(since.body.vendor_spend.length, 1);
  // Both filters bound as PARAMETERS, never interpolated: `vendor` arrives from
  // a shell script on a box.
  const [q] = sqlOf(since.db, /FROM vendor_spend/);
  assert.deepEqual(q.binds, ['openrouter', '2026-09-14T00:00:00Z']);
  assert.match(q.sql, /ORDER BY ts DESC/);
});

test('vendor-spend is behind the same bearer as every other metrics route', async () => {
  assert.equal((await call('/api/metrics/vendor-spend', { secret: null })).status, 401);
  assert.equal((await call('/api/metrics/vendor-spend', { method: 'POST', body: ROW, secret: null })).status, 401);
});
