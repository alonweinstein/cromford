import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { alertDecision } from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-1069 (BH-1030.1): the /api/alerts routes, driven through the worker's own
// fetch handler against real SQLite. The contract is worker/jobs/README.md
// `## Alerts table (2026-09-19)`; the fire/remind/suppress rule is the one
// bin/lib/alert-state.sh has been running on files.
//
// Every write in these routes is a compare-and-swap, so the SQL is the
// behaviour and a pattern-matching stub would prove nothing about it (that is
// what test/lib/d1-sqlite.bh-1030.js exists for). Red on the contract branch:
// every route 404s.

const SECRET = 'test-secret';
// THE CLOCK IS PINNED, not sampled. The routes stamp rows with their own
// nowIso(), which floors to the second, so a fixture one second off a boundary
// (2699s against a 2700s TTL) flips on which side of a second the run lands —
// green all afternoon and red at :00. open() freezes the worker's clock at this
// instant instead, and every fixture below is iso(secondsAgo) off it.
const NOW_MS = Date.parse('2026-09-19T12:00:00Z');
const iso = (sAgo) => new Date(NOW_MS - sAgo * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');

async function open(t, hooks) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb(hooks);
  // Visible in TAP as a skip: the one suite that runs the real SQL must never
  // be quietly absent.
  if (!env) t.skip('node:sqlite unavailable on this runtime');
  return env;
}

async function call(DB, method, path, body) {
  const init = { method, headers: { authorization: `Bearer ${SECRET}` } };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

const COLS = 'id,family,box,project,line,severity,first_seen,last_seen,count,state,claimed_by,claimed_at,notified_at';
function seed(db, row) {
  const r = {
    family: null, box: 'hub', project: 'cromford', line: 'disk 91% on /', severity: 'warn',
    first_seen: iso(120), last_seen: iso(120), count: 1, state: 'new',
    claimed_by: null, claimed_at: null, notified_at: null, ...row,
  };
  db.prepare(`INSERT INTO alerts (${COLS}) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(
    r.id, r.family, r.box, r.project, r.line, r.severity, r.first_seen, r.last_seen,
    r.count, r.state, r.claimed_by, r.claimed_at, r.notified_at,
  );
  return r;
}
const read = (db, id) => db.prepare('SELECT * FROM alerts WHERE id=?').get(id);
const note = (over = {}) => ({ id: 'a1', box: 'hub', project: 'cromford', severity: 'warn', line: 'disk 91% on /', ...over });

// ── the routes exist at all (red on the contract branch: 404) ───────────────

test('alerts: GET /api/alerts answers 200 with an empty list on an empty table', async (t) => {
  const env = await open(t); if (!env) return;
  const res = await call(env.DB, 'GET', '/api/alerts');
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.alerts, []);
  assert.equal(res.body.truncated, false);
  assert.match(String(res.body.as_of), /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);

  const unauth = await worker.fetch(new Request('https://jobs.test/api/alerts'), { DB: env.DB, HARNESS_SECRET: SECRET });
  assert.equal(unauth.status, 401, 'the alerts routes sit behind the same bearer as every other lane route');
});

// ── note ────────────────────────────────────────────────────────────────────

test('note: the same id twice is one row, count 2, fire then suppress', async (t) => {
  const env = await open(t); if (!env) return;
  const first = await call(env.DB, 'POST', '/api/alerts/note', note({ family: '0123456789ab' }));
  assert.equal(first.status, 200);
  assert.equal(first.body.decision, 'fire');
  assert.equal(first.body.count, 1);

  const second = await call(env.DB, 'POST', '/api/alerts/note', note({ family: '0123456789ab', line: 'disk 93% on /' }));
  assert.equal(second.status, 200);
  assert.equal(second.body.decision, 'suppress');
  assert.equal(second.body.count, 2);

  const rows = env.db.prepare('SELECT * FROM alerts').all();
  assert.equal(rows.length, 1, 'two notes on one id must not make two rows');
  assert.equal(rows[0].count, 2);
  assert.equal(rows[0].first_seen, first.body.as_of, 'first_seen belongs to the incident, not to the sighting');
  assert.equal(rows[0].last_seen, second.body.as_of);
  assert.equal(rows[0].line, 'disk 93% on /', 'the latest sighting wins on line');
  assert.equal(rows[0].notified_at, first.body.as_of, 'a suppressed note does not move notified_at');
  assert.equal(rows[0].state, 'new');
  assert.equal(rows[0].family, '0123456789ab');
});

test('note: a stamp older than reminder_s reminds and moves notified_at; a fresh one suppresses', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db, { id: 'a1', first_seen: iso(8 * 3600), last_seen: iso(60), notified_at: iso(7 * 3600), count: 5 });
  const res = await call(env.DB, 'POST', '/api/alerts/note', note());
  assert.equal(res.body.decision, 'remind');
  assert.equal(res.body.count, 6);
  assert.equal(read(env.db, 'a1').notified_at, res.body.as_of);
  assert.equal(read(env.db, 'a1').first_seen, iso(8 * 3600), 'a remind is the same incident');

  seed(env.db, { id: 'a2', first_seen: iso(8 * 3600), last_seen: iso(60), notified_at: iso(3600), count: 2 });
  const quiet = await call(env.DB, 'POST', '/api/alerts/note', note({ id: 'a2' }));
  assert.equal(quiet.body.decision, 'suppress');
  assert.equal(read(env.db, 'a2').notified_at, iso(3600));
});

test('note: quiet for longer than close_s starts a new incident', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db, { id: 'a1', first_seen: iso(9 * 3600), last_seen: iso(7 * 3600), notified_at: iso(7 * 3600), count: 9 });
  const res = await call(env.DB, 'POST', '/api/alerts/note', note());
  assert.equal(res.body.decision, 'fire');
  assert.equal(res.body.count, 1);
  const row = read(env.db, 'a1');
  assert.equal(row.count, 1);
  assert.equal(row.first_seen, res.body.as_of, 'the incident restarts, so first_seen is now');
  assert.equal(row.notified_at, res.body.as_of);
});

test('note: a resolved row reopens as a new incident with the claim cleared', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db, {
    id: 'a1', state: 'resolved', count: 4, last_seen: iso(60), notified_at: iso(60),
    claimed_by: 'medic@x', claimed_at: iso(60),
  });
  const res = await call(env.DB, 'POST', '/api/alerts/note', note());
  assert.equal(res.body.decision, 'fire');
  assert.equal(res.body.count, 1);
  const row = read(env.db, 'a1');
  assert.equal(row.state, 'new');
  assert.equal(row.count, 1);
  assert.equal(row.claimed_by, null, 'a reopened incident belongs to nobody');
  assert.equal(row.claimed_at, null);
});

test('note: three notes inside a minute remind at most once', async (t) => {
  const env = await open(t); if (!env) return;
  const decisions = [];
  for (let i = 0; i < 3; i++) {
    const res = await call(env.DB, 'POST', '/api/alerts/note', note({ reminder_s: 60 }));
    decisions.push(res.body.decision);
  }
  assert.deepEqual(decisions, ['fire', 'suppress', 'suppress']);
  assert.equal(decisions.filter((d) => d === 'remind').length, 0);
  assert.equal(read(env.db, 'a1').count, 3);

  // A minute later — the clock is frozen, so the stamp is backdated instead:
  // exactly one of the next two notes reminds.
  env.db.prepare('UPDATE alerts SET notified_at=? WHERE id=?').run(iso(61), 'a1');
  const fourth = await call(env.DB, 'POST', '/api/alerts/note', note({ reminder_s: 60 }));
  const fifth = await call(env.DB, 'POST', '/api/alerts/note', note({ reminder_s: 60 }));
  assert.deepEqual([fourth.body.decision, fifth.body.decision], ['remind', 'suppress']);
  assert.equal(read(env.db, 'a1').notified_at, fourth.body.as_of);
});

test('note: a body the contract refuses is a 400 and writes no row', async (t) => {
  const env = await open(t); if (!env) return;
  const bad = [
    note({ id: 'a/b' }), note({ id: 'a b' }), note({ id: 'x'.repeat(121) }), note({ id: '' }),
    note({ severity: 'fatal' }), note({ severity: 'WARN' }), note({ severity: '' }),
    note({ reminder_s: 59 }), note({ reminder_s: 604801 }), note({ reminder_s: 'abc' }),
    note({ close_s: 59 }), note({ close_s: 604801 }),
    note({ family: 'ABC' }), note({ family: '0123456789ab0' }),
    note({ state: 'triaged' }), note({ state: 'resolved' }),
  ];
  for (const body of bad) {
    const res = await call(env.DB, 'POST', '/api/alerts/note', body);
    assert.equal(res.status, 400, `expected 400 for ${JSON.stringify(body)}`);
    assert.ok(res.body.error, 'a 400 says what was wrong');
  }
  assert.equal(env.db.prepare('SELECT count(*) AS n FROM alerts').get().n, 0, 'a refused note wrote a row');

  // The accepted edges of the same validators.
  for (const body of [note({ family: '' }), note({ id: 'b2', family: '0123456789ab' }), note({ id: 'b3', reminder_s: 60, close_s: 604800 }), note({ id: 'b4', state: 'quarantined' })]) {
    const res = await call(env.DB, 'POST', '/api/alerts/note', body);
    assert.equal(res.status, 200, `expected 200 for ${JSON.stringify(body)}`);
  }
  assert.equal(read(env.db, 'b4').state, 'quarantined', 'a note may open an incident already quarantined');
});

test('note: a row that moves between the read and the write is re-read, never blind-written', async (t) => {
  let raw = null, races = 0;
  const env = await open(t, {
    beforeRun(sql) {
      if (!raw || races <= 0 || !/UPDATE alerts SET family=/.test(sql)) return;
      races--;
      // Another box noting the same incident in the same instant.
      raw.prepare('UPDATE alerts SET count=count+1, last_seen=? WHERE id=?').run(iso(0), 'a1');
    },
  });
  if (!env) return;
  raw = env.db;

  assert.equal((await call(env.DB, 'POST', '/api/alerts/note', note())).body.count, 1);

  races = 1;
  const lost = await call(env.DB, 'POST', '/api/alerts/note', note());
  assert.equal(lost.status, 200);
  assert.equal(lost.body.decision, 'suppress');
  assert.equal(lost.body.count, 3, 'the retry re-read the racing box\'s count instead of overwriting it');
  assert.equal(read(env.db, 'a1').count, 3);

  races = 3;
  const contended = await call(env.DB, 'POST', '/api/alerts/note', note());
  assert.equal(contended.status, 409);
  assert.equal(contended.body.error, 'contended');
  assert.equal(contended.body.id, 'a1');
});

// ── state ───────────────────────────────────────────────────────────────────

test('state: allowed edges move the row, everything else is a 409 that changes nothing', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db, { id: 'n1', state: 'new' });
  const ok = await call(env.DB, 'PATCH', '/api/alerts/state', { id: 'n1', state: 'quarantined', actor: 'triage@hub' });
  assert.equal(ok.status, 200);
  assert.equal(ok.body.alert.state, 'quarantined');
  assert.equal(read(env.db, 'n1').state, 'quarantined');
  assert.equal(read(env.db, 'n1').notified_at, null, 'only the delivery edge stamps notified_at');

  seed(env.db, { id: 'q1', state: 'quarantined' });
  const delivered = await call(env.DB, 'PATCH', '/api/alerts/state', { id: 'q1', state: 'new' });
  assert.equal(delivered.status, 200);
  assert.equal(read(env.db, 'q1').notified_at, delivered.body.as_of, 'quarantined -> new is the flush delivery edge');

  seed(env.db, { id: 'q2', state: 'quarantined', notified_at: iso(300) });
  seed(env.db, { id: 'p1', state: 'parked', notified_at: iso(300) });
  seed(env.db, { id: 't1', state: 'triaged', notified_at: iso(300) });
  const refused = [
    ['q2', 'resolved'], ['p1', 'triaged'], ['t1', 'quarantined'],
  ];
  for (const [id, to] of refused) {
    const before = read(env.db, id);
    const res = await call(env.DB, 'PATCH', '/api/alerts/state', { id, state: to });
    assert.equal(res.status, 409, `${before.state} -> ${to} must be refused`);
    assert.equal(res.body.error, 'disallowed edge');
    assert.equal(res.body.from, before.state);
    assert.equal(res.body.to, to);
    const after = read(env.db, id);
    assert.equal(after.state, before.state, 'a refused edge changed the row');
    assert.equal(after.notified_at, before.notified_at);
  }

  const missing = await call(env.DB, 'PATCH', '/api/alerts/state', { id: 'nope', state: 'parked' });
  assert.equal(missing.status, 404);
  assert.equal(missing.body.error, 'no such alert');

  for (const body of [{ id: 'n1', state: 'bogus' }, { id: 'a/b', state: 'parked' }, { id: 'n1', state: '' }]) {
    assert.equal((await call(env.DB, 'PATCH', '/api/alerts/state', body)).status, 400, JSON.stringify(body));
  }
});

// ── resolve ─────────────────────────────────────────────────────────────────

test('resolve: counts the rows it actually changed', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db, { id: 'r1' });
  seed(env.db, { id: 'r2', state: 'triaged' });

  const res = await call(env.DB, 'POST', '/api/alerts/resolve', { ids: ['r1', 'r2', 'r3-unknown'], actor: 'medic@hub' });
  assert.equal(res.status, 200);
  assert.equal(res.body.resolved, 2);
  assert.equal(read(env.db, 'r1').state, 'resolved');
  assert.equal(read(env.db, 'r2').state, 'resolved');

  const again = await call(env.DB, 'POST', '/api/alerts/resolve', { ids: ['r1', 'r2'] });
  assert.equal(again.body.resolved, 0, 'resolving a resolved row changes nothing');

  const unknown = await call(env.DB, 'POST', '/api/alerts/resolve', { ids: ['zzz'] });
  assert.equal(unknown.status, 200);
  assert.equal(unknown.body.resolved, 0);

  for (const ids of [[], undefined, 'r1', ['a/b'], Array.from({ length: 100 }, (_, i) => `id-${i}`)]) {
    assert.equal((await call(env.DB, 'POST', '/api/alerts/resolve', { ids })).status, 400, JSON.stringify(ids));
  }

  // 99 ids is the D1 bind ceiling, and this statement really executes with it.
  seed(env.db, { id: 'r9' });
  const wide = Array.from({ length: 98 }, (_, i) => `pad-${i}`).concat('r9');
  const full = await call(env.DB, 'POST', '/api/alerts/resolve', { ids: wide });
  assert.equal(full.status, 200);
  assert.equal(full.body.resolved, 1);
  assert.equal(read(env.db, 'r9').state, 'resolved');
});

// ── claim ───────────────────────────────────────────────────────────────────

test('claim: one row goes to exactly one lane', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db, { id: 'q1', state: 'quarantined', first_seen: iso(1000) });

  const a = await call(env.DB, 'POST', '/api/alerts/claim', { lane: 'medic@a', state: 'quarantined' });
  const b = await call(env.DB, 'POST', '/api/alerts/claim', { lane: 'medic@b', state: 'quarantined' });
  assert.equal(a.status, 200);
  assert.equal(b.status, 200);
  // Mutation check (ticket): weaken the CAS predicate
  // `claimed_by IS NULL OR claimed_at<=?5` so a live claim is re-claimable and
  // this total becomes 2.
  assert.equal(a.body.alerts.length + b.body.alerts.length, 1, 'two lanes both got the same row');
  const winner = a.body.alerts[0] || b.body.alerts[0];
  assert.equal(winner.id, 'q1');
  assert.equal(winner.claimed_by, a.body.alerts.length ? 'medic@a' : 'medic@b');
  assert.equal(winner.claimed_at, a.body.alerts.length ? a.body.as_of : b.body.as_of);
  assert.equal(read(env.db, 'q1').claimed_by, winner.claimed_by);
});

test('claim: the claimant is <lane>@<box>, so the family brake can see the claim', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db, { id: 'q1', family: '0123456789ab', state: 'quarantined', first_seen: iso(1000) });

  // Mutation check (ticket): drop the `box` read and file `lane` verbatim. The
  // row is still claimed and nothing errors — but the families group below goes
  // empty, and BH-1071's 6h family brake silently never engages.
  const res = await call(env.DB, 'POST', '/api/alerts/claim', { lane: 'medic', box: 'hub', state: 'quarantined' });
  assert.equal(res.status, 200);
  assert.equal(res.body.alerts[0].claimed_by, 'medic@hub');
  assert.equal(read(env.db, 'q1').claimed_by, 'medic@hub');

  const fams = await call(env.DB, 'GET', '/api/alerts/families?lane=medic&claimed_since_s=21600');
  assert.deepEqual(fams.body.families.map((f) => f.family), ['0123456789ab'],
    'a claim made through the documented call is invisible to the family brake');

  // No box is still the bare lane: the boxless caller (and every fixture that
  // hands the full claimant in `lane`) keeps the claimant it passed.
  seed(env.db, { id: 'q2', state: 'quarantined', first_seen: iso(1000) });
  const bare = await call(env.DB, 'POST', '/api/alerts/claim', { lane: 'medic@a', state: 'quarantined' });
  assert.equal(bare.body.alerts[0].claimed_by, 'medic@a', 'no box means no @box suffix');

  assert.equal((await call(env.DB, 'POST', '/api/alerts/claim', { lane: 'medic', box: 'hub@evil', state: 'new' })).status, 400,
    'the box becomes half of claimed_by, so it is held to the same class as every other box name');
});

test('claim: state, lease, min_age_s and ids all narrow the candidate set', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db, { id: 'new1', state: 'new', first_seen: iso(1000) });
  seed(env.db, { id: 'park1', state: 'parked', first_seen: iso(1000) });
  seed(env.db, { id: 'quar1', state: 'quarantined', first_seen: iso(1000) });
  const only = await call(env.DB, 'POST', '/api/alerts/claim', { lane: 'medic@a', state: 'quarantined' });
  assert.deepEqual(only.body.alerts.map((r) => r.id), ['quar1']);
  assert.equal(only.body.truncated, false);

  // The lease: 900s by default (settings row alert_claim_lease_s).
  seed(env.db, { id: 'live', state: 'new', first_seen: iso(2000), claimed_by: 'other@x', claimed_at: iso(899) });
  seed(env.db, { id: 'stale', state: 'new', first_seen: iso(2000), claimed_by: 'other@x', claimed_at: iso(901) });
  const leased = await call(env.DB, 'POST', '/api/alerts/claim', { lane: 'medic@a', state: 'new' });
  const leasedIds = leased.body.alerts.map((r) => r.id);
  assert.ok(leasedIds.includes('stale'), 'a claim older than the lease is re-claimable');
  assert.ok(!leasedIds.includes('live'), 'a live claim was stolen');

  // min_age_s is measured on first_seen (the incident, not the sighting).
  seed(env.db, { id: 'young', state: 'triaged', first_seen: iso(300) });
  seed(env.db, { id: 'old', state: 'triaged', first_seen: iso(900) });
  const aged = await call(env.DB, 'POST', '/api/alerts/claim', { lane: 'medic@a', state: 'triaged', min_age_s: 600 });
  assert.deepEqual(aged.body.alerts.map((r) => r.id), ['old']);

  // ids narrows further.
  seed(env.db, { id: 'i1', state: 'parked', first_seen: iso(1000) });
  seed(env.db, { id: 'i2', state: 'parked', first_seen: iso(1000) });
  const narrowed = await call(env.DB, 'POST', '/api/alerts/claim', { lane: 'medic@a', state: 'parked', ids: ['i1'] });
  assert.deepEqual(narrowed.body.alerts.map((r) => r.id), ['i1']);
  assert.equal(read(env.db, 'i2').claimed_by, null);

  const empty = await call(env.DB, 'POST', '/api/alerts/claim', { lane: 'medic@a', state: 'quarantined' });
  assert.equal(empty.status, 200);
  assert.deepEqual(empty.body.alerts, []);
  assert.equal(empty.body.truncated, false);

  const capped = await call(env.DB, 'POST', '/api/alerts/claim', { lane: 'medic@a', state: 'parked', limit: 1, ids: ['i2', 'park1'] });
  assert.equal(capped.body.alerts.length, 1);
  assert.equal(capped.body.truncated, true, 'a full page says so');

  for (const body of [{ state: 'new' }, { lane: 'medic@a' }, { lane: 'medic@a', state: 'resolved' }, { lane: 'a b', state: 'new' }, { lane: 'medic@a', state: 'new', ids: ['a/b'] }]) {
    assert.equal((await call(env.DB, 'POST', '/api/alerts/claim', body)).status, 400, JSON.stringify(body));
  }
});

test('claim: a row taken between the read and the write is not handed out twice', async (t) => {
  // The candidate select and the per-row CAS both filter the lease, so neither
  // alone can be proven by two sequential claims — the select already hides the
  // row from the second one. This is the interleaving that leaves only the CAS:
  // another lane takes q1 after it has been selected and before it is written.
  let raw = null, race = 0;
  const env = await open(t, {
    beforeRun(sql) {
      if (!raw || race <= 0 || !/UPDATE alerts SET claimed_by=/.test(sql)) return;
      race--;
      raw.prepare("UPDATE alerts SET claimed_by='other@x', claimed_at=? WHERE id='q1'").run(iso(0));
    },
  });
  if (!env) return;
  raw = env.db;
  seed(env.db, { id: 'q1', state: 'quarantined', first_seen: iso(1000) });

  race = 1;
  const res = await call(env.DB, 'POST', '/api/alerts/claim', { lane: 'medic@a', state: 'quarantined' });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.alerts, [], 'a lost CAS must leave the row out of the answer, not hand it to both lanes');
  assert.equal(read(env.db, 'q1').claimed_by, 'other@x');
});

test('claim: a leased row does not eat the page it cannot be taken from', async (t) => {
  const env = await open(t); if (!env) return;
  // `held` is the oldest, so it sorts first and would be the only candidate.
  seed(env.db, { id: 'held', state: 'quarantined', first_seen: iso(3000), claimed_by: 'other@x', claimed_at: iso(10) });
  seed(env.db, { id: 'free', state: 'quarantined', first_seen: iso(2000) });

  const res = await call(env.DB, 'POST', '/api/alerts/claim', { lane: 'medic@a', state: 'quarantined', limit: 1 });
  assert.deepEqual(res.body.alerts.map((r) => r.id), ['free'], 'the candidate query filters the lease, not only the CAS');
  assert.equal(read(env.db, 'held').claimed_by, 'other@x');
});

// ── flush ───────────────────────────────────────────────────────────────────

test('flush: takes quarantined rows past the TTL, once, and honours the settings override', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db, { id: 'young', state: 'quarantined', first_seen: iso(2699) });
  seed(env.db, { id: 'old', state: 'quarantined', first_seen: iso(2701) });

  const first = await call(env.DB, 'POST', '/api/alerts/flush', { box: 'hub' });
  assert.equal(first.status, 200);
  assert.deepEqual(first.body.alerts.map((r) => r.id), ['old'], '44m59s is not 45m');
  assert.equal(first.body.alerts[0].claimed_by, 'flush@hub');
  assert.equal(first.body.alerts[0].claimed_at, first.body.as_of);
  assert.equal(read(env.db, 'old').claimed_by, 'flush@hub');
  assert.equal(read(env.db, 'old').notified_at, null, 'flush sends nothing, so it stamps nothing');

  assert.equal((await call(env.DB, 'POST', '/api/alerts/flush', { box: 'hub@evil' })).status, 400,
    'the box becomes half of claimed_by, so it is held to the same class as every other box name');

  const second = await call(env.DB, 'POST', '/api/alerts/flush', { box: 'hub' });
  assert.deepEqual(second.body.alerts, [], 'a second flush in the same second escalates the same row again');

  env.db.prepare("UPDATE settings SET value='60' WHERE key='alert_flush_ttl_s'").run();
  const overridden = await call(env.DB, 'POST', '/api/alerts/flush', { box: 'hub' });
  assert.deepEqual(overridden.body.alerts.map((r) => r.id), ['young'], 'the operator knob beat the code fallback');
});

test('flush: a live claim protects a row, an expired one does not, and a missing knob falls back to 2700', async (t) => {
  const env = await open(t); if (!env) return;
  env.db.prepare("DELETE FROM settings WHERE key='alert_flush_ttl_s'").run();
  seed(env.db, { id: 'held', state: 'quarantined', first_seen: iso(3000), claimed_by: 'medic@x', claimed_at: iso(100) });
  seed(env.db, { id: 'dropped', state: 'quarantined', first_seen: iso(3000), claimed_by: 'medic@x', claimed_at: iso(1000) });
  seed(env.db, { id: 'fresh', state: 'quarantined', first_seen: iso(2699) });

  const res = await call(env.DB, 'POST', '/api/alerts/flush', {});
  assert.deepEqual(res.body.alerts.map((r) => r.id), ['dropped']);
  assert.equal(res.body.alerts[0].claimed_by, 'flush', 'no box means no @box suffix');
  assert.equal(read(env.db, 'held').claimed_by, 'medic@x');
  assert.equal(read(env.db, 'fresh').claimed_by, null, 'the 2700 fallback applied with no settings row');
});

// ── list ────────────────────────────────────────────────────────────────────

test('list: every documented filter, both param spellings, and an honest truncated', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db, { id: 'l1', family: '0123456789ab', box: 'hub', state: 'new', first_seen: iso(7200), last_seen: iso(30) });
  seed(env.db, { id: 'l2', family: 'cafebabe0001', box: 'small', state: 'triaged', first_seen: iso(600), last_seen: iso(600) });
  seed(env.db, { id: 'l3', family: '0123456789ab', box: 'hub', state: 'resolved', first_seen: iso(7200), last_seen: iso(7200) });

  const all = await call(env.DB, 'GET', '/api/alerts');
  assert.deepEqual(all.body.alerts.map((r) => r.id), ['l1', 'l2', 'l3'], 'most recent activity first');

  assert.deepEqual((await call(env.DB, 'GET', '/api/alerts?state=!resolved')).body.alerts.map((r) => r.id), ['l1', 'l2']);
  assert.deepEqual((await call(env.DB, 'GET', '/api/alerts?state=triaged')).body.alerts.map((r) => r.id), ['l2']);
  assert.deepEqual((await call(env.DB, 'GET', '/api/alerts?family=0123456789ab')).body.alerts.map((r) => r.id), ['l1', 'l3']);
  assert.deepEqual((await call(env.DB, 'GET', '/api/alerts?box=small')).body.alerts.map((r) => r.id), ['l2']);
  assert.deepEqual((await call(env.DB, 'GET', '/api/alerts?older_than_s=3600')).body.alerts.map((r) => r.id), ['l1', 'l3']);
  assert.deepEqual((await call(env.DB, 'GET', '/api/alerts?older_than=3600')).body.alerts.map((r) => r.id), ['l1', 'l3'], 'the shipped client sends older_than');
  assert.deepEqual((await call(env.DB, 'GET', '/api/alerts?since_s=60')).body.alerts.map((r) => r.id), ['l1']);
  assert.deepEqual((await call(env.DB, 'GET', '/api/alerts?since=60')).body.alerts.map((r) => r.id), ['l1'], 'the shipped client sends since');

  // The exact query string bin/jobs-client.sh alerts_list builds.
  const clientShaped = await call(env.DB, 'GET', '/api/alerts?state=new&older_than=60&since=3600&limit=5');
  assert.equal(clientShaped.status, 200);
  assert.deepEqual(clientShaped.body.alerts.map((r) => r.id), ['l1']);
});

test('list: limit is a page size, capped at 500, and truncated never lies', async (t) => {
  const env = await open(t); if (!env) return;
  for (let i = 0; i < 501; i++) seed(env.db, { id: `p${String(i).padStart(3, '0')}`, last_seen: iso(1000 + i) });

  const capped = await call(env.DB, 'GET', '/api/alerts?limit=1000');
  assert.equal(capped.body.alerts.length, 500);
  assert.equal(capped.body.truncated, true);

  // since_s=1010 selects exactly the eleven rows stamped iso(1000)..iso(1010).
  const ten = await call(env.DB, 'GET', '/api/alerts?limit=10&box=hub&since_s=1010');
  assert.equal(ten.body.alerts.length, 10);
  assert.equal(ten.body.truncated, true);
  const eleven = await call(env.DB, 'GET', '/api/alerts?limit=11&box=hub&since_s=1010');
  assert.equal(eleven.body.alerts.length, 11);
  assert.equal(eleven.body.truncated, false, 'exactly a page is not a truncation');
});

test('families: the group counts only the rows one lane claimed inside the window', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db, { id: 'f1', family: '0123456789ab', claimed_by: 'medic@a', claimed_at: iso(3600) });
  seed(env.db, { id: 'f2', family: '0123456789ab', claimed_by: 'medic@b', claimed_at: iso(7 * 3600) });
  seed(env.db, { id: 'f3', family: 'cafebabe0001', claimed_by: 'medicine@a', claimed_at: iso(3600) });
  seed(env.db, { id: 'f4', family: 'cafebabe0002', claimed_by: 'triage@a', claimed_at: iso(3600) });

  const grouped = await call(env.DB, 'GET', '/api/alerts?group=family&claimed_by_prefix=medic&claimed_since_s=21600');
  assert.equal(grouped.status, 200);
  assert.equal(grouped.body.families.length, 1, 'medicine@a and triage@a are not medic');
  assert.deepEqual(grouped.body.families[0], { family: '0123456789ab', last_claimed_at: iso(3600), n: 1 });

  const alias = await call(env.DB, 'GET', '/api/alerts/families?lane=medic&claimed_since_s=21600');
  assert.equal(alias.status, 200);
  assert.deepEqual(alias.body.families, grouped.body.families, 'the client path is the same query');

  const wildcard = await call(env.DB, 'GET', '/api/alerts/families?lane=med%25&claimed_since_s=21600');
  assert.equal(wildcard.status, 200);
  assert.deepEqual(wildcard.body.families, [], 'under LIKE, med% would match medic@a — the prefix is matched literally');

  assert.equal((await call(env.DB, 'GET', '/api/alerts/families')).status, 400, 'a prefix-less family count answers nobody');
});

// ── the decision rule, without SQL ──────────────────────────────────────────

test('alertDecision: fire, remind and suppress, at the boundaries', async () => {
  const knobs = { reminder_s: 21600, close_s: 21600 };
  const body = { id: 'a1', box: 'hub', project: 'cromford', line: 'disk', severity: 'warn' };
  const t = iso(0);

  const fresh = alertDecision(null, body, t, knobs);
  assert.equal(fresh.decision, 'fire');
  assert.equal(fresh.count, 1);
  assert.equal(fresh.first_seen, t);
  assert.equal(fresh.notified_at, t);
  assert.equal(fresh.state, 'new');
  assert.equal(fresh.clearClaim, true);

  const resolved = alertDecision({ state: 'resolved', count: 9, first_seen: iso(600), last_seen: iso(10), notified_at: iso(10) }, body, t, knobs);
  assert.equal(resolved.decision, 'fire');
  assert.equal(resolved.count, 1);

  const quiet = alertDecision({ state: 'new', count: 9, first_seen: iso(99999), last_seen: iso(21600), notified_at: iso(21600) }, body, t, knobs);
  assert.equal(quiet.decision, 'fire', 'quiet for exactly close_s is a new incident');

  const due = alertDecision({ state: 'new', count: 2, first_seen: iso(30000), last_seen: iso(10), notified_at: iso(21600) }, body, t, knobs);
  assert.equal(due.decision, 'remind');
  assert.equal(due.count, 3);
  assert.equal(due.notified_at, t);
  assert.equal(due.first_seen, iso(30000), 'a remind keeps the incident');
  assert.equal(due.clearClaim, false);

  const notDue = alertDecision({ state: 'quarantined', count: 2, first_seen: iso(30000), last_seen: iso(10), notified_at: iso(21599) }, body, t, knobs);
  assert.equal(notDue.decision, 'suppress');
  assert.equal(notDue.notified_at, iso(21599), 'a suppressed sighting does not move the stamp');
  assert.equal(notDue.state, 'quarantined', 'an active row keeps its state');

  const neverNotified = alertDecision({ state: 'new', count: 1, first_seen: iso(600), last_seen: iso(10), notified_at: null }, body, t, knobs);
  assert.equal(neverNotified.decision, 'remind', 'a row nobody has ever been told about is due');

  assert.equal(alertDecision(null, { ...body, state: 'quarantined' }, t, knobs).state, 'quarantined');
  assert.equal(
    alertDecision({ state: 'new', count: 1, first_seen: iso(600), last_seen: iso(10), notified_at: iso(10) }, { ...body, state: 'quarantined' }, t, knobs).state,
    'new',
    'a note never walks a live row around the state edges',
  );

  // Three sightings inside one minute with reminder_s=60: one remind.
  let row = { state: 'new', count: 1, first_seen: iso(600), last_seen: iso(101), notified_at: iso(101) };
  const minute = { reminder_s: 60, close_s: 21600 };
  const decisions = [];
  for (const at of [iso(40), iso(20), iso(0)]) {
    const d = alertDecision(row, body, at, minute);
    decisions.push(d.decision);
    row = { ...row, count: d.count, last_seen: d.last_seen, notified_at: d.notified_at, state: d.state };
  }
  assert.deepEqual(decisions, ['remind', 'suppress', 'suppress']);
});
