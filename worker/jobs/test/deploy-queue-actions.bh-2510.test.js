import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-3152 (BH-2510.2): POST /api/deploy-queue/action, the QUEUES panel's audited
// RELEASE of one claimed deploy-queue row, driven through worker.fetch against
// the SQL that ships (real SQLite, the deploy-queue-routes.bh-1026 idiom).
//
// The guards ARE the feature: the status write is a CAS bound to the row the
// route read, and the RELEASED event only lands in the same batch when that
// CAS changed the row. A stub answering changes:1 would pass a route that
// wrote an event for a release it lost, so the lost-CAS cases below run the
// competing write with `hooks.beforeRun`, between the read and the UPDATE.

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

async function fixture(hooks = {}) {
  const opened = await openDb(hooks);
  assert.ok(opened, 'node:sqlite is required for this suite — CI runs node 22');
  const { db, DB } = opened;
  const seen = [];
  const call = (path, body) => worker.fetch(new Request(`https://jobs.test${path}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  }), { DB: recorded(DB, seen), HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
  const row = (sha = SHA, project = P) =>
    db.prepare('SELECT * FROM deploy_queue WHERE project=? AND sha=?').get(project, sha) ?? null;
  const events = () => db.prepare("SELECT * FROM stage_events WHERE stage='deploy-queue'").all();
  // Seeded through the production routes, so the fixture is a row the train makes.
  const queueAndClaim = async (sha = SHA, project = P, box = 'box-a') => {
    assert.equal((await call('/api/deploy-queue', { project, sha, build_dir: '/b' })).status, 201);
    const c = await call('/api/deploy-queue/claim', { project, sha, box });
    assert.equal(c.status, 200);
    assert.equal(c.body.claimed, true);
  };
  const release = (over = {}) => call('/api/deploy-queue/action',
    { project: P, sha: SHA, action: 'release', reason: 'train died', actor: 'operator', ...over });
  return { db, seen, call, row, events, queueAndClaim, release };
}

test('release: a claimed row goes back to queued, with one audited RELEASED event, and a train can re-claim it', async () => {
  const f = await fixture();
  await f.queueAndClaim();
  const r = await f.release({ sha: `  ${SHA.toUpperCase()}  ` });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.decision, 'released');
  assert.equal(r.body.actor, 'operator');
  assert.equal(r.body.reason, 'train died');
  const row = f.row();
  assert.equal(row.status, 'queued');
  assert.equal(row.claimed_by, null);
  assert.equal(row.departed_at, null);
  assert.equal(row.reason, 'train died');
  assert.deepEqual(r.body.deploy, { ...row });
  const ev = f.events();
  assert.equal(ev.length, 1);
  assert.equal(ev[0].job_id, JOB);
  assert.equal(ev[0].stage, 'deploy-queue');
  assert.equal(ev[0].verdict, 'RELEASED');
  assert.equal(ev[0].actor, 'operator');
  assert.deepEqual(JSON.parse(ev[0].detail), { reason: 'train died', from: 'claimed', to: 'queued' });
  assert.equal(ev[0].created_at, row.updated_at);
  const again = await f.call('/api/deploy-queue/claim', { project: P, sha: SHA, box: 'box-b' });
  assert.equal(again.status, 200);
  assert.equal(again.body.claimed, true);
  assert.equal(f.row().claimed_by, 'box-b');
  f.db.close();
});

test('release refuses a row that is not an undeparted claim: 409, nothing written', async () => {
  const f = await fixture();
  // departed done
  await f.queueAndClaim();
  assert.equal((await f.call('/api/deploy-queue/depart', { project: P, sha: SHA, status: 'done' })).status, 200);
  const before = f.row();
  let r = await f.release();
  assert.equal(r.status, 409);
  assert.equal(r.body.refused, true);
  assert.equal(r.body.scope, 'deploy-queue');
  assert.match(r.body.error, /row is done/);
  assert.deepEqual(f.row(), before);
  assert.equal(f.events().length, 0);

  // departed failed
  const SHA_F = 'f'.repeat(40);
  await f.queueAndClaim(SHA_F);
  assert.equal((await f.call('/api/deploy-queue/depart', { project: P, sha: SHA_F, status: 'failed' })).status, 200);
  r = await f.release({ sha: SHA_F });
  assert.equal(r.status, 409);
  assert.equal(f.row(SHA_F).status, 'failed');

  // claimed with departed_at set: the API cannot make this; defence in depth.
  const SHA_D = 'd'.repeat(40);
  await f.queueAndClaim(SHA_D);
  f.db.prepare("UPDATE deploy_queue SET departed_at='2026-09-28T00:00:00Z' WHERE sha=?").run(SHA_D);
  const claimedDeparted = f.row(SHA_D);
  r = await f.release({ sha: SHA_D });
  assert.equal(r.status, 409);
  assert.equal(r.body.refused, true);
  assert.match(r.body.error, /claimed, departed/);
  assert.deepEqual(f.row(SHA_D), claimedDeparted);

  // queued
  const SHA_Q = 'c'.repeat(40);
  assert.equal((await f.call('/api/deploy-queue', { project: P, sha: SHA_Q })).status, 201);
  const queued = f.row(SHA_Q);
  r = await f.release({ sha: SHA_Q });
  assert.equal(r.status, 409);
  assert.match(r.body.error, /row is queued/);
  assert.deepEqual(f.row(SHA_Q), queued);

  assert.equal(f.events().length, 0, 'no refusal writes an event');
  f.db.close();
});

test('release: a bad body is a 400 before any SQL, and the claim stays', async () => {
  const f = await fixture();
  await f.queueAndClaim();
  const bad = [
    { reason: '' }, { reason: '   ' }, { reason: undefined },
    { actor: undefined }, { actor: '  ' },
    // TEST-CHANGE: BH-3154 — `hold` is a real action now; `HOLD` is still unknown (case-sensitive).
    { action: 'HOLD' }, { action: '__proto__' }, { action: 'constructor' }, { action: 'RELEASE ' }, { action: undefined },
    { sha: 'xyz' }, { sha: '' }, { project: '' }, { project: 'no spaces' },
  ];
  for (const over of bad) {
    f.seen.length = 0;
    const r = await f.release(over);
    assert.equal(r.status, 400, `${JSON.stringify(over)} -> ${r.status} ${JSON.stringify(r.body)}`);
    assert.deepEqual(f.seen, [], `${JSON.stringify(over)} must not touch the DB`);
  }
  assert.equal(f.row().status, 'claimed');
  assert.equal(f.row().claimed_by, 'box-a');
  assert.equal(f.events().length, 0);
  f.db.close();
});

test('release: a claim renewed between the read and the CAS loses — 409, no event, still claimed', async () => {
  let fired = false;
  let db;
  const f = await fixture({
    beforeRun(sql) {
      if (!fired && /UPDATE deploy_queue SET status='queued'/.test(sql)) {
        fired = true;
        db.prepare("UPDATE deploy_queue SET updated_at='2099-01-01T00:00:00Z' WHERE sha=?").run(SHA);
      }
    },
  });
  db = f.db;
  await f.queueAndClaim();
  const r = await f.release();
  assert.ok(fired, 'the race ran');
  assert.equal(r.status, 409);
  assert.equal(r.body.refused, true);
  assert.match(r.body.error, /moved, reload/);
  assert.equal(r.body.deploy.status, 'claimed');
  assert.equal(f.row().status, 'claimed');
  assert.equal(f.row().claimed_by, 'box-a');
  assert.equal(f.events().length, 0);
  f.db.close();
});

test('release: a same-second depart-queued that lands first writes no phantom RELEASED event', async () => {
  let fired = false;
  let db;
  const f = await fixture({
    beforeRun(sql, binds) {
      if (!fired && /UPDATE deploy_queue SET status='queued'/.test(sql)) {
        fired = true;
        // binds: ?1 project ?2 sha ?3 reason ?4 t ?5 read updated_at
        db.prepare("UPDATE deploy_queue SET status='queued', claimed_by=NULL, updated_at=? WHERE sha=?")
          .run(binds[3], SHA);
      }
    },
  });
  db = f.db;
  await f.queueAndClaim();
  const r = await f.release();
  assert.ok(fired, 'the race ran');
  assert.equal(r.status, 409);
  assert.equal(r.body.refused, true);
  assert.equal(f.row().status, 'queued');
  assert.equal(f.events().filter((e) => e.verdict === 'RELEASED').length, 0);
  f.db.close();
});

test('release: no such row is a 404, including the same sha under another project', async () => {
  const f = await fixture();
  let r = await f.release();
  assert.equal(r.status, 404);
  assert.equal(r.body.error, 'nothing queued');
  await f.queueAndClaim(SHA, 'other-proj');
  r = await f.release();
  assert.equal(r.status, 404);
  assert.equal(f.row(SHA, 'other-proj').status, 'claimed');
  assert.equal(f.events().length, 0);
  f.db.close();
});
