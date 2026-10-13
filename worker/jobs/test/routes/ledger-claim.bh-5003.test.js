// BH-5003: POST /api/ledger/claim — the ledger's compare-and-set.
//
// PUT /api/ledger is a blind upsert, so two hubs ticking in the same second
// both read "not sent" and both sent the daily digest. The claim is ONE
// statement: take the row when it is absent, or when its status is not
// terminal and (differs from the claimed one, or is the same one gone stale).
//
// Runs on a REAL schema.sql database behind the node:sqlite shim and through
// the real worker.fetch (bearer, router and SQL all under test).
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';

const post = (DB, body) => worker.fetch(
  new Request('https://jobs.test/api/ledger/claim', {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const row = (db, kind, key) => db.prepare('SELECT * FROM ledgers WHERE kind=? AND key=?').get(kind, key);

function seed(db, kind, key, status, actor, updatedAt, detail = null) {
  db.prepare(`INSERT INTO ledgers (kind, key, status, actor, detail, created_at, updated_at)
              VALUES (?,?,?,?,?,?,?)`).run(kind, key, status, actor, detail, updatedAt, updatedAt);
}

// The route judges staleness against the worker's own clock, so the fixtures
// are derived from one anchor captured at load, not from a fixed instant.
const ANCHOR = Date.now(); // determinism: ok the single anchor every fresh/stale fixture below is derived from
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const HOUR_AGO = () => iso(ANCHOR - 3600 * 1000);
const NOW = () => iso(ANCHOR);
const CLAIM = { kind: 'daily_digest', key: '2026-10-06', status: 'sending', terminal: ['sent'], stale_s: 900 };

test('BH-5003 ledger claim', async (t) => {
  if (!(await openDb())) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  await t.test('K1. a claim on an absent key is won and writes status and actor', async () => {
    const { db, DB } = await openDb();
    const r = await post(DB, { ...CLAIM, actor: 'hub-a' });
    assert.equal(r.status, 200);
    assert.equal(r.body.claimed, true);
    assert.equal(r.body.ledger.status, 'sending');
    assert.equal(r.body.ledger.actor, 'hub-a');
    assert.ok(r.body.as_of);
    assert.equal(row(db, 'daily_digest', '2026-10-06').status, 'sending');
  });

  await t.test('K2. the same status while fresh is NOT claimed; actor and updated_at unchanged', async () => {
    const { db, DB } = await openDb();
    const stamp = NOW();
    seed(db, 'daily_digest', '2026-10-06', 'sending', 'hub-a', stamp);
    const r = await post(DB, { ...CLAIM, actor: 'hub-b' });
    assert.equal(r.status, 200);
    assert.equal(r.body.claimed, false);
    assert.equal(r.body.ledger.actor, 'hub-a');
    const after = row(db, 'daily_digest', '2026-10-06');
    assert.equal(after.actor, 'hub-a');
    assert.equal(after.updated_at, stamp);
  });

  await t.test('K3. a terminal status is never claimed, however old', async () => {
    const { db, DB } = await openDb();
    seed(db, 'daily_digest', '2026-10-06', 'sent', 'hub-a', '2020-01-01T00:00:00Z');
    const r = await post(DB, { ...CLAIM, actor: 'hub-b' });
    assert.equal(r.body.claimed, false);
    assert.equal(r.body.ledger.status, 'sent');
    assert.equal(row(db, 'daily_digest', '2026-10-06').actor, 'hub-a');
  });

  await t.test('K4. the same status older than stale_s is reclaimed by the new actor', async () => {
    const { db, DB } = await openDb();
    seed(db, 'daily_digest', '2026-10-06', 'sending', 'hub-a', HOUR_AGO());
    const r = await post(DB, { ...CLAIM, actor: 'hub-b' });
    assert.equal(r.body.claimed, true);
    assert.equal(r.body.ledger.actor, 'hub-b');
    assert.equal(r.body.ledger.updated_at, r.body.as_of);
  });

  await t.test('K5. a send-failed row is claimable while fresh', async () => {
    const { db, DB } = await openDb();
    seed(db, 'daily_digest', '2026-10-06', 'send-failed', 'hub-a', NOW());
    const r = await post(DB, { ...CLAIM, actor: 'hub-b' });
    assert.equal(r.body.claimed, true);
    assert.equal(r.body.ledger.status, 'sending');
  });

  await t.test('K6. malformed bodies are a 400', async () => {
    const { DB } = await openDb();
    const bad = [
      { ...CLAIM, kind: '' },
      { ...CLAIM, key: undefined },
      { ...CLAIM, status: ' ' },
      { ...CLAIM, stale_s: undefined },
      { ...CLAIM, stale_s: 29 },
      { ...CLAIM, stale_s: 86401 },
      { ...CLAIM, stale_s: 60.5 },
      { ...CLAIM, stale_s: '900' },
      { ...CLAIM, terminal: 'sent' },
      { ...CLAIM, terminal: ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i'] },
      { ...CLAIM, terminal: [1] },
      { ...CLAIM, terminal: [''] },
    ];
    for (const b of bad) {
      const r = await post(DB, b);
      assert.equal(r.status, 400, JSON.stringify(b));
    }
    const edge = await post(DB, { ...CLAIM, stale_s: 30, terminal: ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'] });
    assert.equal(edge.status, 200);
  });

  await t.test('K7. a claim without detail keeps the stored detail; terminal list is honoured', async () => {
    const { db, DB } = await openDb();
    seed(db, 'build_note', 'tproj TK-9', 'pending', 'hub', NOW(), 'TEST-CHANGE: adjudicated ACCEPT');
    const r = await post(DB, {
      kind: 'build_note', key: 'tproj TK-9', status: 'consumed', actor: 'box-1',
      terminal: ['consumed', 'relayed'], stale_s: 30,
    });
    assert.equal(r.body.claimed, true);
    assert.equal(r.body.ledger.detail, 'TEST-CHANGE: adjudicated ACCEPT');
    const again = await post(DB, {
      kind: 'build_note', key: 'tproj TK-9', status: 'consumed', actor: 'box-2',
      terminal: ['consumed', 'relayed'], stale_s: 30,
    });
    assert.equal(again.body.claimed, false);
    assert.equal(row(db, 'build_note', 'tproj TK-9').actor, 'box-1');
  });

  await t.test('K8. a won claim with no actor keeps the stored actor (as the PUT does)', async () => {
    const { db, DB } = await openDb();
    seed(db, 'build_note', 'tproj TK-8', 'pending', 'hub', NOW(), 'note');
    const r = await post(DB, {
      kind: 'build_note', key: 'tproj TK-8', status: 'consumed',
      terminal: ['consumed', 'relayed'], stale_s: 30,
    });
    assert.equal(r.body.claimed, true);
    assert.equal(row(db, 'build_note', 'tproj TK-8').actor, 'hub');
  });
});
