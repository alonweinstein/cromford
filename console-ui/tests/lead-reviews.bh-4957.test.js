import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { h } from 'preact';
import { render } from 'preact-render-to-string';
import { api } from '../src/api.js';
import { ROUTES, NAV } from '../src/app.js';
import { LeadReviewsScreen } from '../src/screens/LeadReviews.js';
import { KanbanScreen } from '../src/screens/Kanban.js';
import { PRScreen } from '../src/screens/PR.js';
import { leadReviewFailure, LeadReviewFailedLine } from '../src/ui/PRVerdicts.js';
import {
  SPEND_KEY, CONCURRENCY_KEY, DRIFT_LIMIT, autoReposFrom, projectByRepo, prHref, driftCount,
  failedRows, parseLimit, prOfJob
} from '../src/lib/lead-reviews.js';
import { flush } from './helpers/settle.js';

// BH-4957 (BH-4950.4): the /lead-reviews screen and the PR screen's "Lead
// review failed" line. The screen cases mount the real LeadReviewsScreen in a
// fake DOM with fetch stubbed; every fixture below is shaped like the worker
// route it stands in for (worker/jobs/src/routes/pr-state.js, lead-reviews.js,
// jobs.js, cost.js, settings.js, projects.js, lanes registry).

const REPO = 'example-org/cromford';
const OTHER = 'example-org/unmapped';
const H1 = 'a'.repeat(40);
const H2 = 'b'.repeat(40);
const H3 = 'c'.repeat(40);
const OLD = '0'.repeat(40);

const REGISTRY = { lanes: [{ id: 'lead-review-land', knobs: [{ env: 'LEAD_REVIEW_AUTO_REPOS', default: `${REPO} ${OTHER}` }] }] };
const PROJECTS = { projects: [{ project: 'cromford', repo: REPO }] };
const NEEDS = {
  [REPO]: [
    { repo: REPO, number: 41, url: `https://github.com/${REPO}/pull/41`, head: H1, hotfix: 1, nudged: 0, approved_at: '2026-10-06T09:00:00Z' },
    { repo: REPO, number: 40, url: `https://github.com/${REPO}/pull/40`, head: H2, hotfix: 0, nudged: 0, approved_at: '2026-10-06T08:00:00Z' }
  ],
  [OTHER]: [
    { repo: OTHER, number: 7, url: `https://github.com/${OTHER}/pull/7`, head: H3, hotfix: 0, nudged: 1, approved_at: '2026-10-06T07:00:00Z' }
  ]
};
const GATE = {
  [REPO]: [
    { repo: REPO, number: 30, head: H1, review_failed_sha: H1, url: null },
    { repo: REPO, number: 31, head: H2, review_failed_sha: OLD, url: null },
    { repo: REPO, number: 32, head: H3, review_failed_sha: null, url: null }
  ],
  [OTHER]: []
};
const FAILED = [
  { id: 'r1', repo: REPO, pr: 30, head_sha: H1, status: 'failed', detail: 'agent timed out after 900s', job_id: 'lr-30-aaaaaaaaaaaa-1', updated_at: '2026-10-06T10:00:00Z' },
  { id: 'r2', repo: REPO, pr: 31, head_sha: OLD, status: 'failed', detail: 'old head failure', job_id: 'lr-31-000000000000-1', updated_at: '2026-10-05T10:00:00Z' }
];
const JOBS = [
  { id: 'lr-41-aaaaaaaaaaaa-9', project: 'cromford', ticket_id: 'lr-41-aaaaaaaaaaaa', kind: 'lead_review', box: 'hub', status: 'running', age_s: 300, created_at: '2026-10-07T00:00:00Z' },
  { id: 'lr-x-1', project: 'cromford', ticket_id: null, kind: 'lead_review', box: 'mac', status: 'running', age_s: 60, created_at: '2026-10-07T00:04:00Z' }
];
// The event log is read over a rolling 24h window, so its fixtures hang off one
// captured anchor (NOW), in the worker's fixed-width form, and the stub below
// applies `since` to `at` the way GET /api/pr-state-events does. The 30h-old
// reconcile is outside the window and must never be counted.
const NOW = Date.now(); // determinism: ok one captured anchor; every event is an offset from it and none sits within 6h of the 24h edge
const HOURS = 3600e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const EVENTS = [
  { id: 4, repo: REPO, number: 1, state: 'gate', reason: 'reconcile', at: iso(NOW - 1 * HOURS) },
  { id: 3, repo: REPO, number: 2, state: 'open', reason: 'webhook', at: iso(NOW - 2 * HOURS) },
  { id: 2, repo: REPO, number: 3, state: 'gate', reason: 'reconcile', at: iso(NOW - 3 * HOURS) },
  { id: 1, repo: REPO, number: 4, state: 'gate', reason: 'reconcile', at: iso(NOW - 30 * HOURS) }
];
const inWindow = (rows, since) => rows.filter((r) => !since || !r.at || r.at >= since);

// ---- the fake DOM (tests/protected-paths.bh-4140.test.js) -----------------
class FakeNode {
  constructor(nodeType, name, data) {
    Object.assign(this, { nodeType, localName: name, nodeName: name ? name.toUpperCase() : '#text', data,
      childNodes: [], parentNode: null, attrs: {}, style: {}, listeners: {} });
  }
  get firstChild() { return this.childNodes[0] || null; }
  get nextSibling() {
    if (!this.parentNode) return null;
    const s = this.parentNode.childNodes;
    return s[s.indexOf(this) + 1] || null;
  }
  insertBefore(n, ref) {
    if (n.parentNode) n.parentNode.removeChild(n);
    n.parentNode = this;
    const i = ref ? this.childNodes.indexOf(ref) : -1;
    if (i < 0) this.childNodes.push(n); else this.childNodes.splice(i, 0, n);
    return n;
  }
  appendChild(n) { return this.insertBefore(n, null); }
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n; }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  removeAttribute(k) { delete this.attrs[k]; }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(t, fn) { this.listeners[t.toLowerCase()] = fn; (this.types = this.types || {})[t.toLowerCase()] = t; }
  removeEventListener(t) { delete this.listeners[t.toLowerCase()]; }
  focus() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const byText = (root, tag, text) => all(root).filter((n) => n.localName === tag && n.textContent.trim() === text);
const fire = (node, type, extra = {}) => node.listeners[type].call(node, { type: node.types[type], button: 0, preventDefault() {}, ...extra });
const section = (root, title) => all(root).find((n) => n.attrs && n.attrs.class === 'section'
  && n.textContent.trim().startsWith(title));
const tile = (root, id) => all(root).find((n) => n.attrs && n.attrs['data-tile'] === id);
const hrefs = (node) => all(node).filter((n) => n.localName === 'a').map((n) => n.attrs.href);
const modalBtn = (root, text) => {
  const box = all(root).find((n) => n.attrs && n.attrs.class === 'modal__actions');
  return box ? byText(box, 'button', text)[0] : undefined;
};

let mounted = null;
const realFetch = globalThis.fetch;
afterEach(async () => {
  if (mounted) { const { render: m } = await import('preact'); m(null, mounted); mounted = null; }
  globalThis.fetch = realFetch;
  delete globalThis.confirm;
  delete globalThis.alert;
  delete globalThis.prompt;
});

function fakeDom() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  globalThis.window.location = globalThis.window.location || { pathname: '/lead-reviews', search: '' };
  return doc;
}
function fakeFetch(respond) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    calls.push({ url: u, method: init.method || 'GET', body: init.body });
    const [status, body] = respond(u, init);
    return { ok: status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}
async function mount(vnode) {
  const doc = fakeDom();
  const { render: m } = await import('preact');
  const root = doc.createElement('div');
  m(vnode, root);
  mounted = root;
  await flush();
  return { root, doc };
}

// The worker, stubbed. `o` overrides one answer per route; a function answer
// gets (url, init).
function world(o = {}) {
  const settings = { [SPEND_KEY]: o.cap === undefined ? { key: SPEND_KEY, value: '20' } : o.cap,
    [CONCURRENCY_KEY]: o.conc === undefined ? { key: CONCURRENCY_KEY, value: '3' } : o.conc };
  return (u, init) => {
    const url = new URL(u, 'https://mc.test');
    const p = url.pathname;
    const repo = url.searchParams.get('repo');
    if (p === '/api/coord/settings' && init.method === 'PUT') {
      if (o.put) return o.put(JSON.parse(init.body));
      const b = JSON.parse(init.body);
      settings[b.key] = { key: b.key, value: b.value };
      return [200, { setting: settings[b.key] }];
    }
    if (p === '/api/coord/lanes/registry') return o.registry || [200, { registry: REGISTRY, as_of: 't' }];
    if (p === '/api/coord/projects') return o.projects || [200, { ...PROJECTS, as_of: 't' }];
    if (p.startsWith('/api/coord/settings/')) {
      const key = decodeURIComponent(p.slice('/api/coord/settings/'.length));
      return [200, { key, setting: settings[key] || null, source: settings[key] ? 'settings' : 'none' }];
    }
    if (p === '/api/coord/metrics/llm-spend') return o.spend || [200, { usd: 4.5, calls: 3, refused: 0, settled: 3, lane: 'lead-review' }];
    if (p === '/api/coord/jobs') return o.jobs || [200, { jobs: JOBS, as_of: 't' }];
    if (p === '/api/coord/pr-state-events') return o.events || [200, { rows: inWindow(EVENTS, url.searchParams.get('since')), as_of: 't' }];
    if (p === '/api/coord/pr-state/needs-review') return o.needs ? o.needs(repo) : [200, { rows: NEEDS[repo] || [], as_of: 't' }];
    if (p === '/api/coord/pr-state/gate') return o.gate ? o.gate(repo) : [200, { rows: GATE[repo] || [], as_of: 't' }];
    if (p === '/api/coord/lead-reviews') return o.failed || [200, { requests: FAILED, truncated: false, as_of: 't' }];
    return [404, { error: `unstubbed ${p}` }];
  };
}

// ---- 1. the strip and the three tables -------------------------------------
test('1: renders the strip and the three tables from the stubbed api, worklist columns in order', async () => {
  const calls = fakeFetch(world());
  const { root } = await mount(h(LeadReviewsScreen));
  assert.match(tile(root, 'spend').textContent, /\$4\.50 \/ cap \$20\.00/);
  assert.deepEqual(hrefs(tile(root, 'spend')), ['/costs'], 'spend links to /costs');
  assert.match(tile(root, 'running').textContent, /2 \/ concurrency 3/);
  assert.match(tile(root, 'drift').textContent, /DRIFT 24H.*2/);

  const work = section(root, 'WORKLIST');
  const heads = all(work).filter((n) => n.localName === 'th').map((n) => n.textContent.replace(/[↑↓]/g, '').trim());
  assert.deepEqual(heads, ['POSITION', 'PR', 'HEAD', 'HOTFIX', 'NUDGED', 'APPROVED AT']);
  const workRows = all(work).filter((n) => n.localName === 'tr').slice(1).map((n) => n.textContent);
  assert.equal(workRows.length, 3);
  assert.ok(workRows.some((t) => t.includes(`${REPO}#41`) && t.includes(H1.slice(0, 12)) && t.includes('hotfix')));
  assert.ok(workRows.some((t) => t.includes(`${OTHER}#7`) && t.includes('nudged')));

  const run = section(root, 'RUNNING');
  const runText = all(run).filter((n) => n.localName === 'tr').slice(1).map((n) => n.textContent);
  assert.equal(runText.length, 2);
  assert.ok(runText.some((t) => t.includes('lr-41-aaaaaaaaaaaa-9') && t.includes('#41') && t.includes('hub') && t.includes('5m 0s')));

  const failed = section(root, 'FAILED');
  const failedText = all(failed).filter((n) => n.localName === 'tr').slice(1).map((n) => n.textContent);
  assert.equal(failedText.length, 1, 'only #30, whose failure is on its live head');
  assert.match(failedText[0], /#30/);
  assert.match(failedText[0], /agent timed out after 900s/);

  // the reads went where the plan says, with the filters on
  const gets = calls.filter((c) => c.method === 'GET').map((c) => c.url);
  assert.ok(gets.includes('/api/coord/metrics/llm-spend?stage=lead-review&lane=lead-review'));
  assert.ok(gets.includes('/api/coord/jobs?status=running&kind=lead_review&limit=100'));
  assert.ok(gets.includes(`/api/coord/pr-state/needs-review?repo=${encodeURIComponent(REPO)}&limit=200`));
  assert.ok(gets.includes(`/api/coord/pr-state/gate?repo=${encodeURIComponent(OTHER)}`));
  assert.ok(gets.includes('/api/coord/lead-reviews?status=failed&limit=100'));
  assert.ok(gets.some((u) => /^\/api\/coord\/pr-state-events\?since=\d{4}-\d\d-\d\dT\d\d%3A\d\d%3A\d\dZ&limit=1000$/.test(u)), gets.join('\n'));
  assert.ok(gets.includes(`/api/coord/settings/${SPEND_KEY}`));
  assert.ok(gets.includes(`/api/coord/settings/${CONCURRENCY_KEY}`));
  assert.ok(gets.includes('/api/coord/projects'));
});

test('1b: fetch paths of the new api methods', async () => {
  const calls = fakeFetch(() => [200, { rows: [], requests: [], projects: [] }]);
  await api.prNeedsReview(REPO);
  await api.prGate(REPO);
  await api.prStateEvents({ since: '2026-10-06T00:00:00Z', limit: 5 });
  await api.leadReviews({ status: 'failed', repo: REPO, limit: 7 });
  await api.coordProjects();
  await api.jobs({ kind: 'lead_review' });
  await api.llmSpend({ stage: 'lead-review', lane: 'lead-review' });
  assert.deepEqual(calls.map((c) => c.url), [
    '/api/coord/pr-state/needs-review?repo=example-org%2Fcromford',
    '/api/coord/pr-state/gate?repo=example-org%2Fcromford',
    '/api/coord/pr-state-events?since=2026-10-06T00%3A00%3A00Z&limit=5',
    '/api/coord/lead-reviews?status=failed&repo=example-org%2Fcromford&limit=7',
    '/api/coord/projects',
    '/api/coord/jobs?kind=lead_review&limit=100',
    '/api/coord/metrics/llm-spend?stage=lead-review&lane=lead-review'
  ]);
});

// ---- 2. absent rows ---------------------------------------------------------
test('2: "no cap set" with no spend row, "default (free slots)" with no concurrency row; junk is unreadable, never 0', async () => {
  fakeFetch(world({ cap: null, conc: null }));
  let { root } = await mount(h(LeadReviewsScreen));
  assert.match(tile(root, 'spend').textContent, /no cap set/);
  assert.match(tile(root, 'running').textContent, /default \(free slots\)/);
  const { render: m } = await import('preact'); m(null, mounted); mounted = null;

  fakeFetch(world({ cap: { key: SPEND_KEY, value: 'lots' }, conc: { key: CONCURRENCY_KEY, value: '0' }, spend: [503, { error: 'd1 down' }] }));
  ({ root } = await mount(h(LeadReviewsScreen)));
  assert.match(tile(root, 'spend').textContent, /spend unreadable \/ cap lots \(unreadable\)/);
  assert.doesNotMatch(tile(root, 'spend').textContent, /\$0\.00|no cap set/);
  assert.match(tile(root, 'running').textContent, /concurrency 0 \(unreadable\)/);
});

// ---- 3. the EDIT modal --------------------------------------------------------
test('3: EDIT cap: Escape sends nothing; a bad value keeps SAVE blocked; SAVE PUTs exactly one settings row', async () => {
  for (const k of ['confirm', 'alert', 'prompt']) globalThis[k] = () => { throw new Error(`native ${k} called`); };
  const calls = fakeFetch(world({ cap: null }));
  const { root, doc } = await mount(h(LeadReviewsScreen));
  const puts = () => calls.filter((c) => c.method === 'PUT');
  const editBtn = () => byText(tile(root, 'spend'), 'button', 'EDIT')[0];

  fire(editBtn(), 'click');
  await flush();
  assert.match(root.textContent, /EDIT DAILY SPEND CAP/);
  doc.listeners.keydown({ key: 'Escape', preventDefault() {} });
  await flush();
  assert.equal(puts().length, 0, 'Escape sends nothing');
  assert.doesNotMatch(root.textContent, /EDIT DAILY SPEND CAP/);

  fire(editBtn(), 'click');
  await flush();
  const input = () => all(root).find((n) => n.localName === 'input' && n.attrs['aria-label'] === SPEND_KEY);
  const save = () => modalBtn(root, 'SAVE');
  for (const bad of ['-1', 'abc', '']) {
    fire(input(), 'input', { target: { value: bad } });
    await flush();
    assert.ok(save().disabled === true || save().attrs.disabled !== undefined, `SAVE blocked on ${JSON.stringify(bad)}`);
    fire(save(), 'click');
    await flush();
    assert.equal(puts().length, 0, `no PUT on ${JSON.stringify(bad)}`);
  }
  fire(input(), 'input', { target: { value: '25' } });
  await flush();
  fire(save(), 'click');
  await flush();
  assert.equal(puts().length, 1);
  assert.equal(puts()[0].url, '/api/coord/settings');
  assert.deepEqual(JSON.parse(puts()[0].body), { key: SPEND_KEY, value: '25', reason: 'console edit' });
  assert.match(tile(root, 'spend').textContent, /cap \$25\.00/, 'the strip reloads the saved row');
});

test('3b: a refused PUT shows the worker error and the strip keeps the server value', async () => {
  const calls = fakeFetch(world({ put: () => [400, { error: 'value must be non-empty and <= 64 chars' }] }));
  const { root } = await mount(h(LeadReviewsScreen));
  fire(byText(tile(root, 'running'), 'button', 'EDIT')[0], 'click');
  await flush();
  fire(all(root).find((n) => n.localName === 'input' && n.attrs['aria-label'] === CONCURRENCY_KEY), 'input', { target: { value: '5' } });
  await flush();
  fire(modalBtn(root, 'SAVE'), 'click');
  await flush();
  assert.equal(calls.filter((c) => c.method === 'PUT').length, 1);
  assert.match(root.textContent, /value must be non-empty/);
  assert.match(tile(root, 'running').textContent, /concurrency 3/);
  assert.doesNotMatch(root.textContent, /set to 5/);
});

test('3c: no native dialog in the screen source', () => {
  const src = readFileSync(new URL('../src/screens/LeadReviews.js', import.meta.url), 'utf8');
  assert.ok(src.length > 0);
  assert.doesNotMatch(src, /window\.confirm|\bconfirm\(\s*['"`]|\balert\(|\bprompt\(/);
  assert.match(src, /useConfirm/);
});

// ---- 4. sortable headers -------------------------------------------------------
test('4: every table header sorts and toggles aria-sort asc -> desc', async () => {
  fakeFetch(world());
  const { root } = await mount(h(LeadReviewsScreen));
  for (const [title, label] of [['WORKLIST', 'APPROVED AT'], ['RUNNING', 'BOX'], ['FAILED', 'HEAD']]) {
    const th = () => all(section(root, title)).find((n) => n.localName === 'th' && n.textContent.includes(label));
    assert.equal(th().attrs['aria-sort'], 'none', `${title} ${label} starts unsorted`);
    fire(byText(th(), 'button', label)[0] || all(th()).find((n) => n.localName === 'button'), 'click');
    await flush();
    assert.equal(th().attrs['aria-sort'], 'ascending', `${title} ${label}`);
    fire(all(th()).find((n) => n.localName === 'button'), 'click');
    await flush();
    assert.equal(th().attrs['aria-sort'], 'descending', `${title} ${label}`);
  }
  // and the worklist sort is on the displayed value: approved_at ascending puts #7 first
  const work = section(root, 'WORKLIST');
  const th = all(work).find((n) => n.localName === 'th' && n.textContent.includes('APPROVED AT'));
  fire(all(th).find((n) => n.localName === 'button'), 'click');
  await flush();
  const first = all(work).filter((n) => n.localName === 'tr')[1].textContent;
  assert.match(first, new RegExp(`${OTHER}#7`));
});

// ---- 5. links ---------------------------------------------------------------------
test('5: PR cells link to /pr/:project/:n (GitHub for an unmapped repo), job cells to /jobs/:id', async () => {
  fakeFetch(world());
  const { root } = await mount(h(LeadReviewsScreen));
  const work = hrefs(section(root, 'WORKLIST'));
  assert.ok(work.includes('/pr/cromford/41'));
  assert.ok(work.includes('/pr/cromford/40'));
  assert.ok(work.includes(`https://github.com/${OTHER}/pull/7`));
  const run = hrefs(section(root, 'RUNNING'));
  assert.ok(run.includes('/jobs/lr-41-aaaaaaaaaaaa-9'));
  assert.ok(run.includes('/jobs/lr-x-1'), 'a job with no PR still links');
  assert.ok(run.includes('/pr/cromford/41'));
  const failed = hrefs(section(root, 'FAILED'));
  assert.ok(failed.includes('/pr/cromford/30'));
  assert.ok(failed.includes('/jobs/lr-30-aaaaaaaaaaaa-1'));
  // pure: the map and the no-project fallback
  const map = projectByRepo({ projects: [{ project: 'a', repo: 'O/R' }, { project: 'x', repo: 'D/D' }, { project: 'y', repo: 'd/d' }] });
  assert.equal(prHref(map, 'o/r', 3), '/pr/a/3', 'repo match is case-insensitive');
  assert.equal(prHref(map, 'Z/Z', 3), null, 'no project, no console link');
  assert.equal(prHref(map, 'D/D', 3), null, 'a repo two projects claim maps to neither');
  assert.equal(prOfJob({ ticket_id: 'lr-41-aaaaaaaaaaaa' }), 41);
  assert.equal(prOfJob({ ticket_id: 'BH-41' }), null);
});

// ---- 6. drift ------------------------------------------------------------------
test('6: drift reads reconcile only, and a full page shows >=n', async () => {
  assert.deepEqual(driftCount(inWindow(EVENTS, iso(NOW - 24 * HOURS)), DRIFT_LIMIT), { n: 2, capped: false });
  assert.deepEqual(driftCount([{ reason: 'webhook' }, { reason: null }, {}], DRIFT_LIMIT), { n: 0, capped: false });
  const full = Array.from({ length: DRIFT_LIMIT }, (_, i) => ({ id: i, reason: i % 4 === 0 ? 'reconcile' : 'tick' }));
  assert.deepEqual(driftCount(full, DRIFT_LIMIT), { n: 250, capped: true });
  fakeFetch(world({ events: [200, { rows: full }] }));
  const { root } = await mount(h(LeadReviewsScreen));
  assert.match(tile(root, 'drift').textContent, /≥250/);
});

// ---- 7. PR screen failed line ---------------------------------------------------
test('7: leadReviewFailure / LeadReviewFailedLine show only when the failure is on the live head', () => {
  const N = 30;
  const failedOnLive = { repo: REPO, pr: N, head_sha: H1, status: 'failed', detail: 'boom', job_id: 'j1', updated_at: 't' };
  // no: review_failed_sha on an older head
  assert.equal(leadReviewFailure({ liveHead: H1, number: N, gateRow: { number: N, head: H1, review_failed_sha: OLD }, failedRequests: [] }), null);
  // no: review_failed_sha null
  assert.equal(leadReviewFailure({ liveHead: H1, number: N, gateRow: { number: N, head: H1, review_failed_sha: null }, failedRequests: [] }), null);
  // no: a failed request for another PR in the same repo, on the same sha
  assert.equal(leadReviewFailure({ liveHead: H1, number: N, gateRow: null, failedRequests: [{ ...failedOnLive, pr: 31 }] }), null);
  // no: a failed request for this PR on an old head
  assert.equal(leadReviewFailure({ liveHead: H1, number: N, gateRow: null, failedRequests: [{ ...failedOnLive, head_sha: OLD }] }), null);
  // no: a short live head
  assert.equal(leadReviewFailure({ liveHead: H1.slice(0, 12), number: N, gateRow: { number: N, review_failed_sha: H1 }, failedRequests: [failedOnLive] }), null);
  // no: nothing at all
  assert.equal(leadReviewFailure({ liveHead: H1, number: N, gateRow: null, failedRequests: [] }), null);
  // yes: gate row on the live head, joined to the request
  assert.deepEqual(leadReviewFailure({ liveHead: H1, number: N, gateRow: { number: N, review_failed_sha: H1 }, failedRequests: [failedOnLive] }), { detail: 'boom', job_id: 'j1' });
  // yes: a failed request on the live head with no gate row
  assert.deepEqual(leadReviewFailure({ liveHead: H1, number: N, gateRow: null, failedRequests: [failedOnLive] }), { detail: 'boom', job_id: 'j1' });
  // yes: gate row with no request: no detail
  assert.deepEqual(leadReviewFailure({ liveHead: H1, number: N, gateRow: { number: N, review_failed_sha: H1 }, failedRequests: [] }), { detail: null, job_id: null });

  const line = (data, extra = {}) => render(h(LeadReviewFailedLine, { number: N, liveHead: H1, state: { data, loading: false, error: null, ...extra } }));
  const onLive = line({ gate: { rows: [{ number: N, head: H1, review_failed_sha: H1 }] }, failed: { requests: [failedOnLive], truncated: false } });
  assert.match(onLive, /Lead review failed: <b>boom<\/b>/);
  assert.match(onLive, /href="\/lead-reviews"/);
  assert.match(onLive, /href="\/jobs\/j1"/);
  const onOld = line({ gate: { rows: [{ number: N, head: H1, review_failed_sha: OLD }] }, failed: { requests: [], truncated: false } });
  assert.doesNotMatch(onOld, /Lead review failed/);
  const reqOnly = line({ gate: { rows: [] }, failed: { requests: [failedOnLive], truncated: false } });
  assert.match(reqOnly, /Lead review failed/);
  const noDetail = line({ gate: { rows: [{ number: N, review_failed_sha: H1 }] }, failed: { requests: [], truncated: false } });
  assert.match(noDetail, /Lead review failed: <b>no detail recorded<\/b>/);
  assert.equal(line({ gate: { rows: [] }, failed: { requests: [], truncated: false } }), '');
  // unreadable is said, never "not failed"
  const err = line(null, { error: new Error('d1 down') });
  assert.match(err, /lead review state unreadable \(d1 down\)/);
  assert.doesNotMatch(err, /Lead review failed/);
  assert.equal(render(h(LeadReviewFailedLine, { number: N, liveHead: null, state: { data: null } })), '');
});

test('7b: the real PR screen shows the failed line on its live head, and not on an old one', async () => {
  const prBody = { html_url: `https://github.com/${REPO}/pull/30`, head_sha: H1, builds: [] };
  const prWorld = (gateRows, requests) => (u) => {
    const p = new URL(u, 'https://mc.test').pathname;
    if (p === '/api/dash/pr/cromford/30') return [200, prBody];
    if (p === '/api/coord/verdicts') return [200, { rows: [], standing: null, truncated: false }];
    if (p === '/api/coord/pr-state/gate') return [200, { rows: gateRows }];
    if (p === '/api/coord/lead-reviews') return [200, { requests, truncated: false }];
    return [200, {}];
  };
  const { render: m } = await import('preact');
  let calls = fakeFetch(prWorld([{ repo: REPO, number: 30, head: H1, review_failed_sha: H1 }], [FAILED[0]]));
  let { root } = await mount(h(PRScreen, { project: 'cromford', number: '30' }));
  assert.ok(calls.some((c) => c.url === `/api/coord/pr-state/gate?repo=${encodeURIComponent(REPO)}`));
  assert.ok(calls.some((c) => c.url === `/api/coord/lead-reviews?status=failed&repo=${encodeURIComponent(REPO)}&limit=100`));
  assert.match(root.textContent, /Lead review failed: agent timed out after 900s/);
  const line = all(root).find((n) => n.attrs && 'data-lead-review-failed' in n.attrs);
  assert.ok(hrefs(line).includes('/lead-reviews'));
  m(null, mounted); mounted = null;

  fakeFetch(prWorld([{ repo: REPO, number: 30, head: H1, review_failed_sha: OLD }], [FAILED[1]]));
  ({ root } = await mount(h(PRScreen, { project: 'cromford', number: '30' })));
  assert.match(root.textContent, /VERDICTS/);
  assert.doesNotMatch(root.textContent, /Lead review failed/);
});

// ---- 8. empty and errors ----------------------------------------------------------
test('8: empty data reads "none"; an errored read is an ErrorBox, never "none"', async () => {
  fakeFetch(world({
    cap: null, conc: null, jobs: [200, { jobs: [] }], events: [200, { rows: [] }], failed: [200, { requests: [], truncated: false }],
    needs: () => [200, { rows: [] }], gate: () => [200, { rows: [] }]
  }));
  let { root } = await mount(h(LeadReviewsScreen));
  for (const t of ['WORKLIST', 'RUNNING', 'FAILED']) {
    assert.match(section(root, t).textContent, /none/, `${t} empty reads none`);
    assert.doesNotMatch(section(root, t).textContent, /could not load/, `${t} empty is not an error`);
  }
  assert.match(tile(root, 'drift').textContent, /DRIFT 24H.*0/);
  const { render: m } = await import('preact'); m(null, mounted); mounted = null;

  fakeFetch(world({
    jobs: [503, { error: 'd1 down' }],
    needs: () => [503, { error: 'd1 down' }], gate: () => [503, { error: 'd1 down' }]
  }));
  ({ root } = await mount(h(LeadReviewsScreen)));
  for (const t of ['WORKLIST', 'RUNNING', 'FAILED']) {
    assert.match(section(root, t).textContent, /could not load/, `${t} error is an ErrorBox`);
    assert.doesNotMatch(section(root, t).textContent, /\bnone\b/, `${t} error is not none`);
  }
  m(null, mounted); mounted = null;

  // one repo down: its name is in the banner and the other repo's rows render
  fakeFetch(world({ needs: (repo) => (repo === OTHER ? [503, { error: 'd1 down' }] : [200, { rows: NEEDS[repo] }]) }));
  ({ root } = await mount(h(LeadReviewsScreen)));
  const work = section(root, 'WORKLIST').textContent;
  assert.match(work, /incomplete: could not read the worklist for example-org\/unmapped \(d1 down\)/);
  assert.match(work, /example-org\/cromford#41/);
  m(null, mounted); mounted = null;

  // no auto repo knob: an error, never an empty worklist
  fakeFetch(world({ registry: [200, { registry: { lanes: [] } }] }));
  ({ root } = await mount(h(LeadReviewsScreen)));
  assert.match(section(root, 'WORKLIST').textContent, /no LEAD_REVIEW_AUTO_REPOS/);
  assert.doesNotMatch(section(root, 'WORKLIST').textContent, /\bnone\b/);
});

test('8b: pure helpers: auto repos, failed rows, limit parsing', () => {
  assert.deepEqual(autoReposFrom(REGISTRY), [REPO, OTHER]);
  assert.deepEqual(autoReposFrom({ lanes: [{ id: 'lead-review-land', knobs: [{ env: 'LEAD_REVIEW_AUTO_REPOS', default: 'a/b, c/d' }] }] }), ['a/b', 'c/d']);
  assert.equal(autoReposFrom({ lanes: [{ id: 'lead-review-land', knobs: [] }] }), null);
  assert.equal(autoReposFrom(null), null);
  const rows = failedRows(GATE[REPO], FAILED);
  assert.deepEqual(rows.map((r) => [r.number, r.detail, r.job_id]), [[30, 'agent timed out after 900s', 'lr-30-aaaaaaaaaaaa-1']]);
  for (const bad of ['-1', 'abc', '', '1e3', ' ', null]) assert.equal(parseLimit('spend', bad).ok, false, `spend ${bad}`);
  for (const bad of ['0', '1.5', '-2', 'x', '']) assert.equal(parseLimit('concurrency', bad).ok, false, `concurrency ${bad}`);
  assert.deepEqual(parseLimit('spend', ' 12.50 '), { ok: true, value: 12.5 });
  assert.deepEqual(parseLimit('spend', '0'), { ok: true, value: 0 });
  assert.deepEqual(parseLimit('concurrency', '4'), { ok: true, value: 4 });
});

// ---- 9. route and nav ---------------------------------------------------------------
test('9: ROUTES has /lead-reviews -> LeadReviewsScreen; KANBAN nav matches it; /kanban links to it', () => {
  const route = ROUTES.find(([p]) => p === '/lead-reviews');
  assert.ok(route, 'route present');
  assert.equal(route[1], LeadReviewsScreen);
  const kanban = NAV.find((n) => n.label === 'KANBAN');
  assert.equal(kanban.match('/lead-reviews'), true);
  const src = readFileSync(new URL('../src/screens/Kanban.js', import.meta.url), 'utf8');
  assert.match(src, /<\$\{Link\} to="\/lead-reviews" class="btn btn--sm">LEAD REVIEWS<\/\/>/);
  assert.equal(typeof KanbanScreen, 'function');
});
