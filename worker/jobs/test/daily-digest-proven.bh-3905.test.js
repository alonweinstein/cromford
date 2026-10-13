// BH-3905 (built as BH-4091): the daily digest's human_interventions.by_table.
// verdicts counts only PROVEN human rows: a human-token row whose human_sig
// verifies under HUMAN_VERDICT_SIG_KEY and is the lowest verdicts.id carrying
// that sig. An unsigned row, a junk sig and a whole-row replay count 0, and with
// no key nothing can be proven, so the count is 0.
//
// Driven through worker.fetch on the real schema.sql. The signed row is written
// through POST /api/verdicts with the clock pinned inside D; the junk, unsigned
// and replay rows are raw D1 writes, the way `wrangler d1 execute` would do it.
import test, { mock } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHmac } from 'node:crypto';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const LEAD = 'lead-test-token';
const HUMAN = 'human-test-token';
const KEY = 'sig-test-key';
const D = '2026-09-29';
const URL_ = `/api/metrics/daily-digest?day=${D}`;
const EMPTY = JSON.parse(readFileSync(
  new URL('../../../tests/fixtures/daily-digest/empty-day.json', import.meta.url), 'utf8'));
const BY_TABLE_KEYS = Object.keys(EMPTY.autonomy.human_interventions.by_table);
const ENV = { HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD, HUMAN_VERDICT_TOKEN: HUMAN, HUMAN_VERDICT_SIG_KEY: KEY };
const NOKEY = { HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD, HUMAN_VERDICT_TOKEN: HUMAN };
const REPO = 'example-org/cromford';

const call = (DB, path, { env = ENV, ...init } = {}) => worker.fetch(
  new Request(`https://jobs.test${path}`, {
    ...init,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json', ...(init.headers || {}) },
  }),
  { DB, ...env },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

// A human-token MERGE through the real POST, with Date pinned at `at`.
async function signedPost(DB, pr, at) {
  mock.timers.enable({ apis: ['Date'], now: Date.parse(at) });
  try {
    const r = await call(DB, '/api/verdicts', {
      method: 'POST',
      headers: { 'x-lead-verdict-token': LEAD, 'x-human-verdict-token': HUMAN },
      body: JSON.stringify({ repo: REPO, pr, head_sha: 'c'.repeat(40), verdict: 'MERGE', source: 'human' }),
    });
    assert.equal(r.status, 201, JSON.stringify(r.body));
    assert.equal(r.body.human_signed, true);
    return r.body.verdict.id;
  } finally {
    mock.timers.reset();
  }
}

const rawInsert = (db, { pr, auth = null, sig = null, at = `${D}T11:00:00Z` }) =>
  db.prepare(`INSERT INTO verdicts (repo, pr, head_sha, verdict, source, created_at, auth, human_sig)
              VALUES (?,?,?,?,?,?,?,?)`).run(REPO, pr, 'c'.repeat(40), 'MERGE', 'human', at, auth, sig);

const replay = (db, id) => db.prepare(
  `INSERT INTO verdicts (repo, pr, head_sha, verdict, source, reviewer_model, reviewer, report_url, note, created_at, auth, human_sig)
   SELECT repo, pr, head_sha, verdict, source, reviewer_model, reviewer, report_url, note, created_at, auth, human_sig
     FROM verdicts WHERE id=?`).run(id);

// The D1 seed: one signed row, one unsigned, one junk sig, one whole-row replay.
async function seedD1(db, DB) {
  const signed = await signedPost(DB, 1, `${D}T10:00:00Z`);
  rawInsert(db, { pr: 2 });
  rawInsert(db, { pr: 3, auth: 'human-token', sig: 'ab'.repeat(32) });
  replay(db, signed);
  assert.equal(db.prepare(`SELECT COUNT(*) AS n FROM verdicts WHERE source='human'`).get().n, 4);
  return signed;
}

const sumOf = (o) => Object.values(o).reduce((a, b) => a + b, 0);

test('D1 only the signed, first-by-sig human row counts; unsigned, junk and replay rows do not', async () => {
  const { db, DB } = await openDb();
  await seedD1(db, DB);
  const r = await call(DB, URL_);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.autonomy.ok, true, JSON.stringify(r.body.autonomy));
  const hi = r.body.autonomy.human_interventions;
  assert.equal(hi.by_table.verdicts, 1, JSON.stringify(hi));
  assert.deepEqual(Object.keys(hi.by_table), BY_TABLE_KEYS);
  assert.equal(hi.n, sumOf(hi.by_table));
  assert.equal(hi.n, 1);
});

test('D2 two distinct signed posts count 2; a signed row from the previous day counts 0 for D', async () => {
  const { DB } = await openDb();
  await signedPost(DB, 10, `${D}T08:00:00Z`);
  await signedPost(DB, 11, `${D}T23:59:59Z`);
  const r = await call(DB, URL_);
  assert.equal(r.body.autonomy.human_interventions.by_table.verdicts, 2);

  const { DB: DB2 } = await openDb();
  await signedPost(DB2, 12, '2026-09-28T23:59:59Z');
  const prev = await call(DB2, URL_);
  assert.equal(prev.body.autonomy.human_interventions.by_table.verdicts, 0);
  const prevDay = await call(DB2, '/api/metrics/daily-digest?day=2026-09-28');
  assert.equal(prevDay.body.autonomy.human_interventions.by_table.verdicts, 1, 'the row counts on its own day');
});

test('D2b past 5000 rows it counts the first 5000 and warns naming the cap', async () => {
  const { db, DB } = await openDb();
  const at = `${D}T12:00:00Z`;
  const ins = db.prepare(`INSERT INTO verdicts (repo, pr, head_sha, verdict, source, created_at, auth, human_sig)
                          VALUES (?,?,?,?,?,?,?,?)`);
  db.exec('BEGIN');
  for (let pr = 1; pr <= 5001; pr++) {
    // exactly the HMAC the worker's POST writes (verdictSigMessage)
    const sig = createHmac('sha256', KEY).update(`bh-verdict-v1\n${REPO}\n${pr}\n${'c'.repeat(40)}\nMERGE\n${at}`).digest('hex');
    ins.run(REPO, pr, 'c'.repeat(40), 'MERGE', 'human', at, 'human-token', sig);
  }
  db.exec('COMMIT');
  const seen = [];
  const orig = console.warn;
  console.warn = (...a) => { seen.push(a.join(' ')); };
  let r;
  try { r = await call(DB, URL_); } finally { console.warn = orig; }
  assert.equal(r.body.autonomy.ok, true, JSON.stringify(r.body.autonomy));
  assert.equal(r.body.autonomy.human_interventions.by_table.verdicts, 5000);
  const capped = seen.filter((l) => /BH-3905/.test(l) && /5000/.test(l));
  assert.equal(capped.length, 1, `warns: ${JSON.stringify(seen)}`);
});

test('D3 with no HUMAN_VERDICT_SIG_KEY nothing is proven: the D1 seed counts 0', async () => {
  const { db, DB } = await openDb();
  await seedD1(db, DB);
  const r = await call(DB, URL_, { env: NOKEY });
  assert.equal(r.status, 200);
  const hi = r.body.autonomy.human_interventions;
  assert.equal(hi.by_table.verdicts, 0);
  assert.equal(hi.n, sumOf(hi.by_table));
});
