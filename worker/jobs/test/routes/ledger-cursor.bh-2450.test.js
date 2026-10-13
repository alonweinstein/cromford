// BH-2450: GET /api/ledger pages on a compound (updated_at, key) cursor.
//
// updated_at has 1-second resolution, so a burst of PUTs lands many rows on one
// stamp. A strict `updated_at < before` cursor skipped every row that shared
// the page's last second. The fix: `before` + `before_key` pages on
// `(updated_at < b OR (updated_at = b AND key < k))`, and the order is always
// `updated_at DESC, key DESC`. `before` alone keeps the legacy strict predicate.
//
// Runs on a REAL schema.sql database behind the node:sqlite shim and through
// the real worker.fetch (bearer, router and SQL all under test).
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const KIND = 'brake:triage-family';
const T0 = '2026-09-25T12:00:00Z';
const T1 = '2026-09-25T11:59:59Z';
const T2 = '2026-09-25T11:59:58Z';

const get = (DB, path) => worker.fetch(
  new Request(`https://jobs.test${path}`, { headers: { authorization: `Bearer ${SECRET}` } }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const pad = (i) => `k${String(i).padStart(4, '0')}`;

// Seed rows straight into the table, the way a burst of same-second PUTs leaves them.
function seed(db, kind, stamp, from, n) {
  const stmt = db.prepare(
    `INSERT INTO ledgers (kind,key,status,created_at,updated_at) VALUES (?,?,?,?,?)`,
  );
  db.exec('BEGIN');
  for (let i = from; i < from + n; i++) stmt.run(kind, pad(i), 'set', stamp, stamp);
  db.exec('COMMIT');
}

// Walk the list the way brake_read does: last row's updated_at + key as the cursor.
async function walk(DB, kind) {
  const lengths = [];
  const keys = [];
  let q = '';
  for (let p = 0; p < 20; p++) {
    const r = await get(DB, `/api/ledger?kind=${encodeURIComponent(kind)}&limit=1000${q}`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const rows = r.body.ledgers;
    lengths.push(rows.length);
    for (const row of rows) keys.push(row.key);
    if (rows.length < 1000) break;
    const last = rows[rows.length - 1];
    q = `&before=${encodeURIComponent(last.updated_at)}&before_key=${encodeURIComponent(last.key)}`;
  }
  return { lengths, keys };
}

test('BH-2450 /api/ledger compound cursor', async (t) => {
  const probe = await openDb();
  if (probe === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  await t.test('1. 2,500 same-second rows page as 1000/1000/500, every row exactly once', async () => {
    const { db, DB } = await openDb();
    seed(db, KIND, T0, 0, 2500);
    const { lengths, keys } = await walk(DB, KIND);
    assert.deepEqual(lengths, [1000, 1000, 500]);
    assert.equal(keys.length, 2500);
    assert.equal(new Set(keys).size, 2500);
    for (let i = 0; i < 2500; i++) assert.ok(keys.includes(pad(i)), `missing ${pad(i)}`);
  });

  await t.test('2. ties straddling both page edges, other kinds never leak', async () => {
    const { db, DB } = await openDb();
    seed(db, KIND, T0, 0, 1200);     // page 1 edge falls inside T0
    seed(db, KIND, T1, 1200, 600);   // page 2 edge falls inside T1 (rows 1800..)
    seed(db, KIND, T2, 1800, 300);
    seed(db, 'brake:medic-seen', T0, 0, 1);
    const { lengths, keys } = await walk(DB, KIND);
    assert.deepEqual(lengths, [1000, 1000, 100]);
    assert.equal(keys.length, 2100);
    assert.equal(new Set(keys).size, 2100);
    for (let i = 0; i < 2100; i++) assert.ok(keys.includes(pad(i)), `missing ${pad(i)}`);
  });

  await t.test('3. before alone keeps the legacy strict predicate', async () => {
    const { db, DB } = await openDb();
    seed(db, KIND, T0, 0, 2500);
    const same = await get(DB, `/api/ledger?kind=${encodeURIComponent(KIND)}&limit=1000&before=${encodeURIComponent(T0)}`);
    assert.equal(same.status, 200);
    assert.equal(same.body.ledgers.length, 0);
    seed(db, KIND, T1, 2500, 3);
    const older = await get(DB, `/api/ledger?kind=${encodeURIComponent(KIND)}&limit=1000&before=${encodeURIComponent(T0)}`);
    assert.deepEqual(older.body.ledgers.map((r) => r.key), ['k2502', 'k2501', 'k2500']);
  });

  await t.test('4. page 1 is ordered updated_at DESC, key DESC', async () => {
    const { db, DB } = await openDb();
    seed(db, KIND, T1, 0, 5);
    seed(db, KIND, T0, 5, 5);
    const r = await get(DB, `/api/ledger?kind=${encodeURIComponent(KIND)}&limit=1000`);
    assert.deepEqual(r.body.ledgers.map((x) => x.key),
      ['k0009', 'k0008', 'k0007', 'k0006', 'k0005', 'k0004', 'k0003', 'k0002', 'k0001', 'k0000']);
  });

  await t.test('5. before_key without before, or longer than a key can be, is a 400', async () => {
    const { db, DB } = await openDb();
    seed(db, KIND, T0, 0, 3);
    const alone = await get(DB, `/api/ledger?kind=${encodeURIComponent(KIND)}&before_key=x`);
    assert.equal(alone.status, 400);
    assert.equal(alone.body.error, 'before_key requires before');
    const long = await get(DB, `/api/ledger?kind=${encodeURIComponent(KIND)}&before=${encodeURIComponent(T0)}&before_key=${'x'.repeat(513)}`);
    assert.equal(long.status, 400);
    const max = await get(DB, `/api/ledger?kind=${encodeURIComponent(KIND)}&before=${encodeURIComponent(T0)}&before_key=${'x'.repeat(512)}`);
    assert.equal(max.status, 200);
  });
});
