import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { githubGateEvents, holdWordOf } from '../src/lib/pr-gate-intake.js';

// BH-4954 (BH-4950.1) — the WRITERS of PR gate facts. Every route case drives
// `worker.fetch` (D2) over the real schema.sql in node:sqlite: a signed
// delivery to /webhooks/github, a builder artifact put to
// PUT /api/jobs/:id/artifacts, and a verdict to POST /api/verdicts. The
// assertions are on `state='gate'` rows in pr_state_events. `t.skip` when
// node:sqlite is absent.

const REPO = 'example-org/cromford';
const URL7 = `https://github.com/${REPO}/pull/7`;
const A = 'a'.repeat(40);
const B = 'b'.repeat(40);
const GH = 'gh-secret';
const LEAD = 'lead-tok';
const repository = { full_name: REPO };

async function setup(t, hooks) {
  const o = await openDb(hooks);
  if (!o) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  const env = { DB: o.DB, HARNESS_SECRET: 'bearer', GITHUB_WEBHOOK_SECRET: GH, LEAD_VERDICT_TOKEN: LEAD };
  const gates = () => {
    try {
      return o.db.prepare("SELECT * FROM pr_state_events WHERE state='gate' ORDER BY id").all().map((r) => ({ ...r }));
    } catch { return []; }
  };
  return { ...o, env, gates };
}

let dn = 0;
async function hook(ctx, event, payload, { delivery, sig, raw } = {}) {
  const body = raw ?? JSON.stringify(payload);
  dn += 1;
  const headers = { 'content-type': 'application/json', 'x-github-event': event,
    'x-hub-signature-256': sig ?? 'sha256=' + createHmac('sha256', GH).update(body).digest('hex') };
  if (delivery !== null) headers['x-github-delivery'] = delivery ?? `dlv-${dn}`;
  const res = await worker.fetch(new Request('https://jobs.test/webhooks/github', { method: 'POST', headers, body }), ctx.env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
async function api(ctx, path, { method = 'GET', body, headers = {} } = {}) {
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, body: body === undefined ? undefined : JSON.stringify(body),
    headers: { 'content-type': 'application/json', authorization: 'Bearer bearer', ...headers },
  }), ctx.env);
  return { status: res.status, body: await res.json().catch(() => null) };
}

const prPayload = (action, { sha = A, draft = false, state = 'open', extra = {} } = {}) => ({
  action, number: 7, repository,
  pull_request: { number: 7, state, draft, html_url: URL7, head: { sha } }, ...extra,
});
const suite = (conclusion = 'success', slug = 'github-actions', action = 'completed', prs = [{ number: 7 }]) => ({
  action, repository, check_suite: { head_sha: A, conclusion, app: { slug }, pull_requests: prs },
});
const commentPayload = (body, { action = 'created', type = 'User', onPr = true } = {}) => ({
  action, repository,
  issue: { number: 7, ...(onPr ? { pull_request: { url: URL7 } } : {}) },
  comment: { body, user: { type } },
});

// ── W: webhook intake ────────────────────────────────────────────────────────
test('W1/W2: synchronize writes one gate row keyed on the delivery id; a redelivery writes none', async (t) => {
  const c = await setup(t); if (!c) return;
  const r = await hook(c, 'pull_request', prPayload('synchronize'), { delivery: 'uuid-1' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const g = c.gates();
  assert.equal(g.length, 1);
  assert.equal(g[0].repo, REPO);
  assert.equal(g[0].number, 7);
  assert.equal(g[0].since, 'uuid-1');
  assert.equal(g[0].head, A);
  assert.equal(g[0].draft, 0);
  assert.equal(g[0].closed, 0);
  assert.equal(g[0].url, URL7);
  assert.equal(g[0].reason, 'webhook:pull_request.synchronize');
  assert.equal(g[0].actor, 'github');
  const again = await hook(c, 'pull_request', prPayload('synchronize'), { delivery: 'uuid-1' });
  assert.equal(again.status, 200);
  assert.equal(c.gates().length, 1);
});

test('W3: converted_to_draft records draft=1 and still answers 202 ignored', async (t) => {
  const c = await setup(t); if (!c) return;
  const r = await hook(c, 'pull_request', prPayload('converted_to_draft', { draft: true }));
  assert.equal(r.status, 202);
  assert.equal(r.body.ignored, 'pull_request');
  const g = c.gates();
  assert.equal(g.length, 1);
  assert.equal(g[0].draft, 1);
});

test('W4: closed records closed=1', async (t) => {
  const c = await setup(t); if (!c) return;
  await hook(c, 'pull_request', prPayload('closed', { state: 'closed' }));
  assert.equal(c.gates()[0].closed, 1);
});

test('W5: labeled hotfix records hotfix=1, unlabeled records 0', async (t) => {
  const c = await setup(t); if (!c) return;
  const on = await hook(c, 'pull_request', prPayload('labeled', { extra: { label: { name: 'Hotfix' } } }));
  assert.equal(on.status, 202);
  await hook(c, 'pull_request', prPayload('unlabeled', { extra: { label: { name: 'hotfix' } } }));
  assert.deepEqual(c.gates().map((g) => [g.hotfix, g.head]), [[1, null], [0, null]]);
});

test('W6: a GitHub Actions check_suite success sets ci_green_sha on every listed PR', async (t) => {
  const c = await setup(t); if (!c) return;
  await hook(c, 'check_suite', suite('success', 'github-actions', 'completed', [{ number: 7 }, { number: 9 }, { number: 'x' }]));
  assert.deepEqual(c.gates().map((g) => [g.number, g.ci_green_sha]), [[7, A], [9, A]]);
});

test('W7: an issue_comment HOLD: records held=1 and UNHOLD held=0', async (t) => {
  const c = await setup(t); if (!c) return;
  await hook(c, 'issue_comment', commentPayload('HOLD: wait for the migration'));
  await hook(c, 'issue_comment', commentPayload('UNHOLD\nthe migration is applied'));
  assert.deepEqual(c.gates().map((g) => g.held), [1, 0]);
  const gate = await api(c, `/api/pr-state/gate?repo=${REPO}`);
  assert.equal(gate.body.rows[0].held, 0);
});

test('W8: no X-GitHub-Delivery means no gate row, and the wake is answered as before', async (t) => {
  const c = await setup(t); if (!c) return;
  const r = await hook(c, 'pull_request', prPayload('synchronize'), { delivery: null });
  assert.equal(r.status, 200);
  assert.equal(c.gates().length, 0);
});

// ── N: adversarial negatives — each writes NO gate row, status unchanged ───
const NEGATIVES = [
  ['HOLD on an issue', 'issue_comment', commentPayload('HOLD: x', { onPr: false })],
  ['bot HOLD:', 'issue_comment', commentPayload('HOLD: x', { type: 'Bot' })],
  ['HOLD until (prose)', 'issue_comment', commentPayload('HOLD until #12 merges')],
  ['> HOLD quote', 'issue_comment', commentPayload('> HOLD')],
  ['- HOLD: list item', 'issue_comment', commentPayload('- HOLD: x')],
  ['**HOLD**', 'issue_comment', commentPayload('**HOLD**')],
  ['mid-line please HOLD:', 'issue_comment', commentPayload('please HOLD: this')],
  ['HOLD: then RESUME', 'issue_comment', commentPayload('HOLD: x\nRESUME')],
  ['edited comment', 'issue_comment', commentPayload('HOLD: x', { action: 'edited' })],
  ['holdover', 'issue_comment', commentPayload('holdover')],
  ['UNHOLDING', 'issue_comment', commentPayload('UNHOLDING now')],
  ['mergify suite', 'check_suite', suite('success', 'mergify')],
  ['failure suite', 'check_suite', suite('failure')],
  ['neutral suite', 'check_suite', suite('neutral')],
  ['requested suite', 'check_suite', suite('success', 'github-actions', 'requested')],
  ['empty pull_requests', 'check_suite', suite('success', 'github-actions', 'completed', [])],
  ['Hotfix-candidate label', 'pull_request', prPayload('labeled', { extra: { label: { name: 'Hotfix-candidate' } } })],
  ['39-char head', 'pull_request', prPayload('synchronize', { sha: 'a'.repeat(39) })],
  ['uppercase non-hex head', 'pull_request', prPayload('synchronize', { sha: 'G'.repeat(40) })],
  ['no head.sha', 'pull_request', { action: 'synchronize', number: 7, repository, pull_request: { number: 7, state: 'open', draft: false } }],
  ['no draft field', 'pull_request', { action: 'opened', number: 7, repository, pull_request: { number: 7, state: 'open', head: { sha: A } } }],
  ['number not an int', 'pull_request', { action: 'opened', number: '7', repository, pull_request: { number: '7', state: 'open', draft: false, head: { sha: A } } }],
  ['edited pull_request', 'pull_request', prPayload('edited')],
  ['other event', 'push', { ref: 'refs/heads/main', repository }],
];
for (const [name, event, payload] of NEGATIVES) {
  test(`N: ${name} writes no gate row`, async (t) => {
    const c = await setup(t); if (!c) return;
    const r = await hook(c, event, payload);
    assert.ok([200, 202].includes(r.status), `${name}: ${r.status} ${JSON.stringify(r.body)}`);
    assert.deepEqual(c.gates(), [], name);
  });
}

test('N: an overlong delivery id, a bad repo and a non-object payload map to []', () => {
  assert.deepEqual(githubGateEvents('pull_request', prPayload('opened'), 'x'.repeat(65)), []);
  assert.deepEqual(githubGateEvents('pull_request', prPayload('opened'), ''), []);
  assert.deepEqual(githubGateEvents('pull_request', { ...prPayload('opened'), repository: { full_name: 'no-slash' } }, 'd'), []);
  assert.deepEqual(githubGateEvents('pull_request', [prPayload('opened')], 'd'), []);
  assert.deepEqual(githubGateEvents('pull_request', null, 'd'), []);
  assert.equal(githubGateEvents('pull_request', prPayload('opened', { sha: 'A'.repeat(40) }), 'd')[0].head, A);
});

test('N: holdWordOf follows hold.sh — RESUME is a lift, ABANDON/CLOSE-PR hold, HOLD alone holds', () => {
  assert.equal(holdWordOf('HOLD'), 'hold');
  assert.equal(holdWordOf('HOLD — rebase first'), 'hold');
  assert.equal(holdWordOf('HOLD\r\nwhy'), 'hold');
  assert.equal(holdWordOf('RESUME'), 'lift');
  assert.equal(holdWordOf('ABANDON'), 'abandon');
  assert.equal(holdWordOf('CLOSE-PR superseded'), 'abandon');
  assert.equal(holdWordOf('ABANDON\nUNHOLD'), null);
  assert.equal(holdWordOf('note\nHOLD:'), null);
  assert.equal(holdWordOf(42), null);
});

test('N: an unsigned or bad-signature delivery is a 401 before any parse, no row', async (t) => {
  const c = await setup(t); if (!c) return;
  const r = await hook(c, 'pull_request', prPayload('synchronize'), { sig: 'sha256=' + '0'.repeat(64) });
  assert.equal(r.status, 401);
  const r2 = await hook(c, 'pull_request', prPayload('synchronize'), { sig: '' });
  assert.equal(r2.status, 401);
  assert.deepEqual(c.gates(), []);
});

test('N: a gate write that throws never fails the webhook', async (t) => {
  const c = await setup(t, { beforeRun(sql) { if (/INSERT INTO pr_state_events/.test(sql)) throw new Error('D1 blip'); } });
  if (!c) return;
  const warn = console.warn; const seen = []; console.warn = (...a) => seen.push(a.join(' '));
  try {
    const r = await hook(c, 'pull_request', prPayload('synchronize'));
    assert.equal(r.status, 200, JSON.stringify(r.body));
  } finally { console.warn = warn; }
  assert.deepEqual(c.gates(), []);
  assert.ok(seen.some((s) => s.includes('[pr-gate-intake]')), seen.join('|'));
});

// ── A: builder approve through PUT /api/jobs/:id/artifacts ───────────────────
function job(c, id = 'job-7') {
  c.db.prepare(`INSERT INTO jobs (id,project,kind,stage,box,ticket_id,status,created_at,updated_at)
    VALUES (?,'cromford','build','done','b','BH-1','done','2026-10-07T00:00:00Z','2026-10-07T00:00:00Z')`).run(id);
}
const putUrl = (c, ref = URL7, id = 'job-7') =>
  api(c, `/api/jobs/${id}/artifacts`, { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: ref } });
const putVerdict = (c, verdict, detail, id = 'job-7') =>
  api(c, `/api/jobs/${id}/artifacts`, { method: 'PUT', body: { artifact_kind: 'verdict', artifact_ref: verdict, detail } });
const approvals = (c) => c.gates().map((g) => [g.number, g.builder_approved_sha, g.since]);

test('A1: APPROVE + pr_url in either order writes ONE builder_approved_sha row', async (t) => {
  for (const order of ['verdict-first', 'url-first']) {
    const c = await setup(t); if (!c) return;
    job(c);
    const d = { reviewed_sha: A, settled: true, headbound: 'n/a' };
    if (order === 'verdict-first') {
      assert.equal((await putVerdict(c, 'APPROVE', d)).status, 200);
      assert.deepEqual(approvals(c), [], 'no pr_url yet, no row');
      assert.equal((await putUrl(c)).status, 200);
    } else {
      assert.equal((await putUrl(c)).status, 200);
      assert.equal((await putVerdict(c, 'APPROVE', d)).status, 200);
    }
    // Recorded by the SECOND put, whichever kind that was.
    assert.deepEqual(approvals(c), [[7, A, `approve@${A}`]], `${order}: after the second put`);
    // A re-put of either is a duplicate on approve@<sha>.
    await putVerdict(c, 'APPROVE', d);
    await putUrl(c);
    assert.deepEqual(approvals(c), [[7, A, `approve@${A}`]], order);
    const g = c.gates()[0];
    assert.equal(g.repo, REPO);
    assert.equal(g.actor, 'worker');
    assert.equal(g.reason, 'builder-verdict:job-7');
  }
});

test('A2: a provisional (settled:false) APPROVE writes nothing', async (t) => {
  const c = await setup(t); if (!c) return;
  job(c); await putUrl(c);
  await putVerdict(c, 'APPROVE', { reviewed_sha: A, settled: false });
  assert.deepEqual(approvals(c), []);
});

test('A3: BLOCK (even with a blocked@ headbound), APPROVE with no sha, and a non-pull url write nothing', async (t) => {
  const c = await setup(t); if (!c) return;
  job(c); await putUrl(c);
  await putVerdict(c, 'BLOCK', { reviewed_sha: A, headbound: `blocked@${A}`, settled: true });
  await putVerdict(c, 'APPROVE', { settled: true, headbound: 'n/a' });
  assert.deepEqual(approvals(c), []);
  job(c, 'job-8');
  await putUrl(c, `https://github.com/${REPO}/issues/8`, 'job-8');
  await putVerdict(c, 'APPROVE', { reviewed_sha: A, settled: true }, 'job-8');
  assert.deepEqual(approvals(c), []);
});

test('A4: a reapproved@<sha> headbound records that sha, not the old reviewed_sha', async (t) => {
  const c = await setup(t); if (!c) return;
  job(c); await putUrl(c);
  await putVerdict(c, 'APPROVE', { reviewed_sha: A, settled: true });
  await putVerdict(c, 'APPROVE', { reviewed_sha: A, headbound: `reapproved@${B}`, settled: true });
  assert.deepEqual(approvals(c), [[7, A, `approve@${A}`], [7, B, `approve@${B}`]]);
});

test('A5: a gate write that throws never fails the artifact PUT', async (t) => {
  const c = await setup(t, { beforeRun(sql) { if (/INSERT INTO pr_state_events/.test(sql)) throw new Error('D1 blip'); } });
  if (!c) return;
  job(c); await putUrl(c);
  const warn = console.warn; const seen = []; console.warn = (...a) => seen.push(a.join(' '));
  let r;
  try { r = await putVerdict(c, 'APPROVE', { reviewed_sha: A, settled: true }); } finally { console.warn = warn; }
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.artifact.artifact_ref, 'APPROVE');
  assert.equal(r.body.history_appended, true);
  assert.deepEqual(approvals(c), []);
  assert.ok(seen.some((s) => s.includes('[pr-gate-intake]')), seen.join('|'));
});

// ── L: lead verdicts through POST /api/verdicts ─────────────────────────────
const postVerdict = (c, source, verdict = 'MERGE', headers = { 'x-lead-verdict-token': LEAD }) =>
  api(c, '/api/verdicts', { method: 'POST', headers, body: { repo: REPO, pr: 7, head_sha: B, verdict, source } });

test('L1: a lead MERGE writes lead_verdict_sha and lead_verdict_word', async (t) => {
  const c = await setup(t); if (!c) return;
  const r = await postVerdict(c, 'lead');
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const g = c.gates();
  assert.equal(g.length, 1);
  assert.equal(g[0].lead_verdict_sha, B);
  assert.equal(g[0].lead_verdict_word, 'MERGE');
  assert.equal(g[0].since, `verdict#${r.body.verdict.id}`);
  assert.equal(g[0].reason, 'verdict:lead');
});

test('L2: a box row and a refused (403) lead row write nothing', async (t) => {
  const c = await setup(t); if (!c) return;
  const box = await postVerdict(c, 'box', 'BLOCK', {});
  assert.equal(box.status, 201, JSON.stringify(box.body));
  const refused = await postVerdict(c, 'lead', 'MERGE', {});
  assert.equal(refused.status, 403);
  assert.deepEqual(c.gates(), []);
});

test('L4: a risk-tier MERGE writes the gate row too, as vd_standing counts it (lead review lr-5060-f2bef1d50074)', async (t) => {
  // BH-5022 made risk-tier a STANDING source: vd_standing returns it and the
  // reconcile sweep writes lead_verdict_sha from it. The event writer has to
  // agree, or needs-review shows the PR until the next sweep.
  const c = await setup(t); if (!c) return;
  const r = await postVerdict(c, 'risk-tier');
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const g = c.gates();
  assert.equal(g.length, 1, JSON.stringify(g));
  assert.equal(g[0].lead_verdict_sha, B);
  assert.equal(g[0].lead_verdict_word, 'MERGE');
  assert.equal(g[0].reason, 'verdict:risk-tier');
});

test('L5: the event writer and the route read ONE standing-source list', async () => {
  const { STANDING_SOURCES } = await import('../src/lib/verdict-sources.js');
  assert.deepEqual([...STANDING_SOURCES].sort(), ['human', 'lead', 'risk-tier']);
  const fs = await import('node:fs');
  const intake = fs.readFileSync(new URL('../src/lib/pr-gate-intake.js', import.meta.url), 'utf8');
  const route = fs.readFileSync(new URL('../src/routes/verdicts.js', import.meta.url), 'utf8');
  assert.match(intake, /STANDING_SOURCES\.includes\(row\.source\)/);
  assert.doesNotMatch(intake, /\["lead", "human"\]\.includes/);
  assert.match(route, /import \{ STANDING_SOURCES \} from "\.\.\/lib\/verdict-sources\.js"/);
});

test('L3: a gate write that throws never fails the verdict POST', async (t) => {
  const c = await setup(t, { beforeRun(sql) { if (/INSERT INTO pr_state_events/.test(sql)) throw new Error('D1 blip'); } });
  if (!c) return;
  const warn = console.warn; const seen = []; console.warn = (...a) => seen.push(a.join(' '));
  let r;
  try { r = await postVerdict(c, 'lead', 'BLOCK'); } finally { console.warn = warn; }
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.verdict.verdict, 'BLOCK');
  assert.deepEqual(c.gates(), []);
  assert.ok(seen.some((s) => s.includes('[pr-gate-intake]')), seen.join('|'));
});
