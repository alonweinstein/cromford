// BH-2743: a fly_images row is written `baked` (inactive) first and becomes
// active only after the rollout's SMOKE passes. A failed smoke records
// `smoke_failed` on the candidate and leaves the active row exactly as it was;
// an activation demotes the previous row. Driven through the REAL router
// against a real schema.sql database (the node:sqlite shim), as the #2523 suite.
// The shell side is tests/fly-images.bh-2743-test.sh.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const APP = 'builder-alpha-os';
const REF_A = 'registry.fly.io/builder-alpha-os:deployment-01AAAAAAAAAAAAAAAAAAAAAAAA';
const REF_B = 'registry.fly.io/builder-alpha-os:deployment-01BBBBBBBBBBBBBBBBBBBBBBBB';
const REF_C = 'registry.fly.io/builder-alpha-os:deployment-01CCCCCCCCCCCCCCCCCCCCCCCC';

const call = (DB, path, { method = 'GET', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const put = (DB, body) => call(DB, '/api/fly-images', { method: 'PUT', body: { project: 'alpha-os', app: APP, ...body } });
const get = (DB) => call(DB, '/api/fly-images?project=alpha-os');
const rowOf = (db, digest) => db.prepare('SELECT active, state FROM fly_images WHERE project = ? AND digest = ?').get('alpha-os', digest);
const nActive = (db) => db.prepare("SELECT count(*) AS n FROM fly_images WHERE project = 'alpha-os' AND active = 1").get().n;
const ok200 = (res) => assert.equal(res.status, 200, JSON.stringify(res.body));

test('BH-2743 fly_images candidate state', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1: a baked PUT records the candidate inactive and leaves the active row alone', async () => {
    const { DB, db } = await openDb();
    ok200(await put(DB, { digest: REF_A, active: 1 }));
    const res = await put(DB, { digest: REF_B, state: 'baked', baked_at: 1700000000 });
    ok200(res);
    assert.equal(res.body.row.state, 'baked');
    assert.equal(res.body.row.active, 0);
    assert.equal((await get(DB)).body.row.digest, REF_A);
    assert.deepEqual({ ...rowOf(db, REF_B) }, { active: 0, state: 'baked' });
  });

  await t.test('W2 (smoke passes): activating the candidate makes it active and demotes the previous row', async () => {
    const { DB, db } = await openDb();
    ok200(await put(DB, { digest: REF_A, active: 1 }));
    ok200(await put(DB, { digest: REF_B, state: 'baked' }));
    ok200(await put(DB, { digest: REF_B, active: 1 }));
    const g = (await get(DB)).body.row;
    assert.equal(g.digest, REF_B);
    assert.equal(g.state, 'active');
    assert.deepEqual({ ...rowOf(db, REF_A) }, { active: 0, state: 'demoted' });
    assert.equal(nActive(db), 1);
  });

  await t.test('W3 (smoke fails): smoke_failed on the candidate, the active row byte-identical', async () => {
    const { DB, db } = await openDb();
    ok200(await put(DB, { digest: REF_A, active: 1, bake: 'node=22.1\n', baked_at: 1700000000, box: 'hub' }));
    ok200(await put(DB, { digest: REF_B, state: 'baked' }));
    const before = (await get(DB)).body.row;
    const res = await put(DB, { digest: REF_B, state: 'smoke_failed' });
    ok200(res);
    assert.equal(res.body.row.state, 'smoke_failed');
    assert.deepEqual((await get(DB)).body.row, before);
    assert.equal(before.digest, REF_A);
    assert.deepEqual({ ...rowOf(db, REF_B) }, { active: 0, state: 'smoke_failed' });
    assert.equal(nActive(db), 1);
  });

  await t.test('W3b: a state the client may not set is a 400 and writes nothing', async () => {
    const { DB, db } = await openDb();
    ok200(await put(DB, { digest: REF_A, active: 1 }));
    const before = db.prepare('SELECT * FROM fly_images ORDER BY digest').all();
    const bad = [
      { digest: REF_B, state: 'active' },
      { digest: REF_B, state: 'demoted' },
      { digest: REF_B, state: 'SMOKE_FAILED' },
      { digest: REF_B, state: 1 },
      { digest: REF_B, state: 'baked', active: 1 },
      { digest: REF_B, state: 'smoke_failed', active: true },
    ];
    for (const b of bad) {
      const res = await put(DB, b);
      assert.equal(res.status, 400, `${JSON.stringify(b)} -> ${res.status} ${JSON.stringify(res.body)}`);
      assert.equal(typeof res.body.error, 'string');
    }
    assert.deepEqual(db.prepare('SELECT * FROM fly_images ORDER BY digest').all(), before);
    assert.equal((await get(DB)).body.row.digest, REF_A);
  });

  await t.test('W3c: absent state is null, never baked; a resend without state keeps the stored one', async () => {
    const { DB, db } = await openDb();
    ok200(await put(DB, { digest: REF_C }));
    assert.equal(rowOf(db, REF_C).state, null);
    ok200(await put(DB, { digest: REF_B, state: 'baked' }));
    ok200(await put(DB, { digest: REF_B, bake: 'node=22.1\n' }));
    assert.equal(rowOf(db, REF_B).state, 'baked');
  });

  await t.test('W4: a candidate state on the ACTIVE digest never relabels or deactivates it', async () => {
    const { DB, db } = await openDb();
    ok200(await put(DB, { digest: REF_A, active: 1 }));
    ok200(await put(DB, { digest: REF_A, state: 'smoke_failed' }));
    ok200(await put(DB, { digest: REF_A, state: 'baked' }));
    assert.deepEqual({ ...rowOf(db, REF_A) }, { active: 1, state: 'active' });
    assert.equal((await get(DB)).body.row.state, 'active');
  });

  await t.test('W5: a #2523-shape table gains the column on the first PUT; a legacy active row demotes', async () => {
    const { DB, db } = await openDb();
    db.exec('DROP TABLE IF EXISTS fly_images');
    db.exec(`CREATE TABLE fly_images (
       project TEXT NOT NULL, digest TEXT NOT NULL, app TEXT NOT NULL, bake TEXT, cli TEXT,
       baked_at INTEGER, active INTEGER NOT NULL DEFAULT 0, box TEXT, set_at TEXT NOT NULL,
       PRIMARY KEY (project, digest))`);
    db.prepare("INSERT INTO fly_images (project, digest, app, active, set_at) VALUES ('alpha-os', ?, ?, 1, 't')").run(REF_A, APP);
    db.prepare("INSERT INTO fly_images (project, digest, app, active, set_at) VALUES ('alpha-os', ?, ?, 0, 't')").run(REF_C, APP);
    assert.ok(!db.prepare('PRAGMA table_info(fly_images)').all().some((c) => c.name === 'state'));
    ok200(await put(DB, { digest: REF_B, state: 'baked' }));
    assert.ok(db.prepare('PRAGMA table_info(fly_images)').all().some((c) => c.name === 'state'), 'state column added');
    assert.equal(rowOf(db, REF_A).state, null);
    assert.equal((await get(DB)).body.row.state, null, 'a legacy active row reads state null');
    ok200(await put(DB, { digest: REF_B, active: 1 }));
    assert.deepEqual({ ...rowOf(db, REF_A) }, { active: 0, state: 'demoted' });
    assert.deepEqual({ ...rowOf(db, REF_C) }, { active: 0, state: null }, 'an unrelated inactive legacy row is untouched');
    assert.deepEqual({ ...rowOf(db, REF_B) }, { active: 1, state: 'active' });
  });
});
