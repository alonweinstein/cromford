// BH-4079: Jira and Linear webhook intake, and per-delivery dedupe for all
// three vendors. Every case goes through the REAL worker.fetch onto the REAL
// schema.sql in node:sqlite, so the assertions are on rows, not on SQL text.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jiraWakeOf, linearWakeOf, WEBHOOK_DEFAULTS } from '../src/lib/tracker-webhooks.js';

const S = { github: 'gh-secret', jira: 'jira-secret', linear: 'linear-secret' };
const REPO = 'Example-Org/example-repo';
// The route checks webhookTimestamp and prunes deliveries off its own request
// clock, so every timestamp fixture is an offset from this one read; the
// smallest margin (300 s, the 900 s window against a 600 s-old event) dwarfs the
// suite's run time.
const ANCHOR = Date.now(); // determinism: ok the single anchor every timestamp fixture is derived from
const hmac = (secret, raw) => createHmac('sha256', secret).update(raw).digest('hex');

async function setup(t, { settings = {}, secrets = S } = {}) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const rows = { 'webhook_route.jira.crom': REPO, 'webhook_route.linear.eng': REPO, ...settings };
  for (const [k, v] of Object.entries(rows)) {
    o.db.prepare(`INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES (?,?,?,?,?)`)
      .run(k, v, 'test', 'test', '2026-10-05T00:00:00Z');
  }
  const env = { DB: o.DB, HARNESS_SECRET: 'bearer' };
  if (secrets.github) env.GITHUB_WEBHOOK_SECRET = secrets.github;
  if (secrets.jira) env.JIRA_WEBHOOK_SECRET = secrets.jira;
  if (secrets.linear) env.LINEAR_WEBHOOK_SECRET = secrets.linear;
  const count = (table) => o.db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;
  const wakes = () => o.db.prepare(`SELECT repo, kind, key, event FROM wakes ORDER BY id`).all()
    .map((r) => ({ ...r }));
  return { ...o, env, count, wakes };
}

// opts: { delivery, sig (override), noSig, tamper, method, headers }
async function send(ctx, vendor, payload, opts = {}) {
  const raw = typeof payload === 'string' ? payload : JSON.stringify(payload);
  const headers = { 'content-type': 'application/json', ...(vendor === 'github' ? { 'x-github-event': 'issues' } : {}), ...(opts.headers || {}) };
  const secret = opts.secret || S[vendor];
  if (!opts.noSig) {
    const hex = hmac(secret, raw);
    if (vendor === 'github') headers['x-hub-signature-256'] = opts.sig ?? 'sha256=' + hex;
    if (vendor === 'jira') headers['x-hub-signature'] = opts.sig ?? 'sha256=' + hex;
    if (vendor === 'linear') headers['linear-signature'] = opts.sig ?? hex;
  }
  if (opts.delivery) {
    const h = { github: 'x-github-delivery', jira: 'x-atlassian-webhook-identifier', linear: 'linear-delivery' }[vendor];
    headers[h] = opts.delivery;
  }
  const method = opts.method || 'POST';
  const req = new Request(`https://jobs.test/webhooks/${vendor}`, {
    method, headers, body: method === 'GET' ? undefined : (opts.tamper ?? raw),
  });
  const res = await worker.fetch(req, ctx.env);
  return { status: res.status, body: await res.json().catch(() => null) };
}

const ghIssue = (n = 7) => ({ action: 'opened', issue: { number: n }, repository: { full_name: REPO } });
const jiraComment = (key = 'CROM-12', who = 'client-acct') => ({
  webhookEvent: 'comment_created', issue: { key }, comment: { id: '1', author: { accountId: who } },
});
const jiraUpdate = (items, key = 'CROM-12') => ({
  webhookEvent: 'jira:issue_updated', issue: { key }, user: { accountId: 'client-acct' },
  changelog: items === undefined ? undefined : { items },
});
const linIssueUpdate = (updatedFrom, ident = 'ENG-5') => ({
  type: 'Issue', action: 'update', actor: { id: 'client-user' },
  data: { id: 'lin-1', identifier: ident }, updatedFrom,
  url: `https://linear.app/example/issue/${ident}/a-title`, webhookTimestamp: ANCHOR,
});
const linComment = (extra = {}) => ({
  type: 'Comment', action: 'create', actor: { id: 'client-user' },
  data: { id: 'c1', body: 'hi' }, url: 'https://linear.app/example/issue/ENG-9/x#comment-1',
  webhookTimestamp: ANCHOR, ...extra,
});
const valid = { github: ghIssue(), jira: jiraComment(), linear: linIssueUpdate({ stateId: 's-old' }) };

// ── valid signed event → one wake ───────────────────────────────────────────
test('valid signed event -> exactly one wake per vendor, with a delivery row', async (t) => {
  const want = {
    github: { repo: REPO, kind: 'issue', key: '7', event: 'issues.opened' },
    jira: { repo: REPO, kind: 'issue', key: 'CROM-12', event: 'jira.comment_created' },
    linear: { repo: REPO, kind: 'issue', key: 'ENG-5', event: 'linear.issue.update' },
  };
  for (const vendor of ['github', 'jira', 'linear']) {
    const ctx = await setup(t); if (!ctx) return;
    const r = await send(ctx, vendor, valid[vendor], { delivery: `${vendor}-d1` });
    assert.equal(r.status, 200, `${vendor}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.duplicate, false, vendor);
    assert.equal(r.body.vendor, vendor);
    assert.deepEqual(ctx.wakes(), [want[vendor]], vendor);
    assert.equal(ctx.count('webhook_deliveries'), 1, vendor);
  }
});

test('github ping is still a 200 pong with no row', async (t) => {
  const ctx = await setup(t); if (!ctx) return;
  const r = await send(ctx, 'github', { zen: 'x' }, { headers: { 'x-github-event': 'ping' }, delivery: 'p1' });
  assert.equal(r.status, 200);
  assert.equal(r.body.pong, true);
  assert.equal(ctx.count('wakes'), 0);
});

// ── bad signature → rejected ────────────────────────────────────────────────
test('bad signature -> 401 and no row in either table, every vendor', async (t) => {
  for (const vendor of ['github', 'jira', 'linear']) {
    for (const [name, opts] of [
      ['wrong secret', { secret: 'not-the-secret' }],
      ['tampered body', { tamper: JSON.stringify({ ...valid[vendor], extra: 1 }) }],
      ['missing header', { noSig: true }],
    ]) {
      const ctx = await setup(t); if (!ctx) return;
      const r = await send(ctx, vendor, valid[vendor], { ...opts, delivery: 'd-bad' });
      assert.equal(r.status, 401, `${vendor} ${name}`);
      assert.equal(ctx.count('wakes'), 0, `${vendor} ${name}`);
      assert.equal(ctx.count('webhook_deliveries'), 0, `${vendor} ${name}`);
    }
  }
});

test('jira signature without the sha256= prefix -> 401', async (t) => {
  const ctx = await setup(t); if (!ctx) return;
  const raw = JSON.stringify(valid.jira);
  const r = await send(ctx, 'jira', valid.jira, { sig: hmac(S.jira, raw) });
  assert.equal(r.status, 401);
  assert.equal(ctx.count('wakes'), 0);
});

test('unset secret -> 503 per vendor; GET -> 405', async (t) => {
  for (const vendor of ['github', 'jira', 'linear']) {
    const ctx = await setup(t, { secrets: { ...S, [vendor]: '' } }); if (!ctx) return;
    const r = await send(ctx, vendor, valid[vendor]);
    assert.equal(r.status, 503, vendor);
    assert.equal(ctx.count('wakes'), 0);
    const g = await send(await setup(t), vendor, valid[vendor], { method: 'GET', noSig: true });
    assert.equal(g.status, 405, vendor);
  }
});

test('linear webhookTimestamp 10 minutes old, or missing -> 401', async (t) => {
  for (const ts of [ANCHOR - 600_000, undefined]) {
    const ctx = await setup(t); if (!ctx) return;
    const r = await send(ctx, 'linear', { ...valid.linear, webhookTimestamp: ts });
    assert.equal(r.status, 401, String(ts));
    assert.equal(ctx.count('wakes'), 0);
  }
});

test('linear replay window is the webhook_max_age_s row', async (t) => {
  const ctx = await setup(t, { settings: { webhook_max_age_s: '900' } }); if (!ctx) return;
  const r = await send(ctx, 'linear', { ...valid.linear, webhookTimestamp: ANCHOR - 600_000 });
  assert.equal(r.status, 200);
  assert.equal(ctx.count('wakes'), 1);
});

test('correctly signed non-JSON body -> 202 ignored, no row', async (t) => {
  for (const vendor of ['jira', 'linear']) {
    const ctx = await setup(t); if (!ctx) return;
    const r = await send(ctx, vendor, 'not json at all');
    assert.equal(r.status, 202, vendor);
    assert.equal(ctx.count('wakes'), 0);
  }
});

// ── duplicate delivery → one wake ───────────────────────────────────────────
test('same delivery id redelivered in a later minute -> one wake, duplicate:true', async (t) => {
  for (const vendor of ['github', 'jira', 'linear']) {
    const ctx = await setup(t); if (!ctx) return;
    const a = await send(ctx, vendor, valid[vendor], { delivery: 'dup-1' });
    assert.equal(a.status, 200);
    // So the (repo,kind,key,minute) index cannot be what saves the second one.
    ctx.db.prepare(`UPDATE wakes SET minute='2000-01-01T00:00:00Z'`).run();
    const b = await send(ctx, vendor, valid[vendor], { delivery: 'dup-1' });
    assert.equal(b.status, 200, vendor);
    assert.equal(b.body.duplicate, true, vendor);
    assert.equal(ctx.count('wakes'), 1, vendor);
    assert.equal(ctx.count('webhook_deliveries'), 1, vendor);
  }
});

test('two delivery ids, same issue, same minute -> one row (minute dedupe)', async (t) => {
  const ctx = await setup(t); if (!ctx) return;
  await send(ctx, 'jira', valid.jira, { delivery: 'm-1' });
  const b = await send(ctx, 'jira', valid.jira, { delivery: 'm-2' });
  assert.equal(b.body.duplicate, true);
  assert.equal(ctx.count('wakes'), 1);
});

test('different issues -> two rows', async (t) => {
  const ctx = await setup(t); if (!ctx) return;
  await send(ctx, 'jira', jiraComment('CROM-12'), { delivery: 'i-1' });
  await send(ctx, 'jira', jiraComment('CROM-13'), { delivery: 'i-2' });
  assert.deepEqual(ctx.wakes().map((w) => w.key), ['CROM-12', 'CROM-13']);
});

test('no delivery header -> the wake is still written (minute dedupe only)', async (t) => {
  for (const vendor of ['github', 'jira', 'linear']) {
    const ctx = await setup(t); if (!ctx) return;
    const r = await send(ctx, vendor, valid[vendor]);
    assert.equal(r.status, 200, vendor);
    assert.equal(r.body.duplicate, false);
    assert.equal(ctx.count('wakes'), 1, vendor);
    assert.equal(ctx.count('webhook_deliveries'), 0, vendor);
  }
});

test('a write that throws -> 500, never a 200 (D1 rolls the batch back; the shim is not transactional)', async (t) => {
  const ctx = await setup(t); if (!ctx) return;
  ctx.db.exec(`DROP INDEX idx_wakes_dedupe; DROP TABLE wakes`);
  const r = await send(ctx, 'jira', valid.jira, { delivery: 'boom-1' });
  assert.equal(r.status, 500);
});

// ── edge detection: negatives (System invariants c) ─────────────────────────
test('jira negatives -> 202 and no row', async (t) => {
  const cases = [
    ['Rank only', jiraUpdate([{ field: 'Rank', fieldId: 'customfield_10019' }])],
    ['timeestimate', jiraUpdate([{ field: 'timeestimate', fieldId: 'timeestimate' }])],
    ['timespent', jiraUpdate([{ field: 'timespent', fieldId: 'timespent' }])],
    ['Sprint', jiraUpdate([{ field: 'Sprint', fieldId: 'customfield_10020' }])],
    ['self comment', jiraComment('CROM-12', 'our-bot')],
    ['worklog_updated', { webhookEvent: 'worklog_updated', issue: { key: 'CROM-12' } }],
    ['issuelink_created', { webhookEvent: 'issuelink_created', issue: { key: 'CROM-12' } }],
    ['version_released', { webhookEvent: 'jira:version_released', issue: { key: 'CROM-12' } }],
    ['board_updated', { webhookEvent: 'board_updated' }],
    ['lowercase key', jiraComment('crom-12')],
    ['zero key', jiraComment('CROM-0')],
  ];
  for (const [name, p] of cases) {
    const ctx = await setup(t, { settings: { 'webhook_self.jira': 'other, our-bot' } }); if (!ctx) return;
    const r = await send(ctx, 'jira', p, { delivery: 'n-1' });
    assert.equal(r.status, 202, `${name}: ${JSON.stringify(r.body)}`);
    assert.equal(ctx.count('wakes'), 0, name);
    assert.equal(ctx.count('webhook_deliveries'), 0, name);
  }
});

test('linear negatives -> 202 and no row', async (t) => {
  const cases = [
    ['sortOrder', linIssueUpdate({ sortOrder: 1 })],
    ['updatedAt', linIssueUpdate({ updatedAt: 'x' })],
    ['subIssueSortOrder', linIssueUpdate({ subIssueSortOrder: 2 })],
    ['boardOrder', linIssueUpdate({ boardOrder: 3 })],
    ['self comment', linComment({ actor: { id: 'our-user' } })],
    ...['Reaction', 'Cycle', 'Project', 'IssueLabel', 'Attachment'].map((type) =>
      [type, { ...linIssueUpdate({ stateId: 'x' }), type, action: 'create' }]),
    ['unrouted team', linIssueUpdate({ stateId: 'x' }, 'OPS-4')],
  ];
  for (const [name, p] of cases) {
    const ctx = await setup(t, { settings: { 'webhook_self.linear': 'our-user' } }); if (!ctx) return;
    const r = await send(ctx, 'linear', p, { delivery: 'n-1' });
    assert.equal(r.status, 202, `${name}: ${JSON.stringify(r.body)}`);
    assert.equal(ctx.count('wakes'), 0, name);
  }
});

// ── edge detection: positives ───────────────────────────────────────────────
test('jira status change, label add, client comment; linear stateId -> one wake each', async (t) => {
  const cases = [
    ['jira', jiraUpdate([{ field: 'status', fieldId: 'status' }])],
    ['jira', jiraUpdate([{ field: 'Rank' }, { field: 'labels', fieldId: 'labels' }])],
    ['jira', jiraComment()],
    ['jira', jiraUpdate(undefined)],                       // no changelog: fail-open
    ['jira', { webhookEvent: 'jira:issue_created', issue: { key: 'CROM-2' }, user: { accountId: 'c' } }],
    ['linear', linIssueUpdate({ stateId: 's-old', updatedAt: 'x' })],
    ['linear', linComment()],                              // identifier only in url
  ];
  for (const [vendor, p] of cases) {
    const ctx = await setup(t, { settings: { 'webhook_self.jira': 'our-bot', 'webhook_self.linear': 'our-user' } });
    if (!ctx) return;
    const r = await send(ctx, vendor, p);
    assert.equal(r.status, 200, `${vendor} ${JSON.stringify(p).slice(0, 80)}: ${JSON.stringify(r.body)}`);
    assert.equal(ctx.count('wakes'), 1);
  }
});

test('linear comment carrying its issue only in url is keyed on it', async (t) => {
  const ctx = await setup(t); if (!ctx) return;
  await send(ctx, 'linear', linComment());
  assert.deepEqual(ctx.wakes(), [{ repo: REPO, kind: 'issue', key: 'ENG-9', event: 'linear.comment.create' }]);
});

test('the edge field list is the webhook_edge_fields row when set', async (t) => {
  const ctx = await setup(t, { settings: { 'webhook_edge_fields.jira': 'Rank' } }); if (!ctx) return;
  const r = await send(ctx, 'jira', jiraUpdate([{ field: 'Rank' }]));
  assert.equal(r.status, 200);
  const r2 = await send(ctx, 'jira', jiraUpdate([{ field: 'status' }], 'CROM-14'));
  assert.equal(r2.status, 202);
  assert.equal(ctx.count('wakes'), 1);
});

// ── routing ─────────────────────────────────────────────────────────────────
test('routing: no route row -> 202 unrouted; malformed row -> 202; both write nothing', async (t) => {
  let ctx = await setup(t); if (!ctx) return;
  let r = await send(ctx, 'jira', jiraComment('ZZZ-1'), { delivery: 'r-1' });
  assert.equal(r.status, 202);
  assert.equal(r.body.ignored, 'unrouted');
  assert.equal(ctx.count('wakes') + ctx.count('webhook_deliveries'), 0);
  ctx = await setup(t, { settings: { 'webhook_route.jira.crom': 'not a slug' } });
  r = await send(ctx, 'jira', jiraComment(), { delivery: 'r-2' });
  assert.equal(r.status, 202);
  assert.equal(r.body.ignored, 'route row malformed');
  assert.equal(ctx.count('wakes') + ctx.count('webhook_deliveries'), 0);
});

// ── prune ───────────────────────────────────────────────────────────────────
test('prune: a delivery older than the webhook_delivery_keep_s row goes, a fresh one stays', async (t) => {
  for (const vendor of ['jira', 'github']) {
    const ctx = await setup(t, { settings: { webhook_delivery_keep_s: '3600' } }); if (!ctx) return;
    const old = new Date(ANCHOR - 7200_000).toISOString().replace(/\.\d{3}Z$/, 'Z');
    const fresh = new Date(ANCHOR - 1800_000).toISOString().replace(/\.\d{3}Z$/, 'Z');
    ctx.db.prepare(`INSERT INTO webhook_deliveries VALUES ('jira','old-1',?), ('jira','fresh-1',?)`).run(old, fresh);
    const r = await send(ctx, vendor, valid[vendor], { delivery: 'now-1' });
    assert.equal(r.status, 200, vendor);
    const ids = ctx.db.prepare(`SELECT delivery_id FROM webhook_deliveries ORDER BY delivery_id`).all().map((x) => x.delivery_id);
    assert.deepEqual(ids, ['fresh-1', 'now-1'], vendor);
  }
});

// ── the pure mappers, at the boundaries ─────────────────────────────────────
test('jiraWakeOf / linearWakeOf unit cases', () => {
  const jcfg = { edgeFields: WEBHOOK_DEFAULTS.edgeFields.jira, selfIds: ['me'] };
  const lcfg = { edgeFields: WEBHOOK_DEFAULTS.edgeFields.linear, selfIds: ['me'] };
  assert.equal(jiraWakeOf(jiraUpdate([{ field: 'Rank' }]), jcfg).ignored, 'no edge field changed');
  assert.equal(jiraWakeOf(jiraUpdate([{ fieldId: 'status', field: 'Status' }]), jcfg).key, 'CROM-12');
  assert.equal(jiraWakeOf(jiraUpdate([]), jcfg).key, 'CROM-12');
  assert.equal(jiraWakeOf({ ...jiraUpdate([{ field: 'status' }]), user: { accountId: 'me' } }, jcfg).ignored, 'self-authored');
  assert.deepEqual(jiraWakeOf(jiraComment('AB_C-9'), jcfg), { project: 'AB_C', key: 'AB_C-9', event: 'jira.comment_created' });
  assert.equal(jiraWakeOf(null, jcfg).ignored, 'unknown');
  assert.equal(linearWakeOf(linIssueUpdate({ sortOrder: 1 }), lcfg).ignored, 'no edge field changed');
  assert.equal(linearWakeOf(linIssueUpdate(undefined), lcfg).key, 'ENG-5');
  assert.equal(linearWakeOf({ ...linComment(), url: '' }, lcfg).ignored, 'no issue identifier');
  assert.equal(linearWakeOf({ ...linComment(), data: { issue: { identifier: 'ENG-3' } } }, lcfg).key, 'ENG-3');
  assert.equal(linearWakeOf({ ...linComment(), actor: { id: 'me' } }, lcfg).ignored, 'self-authored');
  assert.deepEqual(linearWakeOf(linIssueUpdate({ labelIds: [] }, 'AB1-7'), lcfg), { team: 'AB1', key: 'AB1-7', event: 'linear.issue.update' });
});
