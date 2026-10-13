import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-3154 (BH-2510.4): HOLD / UNHOLD one deploy-queue departure, driven through
// worker.fetch against the SQL that ships (real SQLite, the
// deploy-queue-actions.bh-2510 idiom).
//
// A hold is only worth something if every door to the row honours it: the
// action's own CAS, the claim a train makes, the enqueue a merge (or a train's
// ADOPT / self-source) makes, and the list a train reads. Each is driven here.

const SECRET = 'test-secret';
const P = 'project-3';
const SHA = 'abcdef1' + '0123456789abcdef0123456789abcdef0'; // 40 hex
const JOB = `deploy-queue:${P}/${SHA}`;

function recorded(DB, seen) {
  return {
    prepare(sql) { seen.push(sql); return DB.prepare(sql); },
    batch(stmts) { return DB.batch(stmts); },
  };
}

async function fixture(hooks = {}, knob = '1') {
  const opened = await openDb(hooks);
  assert.ok(opened, 'node:sqlite is required for this suite — CI runs node 22');
  const { db, DB } = opened;
  const seen = [];
  const req = (method, path, body) => worker.fetch(new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  }), { DB: recorded(DB, seen), HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
  const call = (path, body) => req('POST', path, body);
  const setKnob = (v) => {
    if (v === null) { db.prepare("DELETE FROM settings WHERE key='deploy_queue_rows'").run(); return; }
    db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('deploy_queue_rows',?,'t','t','t')
                ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(v);
  };
  setKnob(knob);
  const row = (sha = SHA, project = P) =>
    db.prepare('SELECT * FROM deploy_queue WHERE project=? AND sha=?').get(project, sha) ?? null;
  const events = () => db.prepare("SELECT * FROM stage_events WHERE stage='deploy-queue'").all();
  const enqueue = async (sha = SHA, project = P) => {
    const r = await call('/api/deploy-queue', { project, sha, build_dir: '/b' });
    assert.equal(r.status, 201, JSON.stringify(r.body));
  };
  const claim = (sha = SHA, box = 'box-a') => call('/api/deploy-queue/claim', { project: P, sha, box });
  const act = (action, over = {}) => call('/api/deploy-queue/action',
    { project: P, sha: SHA, action, reason: 'bad migration', actor: 'operator', ...over });
  return { db, seen, req, call, setKnob, row, events, enqueue, claim, act };
}

test('hold: a queued row goes held with one audited HELD event, and a train cannot claim it', async () => {
  const f = await fixture();
  await f.enqueue();
  const r = await f.act('hold', { sha: `  ${SHA.toUpperCase()} ` });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.decision, 'held');
  assert.equal(r.body.actor, 'operator');
  assert.equal(r.body.reason, 'bad migration');
  const row = f.row();
  assert.equal(row.status, 'held');
  assert.equal(row.claimed_by, null);
  assert.equal(row.departed_at, null);
  assert.equal(row.reason, 'bad migration');
  assert.deepEqual(r.body.deploy, { ...row });
  const ev = f.events();
  assert.equal(ev.length, 1);
  assert.equal(ev[0].job_id, JOB);
  assert.equal(ev[0].verdict, 'HELD');
  assert.equal(ev[0].actor, 'operator');
  assert.deepEqual(JSON.parse(ev[0].detail), { reason: 'bad migration', from: 'queued', to: 'held' });
  assert.equal(ev[0].created_at, row.updated_at);

  const c = await f.claim();
  assert.equal(c.status, 409);
  assert.ok(!c.body.claimed);
  // A stale-claim re-offer never matches a held row either.
  const s = await f.call('/api/deploy-queue/claim', { project: P, sha: SHA, box: 'box-b', stale_min: 1 });
  assert.equal(s.status, 409);
  assert.equal(f.row().status, 'held');
  assert.equal(f.row().claimed_by, null);
  f.db.close();
});

test('enqueue: POST /api/deploy-queue never re-opens a held row', async () => {
  const f = await fixture();
  await f.enqueue();
  assert.equal((await f.act('hold')).status, 200);
  const before = f.row();
  for (const sha of [SHA, SHA.toUpperCase(), ` ${SHA} `]) {
    f.seen.length = 0;
    const r = await f.call('/api/deploy-queue', { project: P, sha, build_dir: '/other' });
    assert.equal(f.seen.filter((q) => /INSERT INTO deploy_queue/.test(q)).length, 0, 'a held duplicate is not even written');
    assert.equal(r.status, 200, `${sha}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.duplicate, true);
    assert.match(r.body.reason, /is already held/);
    assert.equal(r.body.deploy.status, 'held');
  }
  assert.deepEqual(f.row(), before, 'the held row is untouched');
  // A different sha under the same project is a fresh queued row, as ever.
  const other = 'e'.repeat(40);
  const r2 = await f.call('/api/deploy-queue', { project: P, sha: other });
  assert.equal(r2.status, 201);
  assert.equal(f.row(other).status, 'queued');
  f.db.close();
});

test('enqueue: a hold that lands between the SELECT and the upsert is not re-opened', async () => {
  let fired = false;
  let db;
  const f = await fixture({
    beforeRun(sql) {
      if (!fired && /INSERT INTO deploy_queue/.test(sql)) {
        fired = true;
        db.prepare("UPDATE deploy_queue SET status='held', departed_at=NULL, reason='race' WHERE sha=?").run(SHA);
      }
    },
  });
  db = f.db;
  // A terminal row: the enqueue's SELECT reads `done` and heads for the re-open.
  f.db.prepare(`INSERT INTO deploy_queue (project, sha, build_dir, status, claimed_by, reason, enqueued_at, departed_at, updated_at)
                VALUES (?, ?, '/b', 'done', 'box-a', NULL, '2026-09-28T00:00:00Z', '2026-09-28T00:01:00Z', '2026-09-28T00:01:00Z')`).run(P, SHA);
  const r = await f.call('/api/deploy-queue', { project: P, sha: SHA });
  assert.ok(fired, 'the race ran');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.duplicate, true);
  assert.match(r.body.reason, /is already held/);
  assert.equal(f.row().status, 'held');
  assert.equal(f.row().reason, 'race');
  f.db.close();
});

test('GET ?status=held lists exactly the held rows; ?status=queued excludes them', async () => {
  const f = await fixture();
  const Q = 'c'.repeat(40);
  await f.enqueue();
  await f.enqueue(Q);
  await f.enqueue(SHA, 'other-proj');
  assert.equal((await f.act('hold')).status, 200);
  const held = await f.req('GET', `/api/deploy-queue?project=${P}&status=held`);
  assert.equal(held.status, 200);
  assert.deepEqual(held.body.deploy_queue.map((d) => [d.project, d.sha, d.status]), [[P, SHA, 'held']]);
  const queued = await f.req('GET', `/api/deploy-queue?project=${P}&status=queued`);
  assert.deepEqual(queued.body.deploy_queue.map((d) => d.sha), [Q]);
  f.db.close();
});

test('unhold: a held row goes back to queued with one UNHELD event, and a train claims it', async () => {
  const f = await fixture();
  await f.enqueue();
  assert.equal((await f.act('hold')).status, 200);
  const r = await f.act('unhold', { reason: 'migration fixed' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.decision, 'unheld');
  assert.equal(f.row().status, 'queued');
  assert.equal(f.row().reason, 'migration fixed');
  const ev = f.events().filter((e) => e.verdict === 'UNHELD');
  assert.equal(ev.length, 1);
  assert.deepEqual(JSON.parse(ev[0].detail), { reason: 'migration fixed', from: 'held', to: 'queued' });
  assert.equal(f.events().length, 2);
  const c = await f.claim();
  assert.equal(c.status, 200);
  assert.equal(c.body.claimed, true);
  f.db.close();
});

test('hold / unhold refuse a row in the wrong state: 409, nothing written', async () => {
  const f = await fixture();
  await f.enqueue();
  assert.equal((await f.claim()).status, 200);
  const claimed = f.row();
  let r = await f.act('hold');
  assert.equal(r.status, 409);
  assert.equal(r.body.refused, true);
  assert.match(r.body.error, /hold refused: row is claimed/);
  assert.deepEqual(f.row(), claimed);

  assert.equal((await f.call('/api/deploy-queue/depart', { project: P, sha: SHA, status: 'done' })).status, 200);
  const done = f.row();
  r = await f.act('hold');
  assert.equal(r.status, 409);
  assert.match(r.body.error, /row is done, departed/);
  r = await f.act('unhold');
  assert.equal(r.status, 409);
  assert.match(r.body.error, /unhold refused: row is done/);
  assert.deepEqual(f.row(), done);

  const Q = 'c'.repeat(40);
  await f.enqueue(Q);
  r = await f.act('unhold', { sha: Q });
  assert.equal(r.status, 409);
  assert.match(r.body.error, /unhold refused: row is queued/);
  assert.equal(f.row(Q).status, 'queued');

  // release does not take a held row either.
  assert.equal((await f.act('hold', { sha: Q })).status, 200);
  r = await f.act('release', { sha: Q });
  assert.equal(r.status, 409);
  assert.equal(f.row(Q).status, 'held');

  assert.equal(f.events().filter((e) => e.verdict !== 'HELD').length, 0, 'no refusal writes an event');
  f.db.close();
});

test('hold is refused while deploy_queue_rows is not on; unhold never is', async () => {
  for (const v of ['0', 'off', 'ON', ' on ', '', null]) {
    const f = await fixture({}, v);
    await f.enqueue();
    const r = await f.act('hold');
    assert.equal(r.status, 409, `knob ${JSON.stringify(v)}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.refused, true);
    assert.match(r.body.error, /deploy_queue_rows is not on/);
    assert.equal(f.row().status, 'queued');
    assert.equal(f.events().length, 0);
    f.db.close();
  }
  for (const v of ['1', 'on', 'true', 'yes']) {
    const f = await fixture({}, v);
    await f.enqueue();
    assert.equal((await f.act('hold')).status, 200, `knob ${v}`);
    // Knob turned off after the hold: the hold can still be undone.
    f.setKnob('0');
    const u = await f.act('unhold');
    assert.equal(u.status, 200, JSON.stringify(u.body));
    assert.equal(f.row().status, 'queued');
    f.db.close();
  }
});

test('hold / unhold: a bad body is a 400 before any SQL', async () => {
  const f = await fixture();
  await f.enqueue();
  for (const action of ['hold', 'unhold']) {
    for (const over of [{ reason: '' }, { reason: '   ' }, { reason: undefined }, { actor: '' }]) {
      f.seen.length = 0;
      const r = await f.act(action, over);
      assert.equal(r.status, 400, `${action} ${JSON.stringify(over)} -> ${r.status}`);
      assert.deepEqual(f.seen, []);
    }
  }
  for (const action of ['HOLD', 'hold ', 'Unhold']) {
    f.seen.length = 0;
    const r = await f.act(action);
    assert.equal(r.status, 400);
    assert.equal(r.body.error, 'unknown action');
    assert.deepEqual(f.seen, []);
  }
  assert.equal(f.row().status, 'queued');
  assert.equal(f.events().length, 0);
  f.db.close();
});

test('hold: a claim that lands between the read and the CAS wins — 409, no event, still claimed', async () => {
  let fired = false;
  let db;
  const f = await fixture({
    beforeRun(sql) {
      if (!fired && /UPDATE deploy_queue SET status='held'/.test(sql)) {
        fired = true;
        db.prepare("UPDATE deploy_queue SET status='claimed', claimed_by='box-z', updated_at='2099-01-01T00:00:00Z' WHERE sha=?").run(SHA);
      }
    },
  });
  db = f.db;
  await f.enqueue();
  const r = await f.act('hold');
  assert.ok(fired, 'the race ran');
  assert.equal(r.status, 409);
  assert.equal(r.body.refused, true);
  assert.match(r.body.error, /moved, reload/);
  assert.equal(f.row().status, 'claimed');
  assert.equal(f.row().claimed_by, 'box-z');
  assert.equal(f.events().length, 0);
  f.db.close();
});

test('hold: a same-second write that lands first writes no phantom HELD event', async () => {
  let fired = false;
  let db;
  const f = await fixture({
    beforeRun(sql, binds) {
      if (!fired && /UPDATE deploy_queue SET status='held'/.test(sql)) {
        fired = true;
        // binds: ?1 project ?2 sha ?3 reason ?4 t ?5 read updated_at
        db.prepare("UPDATE deploy_queue SET status='held', updated_at=? WHERE sha=?").run(binds[3], SHA);
      }
    },
  });
  db = f.db;
  await f.enqueue();
  const r = await f.act('hold');
  assert.ok(fired, 'the race ran');
  assert.equal(r.status, 409);
  assert.equal(f.row().status, 'held');
  assert.equal(f.events().filter((e) => e.verdict === 'HELD').length, 0);
  f.db.close();
});

test('hold / unhold: no such row is a 404', async () => {
  const f = await fixture();
  assert.equal((await f.act('hold')).status, 404);
  assert.equal((await f.act('unhold')).status, 404);
  await f.enqueue(SHA, 'other-proj');
  assert.equal((await f.act('hold')).status, 404);
  assert.equal(f.row(SHA, 'other-proj').status, 'queued');
  assert.equal(f.events().length, 0);
  f.db.close();
});
