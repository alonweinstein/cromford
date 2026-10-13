import test from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { waitFor } from './helpers/wait-for.js';

// BH-3569 (BH-3558.2): BUILDING NOW counts running build JOBS, not console
// `builds` rows. Those rows are never closed when a build is abandoned, parked,
// superseded or restarted, so on 2026-09-29 the tile said 60 while the jobs
// ledger had 11 running. The rows with no live job are "stale" and go to NEEDS.

globalThis.window = globalThis.window || {
  location: { pathname: '/now', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};

const { render } = await import('preact-render-to-string');
const { buildingNow, staleBuilds, liveBuildJobs } = await import('../src/lib/cockpit.js');
const { NowView } = await import('../src/screens/Now.js');
const { NeedsView } = await import('../src/screens/Needs.js');
const { onRequest } = await import('../functions/api/cockpit/[[path]].js');
const { assertNoRawHeaders, assertUsdLabelled } = await import('./legibility.bh-3558.js');
const { ROUTES } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');

const NOW = Date.UTC(2026, 8, 29, 22, 4);
const ago = (s) => new Date(NOW - s * 1000).toISOString();
const ok = (data) => ({ data, error: null, loading: false, reload() {} });
const failed = () => ({ data: null, error: new Error('down'), loading: false, reload() {} });

const buildRow = (i, over = {}) => ({
  id: 1000 + i, bkey: `b${i}`, project: 'project-3', ticket_key: `TK-${500 + i}`, stage: 'planning',
  tier: 2, verdict: null, pr_url: null, merged: 0, updated_at: ago(7200), ...over
});
const job = (id, over = {}) => ({
  id, project: 'cromford', ticket_id: `BH-${id}`, kind: 'build', status: 'running', stage: 'execute',
  box: 'hub', heartbeating: true, activity_age_s: 30, beat_age_s: 30, last_beat_at: ago(30),
  created_at: ago(1800), ...over
});
const jobsPayload = (jobs) => ({ jobs, as_of: new Date(NOW).toISOString() });
const nowPayload = (active_builds, over = {}) => ({
  boards: [], active_builds, active_builds_truncated: false, recent_runs: [], events: [],
  needs: { alerts: 0, commands: 0, builds: 4, proposals: 0, total: 4 }, generated_at: new Date(NOW).toISOString(), ...over
});
const needsPayload = (over = {}) => ({
  project: null, alerts: [], commands: [], builds: [], proposals: [], unfinished_builds: [],
  counts: { alerts: 0, commands: 0, builds: 0, proposals: 0, total: 0 },
  truncated: { alerts: false, commands: false, builds: false, proposals: false, unfinished_builds: false },
  generated_at: new Date(NOW).toISOString(), ...over
});

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
function statValue(out, label) {
  const m = out.match(new RegExp(`stat__label">${esc(label)}</span>\\s*<span class="stat__value[^"]*">([\\s\\S]*?)</span>`));
  assert.ok(m, `no ${label} stat in the render`);
  return m[1].replace(/<[^>]+>/g, '').trim();
}
// The markup of one Section, from its title to the next section.
function section(out, title) {
  const at = out.indexOf(`section__title">${title}<`);
  assert.ok(at >= 0, `no ${title} section`);
  const next = out.indexOf('<div class="section">', at);
  return out.slice(at, next === -1 ? undefined : next);
}
const bodyRows = (markup) => (markup.match(/<tbody>([\s\S]*?)<\/tbody>/) || ['', ''])[1].match(/<tr\b/g) || [];
const renderNow = (active, jobs, over) =>
  render(h(NowView, { data: ok(nowPayload(active, over)), jobs, nowMs: NOW }));
const renderNeeds = (payload, jobs) =>
  render(h(NeedsView, { needs: ok(payload), jobs, project: null, kindFilter: null, nowMs: NOW, setParam() {} }));

// 70 stale planning rows on 70 tickets, 3 live jobs on 3 other tickets.
const SEVENTY = Array.from({ length: 70 }, (_, i) => buildRow(i));
const THREE = jobsPayload([job(1), job(2), job(3)]);

test('B1 tile counts running build jobs, not unfinished build rows', () => {
  assert.equal(buildingNow(THREE, SEVENTY).count, 3);
  const out = renderNow(SEVENTY, ok(THREE));
  assert.equal(statValue(out, 'BUILDING NOW'), '3');
  assert.equal(bodyRows(section(out, 'BUILDING NOW')).length, 3);
  assertNoRawHeaders(out);
  assertUsdLabelled(out);
});

test('B2 one row per ticket: the newest attempt wins, one stale row per ticket', () => {
  const jobs = jobsPayload([
    job('j-old', { ticket_id: 'BH-3479', created_at: '2026-09-29T21:00:00Z' }),
    job('j-new', { ticket_id: 'bh-3479 ', created_at: '2026-09-29T21:30:00Z' })
  ]);
  const bn = buildingNow(jobs, []);
  assert.equal(bn.count, 1);
  assert.equal(bn.rows[0].id, 'j-new');
  const out = renderNow([], ok(jobs));
  assert.equal((section(out, 'BUILDING NOW').match(/>BH-3479</g) || []).length, 1);

  const twice = [
    buildRow(1, { id: 7, ticket_key: 'TK-3355', project: 'project-5', updated_at: ago(7200) }),
    buildRow(2, { id: 8, ticket_key: 'TK-3355', project: 'project-5', updated_at: ago(3600) })
  ];
  const stale = staleBuilds(twice, jobsPayload([]), NOW);
  assert.equal(stale.length, 1);
  assert.equal(stale[0].id, 8);
});

test('B3 a stale row goes to NEEDS as STALE BUILD, never into the building table', () => {
  const row = { id: 91, bkey: 'k91', project: 'cromford', ticket_key: 'BH-3479', stage: 'planning', tier: 2,
    verdict: null, pr_url: null, merged: 0, updated_at: ago(2400) };
  const jobs = ok(jobsPayload([job(1)]));
  const needs = renderNeeds(needsPayload({ unfinished_builds: [row] }), jobs);
  assert.match(needs, /STALE BUILD/);
  assert.match(needs, /BH-3479/);
  assert.match(needs, /href="\/builds\/91"/);
  assertNoRawHeaders(needs);
  assertUsdLabelled(needs);

  const now = renderNow([row], jobs);
  assert.doesNotMatch(section(now, 'BUILDING NOW'), /BH-3479/);
  // server total 4 + the one stale row
  assert.equal(statValue(now, 'NEEDS A HUMAN'), '5');
});

test('B4 the 500-row jobs cap shows as N+, never as an exact count', () => {
  const jobs = jobsPayload(Array.from({ length: 500 }, (_, i) => job(i + 1)));
  const bn = buildingNow(jobs, []);
  assert.equal(bn.capped, true);
  const tile = statValue(renderNow([], ok(jobs)), 'BUILDING NOW');
  assert.match(tile, /^\d+\+$/);
});

test('B5 a failed jobs read is "no data" and classifies nothing as stale', () => {
  assert.equal(liveBuildJobs(null), null);
  assert.equal(buildingNow(null, SEVENTY), null);
  assert.deepEqual(staleBuilds(SEVENTY, null, NOW), []);
  const out = renderNow(SEVENTY, failed());
  assert.equal(statValue(out, 'BUILDING NOW'), 'no data');
  // no stale rows added: the server total stands
  assert.equal(statValue(out, 'NEEDS A HUMAN'), '4');
  const needs = renderNeeds(needsPayload({ unfinished_builds: SEVENTY }), failed());
  assert.doesNotMatch(needs, /STALE BUILD</);
});

test('B6 a quiet build job is neither building nor leaves its row stale', () => {
  const quiet = job(9, { ticket_id: 'TK-500', project: 'project-3', activity_age_s: 900, beat_age_s: 900 });
  const jobs = jobsPayload([job(1), quiet]);
  const bn = buildingNow(jobs, [buildRow(0)]);
  assert.equal(bn.count, 1);
  assert.equal(bn.quiet, 1);
  assert.deepEqual(staleBuilds([buildRow(0)], jobs, NOW), []);
  assert.match(renderNow([buildRow(0)], ok(jobs)), /gone quiet/);
});

test('B7 a row moved 2 minutes ago with no job is neither building nor stale', () => {
  const young = buildRow(0, { updated_at: ago(120) });
  const jobs = jobsPayload([]);
  assert.equal(buildingNow(jobs, [young]).count, 0);
  assert.deepEqual(staleBuilds([young], jobs, NOW), []);
  // an unreadable stamp counts as old
  assert.equal(staleBuilds([buildRow(0, { updated_at: 'garbage' })], jobs, NOW).length, 1);
});

// ------------------------------------------------------------ the Function

function stubDb() {
  const seen = [];
  return {
    seen,
    prepare(sql) {
      const stmt = { binds: [] };
      stmt.bind = (...b) => { stmt.binds = b; return stmt; };
      stmt.all = async () => { seen.push(sql); return { results: sql.includes('stage NOT IN') ? [buildRow(1)] : [] }; };
      stmt.first = async () => { seen.push(sql); return null; };
      return stmt;
    }
  };
}
let seq = 0;
async function call(path) {
  const db = stubDb();
  const real = globalThis.fetch;
  globalThis.fetch = async () => new Response('', { status: 200 });
  try {
    const res = await onRequest({
      request: new Request(`https://mc.example/api/cockpit/${path}`, { headers: { cookie: `dash=bh3569-${++seq}` } }),
      env: { CONSOLE_DB: db },
      params: { path: [path] }
    });
    assert.equal(res.status, 200);
    return { db, body: JSON.parse(await res.text()) };
  } finally {
    globalThis.fetch = real;
  }
}

test('B8 Function: no LIMIT 60, a truncation flag, and /needs carries unfinished builds', async () => {
  const now = await call('now');
  const unfinished = now.db.seen.find((s) => s.includes('stage NOT IN'));
  assert.match(unfinished.trim(), /LIMIT 200$/);
  assert.ok(!now.db.seen.some((s) => /LIMIT 60\b/.test(s)), 'no silent 60-row cap');
  assert.equal(typeof now.body.active_builds_truncated, 'boolean');
  for (const s of now.db.seen) assert.match(s.trim(), /^SELECT/i);

  const needs = await call('needs');
  assert.ok(Array.isArray(needs.body.unfinished_builds));
  assert.equal(needs.body.unfinished_builds[0].ticket_key, 'TK-501');
  assert.equal(typeof needs.body.truncated.unfinished_builds, 'boolean');
  for (const s of needs.db.seen) assert.match(s.trim(), /^SELECT/i);
});

// ------------------------------------------------------------ the screens, mounted

// The production entry point: the real ROUTES table, the real api.js, a stubbed
// fetch. Proves the screens make the jobs read and feed it to the Views.
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
  addEventListener(t, fn) { this.listeners[t] = fn; }
  removeEventListener(t) { delete this.listeners[t]; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}
const JOBS_URL = '/api/coord/jobs?status=running&limit=500';
// Waits until the mounted route has rendered `ready`, never a fixed sleep: a
// loaded box ran preact's effect timer after a 150 ms wait (BH-4940).
async function mountRoute(path, answer, ready, what) {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url) => {
    calls.push(String(url));
    return { ok: true, status: 200, text: async () => JSON.stringify(answer(String(url))) };
  };
  window.location.pathname = path;
  window.location.search = '';
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  doc.hidden = false;
  globalThis.document = doc;
  const root = doc.createElement('div');
  try {
    const hit = ROUTES.map(([p, C]) => [matchRoute(p, path), C]).find(([params]) => params);
    mount(h(hit[1], hit[0]), root);
    await waitFor(() => ready(root.textContent, calls), what,
      () => `calls: ${calls.join(' ') || '(none)'}; render: ${root.textContent.slice(0, 400)}`);
    return { calls, text: root.textContent };
  } finally {
    mount(null, root);
    globalThis.fetch = real;
  }
}

test('B9 the mounted /now and /needs read the jobs ledger and count from it', async (t) => {
  // The screens stamp the clock themselves, so pin it to NOW for this test and
  // build the fixture off the same anchor.
  const realNow = Date.now;
  Date.now = () => NOW;
  t.after(() => { Date.now = realNow; });
  const rel = ago;
  const jobsBody = { jobs: [1, 2, 3].map((i) => job(i, { last_beat_at: rel(30), created_at: rel(1800) })), as_of: rel(0) };
  const stale = SEVENTY.map((b) => ({ ...b, updated_at: rel(7200) }));
  const now = await mountRoute('/now', (u) => (u.includes('/api/coord/jobs') ? jobsBody
    : u.includes('/api/cockpit/now') ? nowPayload(stale) : {}),
    (text, calls) => calls.includes(JOBS_URL) && /BUILDING NOW\s*3(?!\d)/.test(text) && /NEEDS A HUMAN\s*74(?!\d)/.test(text),
    '/now with BUILDING NOW 3 and NEEDS A HUMAN 74');
  assert.ok(now.calls.includes('/api/coord/jobs?status=running&limit=500'), now.calls.join(' '));
  assert.match(now.text, /BUILDING NOW\s*3(?!\d)/);
  // 4 from the server + 70 stale rows
  assert.match(now.text, /NEEDS A HUMAN\s*74(?!\d)/);

  const needs = await mountRoute('/needs', (u) => (u.includes('/api/coord/jobs') ? jobsBody
    : u.includes('/api/cockpit/needs') ? needsPayload({ unfinished_builds: stale.slice(0, 2) }) : {}),
    (text, calls) => calls.includes(JOBS_URL) && /STALE BUILDS\s*2(?!\d)/.test(text) && /TK-500 looks stale/.test(text),
    '/needs with STALE BUILDS 2 and the TK-500 stale row');
  assert.ok(needs.calls.includes('/api/coord/jobs?status=running&limit=500'));
  assert.match(needs.text, /STALE BUILDS\s*2(?!\d)/);
  assert.match(needs.text, /TK-500 looks stale/);
});
