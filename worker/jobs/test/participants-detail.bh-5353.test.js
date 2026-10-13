import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import worker from '../src/index.js';
import { ensureColumns, ensureTable } from '../src/lib/core.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-5353 (BH-5348.4): the participant detail route and the claim counts on
// the list, which the Mission Control participants screen reads. Driven
// through worker.fetch against real SQLite built from schema.sql.
const SECRET = 'test-secret';
const LEAD = 'lead-test-token';
const ENV = (DB) => ({ DB, HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD });

const fresh = async () => {
  const o = await openDb();
  assert.ok(o, 'node:sqlite is required');
  return o;
};

const mkToken = () => {
  const raw = randomBytes(24).toString('hex');
  return { raw, sha: createHash('sha256').update(raw).digest('hex') };
};

const call = (DB, path, { method = 'GET', body, lead, token } = {}) => {
  const headers = { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' };
  if (lead !== undefined) headers['x-lead-verdict-token'] = lead;
  if (token !== undefined) headers['x-participant-token'] = token;
  const req = new Request(`https://jobs.test/api/participants${path}`, {
    method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, ENV(DB)).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const noHash = (body) => assert.ok(!JSON.stringify(body).includes('token_sha256'), `token_sha256 leaked: ${JSON.stringify(body)}`);

async function enrolled(DB, name, { approve = true } = {}) {
  const tok = mkToken();
  const res = await call(DB, '/request', { method: 'POST', body: { name, requested_roles: ['lead-review', 'fix'], token_sha256: tok.sha } });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  if (approve) {
    const ok = await call(DB, `/${res.body.participant.id}/approve`, { method: 'POST', body: { granted_roles: ['lead-review'] }, lead: LEAD });
    assert.equal(ok.status, 200, JSON.stringify(ok.body));
  }
  return { tok, p: res.body.participant };
}

let seq = 0;
async function review(DB, { repo = 'example-org/cromford', pr = ++seq, status, verdict = null, participant, updated_at }) {
  const env = ENV(DB);
  await ensureTable(env, 'lead_review_requests');
  await ensureColumns(env, 'lead_review_requests');
  const t = updated_at || `2026-10-08T00:${String(seq % 60).padStart(2, '0')}:00Z`;
  await DB.prepare(
    `INSERT INTO lead_review_requests (id, repo, pr, head_sha, status, verdict, participant, created_at, updated_at)
     VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)`
  ).bind(`r-${seq}-${pr}`, repo, pr, `sha${seq}`, status, verdict, participant, t, t).run();
}

async function project(DB, name, repo) {
  await ensureTable(ENV(DB), 'projects');
  await DB.prepare(`INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES (?1,?2,0,'t','t')`).bind(name, repo).run();
}

test('1. the detail of an approved participant: 200, its row, never token_sha256', async () => {
  const { DB } = await fresh();
  const { p } = await enrolled(DB, 'mac-a');
  const r = await call(DB, `/${p.id}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  noHash(r.body);
  assert.equal(r.body.participant.name, 'mac-a');
  assert.equal(r.body.participant.status, 'approved');
  assert.deepEqual(r.body.participant.granted_roles, ['lead-review']);
  assert.deepEqual(r.body.claims, []);
  assert.deepEqual(r.body.results, []);
  assert.equal(r.body.truncated, false);
});

test('2. claims are its running rows, results the rest; another participant\'s rows never show', async () => {
  const { DB } = await fresh();
  const { p } = await enrolled(DB, 'mac-a');
  await enrolled(DB, 'mac-b');
  await review(DB, { status: 'running', participant: 'mac-a', pr: 101 });
  await review(DB, { status: 'running', participant: 'mac-a', pr: 102 });
  await review(DB, { status: 'done', verdict: 'MERGE', participant: 'mac-a', pr: 103 });
  await review(DB, { status: 'running', participant: 'mac-b', pr: 104 });
  // the pool-claimed row (no participant) is nobody's
  await review(DB, { status: 'running', participant: null, pr: 105 });
  const r = await call(DB, `/${p.id}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  noHash(r.body);
  assert.deepEqual(r.body.claims.map((c) => c.pr).sort(), [101, 102]);
  assert.equal(r.body.results.length, 1);
  assert.equal(r.body.results[0].pr, 103);
  assert.equal(r.body.results[0].verdict, 'MERGE');
  assert.equal(r.body.results[0].status, 'done');
  for (const k of ['id', 'repo', 'pr', 'head_sha', 'status', 'verdict', 'heartbeat_at', 'updated_at', 'project']) {
    assert.ok(k in r.body.claims[0], `claim row carries ${k}`);
  }
});

test('3. project comes from the projects registry by repo, null when there is no row', async () => {
  const { DB } = await fresh();
  const { p } = await enrolled(DB, 'mac-a');
  await project(DB, 'cromford', 'example-org/cromford');
  await review(DB, { status: 'running', participant: 'mac-a', repo: 'example-org/cromford', pr: 7 });
  await review(DB, { status: 'running', participant: 'mac-a', repo: 'example-org/unregistered', pr: 8 });
  const r = await call(DB, `/${p.id}`);
  const by = Object.fromEntries(r.body.claims.map((c) => [c.pr, c.project]));
  assert.deepEqual(by, { 7: 'cromford', 8: null });
});

test('4. an unknown id is a 404 naming it', async () => {
  const { DB } = await fresh();
  const r = await call(DB, '/00000000-0000-0000-0000-000000000000');
  assert.equal(r.status, 404);
  assert.equal(r.body.error, 'no such participant');
});

test('5. /whoami is still whoami, not the detail of a participant called whoami', async () => {
  const { DB } = await fresh();
  const { tok, p } = await enrolled(DB, 'mac-a');
  const who = await call(DB, '/whoami', { token: tok.raw });
  assert.equal(who.status, 200, JSON.stringify(who.body));
  assert.deepEqual(who.body, { id: p.id, name: 'mac-a', status: 'approved', granted_roles: ['lead-review'], knobs: {} });
});

test('6. the list carries claims, last_result and online_window_s from settings', async () => {
  const { DB } = await fresh();
  const a = await enrolled(DB, 'mac-a');
  const c = await enrolled(DB, 'mac-c');
  await project(DB, 'cromford', 'example-org/cromford');
  await review(DB, { status: 'running', participant: 'mac-a', pr: 201 });
  await review(DB, { status: 'running', participant: 'mac-a', pr: 202 });
  await review(DB, { status: 'done', verdict: 'BLOCK', participant: 'mac-a', pr: 203, updated_at: '2026-10-07T00:00:00Z' });
  await review(DB, { status: 'done', verdict: 'MERGE', participant: 'mac-a', pr: 204, updated_at: '2026-10-08T05:00:00Z' });
  const r = await call(DB, '');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  noHash(r.body);
  const by = Object.fromEntries(r.body.participants.map((x) => [x.id, x]));
  assert.equal(by[a.p.id].claims, 2);
  assert.equal(by[c.p.id].claims, 0);
  assert.deepEqual(by[a.p.id].last_result, { verdict: 'MERGE', repo: 'example-org/cromford', pr: 204, project: 'cromford', at: '2026-10-08T05:00:00Z' });
  assert.equal(by[c.p.id].last_result, null);
  assert.equal(r.body.online_window_s, 900);
  assert.equal(r.body.truncated, false);

  await DB.prepare(`INSERT INTO settings (key, value, note, actor, updated_at) VALUES ('lead_review_claim_stale_s','120','t','t','t')
    ON CONFLICT(key) DO UPDATE SET value='120'`).run();
  const r2 = await call(DB, '');
  assert.equal(r2.body.online_window_s, 120);
  const r3 = await call(DB, `/${a.p.id}`);
  assert.equal(r3.body.online_window_s, 120);

  // garbage in the settings row is the documented fallback, never NaN
  await DB.prepare(`UPDATE settings SET value='soon' WHERE key='lead_review_claim_stale_s'`).run();
  assert.equal((await call(DB, '')).body.online_window_s, 900);
});

test('7. a D1 fault on the detail route is a 503 naming participant_machines', async () => {
  const DB = { prepare() { throw new Error('D1_ERROR: boom'); } };
  const r = await call(DB, '/00000000-0000-0000-0000-000000000000');
  assert.equal(r.status, 503);
  assert.match(r.body.error, /participant_machines/);
});

test('8. more than 50 rows: 50 returned and truncated says so', async () => {
  const { DB } = await fresh();
  const { p } = await enrolled(DB, 'mac-a');
  for (let i = 0; i < 52; i++) await review(DB, { status: 'done', verdict: 'MERGE', participant: 'mac-a', pr: 1000 + i });
  const r = await call(DB, `/${p.id}`);
  assert.equal(r.status, 200);
  assert.equal(r.body.claims.length + r.body.results.length, 50);
  assert.equal(r.body.truncated, true);
});
