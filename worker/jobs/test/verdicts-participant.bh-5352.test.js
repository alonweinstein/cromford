import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import worker from '../src/index.js';
import { ensureColumns } from '../src/lib/core.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-5352 (BH-5348.3): an approved participant machine with the lead-review
// grant may write a source=lead verdict in place of the lead token, but only on
// a head it holds a `done` lead_review_request for. The row names the machine
// (reviewer) and the credential (auth='participant'). Everything else keeps the
// BH-1525 rule. Driven through worker.fetch against SQLite built from schema.sql.
const SECRET = 'test-secret';
const LEAD = 'lead-test-token';
const ENV = (DB) => ({ DB, HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD });
const REPO = 'example-org/cromford';
const PR = 5352;
const H = 'a'.repeat(40);
const H2 = 'b'.repeat(40);
const H3 = 'c'.repeat(40);
const T = '2026-10-08T00:00:00Z';

const sha = (s) => createHash('sha256').update(s).digest('hex');
const TOK = { 'mac-test-1': 'tok-mac-test-1', 'mac-other': 'tok-mac-other', 'mac-fix': 'tok-mac-fix',
              'mac-pend': 'tok-mac-pend', 'mac-deny': 'tok-mac-deny', 'mac-rev': 'tok-mac-rev' };

// Every fetch the worker makes leaves this process; none is allowed (no merge,
// no GitHub). The worker's own D1 calls never go through fetch.
const outbound = [];
const realFetch = globalThis.fetch;
test.before(() => { globalThis.fetch = async (u) => { outbound.push(String(u)); return new Response('{}', { status: 599 }); }; });
test.after(() => { globalThis.fetch = realFetch; });

async function fresh({ claim = { participant: 'mac-test-1', status: 'done', head: H } } = {}) {
  const o = await openDb();
  assert.ok(o, 'node:sqlite is required');
  const { db, DB } = o;
  const seed = db.prepare(`INSERT INTO participant_machines (id, name, requested_roles, granted_roles, token_sha256, billing_account, status, requested_at)
                           VALUES (?,?,?,?,?,?,?,?)`);
  seed.run('p1', 'mac-test-1', '["lead-review"]', '["lead-review"]', sha(TOK['mac-test-1']), 'acct-a', 'approved', T);
  seed.run('p2', 'mac-other', '["lead-review"]', '["lead-review"]', sha(TOK['mac-other']), null, 'approved', T);
  seed.run('p3', 'mac-fix', '["fix"]', '["fix"]', sha(TOK['mac-fix']), null, 'approved', T);
  seed.run('p4', 'mac-pend', '["lead-review"]', null, sha(TOK['mac-pend']), null, 'pending', T);
  seed.run('p5', 'mac-deny', '["lead-review"]', null, sha(TOK['mac-deny']), null, 'denied', T);
  seed.run('p6', 'mac-rev', '["lead-review"]', '["lead-review"]', sha(TOK['mac-rev']), null, 'revoked', T);
  await ensureColumns({ DB }, 'lead_review_requests');
  if (claim) {
    db.prepare(`INSERT INTO lead_review_requests (id, repo, pr, head_sha, status, job_id, created_at, updated_at, participant)
                VALUES ('lr1', ?, ?, ?, ?, 'job-1', ?, ?, ?)`).run(REPO, PR, claim.head, claim.status, T, T, claim.participant);
  }
  // mac-rev holds a done claim of its own on H3: only participantAuth can stop it.
  db.prepare(`INSERT INTO lead_review_requests (id, repo, pr, head_sha, status, job_id, created_at, updated_at, participant)
              VALUES ('lr2', ?, ?, ?, 'done', 'job-2', ?, ?, 'mac-rev')`).run(REPO, PR, H3, T, T);
  return { db, DB };
}

const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM verdicts').get().n;

const post = (DB, { body = {}, lead, token, client } = {}) => {
  const headers = { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' };
  if (lead !== undefined) headers['x-lead-verdict-token'] = lead;
  if (token !== undefined) headers['x-participant-token'] = token;
  if (client !== undefined) headers['x-lead-verdict-client'] = String(client);
  const req = new Request('https://jobs.test/api/verdicts', {
    method: 'POST', headers,
    body: JSON.stringify({ repo: REPO, pr: PR, head_sha: H, verdict: 'MERGE', source: 'lead', ...body }),
  });
  return worker.fetch(req, ENV(DB)).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

test('1. an approved lead-review participant with a done claim on the head writes source=lead, auth=participant, reviewer=its name', async () => {
  const { db, DB } = await fresh();
  const res = await post(DB, { token: TOK['mac-test-1'], body: { reviewer: 'someone-else' } });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  assert.equal(res.body.verdict.source, 'lead');
  assert.equal(res.body.verdict.auth, 'participant');
  assert.equal(res.body.verdict.reviewer, 'mac-test-1');
  assert.equal(res.body.verdict.head_sha, H);
  const row = db.prepare('SELECT source, auth, reviewer FROM verdicts').get();
  assert.deepEqual({ ...row }, { source: 'lead', auth: 'participant', reviewer: 'mac-test-1' });
  assert.equal(count(db), 1);
});

// [name, fresh() options, post() options, expected status, error substring]
const NEGATIVES = [
  ['unknown token hash', {}, { token: 'not-enrolled' }, 403, 'unknown participant token'],
  ['blank participant token', {}, { token: '   ' }, 403, 'needs the lead verdict token'],
  ['pending machine', {}, { token: TOK['mac-pend'] }, 403, 'participant is pending'],
  ['denied machine', {}, { token: TOK['mac-deny'] }, 403, 'participant is denied'],
  ['revoked machine with a done claim of its own', {}, { token: TOK['mac-rev'], body: { head_sha: H3 } }, 403, 'participant is revoked'],
  ['fix-only participant', {}, { token: TOK['mac-fix'] }, 403, 'role lead-review not granted'],
  ['no claim row at all', { claim: null }, { token: TOK['mac-test-1'] }, 403, 'holds no done lead review'],
  ['claim still running', { claim: { participant: 'mac-test-1', status: 'running', head: H } }, { token: TOK['mac-test-1'] }, 403, 'holds no done lead review'],
  ['claim reclaimed by another machine', { claim: { participant: 'mac-other', status: 'done', head: H } }, { token: TOK['mac-test-1'] }, 403, 'holds no done lead review'],
  ['claim reclaimed by a box (participant NULL)', { claim: { participant: null, status: 'done', head: H } }, { token: TOK['mac-test-1'] }, 403, 'holds no done lead review'],
  ['done claim on a different head', { claim: { participant: 'mac-test-1', status: 'done', head: H2 } }, { token: TOK['mac-test-1'] }, 403, 'holds no done lead review'],
  ['claim participant not normalized (inverse case)', { claim: { participant: 'Mac-Test-1 ', status: 'done', head: H } }, { token: TOK['mac-test-1'] }, 403, 'holds no done lead review'],
  ['participant token with source=human', {}, { token: TOK['mac-test-1'], body: { source: 'human' } }, 403, 'needs the lead verdict token'],
  ['participant token with source=risk-tier', {}, { token: TOK['mac-test-1'], body: { source: 'risk-tier' } }, 403, 'needs the lead verdict token'],
];

for (const [name, fo, po, status, msg] of NEGATIVES) {
  test(`2. refused, nothing written: ${name}`, async () => {
    const { db, DB } = await fresh(fo);
    const res = await post(DB, po);
    assert.equal(res.status, status, JSON.stringify(res.body));
    assert.ok(String(res.body?.error || '').includes(msg), `error ${JSON.stringify(res.body)} lacks "${msg}"`);
    assert.equal(count(db), 0);
  });
}

test('2. refused, nothing written: a participant post below lead_verdict_min_client is 426', async () => {
  const { db, DB } = await fresh();
  db.prepare("UPDATE settings SET value='3' WHERE key='lead_verdict_min_client'").run();
  const low = await post(DB, { token: TOK['mac-test-1'], client: 2 });
  assert.equal(low.status, 426, JSON.stringify(low.body));
  assert.equal(count(db), 0);
  const ok = await post(DB, { token: TOK['mac-test-1'], client: 3 });
  assert.equal(ok.status, 201, JSON.stringify(ok.body));
  assert.equal(ok.body.verdict.auth, 'participant');
});

test('3. the lead-token path is unchanged, with or without a participant header', async () => {
  const { db, DB } = await fresh({ claim: null });
  const a = await post(DB, { lead: LEAD, body: { reviewer: 'hub' } });
  assert.equal(a.status, 201, JSON.stringify(a.body));
  assert.equal(a.body.verdict.auth, 'lead-token');
  assert.equal(a.body.verdict.reviewer, 'hub');
  const b = await post(DB, { lead: LEAD, token: 'garbage', body: { reviewer: 'hub' } });
  assert.equal(b.status, 201, JSON.stringify(b.body));
  assert.equal(b.body.verdict.auth, 'lead-token');
  const c = await post(DB, { lead: LEAD, token: TOK['mac-test-1'], body: { reviewer: 'hub' } });
  assert.equal(c.status, 201, JSON.stringify(c.body));
  assert.equal(c.body.verdict.auth, 'lead-token');
  assert.equal(c.body.verdict.reviewer, 'hub');
  const d = await post(DB, {});
  assert.equal(d.status, 403);
  assert.match(d.body.error, /needs the lead verdict token/);
  assert.equal(count(db), 3);
});

test('4. a participant token on source=box is the bearer-only path: auth=secret', async () => {
  const { DB } = await fresh();
  const res = await post(DB, { token: TOK['mac-test-1'], body: { source: 'box', reviewer: 'b1' } });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  assert.equal(res.body.verdict.auth, 'secret');
  assert.equal(res.body.verdict.reviewer, 'b1');
});

test('5. no outbound call at all: no merge, no GitHub', () => {
  assert.deepEqual(outbound, []);
});
