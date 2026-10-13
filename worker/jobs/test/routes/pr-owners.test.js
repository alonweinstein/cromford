import test from 'node:test';
import assert from 'node:assert/strict';
import { call, now } from '../lib/harness.js';

test('pr-owners PUT: one batch upsert with tombstone only when complete is true', async () => {
  const rows = [
    { number: 1, state: 'open', since: '2026-09-01T00:00:00Z', reason: 'r1', key: 'k1', url: 'u1', author: 'a1', draft: 0, dirty_since: 1 },
    { number: 2, state: 'closed', since: '2026-09-02T00:00:00Z' }
  ];
  const r = await call('/api/pr-owners', {
    method: 'PUT',
    body: { repo: 'example-org/cromford', project: 'cromford', actor: 'hub', rows }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.pr_owners, 2);
  assert.equal(r.body.tombstoned, 0);
  const batches = r.db._batches.filter((b) => b.some((s) => /INSERT INTO pr_owners/.test(s.sql)));
  assert.equal(batches.length, 1, 'expected one batch');
  const writes = batches[0].filter((s) => /INSERT INTO pr_owners/.test(s.sql));
  assert.equal(writes.length, 2);
  assert.match(writes[0].sql, /ON CONFLICT\(repo, number\)/);
  assert.equal(writes[0].binds[0], 'example-org/cromford');
  assert.equal(writes[0].binds[1], 1);
  assert.equal(writes[0].binds[11], 'hub');
});

test('pr-owners PUT omits tombstone when complete is absent', async () => {
  const rows = [{ number: 3, state: 'open', since: '2026-09-03T00:00:00Z' }];
  const r = await call('/api/pr-owners', {
    method: 'PUT',
    body: { repo: 'example-org/cromford', project: 'cromford', rows }
  });
  assert.equal(r.status, 200);
  const tombstones = r.db._calls.filter((c) => /UPDATE pr_owners SET closed_at/.test(c.sql));
  assert.equal(tombstones.length, 0);
});

test('pr-owners PUT appends tombstone UPDATE bound to batch numbers when complete:true', async () => {
  const rows = [{ number: 4, state: 'open', since: '2026-09-04T00:00:00Z' }];
  const state = { prOwners: [
    { repo: 'example-org/cromford', number: 99, state: 'open', since: '2026-08-01T00:00:00Z', closed_at: null }
  ] };
  const r = await call('/api/pr-owners', {
    method: 'PUT',
    state,
    body: { repo: 'example-org/cromford', project: 'cromford', complete: true, rows }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.pr_owners, 1);
  assert.equal(r.body.tombstoned, 1);
  const tomb = r.db._calls.find((c) => /UPDATE pr_owners SET closed_at/.test(c.sql));
  assert.ok(tomb, 'tombstone must run');
  assert.match(tomb.sql, /number NOT IN \(/);
  assert.equal(tomb.binds[1], 'example-org/cromford');
  assert.ok(tomb.binds.slice(2).includes(4));
  assert.equal(state.prOwners.find((x) => x.number === 99).closed_at !== null, true, '99 is closed out');
  assert.equal(state.prOwners.find((x) => x.number === 4).closed_at, null, 'the pushed PR stays open');
});

test('pr-owners PUT: complete with an empty rows[] closes out the whole repo', async () => {
  // "The hub owns nothing in this repo now" is the reconciliation that closes
  // the LAST open PR of a repo. An empty array is an array; rejecting it is how
  // a closed PR stays owned forever.
  const state = { prOwners: [
    { repo: 'example-org/project-6-runtime', number: 7, state: 'open', since: '2026-08-01T00:00:00Z', closed_at: null, updated_at: '2026-08-01T00:00:00Z' },
    { repo: 'example-org/other', number: 8, state: 'open', since: '2026-08-01T00:00:00Z', closed_at: null, updated_at: '2026-08-01T00:00:00Z' }
  ] };
  const r = await call('/api/pr-owners', {
    method: 'PUT',
    state,
    body: { repo: 'example-org/project-6-runtime', actor: 'hub', complete: true, rows: [] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.pr_owners, 0);
  assert.equal(r.body.tombstoned, 1);
  assert.equal(r.db._calls.filter((c) => /INSERT INTO pr_owners/.test(c.sql)).length, 0, 'nothing to insert');
  assert.ok(state.prOwners.find((x) => x.number === 7).closed_at, 'the last open PR is tombstoned');
  assert.equal(state.prOwners.find((x) => x.number === 8).closed_at, null, 'another repo is untouched');
});

test('pr-owners PUT: an empty rows[] without complete writes nothing and is not an error', async () => {
  const state = { prOwners: [
    { repo: 'example-org/cromford', number: 7, state: 'open', since: '2026-08-01T00:00:00Z', closed_at: null, updated_at: '2026-08-01T00:00:00Z' }
  ] };
  const r = await call('/api/pr-owners', { method: 'PUT', state, body: { repo: 'example-org/cromford', rows: [] } });
  assert.equal(r.status, 200);
  assert.deepEqual([r.body.pr_owners, r.body.tombstoned], [0, 0]);
  assert.equal(r.db._calls.filter((c) => /pr_owners/.test(c.sql)).length, 0, 'no statement at all');
  assert.equal(state.prOwners[0].closed_at, null);
});

test('pr-owners PUT replayed: same binds, one row, no second insert', async () => {
  const state = { prOwners: [] };
  const rows = [{ number: 11, state: 'open', since: '2026-09-05T00:00:00Z', reason: 'waiting', key: 'k', url: 'u', author: 'a', draft: false, dirty_since: 1754000000 }];
  const body = { repo: 'example-org/cromford', project: 'cromford', actor: 'hub', rows };
  const first = await call('/api/pr-owners', { method: 'PUT', state, body });
  const second = await call('/api/pr-owners', { method: 'PUT', state, body });
  assert.equal(second.status, 200);
  assert.equal(state.prOwners.length, 1, 'the upsert replaced the row, it did not add one');
  const binds = (r) => r.db._batches[0].filter((x) => /INSERT INTO pr_owners/.test(x.sql))[0].binds.slice(0, 12);
  assert.deepEqual(binds(second), binds(first), 'same payload binds on replay (updated_at aside)');
  assert.equal(second.db._batches[0].filter((x) => /INSERT INTO pr_owners/.test(x.sql)).length, 1);
  assert.equal(state.prOwners[0].draft, 0, 'a boolean draft still stores as 0/1');
  assert.equal(state.prOwners[0].dirty_since, 1754000000);
});

test('pr-owners PUT: a repo with more open PRs than D1 can bind still tombstones in one statement', async () => {
  // D1 binds at most 100 parameters per statement, and env.DB.batch is a
  // transaction: a tombstone that bound one parameter per PR number would throw
  // (Cloudflare 1101) and roll back every upsert in front of it.
  const rows = [];
  for (let n = 1; n <= 150; n += 1) rows.push({ number: n, state: 'open', since: '2026-09-01T00:00:00Z' });
  const state = { prOwners: [
    { repo: 'example-org/cromford', number: 900, state: 'open', since: '2026-01-01T00:00:00Z', closed_at: null, updated_at: '2026-01-01T00:00:00Z' }
  ] };
  const r = await call('/api/pr-owners', {
    method: 'PUT',
    state,
    body: { repo: 'example-org/cromford', complete: true, rows }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.pr_owners, 150);
  for (const stmt of r.db._batches[0]) {
    assert.ok(stmt.binds.length <= 100, `statement bound ${stmt.binds.length} parameters: ${stmt.sql.slice(0, 60)}`);
  }
  assert.equal(r.body.tombstoned, 1, 'the PR the push did not name is closed');
  assert.ok(state.prOwners.find((x) => x.number === 900).closed_at);
  assert.equal(state.prOwners.find((x) => x.number === 150).closed_at, null, 'a PR in the push stays open');
});

test('pr-owners PUT rejects a non-integer number and a non-object row', async () => {
  const fractional = await call('/api/pr-owners', {
    method: 'PUT',
    body: { repo: 'example-org/cromford', rows: [{ number: 1.5, state: 'open', since: '2026-09-01T00:00:00Z' }] }
  });
  assert.equal(fractional.status, 400, 'PR 1.5 must not be filed as PR 1');
  assert.equal(fractional.db._calls.filter((c) => /INSERT INTO pr_owners/.test(c.sql)).length, 0);
  const junk = await call('/api/pr-owners', { method: 'PUT', body: { repo: 'example-org/cromford', rows: [null] } });
  assert.equal(junk.status, 400, 'a null row is a 400, not a crash');
  assert.equal(junk.db._calls.filter((c) => /INSERT INTO pr_owners/.test(c.sql)).length, 0);
});

test('pr-owners PUT rejects bad rows and writes nothing', async () => {
  const r = await call('/api/pr-owners', {
    method: 'PUT',
    body: { repo: 'example-org/cromford', rows: [{ state: 'open', since: '2026-09-01T00:00:00Z' }] }
  });
  assert.equal(r.status, 400);
  assert.equal(r.db._calls.filter((c) => /INSERT INTO pr_owners/.test(c.sql)).length, 0);
});

test('pr-owners GET requires repo and filters closed_at by default', async () => {
  const missing = await call('/api/pr-owners');
  assert.equal(missing.status, 400);
  const state = { prOwners: [
    { repo: 'example-org/cromford', number: 1, state: 'open', since: '2026-09-01T00:00:00Z', closed_at: null },
    { repo: 'example-org/cromford', number: 2, state: 'closed', since: '2026-09-02T00:00:00Z', closed_at: '2026-09-10T00:00:00Z' },
    { repo: 'example-org/other', number: 3, state: 'open', since: '2026-09-01T00:00:00Z', closed_at: null }
  ] };
  const r = await call('/api/pr-owners?repo=example-org/cromford', { state });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.pr_owners.map((p) => p.number), [1]);
  assert.equal(r.body.repo, 'example-org/cromford');
  const sql = r.db._calls.find((c) => /FROM pr_owners/.test(c.sql)).sql;
  assert.match(sql, /closed_at IS NULL/);
  assert.match(sql, /ORDER BY number ASC LIMIT 500/, 'the client pages by number and wants a bounded answer');
  const all = await call('/api/pr-owners?repo=example-org/cromford&all=1', { state });
  assert.deepEqual(all.body.pr_owners.map((p) => p.number), [1, 2], 'ascending by number');
  assert.doesNotMatch(all.db._calls.find((c) => /FROM pr_owners/.test(c.sql)).sql, /closed_at IS NULL/);
});
