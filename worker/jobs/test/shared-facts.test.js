import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';

// BH-1043 — the two facts every box used to keep its own copy of:
// `account_leases` (how many builds an account is carrying) and `gh_budget`
// (how much of a shared token's rate budget is left).
//
// D1 IS MODELLED, NOT STUBBED, and for the same reason the hub lease is:
// WHICH compare-and-swap wins is the entire feature. A stub answering
// `changes:1` for every INSERT would pass a worker that never checks the cap —
// which is precisely the bug, since the per-box file version also always said
// yes. So the claim statement is PARSED and evaluated against the fixture rows:
// the cap subquery is counted for real, its predicates are applied for real,
// and an unmodelled predicate throws rather than passing quietly.
const SECRET = 'test-secret';
// A fixed anchor: nothing here reads the wall clock, so no case can pick its
// own red day. # determinism: ok fixtures are pinned, the worker's own `t` is
// the only live stamp and every assertion below is relative to it.
const T0 = Date.parse('2026-09-20T12:00:00Z');
const iso = (msFromT0) => new Date(T0 + msFromT0).toISOString().replace(/\.\d{3}Z$/, 'Z');

const cmp = (a, b) => (String(a) < String(b) ? -1 : String(a) > String(b) ? 1 : 0);
function bindVal(tok, binds) {
  const m = /^\?(\d+)$/.exec(String(tok).trim());
  if (m) return binds[Number(m[1]) - 1];
  return Number(String(tok).trim());
}
// Every predicate that is PRESENT is applied; anything this does not understand
// throws, so a statement that quietly grows a new condition cannot pass here
// until the model knows what it means.
function evalPreds(row, where, binds) {
  for (const pred of where.split(' AND ').map((x) => x.trim())) {
    const m = /^(\w+)\s*(<>|<=|>=|=|>|<)\s*(\?\d+)$/.exec(pred);
    if (!m) throw new Error(`unmodelled predicate: ${pred}`);
    const [, col, op, tok] = m;
    const want = bindVal(tok, binds);
    const got = row[col];
    let good;
    switch (op) {
      case '=':  good = got === want; break;
      case '<>': good = got !== want; break;
      case '>':  good = cmp(got, want) > 0; break;
      case '<':  good = cmp(got, want) < 0; break;
      case '<=': good = cmp(got, want) <= 0; break;
      case '>=': good = cmp(got, want) >= 0; break;
      default:   throw new Error(`unmodelled operator: ${op}`);
    }
    if (!good) return false;
  }
  return true;
}

function accountLeaseWrite(state, sql, binds) {
  const rows = state.leases || (state.leases = []);
  let m;
  if ((m = /^DELETE FROM account_leases WHERE (.+)$/.exec(sql))) {
    const doomed = rows.filter((r) => evalPreds(r, m[1], binds));
    state.leases = rows.filter((r) => !doomed.includes(r));
    return doomed.length;
  }
  m = /^INSERT INTO account_leases \(([^)]*)\) SELECT ([^ ]+) WHERE \(SELECT COUNT\(\*\) FROM account_leases WHERE (.+?)\) < (\?\d+) ON CONFLICT\(account, machine_id\) DO UPDATE SET (.+)$/.exec(sql);
  if (!m) throw new Error(`unmodelled account_leases statement: ${sql}`);
  const cols = m[1].split(',').map((c) => c.trim());
  const vals = m[2].split(',');
  const incoming = {};
  cols.forEach((c, i) => { incoming[c] = bindVal(vals[i], binds); });
  // THE CAP, COUNTED THE WAY THE STATEMENT COUNTS IT. Not a shortcut: if the
  // worker ever drops `machine_id<>?2`, a machine renewing its own lease at a
  // full cap starts refusing itself, and case 4 below goes red.
  const live = rows.filter((r) => evalPreds(r, m[3], binds)).length;
  const cap = bindVal(m[4], binds);
  if (!(live < cap)) return 0;   // the SELECT yields no row: nothing is written
  const at = rows.findIndex((r) => r.account === incoming.account && r.machine_id === incoming.machine_id);
  if (at < 0) { rows.push({ ...incoming }); return 1; }
  for (const asg of m[5].split(',').map((x) => x.trim())) {
    const a = /^(\w+)=excluded\.(\w+)$/.exec(asg);
    if (!a) throw new Error(`unmodelled conflict assignment: ${asg}`);
    rows[at][a[1]] = incoming[a[2]];
  }
  return 1;
}

function ghBudgetWrite(state, sql, binds) {
  const rows = state.budget || (state.budget = []);
  const m = /^INSERT INTO gh_budget \(([^)]*)\) VALUES \(([^)]*)\) ON CONFLICT\(fingerprint\) DO UPDATE SET (.+?) WHERE excluded\.fetched_at >= gh_budget\.fetched_at$/.exec(sql);
  if (!m) throw new Error(`unmodelled gh_budget statement: ${sql}`);
  const cols = m[1].split(',').map((c) => c.trim());
  const vals = m[2].split(',');
  const incoming = {};
  cols.forEach((c, i) => { incoming[c] = bindVal(vals[i], binds); });
  const at = rows.findIndex((r) => r.fingerprint === incoming.fingerprint);
  if (at < 0) { rows.push({ ...incoming }); return 1; }
  // MONOTONIC. An older reading arriving late must not raise `remaining` back
  // up, or the low-budget guard reads a countdown that goes backwards.
  if (!(Number(incoming.fetched_at) >= Number(rows[at].fetched_at))) return 0;
  for (const asg of m[3].split(',').map((x) => x.trim())) {
    const a = /^(\w+)=excluded\.(\w+)$/.exec(asg);
    if (!a) throw new Error(`unmodelled gh_budget assignment: ${asg}`);
    rows[at][a[1]] = incoming[a[2]];
  }
  return 1;
}

function fakeDB(state) {
  const calls = [];
  const read = (sql, binds) => {
    if (/^SELECT COUNT\(\*\) AS n FROM account_leases WHERE (.+)$/.test(sql)) {
      const w = /^SELECT COUNT\(\*\) AS n FROM account_leases WHERE (.+)$/.exec(sql)[1];
      return [{ n: (state.leases || []).filter((r) => evalPreds(r, w, binds)).length }];
    }
    if (/^SELECT account, COUNT\(\*\) AS n FROM account_leases WHERE (.+?) GROUP BY account/.test(sql)) {
      const w = /^SELECT account, COUNT\(\*\) AS n FROM account_leases WHERE (.+?) GROUP BY account/.exec(sql)[1];
      const by = new Map();
      for (const r of (state.leases || []).filter((x) => evalPreds(x, w, binds))) {
        by.set(r.account, (by.get(r.account) || 0) + 1);
      }
      return [...by.entries()].sort((a, b) => cmp(a[0], b[0])).map(([account, n]) => ({ account, n }));
    }
    if (/^SELECT \* FROM account_leases WHERE (.+?) ORDER BY machine_id ASC/.test(sql)) {
      const w = /^SELECT \* FROM account_leases WHERE (.+?) ORDER BY machine_id ASC/.exec(sql)[1];
      return (state.leases || []).filter((r) => evalPreds(r, w, binds))
        .sort((a, b) => cmp(a.machine_id, b.machine_id)).map((r) => ({ ...r }));
    }
    if (/^SELECT \* FROM gh_budget WHERE fingerprint=\?1$/.test(sql)) {
      return (state.budget || []).filter((r) => r.fingerprint === binds[0]).map((r) => ({ ...r }));
    }
    throw new Error(`unmodelled read: ${sql}`);
  };
  const stmt = (rawSql) => ({
    bind: (...binds) => ({
      first: async () => {
        const sql = rawSql.replace(/\s+/g, ' ').trim();
        calls.push({ sql, binds });
        return read(sql, binds)[0] || null;
      },
      all: async () => {
        const sql = rawSql.replace(/\s+/g, ' ').trim();
        calls.push({ sql, binds });
        return { results: read(sql, binds) };
      },
      run: async () => {
        const sql = rawSql.replace(/\s+/g, ' ').trim();
        calls.push({ sql, binds });
        if (/account_leases/.test(sql)) return { meta: { changes: accountLeaseWrite(state, sql, binds) } };
        if (/gh_budget/.test(sql)) return { meta: { changes: ghBudgetWrite(state, sql, binds) } };
        throw new Error(`unmodelled write: ${sql}`);
      },
    }),
    // ensureTable's CREATE statements take no binds.
    run: async () => {
      const sql = rawSql.replace(/\s+/g, ' ').trim();
      calls.push({ sql, binds: [] });
      assert.match(sql, /^CREATE (TABLE|INDEX) IF NOT EXISTS/,
        `an unbound run must only ever be a self-creating table: ${sql}`);
      return { meta: { changes: 0 } };
    },
    first: async () => { throw new Error(`unbound first: ${rawSql}`); },
    all: async () => { throw new Error(`unbound all: ${rawSql}`); },
  });
  return { prepare: stmt, _calls: calls };
}

async function call(state, method, path, body) {
  const env = { DB: fakeDB(state), HARNESS_SECRET: SECRET };
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const res = await worker.fetch(req, env);
  return { status: res.status, body: await res.json(), db: env.DB };
}
const claim = (state, extra) =>
  call(state, 'POST', '/api/account-leases/claim', { account: 'max1', machine_id: 'm1', cap: 1, ...extra });

// ── account_leases ───────────────────────────────────────────────────────────

test('S1 two boxes claiming the last slot: exactly one wins', async () => {
  const state = {};
  const a = await claim(state, { machine_id: 'mach-a', box: 'box-one' });
  const b = await claim(state, { machine_id: 'mach-b', box: 'box-two' });
  assert.equal(a.status, 200);
  assert.equal(a.body.claimed, true);
  assert.equal(b.status, 409, 'the second box must be refused, not given a second lease');
  assert.equal(b.body.claimed, false);
  assert.equal(b.body.reason, 'cap');
  assert.equal(state.leases.length, 1, 'only one row may exist for a cap of 1');
  assert.equal(state.leases[0].machine_id, 'mach-a');
});

test('S2 the refusal reports the live count and the cap it was judged on', async () => {
  const state = {};
  await claim(state, { machine_id: 'mach-a' });
  const b = await claim(state, { machine_id: 'mach-b' });
  assert.equal(b.body.live, 1);
  assert.equal(b.body.cap, 1);
  assert.equal(b.body.account, 'max1');
});

test('S3 under the cap, every claimant wins and each gets its own row', async () => {
  const state = {};
  for (const m of ['m1', 'm2', 'm3', 'm4']) {
    const r = await claim(state, { machine_id: m, cap: 4 });
    assert.equal(r.status, 200, `${m} should have fitted under a cap of 4`);
  }
  assert.equal(state.leases.length, 4);
  const fifth = await claim(state, { machine_id: 'm5', cap: 4 });
  assert.equal(fifth.status, 409);
});

test('S4 a machine renews its OWN lease at a full cap', async () => {
  // The count excludes the claimant's own row. Without that, the ONE thing a
  // long build must be able to do — keep its lease alive — fails at cap.
  const state = {};
  const first = await claim(state, { machine_id: 'mach-a', ticket_key: 'TK-1' });
  const again = await claim(state, { machine_id: 'mach-a', ticket_key: 'TK-1' });
  assert.equal(first.status, 200);
  assert.equal(again.status, 200, 'a renew must never be refused by the holder itself');
  assert.equal(state.leases.length, 1, 'a renew is an upsert, never a second row');
  assert.ok(String(again.body.expires_at) >= String(first.body.expires_at),
    'a renew must push the expiry forward');
});

test('S5 an expired lease frees the account, and the claim sweeps it', async () => {
  const state = { leases: [{ account: 'max1', machine_id: 'ghost', expires_at: iso(-60e3),
                             created_at: iso(-3600e3), updated_at: iso(-3600e3) }] };
  const r = await claim(state, { machine_id: 'mach-a' });
  assert.equal(r.status, 200, 'an expired row must not hold the account');
  assert.equal(state.leases.length, 1);
  assert.equal(state.leases[0].machine_id, 'mach-a', 'the expired row is swept, not kept');
});

test('S6 cap 0 means no cap', async () => {
  const state = {};
  for (const m of ['m1', 'm2', 'm3', 'm4', 'm5', 'm6']) {
    assert.equal((await claim(state, { machine_id: m, cap: 0 })).status, 200);
  }
  assert.equal(state.leases.length, 6);
});

test('S7 release frees the slot; a release names one machine, never a table', async () => {
  const state = {};
  await claim(state, { machine_id: 'mach-a' });
  const rel = await call(state, 'POST', '/api/account-leases/release', { machine_id: 'mach-a' });
  assert.equal(rel.status, 200);
  assert.equal(rel.body.released, 1);
  assert.equal(state.leases.length, 0);
  const b = await claim(state, { machine_id: 'mach-b' });
  assert.equal(b.status, 200, 'the freed slot must be claimable');
  // A release for a machine that holds nothing is a no-op, not an error.
  const none = await call(state, 'POST', '/api/account-leases/release', { machine_id: 'never-existed' });
  assert.equal(none.status, 200);
  assert.equal(none.body.released, 0);
  assert.equal(state.leases.length, 1, 'a no-op release must not touch other machines');
});

test('S8 the TTL is the server clock, clamped, and defaults to 3 hours', async () => {
  const state = {};
  const def = await claim(state, { machine_id: 'm-def' });
  const lo  = await claim(state, { machine_id: 'm-lo', cap: 0, ttl_s: 1 });
  const hi  = await claim(state, { machine_id: 'm-hi', cap: 0, ttl_s: 999999 });
  const secs = (r) => Math.round((Date.parse(r.body.expires_at) - Date.parse(r.body.as_of)) / 1000);
  assert.equal(secs(def), 10800);
  assert.equal(secs(lo), 60, 'a ttl under the floor is clamped up');
  assert.equal(secs(hi), 86400, 'a ttl over the ceiling is clamped down');
});

test('S9 GET answers one account, and the whole fleet, from the same rows', async () => {
  const state = {};
  await claim(state, { account: 'max1', machine_id: 'm1', cap: 0 });
  await claim(state, { account: 'max1', machine_id: 'm2', cap: 0 });
  await claim(state, { account: 'max2', machine_id: 'm3', cap: 0 });
  const one = await call(state, 'GET', '/api/account-leases?account=max1');
  assert.equal(one.status, 200);
  assert.equal(one.body.live, 2);
  assert.deepEqual(one.body.rows.map((r) => r.machine_id), ['m1', 'm2']);
  const all = await call(state, 'GET', '/api/account-leases');
  assert.deepEqual(all.body.counts, { max1: 2, max2: 1 });
  assert.equal(all.body.live, 3);
});

test('S10 a name that is not a name is a 400, and writes nothing', async () => {
  const state = {};
  for (const bad of [{ account: '' }, { machine_id: '' }, { account: 'a b' }, { machine_id: 'm/../x' }]) {
    const r = await claim(state, bad);
    assert.equal(r.status, 400, `${JSON.stringify(bad)} should be refused`);
  }
  assert.equal((state.leases || []).length, 0);
  const rel = await call(state, 'POST', '/api/account-leases/release', { machine_id: '' });
  assert.equal(rel.status, 400);
});

test('S11 the claim is ONE statement, and the cap is inside it', async () => {
  // The guarantee is structural: a read-then-write would let two boxes both see
  // the last slot free and both be told they won — the file version's bug,
  // rebuilt inside the fix.
  const state = {};
  const r = await claim(state, { machine_id: 'mach-a' });
  const writes = r.db._calls.filter((c) => /^INSERT INTO account_leases/.test(c.sql));
  assert.equal(writes.length, 1);
  assert.match(writes[0].sql, /SELECT COUNT\(\*\) FROM account_leases WHERE .*machine_id<>\?2.*expires_at>\?7/);
  const reads = r.db._calls.filter((c) => /^SELECT .* FROM account_leases WHERE account/.test(c.sql)
    && r.db._calls.indexOf(c) < r.db._calls.indexOf(writes[0]));
  assert.equal(reads.length, 0, 'nothing may read the cap before the statement that enforces it');
});

test('S12 the table self-creates before the first statement that needs it', async () => {
  const state = {};
  const r = await claim(state, { machine_id: 'mach-a' });
  const creates = r.db._calls.filter((c) => /^CREATE TABLE IF NOT EXISTS account_leases/.test(c.sql));
  assert.equal(creates.length, 1, 'a table that waits for a hand-run schema apply ships dead');
  assert.ok(r.db._calls.indexOf(creates[0]) < r.db._calls.findIndex((c) => /^INSERT INTO account_leases/.test(c.sql)));
});

// ── gh_budget ────────────────────────────────────────────────────────────────

const reading = (fp, fetched, core, gql) => ({
  fingerprint: fp, fetched_at: fetched, box: 'box-one',
  core: { remaining: core, limit: 5000, reset: 1 },
  graphql: { remaining: gql, limit: 5000, reset: 1 },
});

test('S13 two boxes on one token read one row', async () => {
  const state = {};
  const put = await call(state, 'POST', '/api/gh-budget', reading('abc123def456', 1758369600, 4200, 4900));
  assert.equal(put.status, 200);
  assert.equal(put.body.wrote, true);
  const get = await call(state, 'GET', '/api/gh-budget?fingerprint=abc123def456');
  assert.equal(get.status, 200);
  assert.equal(get.body.row.core.remaining, 4200);
  assert.equal(get.body.row.graphql.remaining, 4900);
  assert.equal(get.body.row.fetched_at, 1758369600);
  assert.equal(state.budget.length, 1, 'one token is one row, however many boxes report it');
});

test('S14 a newer reading counts down; an older one never counts back up', async () => {
  const state = {};
  await call(state, 'POST', '/api/gh-budget', reading('abc123def456', 1758369600, 4200, 4900));
  const newer = await call(state, 'POST', '/api/gh-budget', reading('abc123def456', 1758369660, 3100, 4800));
  assert.equal(newer.body.wrote, true);
  assert.equal(newer.body.row.core.remaining, 3100);
  const older = await call(state, 'POST', '/api/gh-budget', reading('abc123def456', 1758369540, 4999, 4999));
  assert.equal(older.status, 200, 'a late reading is not an error');
  assert.equal(older.body.wrote, false);
  assert.equal(older.body.row.core.remaining, 3100, 'a stale box must not raise remaining back up');
});

test('S15 an unknown fingerprint is 200 with row:null, never 404', async () => {
  // The client reads 404 as "the worker is unreachable". "No reading yet" is
  // the normal state of the first box to ask after a deploy, not an outage.
  const r = await call({}, 'GET', '/api/gh-budget?fingerprint=deadbeef0000');
  assert.equal(r.status, 200);
  assert.equal(r.body.row, null);
});

test('S16 gh-budget validates the fingerprint and the stamp', async () => {
  const state = {};
  assert.equal((await call(state, 'GET', '/api/gh-budget')).status, 400);
  assert.equal((await call(state, 'POST', '/api/gh-budget', { fetched_at: 1 })).status, 400);
  assert.equal((await call(state, 'POST', '/api/gh-budget', { fingerprint: 'abc' })).status, 400);
  assert.equal((await call(state, 'POST', '/api/gh-budget', { fingerprint: 'abc', fetched_at: 'soon' })).status, 400);
  assert.equal((await call(state, 'POST', '/api/gh-budget', { fingerprint: 'a b', fetched_at: 1 })).status, 400);
  assert.equal((state.budget || []).length, 0);
});

test('S17 a missing bucket lands as NULL, never as 0', async () => {
  // A zero remaining is an EXHAUSTED token. Writing one for a bucket the vendor
  // did not report would stop every non-essential read in the fleet.
  const state = {};
  await call(state, 'POST', '/api/gh-budget', { fingerprint: 'abc123def456', fetched_at: 1758369600 });
  const r = await call(state, 'GET', '/api/gh-budget?fingerprint=abc123def456');
  assert.equal(r.body.row.core.remaining, null);
  assert.equal(r.body.row.graphql.remaining, null);
});

test('S18 both routes are bearer-gated', async () => {
  const env = { DB: fakeDB({}), HARNESS_SECRET: SECRET };
  for (const [method, path] of [['POST', '/api/account-leases/claim'], ['GET', '/api/account-leases'],
                                ['POST', '/api/gh-budget'], ['GET', '/api/gh-budget?fingerprint=abc']]) {
    const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
      method, headers: { 'content-type': 'application/json' },
      ...(method === 'POST' ? { body: '{}' } : {}),
    }), env);
    assert.equal(res.status, 401, `${method} ${path} must require the bearer`);
  }
});
