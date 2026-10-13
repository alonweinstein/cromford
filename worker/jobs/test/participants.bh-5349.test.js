import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import worker from '../src/index.js';
import { PARTICIPANT_ROLES, participantAuth } from '../src/routes/participants.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-5349 (BH-5348.0): a machine asks to join, the lead approves it, and the
// credential it holds passes the role check. Driven through worker.fetch (the
// production entry point) against real SQLite built from schema.sql.
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

const authReq = (token) => new Request('https://jobs.test/x', { headers: token === undefined ? {} : { 'x-participant-token': token } });

// the hash must never leave the worker, on any route
const noHash = (body) => assert.ok(!JSON.stringify(body).includes('token_sha256'), `token_sha256 leaked: ${JSON.stringify(body)}`);

async function requested(DB, over = {}) {
  const tok = mkToken();
  const res = await call(DB, '/request', { method: 'POST', body: { name: 'mac-test-1', requested_roles: ['lead-review', 'fix'], token_sha256: tok.sha, ...over } });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  noHash(res.body);
  return { tok, p: res.body.participant };
}
const approve = (DB, id, granted_roles = ['lead-review'], lead = LEAD) =>
  call(DB, `/${id}/approve`, { method: 'POST', body: { granted_roles }, lead });

test('1. the observable outcome: request → pending → approve → whoami → role check → revoke → 403', async () => {
  const { db, DB } = await fresh();
  const { tok, p } = await requested(DB);
  assert.equal(p.status, 'pending');
  assert.equal(p.name, 'mac-test-1');
  assert.deepEqual(p.requested_roles, ['lead-review', 'fix']);
  assert.equal(p.granted_roles, null);

  const list = await call(DB, '');
  assert.equal(list.status, 200);
  noHash(list.body);
  assert.equal(list.body.truncated, false);
  assert.deepEqual(list.body.participants.map((r) => [r.id, r.status]), [[p.id, 'pending']]);

  const ok = await approve(DB, p.id);
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  noHash(ok.body);
  assert.equal(ok.body.participant.status, 'approved');
  assert.deepEqual(ok.body.participant.granted_roles, ['lead-review']);
  assert.equal(ok.body.participant.decided_by, 'lead-token');
  assert.match(ok.body.participant.decided_at, /^\d{4}-\d\d-\d\dT/);

  const who = await call(DB, '/whoami', { token: tok.raw });
  assert.equal(who.status, 200, JSON.stringify(who.body));
  noHash(who.body);
  assert.deepEqual(who.body, { id: p.id, name: 'mac-test-1', status: 'approved', granted_roles: ['lead-review'], knobs: {} });

  const fix = await participantAuth(authReq(tok.raw), ENV(DB), 'fix');
  assert.equal(fix.ok, false);
  assert.equal(fix.status, 403);
  assert.match(fix.why, /role fix not granted/);
  const lr = await participantAuth(authReq(tok.raw), ENV(DB), 'lead-review');
  assert.equal(lr.ok, true);
  assert.equal(lr.machine.id, p.id);
  noHash(lr.machine);

  const rv = await call(DB, `/${p.id}/revoke`, { method: 'POST', body: { actor: 'operator' }, lead: LEAD });
  assert.equal(rv.status, 200, JSON.stringify(rv.body));
  noHash(rv.body);
  assert.equal(rv.body.participant.status, 'revoked');
  assert.equal(rv.body.participant.revoked_by, 'operator');
  assert.match(rv.body.participant.revoked_at, /^\d{4}-/);

  // the very next call after revoke is refused: nothing is cached
  const after = await call(DB, '/whoami', { token: tok.raw });
  assert.equal(after.status, 403);
  assert.match(after.body.error, /participant is revoked/);
  assert.equal((await participantAuth(authReq(tok.raw), ENV(DB), 'lead-review')).status, 403);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM participant_machines').get().n, 1);
});

test('2. a request body cannot set status or granted_roles: the row is pending with no grant', async () => {
  const { db, DB } = await fresh();
  const { p } = await requested(DB, { status: 'approved', granted_roles: ['build'], decided_by: 'me' });
  assert.equal(p.status, 'pending');
  const row = db.prepare('SELECT status, granted_roles, decided_by FROM participant_machines WHERE id=?').get(p.id);
  assert.deepEqual({ ...row }, { status: 'pending', granted_roles: null, decided_by: null });
});

test('3. request validation: unknown role, empty/duplicate/non-array roles, bad hash, bad name are 400 and write nothing', async () => {
  const { db, DB } = await fresh();
  const tok = mkToken();
  const base = { name: 'm1', requested_roles: ['fix'], token_sha256: tok.sha };
  const bad = [
    [{ requested_roles: ['admin'] }, /admin/],
    [{ requested_roles: [] }, /requested_roles/],
    [{ requested_roles: 'fix' }, /requested_roles/],
    [{ requested_roles: ['fix', 'fix'] }, /duplicate/],
    [{ token_sha256: 'abc' }, /token_sha256/],
    [{ token_sha256: tok.sha.toUpperCase() }, /token_sha256/],
    [{ name: '' }, /name/],
    [{ name: 'has space' }, /name/],
    [{ name: 'x'.repeat(65) }, /name/],
    [{ owner: 'o'.repeat(129) }, /owner/],
  ];
  for (const [over, re] of bad) {
    const r = await call(DB, '/request', { method: 'POST', body: { ...base, ...over } });
    assert.equal(r.status, 400, JSON.stringify(over));
    assert.match(r.body.error, re);
  }
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM participant_machines').get().n, 0);
});

test('4. a taken name, case- and space-insensitive, is 409; so is a reused token hash', async () => {
  const { db, DB } = await fresh();
  const { tok } = await requested(DB);
  const dup = await call(DB, '/request', { method: 'POST', body: { name: 'Mac-Test-1 ', requested_roles: ['fix'], token_sha256: mkToken().sha } });
  assert.equal(dup.status, 409);
  assert.match(dup.body.error, /name mac-test-1 is already pending/);
  const rehash = await call(DB, '/request', { method: 'POST', body: { name: 'other', requested_roles: ['fix'], token_sha256: tok.sha } });
  assert.equal(rehash.status, 409);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM participant_machines').get().n, 1);
});

test('5. approve without the lead token, or with a wrong one, is 403 and the row stays pending', async () => {
  const { db, DB } = await fresh();
  const { p } = await requested(DB);
  assert.equal((await call(DB, `/${p.id}/approve`, { method: 'POST', body: { granted_roles: ['lead-review'] } })).status, 403);
  assert.equal((await approve(DB, p.id, ['lead-review'], 'wrong')).status, 403);
  assert.equal((await call(DB, `/${p.id}/deny`, { method: 'POST' })).status, 403);
  assert.equal((await call(DB, `/${p.id}/revoke`, { method: 'POST', lead: 'wrong' })).status, 403);
  assert.equal(db.prepare('SELECT status FROM participant_machines WHERE id=?').get(p.id).status, 'pending');
  // a missing id with the token is 404
  assert.equal((await approve(DB, 'nope')).status, 404);
});

test('6. a grant outside requested_roles, an empty grant or a duplicate grant is 400', async () => {
  const { db, DB } = await fresh();
  const { p } = await requested(DB);
  const sup = await approve(DB, p.id, ['build']);
  assert.equal(sup.status, 400);
  assert.match(sup.body.error, /build/);
  assert.equal((await approve(DB, p.id, ['lead-review', 'build'])).status, 400);
  assert.equal((await approve(DB, p.id, [])).status, 400);
  assert.equal((await approve(DB, p.id, ['fix', 'fix'])).status, 400);
  assert.equal((await approve(DB, p.id, 'fix')).status, 400);
  assert.equal(db.prepare('SELECT status FROM participant_machines WHERE id=?').get(p.id).status, 'pending');
});

test('7. deny a pending row → denied; its token is 403; deny of an approved row is 409; revoke of a pending row is 409', async () => {
  const { DB } = await fresh();
  const a = await requested(DB);
  const d = await call(DB, `/${a.p.id}/deny`, { method: 'POST', lead: LEAD });
  assert.equal(d.status, 200, JSON.stringify(d.body));
  noHash(d.body);
  assert.equal(d.body.participant.status, 'denied');
  assert.equal(d.body.participant.decided_by, 'lead-token');
  const who = await call(DB, '/whoami', { token: a.tok.raw });
  assert.equal(who.status, 403);
  assert.match(who.body.error, /participant is denied/);

  const b = await requested(DB, { name: 'mac-test-2' });
  assert.equal((await call(DB, `/${b.p.id}/revoke`, { method: 'POST', lead: LEAD })).status, 409);
  assert.equal((await approve(DB, b.p.id)).status, 200);
  const late = await call(DB, `/${b.p.id}/deny`, { method: 'POST', lead: LEAD });
  assert.equal(late.status, 409);
  assert.match(late.body.error, /approved/);
});

test('8. participantAuth refuses a pending token 403, a blank or whitespace header 401, an unknown token 403', async () => {
  const { DB } = await fresh();
  const { tok } = await requested(DB);
  const pend = await participantAuth(authReq(tok.raw), ENV(DB), 'fix');
  assert.deepEqual([pend.ok, pend.status], [false, 403]);
  assert.match(pend.why, /participant is pending/);
  for (const t of [undefined, '', '   ']) {
    const r = await participantAuth(authReq(t), ENV(DB), 'fix');
    assert.deepEqual([r.ok, r.status], [false, 401], JSON.stringify(t));
  }
  const unk = await participantAuth(authReq(mkToken().raw), ENV(DB), 'fix');
  assert.deepEqual([unk.ok, unk.status], [false, 403]);
  assert.match(unk.why, /unknown participant token/);
  // the same through whoami
  assert.equal((await call(DB, '/whoami')).status, 401);
  assert.equal((await call(DB, '/whoami', { token: '  ' })).status, 401);
  assert.equal((await call(DB, '/whoami', { token: tok.raw })).status, 403);
});

test('9. replays: a double approve with the same grant is 200 unchanged, a different grant is 409; approve of a revoked row is 409; a double revoke is unchanged', async () => {
  const { DB } = await fresh();
  const { p } = await requested(DB);
  const first = await approve(DB, p.id);
  assert.equal(first.status, 200);
  assert.equal(first.body.unchanged, undefined);
  const again = await approve(DB, p.id);
  assert.equal(again.status, 200);
  assert.equal(again.body.unchanged, true);
  assert.equal(again.body.participant.decided_at, first.body.participant.decided_at);
  const other = await approve(DB, p.id, ['fix']);
  assert.equal(other.status, 409);
  assert.equal((await call(DB, `/${p.id}/revoke`, { method: 'POST', lead: LEAD })).status, 200);
  const twice = await call(DB, `/${p.id}/revoke`, { method: 'POST', lead: LEAD });
  assert.equal(twice.status, 200);
  assert.equal(twice.body.unchanged, true);
  const re = await approve(DB, p.id);
  assert.equal(re.status, 409);
  assert.match(re.body.error, /revoked/);
});

test('10. last_seen_at is NULL until an ok participantAuth, and a refused one never stamps it', async () => {
  const { db, DB } = await fresh();
  const { tok, p } = await requested(DB);
  const seen = () => db.prepare('SELECT last_seen_at FROM participant_machines WHERE id=?').get(p.id).last_seen_at;
  await participantAuth(authReq(tok.raw), ENV(DB), 'fix');
  assert.equal(seen(), null);
  await approve(DB, p.id);
  await participantAuth(authReq(tok.raw), ENV(DB), 'fix');
  assert.equal(seen(), null, 'a refused role stamped last_seen_at');
  const ok = await participantAuth(authReq(tok.raw), ENV(DB), 'lead-review');
  assert.equal(ok.ok, true);
  assert.match(seen(), /^\d{4}-\d\d-\d\dT/);
});

test('11. PARTICIPANT_ROLES is the three-role vocabulary', () => {
  assert.deepEqual(PARTICIPANT_ROLES, ['build', 'fix', 'lead-review']);
});

test('12. list: ?status filters, a bad status is 400; malformed granted_roles fails closed and malformed knobs read as {}', async () => {
  const { db, DB } = await fresh();
  const a = await requested(DB);
  await requested(DB, { name: 'mac-test-2' });
  await approve(DB, a.p.id);
  const ap = await call(DB, '?status=approved');
  assert.deepEqual(ap.body.participants.map((r) => r.id), [a.p.id]);
  assert.equal((await call(DB, '?status=pending')).body.participants.length, 1);
  assert.equal((await call(DB, '?status=bogus')).status, 400);

  db.prepare("UPDATE participant_machines SET knobs='{nope' WHERE id=?").run(a.p.id);
  const who = await call(DB, '/whoami', { token: a.tok.raw });
  assert.deepEqual(who.body.knobs, {});
  db.prepare("UPDATE participant_machines SET granted_roles='not json' WHERE id=?").run(a.p.id);
  assert.equal((await participantAuth(authReq(a.tok.raw), ENV(DB), 'lead-review')).status, 403);
});

test('13. a D1 fault is a 503 naming participant_machines, never a 200', async () => {
  const DB = { prepare() { throw new Error('D1_ERROR: boom'); } };
  const r = await call(DB, '');
  assert.equal(r.status, 503);
  assert.match(r.body.error, /participant_machines/);
});
