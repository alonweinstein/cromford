// BH-3905 (built as BH-4091): a human-token verdict signed in the same second as
// an earlier one on the same repo/pr/head/verdict carries the same human_sig, so
// the later row reads unproven (firstRowBySig). That must be loud, not silent:
//   R1  the POST still writes it, logs `BH-3905 same-second retry` and answers
//       human_sig_duplicate_of: <first id>
//   R2  posts a second apart, and unsigned posts, never carry the key or the log
//   R3  a standing row unproven only because an earlier row has its sig logs
//       `BH-3905 duplicate-signature standing row #<id>` on GET
//   R3b a standing unsigned human row does not
// Driven through worker.fetch on the real schema.sql, with Date pinned.
import test, { mock } from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const LEAD = 'lead-test-token';
const HUMAN = 'human-test-token';
const KEY = 'sig-test-key';
const H = 'c'.repeat(40);
const base = { repo: 'example-org/cromford', pr: 3905, head_sha: H, verdict: 'MERGE', source: 'human' };
const ENV = { HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD, HUMAN_VERDICT_TOKEN: HUMAN, HUMAN_VERDICT_SIG_KEY: KEY };
const NOW = Date.parse('2026-10-03T10:00:00.500Z');

const send = (DB, path, method, { body, human = null, lead = LEAD } = {}) => worker.fetch(
  new Request(`https://jobs.test${path}`, {
    method,
    headers: {
      authorization: `Bearer ${SECRET}`,
      'content-type': 'application/json',
      ...(lead ? { 'x-lead-verdict-token': lead } : {}),
      ...(human ? { 'x-human-verdict-token': human } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  }),
  { DB, ...ENV },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
const post = (DB, opts = {}) => send(DB, '/api/verdicts', 'POST', { body: base, human: HUMAN, ...opts });
const get = (DB) => send(DB, `/api/verdicts?repo=${base.repo}&pr=${base.pr}&head=${H}`, 'GET', { lead: null });

// Capture console.error and console.warn while fn runs.
async function logs(fn) {
  const errors = [];
  const warns = [];
  const oe = console.error;
  const ow = console.warn;
  console.error = (...a) => { errors.push(a.join(' ')); };
  console.warn = (...a) => { warns.push(a.join(' ')); };
  let out;
  try { out = await fn(); } finally { console.error = oe; console.warn = ow; }
  return { out, errors, warns };
}

test.beforeEach(() => mock.timers.enable({ apis: ['Date'], now: NOW }));
test.afterEach(() => mock.timers.reset());

test('R1 a same-second identical human-token post is written, logged and flagged', async () => {
  const { db, DB } = await openDb();
  const { out: [a, b], errors } = await logs(async () => [await post(DB), await post(DB)]);
  assert.equal(a.status, 201, JSON.stringify(a.body));
  assert.equal(b.status, 201, JSON.stringify(b.body));
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM verdicts').get().n, 2, 'append-only: both rows are written');
  assert.equal(b.body.verdict.human_sig, a.body.verdict.human_sig);
  assert.equal(b.body.human_sig_duplicate_of, a.body.verdict.id);
  assert.equal('human_sig_duplicate_of' in a.body, false, 'the first post carries no duplicate key');
  const dup = errors.filter((l) => l.includes('BH-3905 same-second retry'));
  assert.equal(dup.length, 1, JSON.stringify(errors));
  assert.ok(dup[0].includes(`#${a.body.verdict.id}`), dup[0]);
  assert.ok(!dup[0].includes(a.body.verdict.human_sig), 'the sig is never logged');
});

test('R2 posts a second apart, and unsigned human posts, carry no duplicate key and log nothing', async () => {
  const { DB } = await openDb();
  const { out: [a, b, c, d], errors } = await logs(async () => {
    const first = await post(DB);
    mock.timers.tick(1000);
    const second = await post(DB);
    // a lead-token source=human post (shadow) is unsigned, twice in one second
    const u1 = await post(DB, { human: null });
    const u2 = await post(DB, { human: null });
    return [first, second, u1, u2];
  });
  for (const r of [a, b, c, d]) assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.notEqual(a.body.verdict.human_sig, b.body.verdict.human_sig);
  for (const r of [a, b, c, d]) assert.equal('human_sig_duplicate_of' in r.body, false, JSON.stringify(r.body));
  assert.equal(c.body.human_signed, false);
  assert.deepEqual(errors.filter((l) => l.includes('BH-3905')), []);
});

test('R3 GET logs a standing row that is unproven only because an earlier row has its sig', async () => {
  const { DB } = await openDb();
  const { out: [, b] } = await logs(async () => [await post(DB), await post(DB)]);
  const { out: g, errors } = await logs(() => get(DB));
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(g.body.standing.id, b.body.verdict.id);
  assert.equal(g.body.standing.human_proven, false);
  const dup = errors.filter((l) => l.includes(`BH-3905 duplicate-signature standing row #${b.body.verdict.id}`));
  assert.equal(dup.length, 1, JSON.stringify(errors));
  assert.ok(dup[0].includes(`repeats the signature of #${b.body.human_sig_duplicate_of}`), dup[0]);
  // the response shape is unchanged: no new keys on standing
  assert.equal('human_sig_duplicate_of' in g.body.standing, false);
});

test('R3 a duplicated BLOCK is still flagged on POST and logged on GET (informational)', async () => {
  const { DB } = await openDb();
  const blk = { ...base, verdict: 'BLOCK' };
  const { out: [a, b] } = await logs(async () => [await post(DB, { body: blk }), await post(DB, { body: blk })]);
  assert.equal(b.body.human_sig_duplicate_of, a.body.verdict.id);
  const { out: g, errors } = await logs(() => get(DB));
  assert.equal(g.body.standing.verdict, 'BLOCK');
  assert.equal(g.body.standing.source, 'human', 'a BLOCK stands as recorded');
  assert.equal(errors.filter((l) => l.includes('BH-3905 duplicate-signature standing row')).length, 1, JSON.stringify(errors));
});

test('R3b a standing unsigned human row logs no BH-3905 error, only the existing shadow warn', async () => {
  const { db, DB } = await openDb();
  db.prepare(`INSERT INTO verdicts (repo, pr, head_sha, verdict, source, created_at, auth, human_sig)
              VALUES (?,?,?,?,?,?,?,?)`).run(base.repo, base.pr, H, 'MERGE', 'human', '2026-10-03T09:00:00Z', 'human-token', null);
  const { out: g, errors, warns } = await logs(() => get(DB));
  assert.equal(g.status, 200);
  assert.equal(g.body.standing.human_proven, false);
  assert.deepEqual(errors.filter((l) => l.includes('BH-3905')), []);
  assert.equal(warns.filter((l) => l.includes('BH-3846 shadow: unproven source=human standing row')).length, 1, JSON.stringify(warns));
});

test('R3c a standing junk-sig row repeating an earlier junk sig logs no BH-3905 error: it is unproven by its sig, not by order', async () => {
  const { db, DB } = await openDb();
  const ins = db.prepare(`INSERT INTO verdicts (repo, pr, head_sha, verdict, source, created_at, auth, human_sig)
                          VALUES (?,?,?,?,?,?,?,?)`);
  for (let i = 0; i < 2; i++) ins.run(base.repo, base.pr, H, 'MERGE', 'human', '2026-10-03T09:00:00Z', 'human-token', 'ab'.repeat(32));
  const { out: g, errors } = await logs(() => get(DB));
  assert.equal(g.status, 200);
  assert.equal(g.body.standing.id, 2);
  assert.equal(g.body.standing.human_proven, false);
  assert.deepEqual(errors.filter((l) => l.includes('BH-3905')), []);
});
