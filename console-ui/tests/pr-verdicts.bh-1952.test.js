import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import {
  repoFromPrUrl, liveHeadOf, verdictColumns, VerdictsView, requestLeadReview
} from '../src/ui/PRVerdicts.js';
import { sortRows, nextDirection } from '../src/lib/sort.js';

// BH-1952 — the PR screen's VERDICTS history and its REQUEST LEAD REVIEW door.
// The response fixture is shaped exactly like worker/jobs/src/routes/verdicts.js
// GET /api/verdicts: {repo, pr, head, standing, rows, truncated, as_of}.
// Fixtures carry model ids; console-ui/tests is lint-exempt.

const REPO = 'example-org/cromford';
const LIVE = 'abcdef0123456789abcdef0123456789abcdef01';
const OLD = '0000000011111111111111111111111111111111';
const row = (id, head, created_at, extra = {}) => ({
  id, repo: REPO, pr: 12, head_sha: head, verdict: 'MERGE', source: 'lead',
  reviewer_model: 'claude-opus-5-5', reviewer: 'mac-lead', report_url: null, note: null, created_at, ...extra
});
const rows = [
  row(5, OLD, '2026-09-20T10:00:00Z', { verdict: 'BLOCK' }),
  row(9, LIVE, '2026-09-24T10:00:00Z', { report_url: 'https://reports.test/9' }),
  row(7, LIVE, '2026-09-22T10:00:00Z', { source: 'box', reviewer_model: null })
];
const resp = (standing, extra = {}) =>
  ({ repo: REPO, pr: 12, head: LIVE, standing, rows, truncated: false, as_of: '2026-09-24T14:00:00Z', ...extra });
const ok = (data) => ({ loading: false, error: null, data, reload: () => {} });
const html = (props) => render(h(VerdictsView, props));
const count = (s, needle) => s.split(needle).length - 1;

function captureFetch() {
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(String(url));
    return { ok: true, status: 200, text: async () => JSON.stringify({ rows: [] }) };
  };
  return calls;
}

test('ui-1 api url: repo and pr always, head only when it is a full 40-hex sha', async () => {
  const calls = captureFetch();
  await api.verdicts(REPO, 12);
  await api.verdicts(REPO, 12, LIVE);
  await api.verdicts(REPO, 12, 'abcdef012345');
  assert.equal(calls[0], '/api/coord/verdicts?repo=example-org%2Fcromford&pr=12');
  assert.equal(calls[1], `/api/coord/verdicts?repo=example-org%2Fcromford&pr=12&head=${LIVE}`);
  assert.equal(calls[2], '/api/coord/verdicts?repo=example-org%2Fcromford&pr=12');
});

test('ui-2 sortable: default created_at desc, a header click flips to asc', () => {
  const out = html({ repo: REPO, liveHead: LIVE, state: ok(resp(null)) });
  const body = out.slice(out.indexOf('<tbody>'));
  assert.ok(body.indexOf('2026-09-24T10:00:00Z') !== -1, 'the newest row renders');
  assert.ok(body.indexOf('2026-09-24T10:00:00Z') < body.indexOf('2026-09-22T10:00:00Z'));
  assert.ok(body.indexOf('2026-09-22T10:00:00Z') < body.indexOf('2026-09-20T10:00:00Z'));
  assert.match(out, /<th aria-sort="descending"[^>]*>\s*<button[^>]*>\s*CREATED/);
  const cols = verdictColumns(REPO, resp(null), LIVE);
  assert.deepEqual(cols.map((c) => c.key), ['created_at', 'head_sha', 'verdict', 'source', 'reviewer_model', 'report_url']);
  assert.ok(cols.every((c) => typeof c.sort === 'function'), 'every column sorts');
  const created = cols.find((c) => c.key === 'created_at');
  const dir = nextDirection('created_at', 'created_at', 'desc');
  assert.equal(dir, 'asc');
  assert.deepEqual(sortRows(rows, created.sort, dir).map((r) => r.id), [5, 7, 9]);
});

test('ui-3 the head sha12 links to its commit', () => {
  const out = html({ repo: REPO, liveHead: LIVE, state: ok(resp(null)) });
  assert.ok(out.includes(`href="https://github.com/${REPO}/commit/${LIVE}"`));
  assert.ok(out.includes(`>${LIVE.slice(0, 12)}<`));
  assert.ok(out.includes(`href="https://github.com/${REPO}/commit/${OLD}"`));
});

test('ui-4 STANDING only on the live-head row that standing names', () => {
  const standingLive = rows[1];
  assert.equal(count(html({ repo: REPO, liveHead: LIVE, state: ok(resp(standingLive)) }), 'STANDING'), 1);
  const out = html({ repo: REPO, liveHead: LIVE, state: ok(resp(standingLive)) });
  const tr = out.slice(out.indexOf('STANDING') - 800, out.indexOf('STANDING'));
  assert.ok(tr.includes(LIVE.slice(0, 12)), 'the marker sits on the live-head row');
  // standing names an older head's row: no marker anywhere.
  assert.equal(count(html({ repo: REPO, liveHead: LIVE, state: ok(resp(rows[0])) }), 'STANDING'), 0);
  // no live head: never guessed.
  assert.equal(count(html({ repo: REPO, liveHead: null, state: ok(resp(standingLive)) }), 'STANDING'), 0);
  // no standing (the GET without &head): none.
  assert.equal(count(html({ repo: REPO, liveHead: LIVE, state: ok(resp(null)) }), 'STANDING'), 0);
});

test('ui-5 an http: report url is not a link', () => {
  const r = [row(3, LIVE, '2026-09-23T00:00:00Z', { report_url: 'http://x.test/r' })];
  const out = html({ repo: REPO, liveHead: LIVE, state: ok(resp(null, { rows: r })) });
  assert.ok(!out.includes('href="http://x.test/r"'));
  assert.ok(out.includes('not https, not linked'));
  const good = html({ repo: REPO, liveHead: LIVE, state: ok(resp(null)) });
  assert.ok(good.includes('href="https://reports.test/9"'), 'an https report is linked');
});

test('ui-6 load failure and empty render differently', () => {
  const err = html({ repo: REPO, liveHead: LIVE, state: { loading: false, error: new Error('http_502'), data: null, reload: () => {} } });
  assert.ok(err.includes('could not load'));
  assert.ok(err.includes('http_502'));
  assert.ok(!err.includes('No verdicts recorded for this PR'));
  const empty = html({ repo: REPO, liveHead: LIVE, state: ok(resp(null, { rows: [] })) });
  assert.ok(empty.includes('No verdicts recorded for this PR'));
  assert.ok(!empty.includes('could not load'));
  const loading = html({ repo: REPO, liveHead: LIVE, state: { loading: true, error: null, data: null, reload: () => {} } });
  assert.ok(loading.includes('skel') && !loading.includes('No verdicts recorded'));
  const trunc = html({ repo: REPO, liveHead: LIVE, state: ok(resp(null, { truncated: true })) });
  assert.ok(trunc.includes('newest 100'));
});

test('ui-7 the table scrolls inside its own overflow-x wrapper', () => {
  const out = html({ repo: REPO, liveHead: LIVE, state: ok(resp(null)) });
  assert.match(out, /<div style="overflow-x:auto[^"]*">\s*<div class="tablewrap">/);
});

test('ui-8 request: cancel sends nothing, confirm sends exactly one lead_review action', async () => {
  const sent = [];
  const action = async (p) => { sent.push(p); return { command_id: 44 }; };
  const base = { action, project: 'cromford', repo: REPO, pr: 12, headSha: LIVE, notes: 'n' };
  let asked = 0;
  const cancel = await requestLeadReview({ ...base, confirm: async () => { asked++; return false; } });
  assert.deepEqual(cancel, { sent: false });
  assert.equal(asked, 1);
  assert.equal(sent.length, 0);
  const res = await requestLeadReview({ ...base, confirm: async () => true });
  assert.equal(sent.length, 1);
  assert.deepEqual(sent[0], { type: 'lead_review', project: 'cromford', repo: REPO, pr: 12, head_sha: LIVE, notes: 'n' });
  assert.deepEqual(res, { ok: true, text: 'lead review requested as command #44' });
});

test('ui-9 no full head, no request and no button', async () => {
  assert.equal(liveHeadOf({ head_sha: 'abc123' }), null);
  assert.equal(liveHeadOf({}), null);
  assert.equal(liveHeadOf(null), null);
  assert.equal(liveHeadOf({ head_sha: LIVE.toUpperCase() }), LIVE);
  assert.equal(liveHeadOf({ gh: { head_sha: LIVE } }), LIVE);
  let called = 0;
  const res = await requestLeadReview({
    confirm: async () => { called++; return true; }, action: async () => { called++; },
    project: 'p', repo: REPO, pr: 12, headSha: 'abc123'
  });
  assert.equal(res, null);
  assert.equal(called, 0);
  assert.equal(repoFromPrUrl('https://github.com/example-org/cromford/pull/12'), REPO);
  assert.equal(repoFromPrUrl('https://evil.test/example-org/cromford/pull/12'), null);
  assert.equal(repoFromPrUrl(null), null);
  // PR.js gates the button on repo && liveHead.
  const src = readFileSync(new URL('../src/screens/PR.js', import.meta.url), 'utf8');
  const i = src.indexOf('REQUEST LEAD REVIEW');
  assert.ok(i !== -1, 'PR.js renders the button');
  assert.ok(src.lastIndexOf('repo && liveHead', i) !== -1, 'the button is gated on repo && liveHead');
});

test('ui-10 never a native dialog', async () => {
  const prev = globalThis.window;
  globalThis.window = { confirm() { throw new Error('native confirm called'); } };
  try {
    const res = await requestLeadReview({
      confirm: async () => true, action: async () => ({ command_id: 1 }),
      project: 'p', repo: REPO, pr: 12, headSha: LIVE
    });
    assert.equal(res.ok, true);
  } finally {
    globalThis.window = prev;
  }
  for (const f of ['../src/screens/PR.js', '../src/ui/PRVerdicts.js']) {
    const src = readFileSync(new URL(f, import.meta.url), 'utf8');
    assert.ok(src.length > 0);
    assert.equal(src.indexOf('window.confirm'), -1, `${f} calls window.confirm`);
    // Every bare confirm( is either the useConfirm binding or a call on it.
    const bare = src.split('\n').filter((l) => /(^|[^.\w])confirm\(/.test(l) && !/await confirm\(/.test(l));
    assert.deepEqual(bare, [], `${f} has a bare confirm( outside useConfirm`);
  }
});

test('ui-11 a rejecting action resolves {ok:false}, and PR.js resets pending in finally', async () => {
  const res = await requestLeadReview({
    confirm: async () => true, action: async () => { throw new Error('http_500'); },
    project: 'p', repo: REPO, pr: 12, headSha: LIVE
  });
  assert.deepEqual(res, { ok: false, text: 'http_500' });
  const src = readFileSync(new URL('../src/screens/PR.js', import.meta.url), 'utf8');
  const i = src.indexOf('setRequesting(true)');
  assert.ok(i !== -1, 'PR.js sets the pending flag');
  const fin = src.indexOf('finally', i);
  assert.ok(fin !== -1 && src.indexOf('setRequesting(false)', fin) !== -1, 'the reset is in finally');
});
