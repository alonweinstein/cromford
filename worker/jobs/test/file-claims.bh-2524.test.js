// BH-2628 (BH-2524.1): the fleet file-claim routes, driven through the REAL
// router against a real schema.sql database (the node:sqlite shim). What is
// pinned are the statements: the upsert that names only the supplied columns,
// the `status='running'` and `files_expires_at > now` filters, the LIMIT+1
// truncation and the MAX over a ticket's not-before windows.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { PREPLAN_FILES_MAX_BYTES, FILE_CLAIM_LIST_MAX } from '../src/lib/core.js';

const SECRET = 'test-secret';
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ANCHOR = Date.now(); // determinism: ok the single anchor every seeded timestamp is derived from

const call = (DB, path, { method = 'GET', body, secret = SECRET } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: secret === null ? {} : { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const put = (DB, id, body) => call(DB, `/api/jobs/${encodeURIComponent(id)}/file-claim`, { method: 'PUT', body });
const list = (DB, qs) => call(DB, `/api/file-claims?${qs}`);
const seedJob = (db, id, { project = 'cromford', ticket = 'BH-1', box = 'boxA', status = 'running' } = {}) =>
  db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at)
              VALUES (?,?,?,?,?,?,?,?,?)`).run(id, project, ticket, 'build', box, 'execute', status,
    iso(ANCHOR), iso(ANCHOR));
const claimRow = (db, id) => db.prepare('SELECT * FROM job_claims WHERE job_id=?').get(id);

test('BH-2524 fleet file claims', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W2 PUT files then GET lists exactly this project\'s live claim', async () => {
    const { db, DB } = await openDb();
    seedJob(db, 'j1');
    seedJob(db, 'o1', { project: 'other', ticket: 'OT-1' });
    const r = await put(DB, 'j1', { files: 'a\nb', ttl_s: 600 });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.job_id, 'j1');
    assert.equal(r.body.overlap_not_before, null);
    const row = claimRow(db, 'j1');
    assert.equal(Date.parse(r.body.files_expires_at) - Date.parse(row.files_claimed_at), 600000);
    assert.equal(row.files_expires_at, r.body.files_expires_at);
    await put(DB, 'o1', { files: 'z', ttl_s: 600 });
    const g = await list(DB, 'project=cromford');
    assert.equal(g.status, 200, JSON.stringify(g.body));
    assert.equal(g.body.claims.length, 1);
    const c = g.body.claims[0];
    assert.deepEqual([c.job_id, c.ticket_id, c.box, c.planned_files], ['j1', 'BH-1', 'boxA', 'a\nb']);
    assert.equal(c.files_claimed_at, row.files_claimed_at);
    assert.equal(g.body.truncated, false);
    assert.equal(g.body.not_before, null);
    assert.equal(typeof g.body.as_of, 'string');
  });

  await t.test('W3 bad ttl and oversized files are refused and write nothing', async () => {
    const { db, DB } = await openDb();
    seedJob(db, 'j1');
    assert.equal((await put(DB, 'j1', { files: 'orig', ttl_s: 600 })).status, 200);
    const before = JSON.stringify(claimRow(db, 'j1'));
    for (const ttl of [30, 90000, 'x', 1.5, true, undefined]) {
      const r = await put(DB, 'j1', { files: 'new', ttl_s: ttl });
      assert.equal(r.status, 400, `ttl_s=${ttl}: ${JSON.stringify(r.body)}`);
      assert.equal(JSON.stringify(claimRow(db, 'j1')), before, `ttl_s=${ttl} changed the row`);
    }
    // A multi-byte character: the limit is bytes, not characters.
    const big = 'é'.repeat(PREPLAN_FILES_MAX_BYTES / 2) + 'x';
    const r413 = await put(DB, 'j1', { files: big, ttl_s: 600 });
    assert.equal(r413.status, 413, JSON.stringify(r413.body));
    assert.equal(JSON.stringify(claimRow(db, 'j1')), before);
    const exact = 'x'.repeat(PREPLAN_FILES_MAX_BYTES);
    assert.equal((await put(DB, 'j1', { files: exact, ttl_s: 60 })).status, 200);
    assert.equal(claimRow(db, 'j1').planned_files, exact);
    assert.equal((await put(DB, 'j1', { files: 'y', ttl_s: 86400 })).status, 200);
  });

  await t.test('W4 an expired claim is not listed', async () => {
    const { db, DB } = await openDb();
    seedJob(db, 'j1');
    assert.equal((await put(DB, 'j1', { files: 'a', ttl_s: 600 })).status, 200);
    assert.equal((await list(DB, 'project=cromford')).body.claims.length, 1);
    db.prepare('UPDATE job_claims SET files_expires_at=? WHERE job_id=?').run(iso(ANCHOR - 60000), 'j1');
    const g = await list(DB, 'project=cromford');
    assert.equal(g.status, 200);
    assert.deepEqual(g.body.claims, []);
  });

  await t.test('W5 a claim whose job is no longer running is not listed', async () => {
    const { db, DB } = await openDb();
    seedJob(db, 'j1');
    seedJob(db, 'j2', { ticket: 'BH-2', status: 'failed' });
    assert.equal((await put(DB, 'j1', { files: 'a', ttl_s: 600 })).status, 200);
    assert.equal((await put(DB, 'j2', { files: 'b', ttl_s: 600 })).status, 200);
    db.prepare("UPDATE jobs SET status='done' WHERE id='j1'").run();
    const g = await list(DB, 'project=cromford');
    assert.equal(g.status, 200);
    assert.deepEqual(g.body.claims, []);
  });

  await t.test('W6 not_before: live window, lapsed window, MAX across the ticket\'s jobs', async () => {
    const { db, DB } = await openDb();
    seedJob(db, 'j1');
    const r = await put(DB, 'j1', { not_before_s: 600 });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.files_expires_at, null);
    assert.equal(typeof r.body.overlap_not_before, 'string');
    let g = await list(DB, 'project=cromford&ticket=BH-1');
    assert.equal(g.status, 200);
    assert.equal(g.body.not_before.at, r.body.overlap_not_before);
    assert.ok(g.body.not_before.left_s > 590 && g.body.not_before.left_s <= 600, JSON.stringify(g.body));
    // not_before-only claim is never listed as a file claim
    assert.deepEqual(g.body.claims, []);
    // without ticket, not_before is null
    assert.equal((await list(DB, 'project=cromford')).body.not_before, null);
    db.prepare('UPDATE job_claims SET overlap_not_before=? WHERE job_id=?').run(iso(ANCHOR - 60000), 'j1');
    g = await list(DB, 'project=cromford&ticket=BH-1');
    assert.equal(g.body.not_before, null);
    seedJob(db, 'j2');
    seedJob(db, 'j3');
    assert.equal((await put(DB, 'j2', { not_before_s: 100 })).status, 200);
    assert.equal((await put(DB, 'j3', { not_before_s: 500 })).status, 200);
    g = await list(DB, 'project=cromford&ticket=BH-1');
    assert.ok(g.body.not_before.left_s > 490 && g.body.not_before.left_s <= 500, JSON.stringify(g.body));
    // another ticket's window is not this ticket's
    assert.equal((await list(DB, 'project=cromford&ticket=BH-9')).body.not_before, null);
  });

  await t.test('W7 refusals, and the retry ledger is left alone', async () => {
    const { db, DB } = await openDb();
    seedJob(db, 'j1');
    assert.equal((await put(DB, 'nope', { files: 'a', ttl_s: 600 })).status, 404);
    assert.equal(claimRow(db, 'nope'), undefined);
    for (const body of [{}, { files: '  \n ' }, { files: '  \n ', ttl_s: 600 }, { not_before_s: 0 },
      { not_before_s: 86401 }, { files: ['a'], ttl_s: 600 }, { files: 'a', ttl_s: 600, not_before_s: 0 }]) {
      const r = await put(DB, 'j1', body);
      assert.equal(r.status, 400, `${JSON.stringify(body)}: ${JSON.stringify(r.body)}`);
      assert.equal(claimRow(db, 'j1'), undefined, `${JSON.stringify(body)} wrote a row`);
    }
    db.prepare(`INSERT INTO job_claims (job_id, lane, attempts, next_attempt_at, updated_at)
                VALUES ('j1','execute/cromford/claude',3,'2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')`).run();
    assert.equal((await put(DB, 'j1', { files: 'a', ttl_s: 600 })).status, 200);
    assert.equal((await put(DB, 'j1', { not_before_s: 60 })).status, 200);
    const row = claimRow(db, 'j1');
    assert.deepEqual([row.lane, row.attempts, row.next_attempt_at],
      ['execute/cromford/claude', 3, '2026-01-01T00:00:00Z']);
    // the not_before-only PUT left the files columns alone
    assert.equal(row.planned_files, 'a');
    assert.equal(typeof row.files_expires_at, 'string');
    for (const qs of ['project=../x', 'project=', '', 'project=cromford&ticket=a/b', 'project=cromford&ticket=']) {
      assert.equal((await list(DB, qs)).status, 400, qs);
    }
    assert.equal((await call(DB, '/api/file-claims?project=cromford', { secret: null })).status, 401);
    assert.equal((await call(DB, '/api/jobs/j1/file-claim', { method: 'PUT', body: { not_before_s: 60 }, secret: null })).status, 401);
  });

  await t.test('W8 over the cap: truncated, capped, oldest claim first', async () => {
    const { db, DB } = await openDb();
    const n = FILE_CLAIM_LIST_MAX + 1;
    for (let i = 0; i < n; i++) {
      const id = `j${String(i).padStart(3, '0')}`;
      seedJob(db, id, { ticket: `BH-${i}` });
      // claimed_at descends as the id ascends, so id order is NOT claim order
      db.prepare(`INSERT INTO job_claims (job_id, planned_files, files_claimed_at, files_expires_at, updated_at)
                  VALUES (?,?,?,?,?)`).run(id, `f${i}`, iso(ANCHOR - (i + 1) * 1000), iso(ANCHOR + 3600000), iso(ANCHOR));
    }
    const g = await list(DB, 'project=cromford');
    assert.equal(g.status, 200);
    assert.equal(g.body.truncated, true);
    assert.equal(g.body.claims.length, FILE_CLAIM_LIST_MAX);
    const at = g.body.claims.map((c) => c.files_claimed_at);
    assert.deepEqual(at, [...at].sort());
    assert.equal(g.body.claims[0].job_id, `j${String(n - 1).padStart(3, '0')}`);
    db.prepare("DELETE FROM job_claims WHERE job_id='j000'").run();
    const g2 = await list(DB, 'project=cromford');
    assert.equal(g2.body.truncated, false);
    assert.equal(g2.body.claims.length, FILE_CLAIM_LIST_MAX);
  });
});
