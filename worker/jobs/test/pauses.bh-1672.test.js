// BH-1682 (BH-1672.1): the /api/pauses routes over the `pauses` table.
//
// A pause is a row with a reason, an actor and an expiry (BH-1681 shipped the
// table). These routes create, renew, list, end and expire those rows.
//
// WHAT IS PINNED, on a REAL schema.sql database behind the node:sqlite shim and
// through the real worker.fetch (bearer, router and table all under test):
//   1. PUT creates with the `pause_default_ttl_s` settings row's ttl (86400 when
//      the row is unusable), clamps ttl_s to [60, 604800], renews the live row
//      under the same id, and refuses what it cannot store with a 400 and no write;
//   2. every timestamp a route writes is YYYY-MM-DDTHH:MM:SSZ (the operator, #1868
//      review): expires_at > now is a STRING comparison, true only for one shape;
//   3. GET active=1 is judged at read time: ended rows and unended rows past
//      their expiry are not live;
//   4. /end resumes only a live row; /expire returns a due row exactly once.
//
// Time is moved by seeding rows with past/future expires_at, not by mocking a
// clock: the worker's clock is the real one. Every fixture time is at(offset)
// off the ONE anchor captured below; the offsets (>= 1s) dwarf the suite's run
// time, so a row seeded past or future stays on that side of the worker's now.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const ZFORM = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

const call = (DB, path, { method = 'GET', body, auth = true } = {}) => {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};

const ANCHOR = Date.now();  // determinism: ok the single anchor; every fixture below is at(ms) off it
const isoZ = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const at = (ms) => ANCHOR + ms;
const secs = (a, b) => (Date.parse(b) - Date.parse(a)) / 1000;
const count = (db) => db.prepare('SELECT count(*) AS n FROM pauses').get().n;

// A row seeded straight into the table, the way a past write would have left it.
const seed = (db, { scope = 'project-4', what = 'reviews', expires, ended = null, endReason = null }) =>
  Number(db.prepare(
    `INSERT INTO pauses (scope,what,reason,actor,created_at,expires_at,ended_at,end_reason)
     VALUES (?,?,?,?,?,?,?,?)`
  ).run(scope, what, 'seeded', 'test', isoZ(at(-7200e3)), expires, ended, endReason).lastInsertRowid);

const put = (DB, over = {}) =>
  call(DB, '/api/pauses', { method: 'PUT', body: { scope: 'project-4', what: 'reviews', reason: 'r', actor: 'operator', ...over } });

test('BH-1682 /api/pauses', async (t) => {
  const probe = await openDb();
  if (probe === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  await t.test('1. PUT creates a live row with the 24h default, in the Z form', async () => {
    const { db, DB } = await openDb();
    const r = await put(DB);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const p = r.body.pause;
    assert.equal(p.scope, 'project-4');
    assert.equal(p.what, 'reviews');
    assert.equal(p.reason, 'r');
    assert.equal(p.actor, 'operator');
    assert.equal(p.ended_at, null);
    assert.match(p.created_at, ZFORM);
    assert.match(p.expires_at, ZFORM);
    assert.equal(secs(p.created_at, p.expires_at), 86400);
    assert.equal(count(db), 1);
  });

  await t.test('2. the pause_default_ttl_s settings row sets the default; garbage falls back', async () => {
    const { db, DB } = await openDb();
    db.prepare("UPDATE settings SET value='3600' WHERE key='pause_default_ttl_s'").run();
    let r = await put(DB, { what: 'merges' });
    assert.equal(r.status, 200);
    assert.equal(secs(r.body.pause.created_at, r.body.pause.expires_at), 3600);

    for (const bad of ['abc', '0']) {
      db.prepare("UPDATE settings SET value=? WHERE key='pause_default_ttl_s'").run(bad);
      r = await put(DB, { scope: `s-${bad}` });
      assert.equal(r.status, 200);
      assert.equal(secs(r.body.pause.created_at, r.body.pause.expires_at), 86400, `value ${bad}`);
    }
    db.prepare("DELETE FROM settings WHERE key='pause_default_ttl_s'").run();
    r = await put(DB, { scope: 'no-row' });
    assert.equal(secs(r.body.pause.created_at, r.body.pause.expires_at), 86400);
  });

  await t.test('3. a second PUT renews the same id with a later expiry', async () => {
    const { db, DB } = await openDb();
    const a = (await put(DB)).body.pause;
    const r = await put(DB, { ttl_s: 172800, reason: 'longer', actor: 'hub' });
    assert.equal(r.status, 200);
    const b = r.body.pause;
    assert.equal(b.id, a.id);
    assert.equal(b.created_at, a.created_at);
    assert.ok(Date.parse(b.expires_at) > Date.parse(a.expires_at), `${b.expires_at} > ${a.expires_at}`);
    assert.match(b.expires_at, ZFORM);
    assert.equal(b.reason, 'longer');
    assert.equal(b.actor, 'hub');
    assert.equal(count(db), 1);
  });

  await t.test('4. ttl_s is clamped to [60, 604800]; a non-number is a 400', async () => {
    const { db, DB } = await openDb();
    let r = await put(DB, { ttl_s: 5 });
    assert.equal(r.status, 200);
    assert.equal(secs(r.body.pause.created_at, r.body.pause.expires_at), 60);
    r = await put(DB, { what: 'builds', ttl_s: 10000000 });
    assert.equal(r.status, 200);
    assert.equal(secs(r.body.pause.created_at, r.body.pause.expires_at), 604800);
    const before = count(db);
    r = await put(DB, { what: 'triage', ttl_s: 'abc' });
    assert.equal(r.status, 400);
    assert.match(r.body.error, /ttl_s/);
    r = await put(DB, { what: 'triage', expires_at: 'not a date' });
    assert.equal(r.status, 400);
    assert.match(r.body.error, /expires_at/);
    assert.equal(count(db), before);
    // expires_at is converted to a ttl, and the stored value is still the Z form.
    // The stored expiry is the one asked for: the route rounds the ttl to whole
    // seconds (<= 0.5s) and isoZ truncates the millis (< 1s), so it lands within
    // 1.5s of the request however long the suite has run since ANCHOR.
    const asked = at(7200e3);
    r = await put(DB, { what: 'triage', expires_at: new Date(asked).toISOString() });
    assert.equal(r.status, 200);
    assert.match(r.body.pause.expires_at, ZFORM);
    const off = Date.parse(r.body.pause.expires_at) - asked;
    assert.ok(Math.abs(off) < 1500, `stored expiry ${off}ms off the request`);
    const ttl = secs(r.body.pause.created_at, r.body.pause.expires_at);
    assert.ok(ttl > 7000 && ttl <= 7201, `ttl ${ttl}`);
  });

  await t.test('5. GET active=1 excludes ended and expired rows, judged at read time', async () => {
    const { DB, db } = await openDb();
    const future = isoZ(at(3600e3));
    const live = seed(db, { what: 'reviews', expires: future });
    const ended = seed(db, { what: 'merges', expires: future, ended: isoZ(at(-60e3)), endReason: 'resumed' });
    const stale = seed(db, { what: 'builds', expires: isoZ(at(-1000)) });

    let r = await call(DB, '/api/pauses?active=1');
    assert.equal(r.status, 200);
    assert.deepEqual(r.body.pauses.map((p) => p.id), [live]);
    assert.equal(r.body.truncated, false);
    assert.match(r.body.as_of, ZFORM);

    for (const q of ['?active=0', '']) {
      r = await call(DB, `/api/pauses${q}`);
      assert.equal(r.status, 200);
      assert.deepEqual(r.body.pauses.map((p) => p.id), [stale, ended, live], `query '${q}'`);
      assert.equal(r.body.truncated, false);
    }
    r = await call(DB, '/api/pauses?active=yes');
    assert.equal(r.status, 400);
  });

  await t.test('6. GET caps at 500 and says truncated', async () => {
    const { db, DB } = await openDb();
    const past = isoZ(at(-3600e3));
    const ins = db.prepare(
      `INSERT INTO pauses (scope,what,reason,actor,created_at,expires_at,ended_at,end_reason)
       VALUES (?,'reviews','r','a',?,?,?,'expired')`
    );
    for (let i = 0; i < 501; i++) ins.run(`p${i}`, past, past, past);
    const r = await call(DB, '/api/pauses');
    assert.equal(r.status, 200);
    assert.equal(r.body.pauses.length, 500);
    assert.equal(r.body.truncated, true);
    assert.equal(r.body.pauses[0].scope, 'p500', 'newest first');
  });

  await t.test('7. GET scope= filters literally; a bad scope is a 400', async () => {
    const { db, DB } = await openDb();
    const future = isoZ(at(3600e3));
    const mine = seed(db, { scope: 'project-4', expires: future });
    seed(db, { scope: 'project-3', expires: future });
    seed(db, { scope: 'fleet', expires: future });
    let r = await call(DB, '/api/pauses?active=1&scope=project-4');
    assert.equal(r.status, 200);
    assert.deepEqual(r.body.pauses.map((p) => p.id), [mine]);
    r = await call(DB, `/api/pauses?scope=${encodeURIComponent('a/b')}`);
    assert.equal(r.status, 400);
    assert.match(r.body.error, /scope/);
  });

  await t.test('8. /end resumes a live row once; 404 for ended, unknown, expired', async () => {
    const { db, DB } = await openDb();
    const id = (await put(DB)).body.pause.id;
    let r = await call(DB, `/api/pauses/${id}/end`, { method: 'POST' });
    assert.equal(r.status, 200);
    assert.equal(r.body.pause.id, id);
    assert.equal(r.body.pause.end_reason, 'resumed');
    assert.match(r.body.pause.ended_at, ZFORM);

    r = await call(DB, `/api/pauses/${id}/end`, { method: 'POST' });
    assert.equal(r.status, 404);
    r = await call(DB, '/api/pauses/999999/end', { method: 'POST' });
    assert.equal(r.status, 404);
    const stale = seed(db, { what: 'builds', expires: isoZ(at(-1000)) });
    r = await call(DB, `/api/pauses/${stale}/end`, { method: 'POST' });
    assert.equal(r.status, 404);
    assert.equal(db.prepare('SELECT ended_at FROM pauses WHERE id=?').get(stale).ended_at, null);
    // Only digits reach the route; anything else is the worker's own 404.
    r = await call(DB, '/api/pauses/x/end', { method: 'POST' });
    assert.equal(r.status, 404);
    assert.equal(r.body.error, 'unknown endpoint');
  });

  await t.test('9. /expire returns a due row once, stamped ended_at=expires_at', async () => {
    const { db, DB } = await openDb();
    const due = isoZ(at(-5000));
    const id = seed(db, { expires: due });
    const live = seed(db, { what: 'merges', expires: isoZ(at(3600e3)) });
    let r = await call(DB, '/api/pauses/expire', { method: 'POST' });
    assert.equal(r.status, 200);
    assert.equal(r.body.expired.length, 1);
    assert.equal(r.body.expired[0].id, id);
    assert.equal(r.body.expired[0].end_reason, 'expired');
    assert.equal(r.body.expired[0].ended_at, due);
    assert.match(r.body.expired[0].ended_at, ZFORM);
    assert.match(r.body.as_of, ZFORM);
    r = await call(DB, '/api/pauses/expire', { method: 'POST' });
    assert.equal(r.status, 200);
    assert.deepEqual(r.body.expired, []);
    assert.equal(db.prepare('SELECT ended_at FROM pauses WHERE id=?').get(live).ended_at, null);
  });

  await t.test('10. PUT over an unended row past its expiry makes a new row', async () => {
    const { db, DB } = await openDb();
    const due = isoZ(at(-1000));
    const old = seed(db, { expires: due });
    const r = await put(DB);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.notEqual(r.body.pause.id, old);
    assert.equal(r.body.pause.ended_at, null);
    const o = db.prepare('SELECT ended_at, end_reason FROM pauses WHERE id=?').get(old);
    assert.equal(o.end_reason, 'expired');
    assert.equal(o.ended_at, due);
  });

  await t.test('11. PUT refuses what it cannot store, and writes nothing', async () => {
    const { db, DB } = await openDb();
    const cases = [
      [{ what: 'deploys' }, /what/],
      [{ reason: '' }, /reason/],
      [{ reason: '   ' }, /reason/],
      [{ scope: 'a/b' }, /scope/],
      [{ scope: '' }, /scope/],
      [{ actor: undefined }, /actor/],
    ];
    for (const [over, re] of cases) {
      const r = await put(DB, over);
      assert.equal(r.status, 400, JSON.stringify(over));
      assert.match(r.body.error, re);
    }
    assert.equal(count(db), 0);
  });

  await t.test('12. no bearer, no pauses', async () => {
    const { DB } = await openDb();
    const r = await call(DB, '/api/pauses', { auth: false });
    assert.equal(r.status, 401);
  });

  await t.test('503 when the table is not applied', async () => {
    const { db, DB } = await openDb();
    db.exec('DROP TABLE pauses');
    const r = await call(DB, '/api/pauses');
    assert.equal(r.status, 503);
    assert.equal(r.body.error, 'pauses schema not applied');
  });
});
