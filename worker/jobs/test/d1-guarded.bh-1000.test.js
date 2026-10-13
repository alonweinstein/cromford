import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';

// BH-1000 — a missing D1 table must be an ANSWER, not a 1101.
//
// THE INCIDENT (2026-09-19, 18:31–19:00Z). #785 gated 52 hub cron lanes behind
// `bin/hub-lease.sh check &&` and shipped `hub_lease` in schema.sql — which
// nothing applies. The worker deployed in minutes, every statement against the
// missing table threw, and Cloudflare turned the uncaught throw into an HTTP
// 500 (error 1101) with NO BODY. `bin/jobs-client.sh` reads a bodiless 500 as
// "worker unreachable", so the hub reported a transport outage for a schema
// problem, every gated lane skipped, and nothing paged. The `settings` table
// had been doing the same thing for three weeks: `GET /api/settings/<key>`
// answered 500, every knob reader silently ran on its code default.
//
// So the property under test is not "the route works" — it is what the route
// says when the TABLE IS NOT THERE. A client can act on
// `503 {"error":"hub_lease schema not applied"}`; it cannot act on a 1101.
//
// The DB here is a stub whose statements THROW, which is exactly the shape D1
// produces on an unapplied table. Everything is driven through the real
// `worker.fetch` (D2) — path spellings, bearer, body parsing and all — so
// deleting the guard at a call site fails a test here.

const SECRET = 'test-secret';

// A DB whose every statement throws `msg`, counting how many times a route
// reached for it. The count is the point of the 400 cases: a request that is
// refused on validation must never touch the database at all, so a broken
// table cannot change what a malformed request answers.
function throwingDb(msg) {
  const calls = [];
  const thrower = () => { throw new Error(msg); };
  return {
    calls,
    prepare(sql) {
      calls.push(sql);
      return { bind() { return this; }, first: thrower, run: thrower, all: thrower };
    },
  };
}

// The healthy side of the same routes, so "answers 503" cannot be satisfied by
// a guard that answers 503 always. Modelled loosely: only the fields the
// assertions below read.
function healthyDb(state) {
  return {
    prepare(sql) {
      const s = sql.replace(/\s+/g, ' ').trim();
      return {
        bind(...b) { this._b = b; return this; },
        async first() {
          if (/FROM hub_lease/.test(s)) return state.hubLease;
          if (/FROM settings WHERE key/.test(s)) return state.setting;
          return null;
        },
        async all() {
          if (/FROM settings/.test(s)) return { results: state.settings || [] };
          return { results: [] };
        },
        async run() {
          if (/^INSERT INTO hub_lease/.test(s)) { state.hubLease = state.afterWrite; return { meta: { changes: 1 } }; }
          if (/^UPDATE hub_lease/.test(s)) return { meta: { changes: 0 } };
          return { meta: { changes: 1 } };
        },
      };
    },
  };
}

function req(path, { method = 'GET', body, secret = SECRET } = {}) {
  const init = { method, headers: { authorization: `Bearer ${secret}` } };
  if (body !== undefined) {
    init.headers['content-type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  return new Request(`https://jobs.invalid${path}`, init);
}

async function call(request, db) {
  const res = await worker.fetch(request, { DB: db, HARNESS_SECRET: SECRET });
  let parsed = null;
  try { parsed = JSON.parse(await res.text()); } catch { parsed = null; }
  return { status: res.status, body: parsed };
}

// ── The incident shape, on every route that reads either table ──────────────
// Both path spellings for the lease: bin/hub-lease.sh ships /api/hub-lease and
// the console uses /api/hub/lease, and a guard on one spelling only would have
// left the 52 gated lanes exactly as blind as they were.
const MISSING_LEASE = [
  ['GET  /api/hub/lease', '/api/hub/lease', { method: 'GET' }],
  ['GET  /api/hub-lease', '/api/hub-lease', { method: 'GET' }],
  ['POST /api/hub/lease/renew', '/api/hub/lease/renew', { method: 'POST', body: { holder: 'box-hub', epoch: 3 } }],
  ['POST /api/hub-lease (renew)', '/api/hub-lease', { method: 'POST', body: { holder: 'box-hub', epoch: 3 } }],
];

// BH-2272: the legacy promote is RETIRED. It answers 410 without reaching D1 at
// all, so a missing table cannot turn it into a 503, or anything else.
for (const path of ['/api/hub/lease/promote', '/api/hub-lease/promote']) {
  test(`POST ${path} is 410 gone with the table missing, and never touches D1`, async () => {
    const db = throwingDb('D1_ERROR: no such table: hub_lease');
    const { status, body } = await call(req(path, { method: 'POST', body: { holder: 'box-hub' } }), db);
    assert.equal(status, 410);
    assert.equal(body.error, 'gone');
    assert.equal(body.use, '/api/hub/promote');
    assert.equal(db.calls.length, 0, `${path} touched D1: ${db.calls.join(' | ')}`);
  });
}

for (const [label, path, opts] of MISSING_LEASE) {
  test(`${label} answers 503 "hub_lease schema not applied" when the table is missing`, async () => {
    const db = throwingDb('D1_ERROR: no such table: hub_lease');
    const { status, body } = await call(req(path, opts), db);
    assert.equal(status, 503, `${label} must not 500 — a 1101 is what the incident was`);
    assert.equal(body.error, 'hub_lease schema not applied');
    // The reason travels: bin/jobs-client.sh logs JOBS_BODY verbatim, and an
    // empty detail would send an operator back to the worker logs.
    assert.match(String(body.detail), /no such table: hub_lease/);
    assert.ok(db.calls.length > 0, 'the route must actually have reached the table');
  });
}

const MISSING_SETTINGS = [
  ['GET  /api/settings', '/api/settings', { method: 'GET' }],
  ['GET  /api/settings/<key>', '/api/settings/gh_budget_min_remaining', { method: 'GET' }],
  ['PUT  /api/settings', '/api/settings', { method: 'PUT', body: { key: 'gh_budget_min_remaining', value: 900 } }],
];

for (const [label, path, opts] of MISSING_SETTINGS) {
  test(`${label} answers 503 "settings schema not applied" when the table is missing`, async () => {
    const db = throwingDb('D1_ERROR: no such table: settings');
    const { status, body } = await call(req(path, opts), db);
    assert.equal(status, 503, `${label} answered 500 for three weeks; it must answer 503 with a reason`);
    assert.equal(body.error, 'settings schema not applied');
    assert.match(String(body.detail), /no such table: settings/);
  });
}

// ── D10: classify narrowly ──────────────────────────────────────────────────
// A lock, a syntax error or a broken binding is NOT a missing table, and
// saying "schema not applied" to any of them would send the next operator to
// re-run a schema that is already there.
test('a D1 error that is not a missing table says "unavailable", never "schema not applied"', async () => {
  for (const [path, table] of [['/api/hub/lease', 'hub_lease'], ['/api/settings', 'settings']]) {
    const { status, body } = await call(req(path), throwingDb('D1_ERROR: database is locked'));
    assert.equal(status, 503);
    assert.equal(body.error, `${table} unavailable`);
    assert.match(String(body.detail), /database is locked/);
  }
});

test('the detail is bounded so a huge D1 message cannot become the response', async () => {
  const { body } = await call(req('/api/hub/lease'), throwingDb('D1_ERROR: ' + 'x'.repeat(5000)));
  assert.ok(String(body.detail).length <= 200, `detail was ${String(body.detail).length} chars`);
});

// ── The guard must not eat the healthy path ─────────────────────────────────
test('a healthy DB still answers 200 on the guarded routes', async () => {
  const lease = { id: 1, holder: 'box-hub', epoch: 4, expires_at: '2999-01-01T00:00:00Z', updated_at: '2026-09-19T18:00:00Z' };

  const get = await call(req('/api/hub/lease'), healthyDb({ hubLease: lease }));
  assert.equal(get.status, 200);
  assert.equal(get.body.lease.holder, 'box-hub');

  // Bootstrap: no row, UPDATEs change nothing, the INSERT wins → taken:true.
  const renew = await call(
    req('/api/hub/lease/renew', { method: 'POST', body: { holder: 'box-hub', epoch: 0 } }),
    healthyDb({ hubLease: null, afterWrite: lease }),
  );
  assert.equal(renew.status, 200);
  assert.equal(renew.body.taken, true);

  // BH-2272: the retired legacy promote is 410 on a healthy DB too.
  const promote = await call(
    req('/api/hub/lease/promote', { method: 'POST', body: { holder: 'box-2' } }),
    healthyDb({ hubLease: null, afterWrite: { ...lease, holder: 'box-2' } }),
  );
  assert.equal(promote.status, 410);
  assert.equal(promote.body.use, '/api/hub/promote');

  const row = { key: 'gh_budget_min_remaining', value: '800', updated_at: '2026-09-01T00:00:00Z' };
  // BH-5781: a non-lead single-key GET reads the table through the settings
  // snapshot (an all() over FROM settings), so the healthy DB lists the row too.
  const one = await call(req('/api/settings/gh_budget_min_remaining'), healthyDb({ setting: row, settings: [row] }));
  assert.equal(one.status, 200);
  assert.equal(one.body.source, 'settings');
  assert.equal(one.body.setting.value, '800');

  const list = await call(req('/api/settings'), healthyDb({ settings: [row] }));
  assert.equal(list.status, 200);
  assert.equal(list.body.settings.length, 1);

  const put = await call(
    req('/api/settings', { method: 'PUT', body: { key: 'gh_budget_min_remaining', value: 900 } }),
    healthyDb({ setting: { ...row, value: '900' } }),
  );
  assert.equal(put.status, 200);
  assert.equal(put.body.setting.value, '900');
});

// ── A broken table must not change what a BAD REQUEST answers ───────────────
// The validation sits above the first statement, so these stay 400 and never
// touch D1 — the property `worker/jobs/test/index.test.js` already pins for
// the lease, held here for both tables while the guard is in the way.
test('validation still answers 400 with zero DB calls, even with the table missing', async () => {
  const cases = [
    ['/api/hub/lease/renew', { method: 'POST', body: { holder: 'not a lane name!', epoch: 1 } }, 'hub_lease'],
    ['/api/hub/lease/renew', { method: 'POST', body: { holder: 'box-hub', epoch: -1 } }, 'hub_lease'],
    ['/api/settings/NOT_A_KEY', { method: 'GET' }, 'settings'],
    ['/api/settings', { method: 'PUT', body: { key: 'ok_key', value: null } }, 'settings'],
  ];
  for (const [path, opts, table] of cases) {
    const db = throwingDb(`D1_ERROR: no such table: ${table}`);
    const { status, body } = await call(req(path, opts), db);
    assert.equal(status, 400, `${opts.method} ${path} must stay a 400`);
    assert.equal(db.calls.length, 0, `${path} touched D1 before validating: ${db.calls.join(' | ')}`);
    assert.ok(body.error && !/schema not applied/.test(body.error), `${path} reported a schema problem for a caller bug`);
  }
});

// ── The bearer still comes first ────────────────────────────────────────────
test('an unauthorized caller gets 401, not a description of our schema', async () => {
  const db = throwingDb('D1_ERROR: no such table: hub_lease');
  const { status, body } = await call(req('/api/hub/lease', { secret: 'wrong' }), db);
  assert.equal(status, 401);
  assert.equal(body.error, 'unauthorized');
  assert.equal(db.calls.length, 0);
});
