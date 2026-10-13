import test from 'node:test';
import assert from 'node:assert/strict';
import { ROUTES } from '../src/index.js';
import { matchRoute } from '../src/lib/router.js';
import { isoPlusSeconds } from '../src/lib/core.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-2369 (BH-2324 child 2): the real handlers behind POST/GET
// /api/alerts/actions, run against node:sqlite so the CAS predicates and the
// audit INSERT ... SELECT are the statements that actually execute.

async function open(t, hooks) {
  const o = await openDb(hooks);
  if (!o) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  return o;
}

const T0 = '2026-09-25T12:00:00Z';

function seed(db, id, state, extra = {}) {
  const row = {
    id, family: 'abcdefabcdef', box: 'bw-1', project: 'p', line: 'disk full', severity: 'warn',
    first_seen: '2026-09-25T10:00:00Z', last_seen: '2026-09-25T11:00:00Z', count: 3, state,
    claimed_by: null, claimed_at: null, notified_at: '2026-09-25T10:00:05Z', ...extra,
  };
  db.prepare(`INSERT INTO alerts (id,family,box,project,line,severity,first_seen,last_seen,count,state,claimed_by,claimed_at,notified_at)
              VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(
    row.id, row.family, row.box, row.project, row.line, row.severity, row.first_seen, row.last_seen,
    row.count, row.state, row.claimed_by, row.claimed_at, row.notified_at);
}

async function call(DB, method, body, query = '', t = T0) {
  const path = '/api/alerts/actions';
  const hit = matchRoute(ROUTES, method, path);
  assert.ok(hit, `${method} ${path} is routed`);
  const url = new URL(`https://jobs.example${path}${query}`);
  const res = await hit.handler({ env: { DB }, url, path, t, body: method === 'GET' ? {} : body, m: hit.m });
  return { status: res.status, body: await res.json() };
}

const rows = (db, id) => db.prepare('SELECT * FROM alert_actions WHERE alert_id=? ORDER BY id').all(id);
const alertRow = (db, id) => ({ ...db.prepare('SELECT * FROM alerts WHERE id=?').get(id) });
const count = (db) => db.prepare('SELECT count(*) AS n FROM alert_actions').get().n;

test('1. ack moves new and quarantined to triaged with one ok audit row', async (t) => {
  const o = await open(t);
  if (!o) return;
  for (const [id, from] of [['a-new', 'new'], ['a-q', 'quarantined']]) {
    seed(o.db, id, from);
    const r = await call(o.DB, 'POST', { id, action: 'ack', actor: 'console' });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.alert.state, 'triaged');
    assert.equal(alertRow(o.db, id).state, 'triaged');
    assert.equal(r.body.as_of, T0);
    const log = rows(o.db, id);
    assert.equal(log.length, 1);
    assert.deepEqual(
      { action: log[0].action, actor: log[0].actor, before_state: log[0].before_state, after_state: log[0].after_state, outcome: log[0].outcome, at: log[0].at },
      { action: 'ack', actor: 'console', before_state: from, after_state: 'triaged', outcome: 'ok', at: T0 });
    assert.deepEqual(r.body.action, { ...log[0] });
  }
});

test('2. ack on triaged/parked/resolved is a 409 disallowed edge with one refused row', async (t) => {
  const o = await open(t);
  if (!o) return;
  for (const from of ['triaged', 'parked', 'resolved']) {
    const id = `b-${from}`;
    seed(o.db, id, from);
    const before = alertRow(o.db, id);
    const r = await call(o.DB, 'POST', { id, action: 'ack', actor: 'console' });
    assert.equal(r.status, 409);
    assert.equal(r.body.error, 'disallowed edge');
    assert.equal(r.body.from, from);
    assert.deepEqual(alertRow(o.db, id), before, 'row unchanged');
    const log = rows(o.db, id);
    assert.equal(log.length, 1);
    assert.equal(log[0].outcome, 'refused:disallowed-edge');
    assert.equal(log[0].before_state, from);
    assert.equal(log[0].after_state, from);
  }
});

test('3. a lost race between the read and the batch is a 409 contended, never an ok row', async (t) => {
  let flipped = false;
  const o = await open(t);
  if (!o) return;
  seed(o.db, 'c1', 'new');
  // The first statement prepared after the handler's read flips the row, which
  // is another writer landing between our SELECT and our batch.
  let sawRead = false;
  const DB = {
    ...o.DB,
    prepare(sql) {
      if (sawRead && !flipped) {
        o.db.prepare("UPDATE alerts SET state='parked' WHERE id='c1'").run();
        flipped = true;
      }
      if (/^SELECT \* FROM alerts WHERE id=/.test(sql)) sawRead = true;
      return o.DB.prepare(sql);
    },
  };
  const r = await call(DB, 'POST', { id: 'c1', action: 'ack', actor: 'console' });
  assert.ok(flipped, 'the race was injected');
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'contended');
  const log = rows(o.db, 'c1');
  assert.equal(log.filter((x) => x.outcome === 'ok').length, 0, 'no ok row');
  assert.deepEqual(log.map((x) => x.outcome), ['refused:contended']);
  assert.equal(alertRow(o.db, 'c1').state, 'parked');
});

test('4. snooze claims the row for the settings lease and the lanes then skip it', async (t) => {
  const o = await open(t);
  if (!o) return;
  seed(o.db, 'd1', 'new');
  const r = await call(o.DB, 'POST', { id: 'd1', action: 'snooze', actor: 'console' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.alert.claimed_by, 'console');
  assert.equal(r.body.alert.claimed_at, T0);
  assert.equal(r.body.alert.state, 'new');
  assert.equal(r.body.action.until, isoPlusSeconds(T0, 900));
  assert.equal(r.body.action.before_state, 'new');
  assert.equal(r.body.action.after_state, 'new');
  assert.equal(r.body.action.outcome, 'ok');

  // The settings row wins over the fallback.
  o.db.prepare("INSERT INTO settings (key, value, updated_at) VALUES ('alert_claim_lease_s','60',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value").run(T0);
  seed(o.db, 'd2', 'new');
  const r2 = await call(o.DB, 'POST', { id: 'd2', action: 'snooze', actor: 'console' });
  assert.equal(r2.status, 200);
  assert.equal(r2.body.action.until, isoPlusSeconds(T0, 60));

  // The medic lane's claim, inside the lease, answers nothing.
  const claim = matchRoute(ROUTES, 'POST', '/api/alerts/claim');
  const res = await claim.handler({ env: { DB: o.DB }, t: isoPlusSeconds(T0, 30), body: { lane: 'medic', state: 'new' }, path: '/api/alerts/claim' });
  assert.equal(res.status, 200);
  assert.deepEqual((await res.json()).alerts, []);

  // A snoozed quarantined row past its flush TTL waits out the lease too.
  seed(o.db, 'd3', 'quarantined', { first_seen: isoPlusSeconds(T0, -86400) });
  assert.equal((await call(o.DB, 'POST', { id: 'd3', action: 'snooze', actor: 'console' })).status, 200);
  const flush = matchRoute(ROUTES, 'POST', '/api/alerts/flush');
  const fl = await flush.handler({ env: { DB: o.DB }, t: isoPlusSeconds(T0, 30), body: {}, path: '/api/alerts/flush' });
  assert.deepEqual((await fl.json()).alerts, []);
  const later = await flush.handler({ env: { DB: o.DB }, t: isoPlusSeconds(T0, 61), body: {}, path: '/api/alerts/flush' });
  assert.deepEqual((await later.json()).alerts.map((a) => a.id), ['d3'], 'the flush takes it once the lease is over');
});

test('5. snooze never steals a live foreign claim, takes an expired one, refuses a resolved row', async (t) => {
  const o = await open(t);
  if (!o) return;
  seed(o.db, 'e1', 'triaged', { claimed_by: 'medic@hub', claimed_at: isoPlusSeconds(T0, -10) });
  const r = await call(o.DB, 'POST', { id: 'e1', action: 'snooze', actor: 'console' });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'claimed');
  assert.equal(r.body.claimed_by, 'medic@hub');
  assert.equal(alertRow(o.db, 'e1').claimed_by, 'medic@hub');
  assert.deepEqual(rows(o.db, 'e1').map((x) => x.outcome), ['refused:claimed:medic@hub']);

  seed(o.db, 'e2', 'parked', { claimed_by: 'medic@hub', claimed_at: isoPlusSeconds(T0, -901) });
  const r2 = await call(o.DB, 'POST', { id: 'e2', action: 'snooze', actor: 'console' });
  assert.equal(r2.status, 200, JSON.stringify(r2.body));
  assert.equal(alertRow(o.db, 'e2').claimed_by, 'console');

  // The same actor re-arms its own live claim.
  const r3 = await call(o.DB, 'POST', { id: 'e2', action: 'snooze', actor: 'console' });
  assert.equal(r3.status, 200);

  seed(o.db, 'e3', 'resolved');
  const r4 = await call(o.DB, 'POST', { id: 'e3', action: 'snooze', actor: 'console' });
  assert.equal(r4.status, 409);
  assert.deepEqual(rows(o.db, 'e3').map((x) => x.outcome), ['refused:resolved']);
  assert.equal(alertRow(o.db, 'e3').claimed_by, null);
});

test('6. resolve resolves once; the second is a 409, never a 200', async (t) => {
  const o = await open(t);
  if (!o) return;
  seed(o.db, 'f1', 'parked');
  const r = await call(o.DB, 'POST', { id: 'f1', action: 'resolve', actor: 'console' });
  assert.equal(r.status, 200);
  assert.equal(r.body.alert.state, 'resolved');
  assert.equal(r.body.action.after_state, 'resolved');
  assert.equal(r.body.action.before_state, 'parked');
  const r2 = await call(o.DB, 'POST', { id: 'f1', action: 'resolve', actor: 'console' });
  assert.equal(r2.status, 409);
  assert.equal(r2.body.error, 'already resolved');
  assert.deepEqual(rows(o.db, 'f1').map((x) => x.outcome), ['ok', 'refused:already-resolved']);
});

test('7. note only appends; every invalid body is a 400 that writes nothing', async (t) => {
  const o = await open(t);
  if (!o) return;
  seed(o.db, 'g1', 'triaged', { claimed_by: 'medic@hub', claimed_at: isoPlusSeconds(T0, -10) });
  const before = alertRow(o.db, 'g1');
  const r = await call(o.DB, 'POST', { id: 'g1', action: 'note', actor: 'console', note: '  hi  ' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(alertRow(o.db, 'g1'), before, 'the alerts row is untouched');
  assert.equal(r.body.action.note, 'hi');
  assert.equal(r.body.action.before_state, 'triaged');
  assert.equal(r.body.action.after_state, 'triaged');
  assert.equal(r.body.action.outcome, 'ok');

  seed(o.db, 'g2', 'new');
  for (const bad of [
    { id: 'g2', action: 'note', actor: 'console', note: '' },
    { id: 'g2', action: 'note', actor: 'console', note: '   ' },
    { id: 'g2', action: 'note', actor: 'console' },
    { id: 'g2', action: 'note', actor: 'console', note: 'x'.repeat(1001) },
    { id: 'g2', action: 'ack', actor: 'console', note: 'x'.repeat(1001) },
    { id: 'g2', action: 'ack', actor: 'console', note: 7 },
    { id: 'g2', action: 'ack' },
    { id: 'g2', action: 'ack', actor: 'a b' },
    { id: 'g2', action: 'delete', actor: 'console' },
    { id: 'a b', action: 'ack', actor: 'console' },
    { action: 'ack', actor: 'console' },
    null,
    [],
  ]) {
    const res = await call(o.DB, 'POST', bad);
    assert.equal(res.status, 400, `400 for ${JSON.stringify(bad)}`);
  }
  assert.equal(rows(o.db, 'g2').length, 0);
  assert.equal(count(o.db), 1, 'only the good note was written');
  assert.equal(alertRow(o.db, 'g2').state, 'new');
});

test('8. an unknown id is a 404 with one refused:no-such-alert row', async (t) => {
  const o = await open(t);
  if (!o) return;
  const r = await call(o.DB, 'POST', { id: 'nope', action: 'ack', actor: 'console' });
  assert.equal(r.status, 404);
  assert.equal(r.body.error, 'no such alert');
  const log = rows(o.db, 'nope');
  assert.equal(log.length, 1);
  assert.equal(log[0].outcome, 'refused:no-such-alert');
  assert.equal(log[0].before_state, null);
});

test('9. GET lists newest first, pages with truncated, and needs an id', async (t) => {
  const o = await open(t);
  if (!o) return;
  seed(o.db, 'h1', 'new');
  await call(o.DB, 'POST', { id: 'h1', action: 'note', actor: 'console', note: 'one' }, '', '2026-09-25T12:00:00Z');
  await call(o.DB, 'POST', { id: 'h1', action: 'ack', actor: 'console' }, '', '2026-09-25T12:00:01Z');
  await call(o.DB, 'POST', { id: 'h1', action: 'note', actor: 'console', note: 'three' }, '', '2026-09-25T12:00:01Z');
  const all = await call(o.DB, 'GET', null, '?id=h1');
  assert.equal(all.status, 200);
  assert.deepEqual(all.body.actions.map((x) => x.note || x.action), ['three', 'ack', 'one']);
  assert.equal(all.body.truncated, false);
  const one = await call(o.DB, 'GET', null, '?id=h1&limit=1');
  assert.equal(one.body.actions.length, 1);
  assert.equal(one.body.actions[0].note, 'three');
  assert.equal(one.body.truncated, true);
  const big = await call(o.DB, 'GET', null, '?id=h1&limit=9999');
  assert.equal(big.status, 200);
  assert.equal(big.body.actions.length, 3);
  const zero = await call(o.DB, 'GET', null, '?id=h1&limit=0');
  assert.equal(zero.body.actions.length, 3, 'limit 0 is the default page, not an empty one');
  assert.equal((await call(o.DB, 'GET', null, '')).status, 400);
  assert.equal((await call(o.DB, 'GET', null, '?id=a%20b')).status, 400);
  const none = await call(o.DB, 'GET', null, '?id=nobody');
  assert.deepEqual([none.status, none.body.actions, none.body.truncated], [200, [], false]);
});

test('10. BH-2405 T4: a non-string action is a 400 that writes nothing, never String()-coerced', async (t) => {
  const o = await open(t);
  if (!o) return;
  seed(o.db, 'h1', 'new');
  for (const action of [['ack'], ['resolve'], { toString: 'ack' }, 7, true]) {
    const res = await call(o.DB, 'POST', { id: 'h1', action, actor: 'console' });
    assert.equal(res.status, 400, `400 for action=${JSON.stringify(action)}`);
    assert.match(res.body.error, /action must be one of/);
  }
  assert.equal(rows(o.db, 'h1').length, 0);
  assert.equal(alertRow(o.db, 'h1').state, 'new', 'an array action never acks the row');
});
