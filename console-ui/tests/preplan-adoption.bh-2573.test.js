import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h, render as mount } from 'preact';
import { api } from '../src/api.js';
import {
  ADOPT_DEFAULTS, adoptKnobs, adoptionState, rateLabel, dayBars, underFloor, recentRows
} from '../src/lib/preplan-adoption.js';
import { PreplanAdoptionView } from '../src/screens/PreplanAdoption.js';
import { flush } from './helpers/settle.js';

// BH-2573 (BH-2543.2): the PREPLAN ADOPTION section of /p/<project>. The
// fixtures are the route's documented answer (bin/lib/preplan-cadence.sh,
// THE ROUTE): bought = adopted + stale, rate = adopted/bought as a fraction,
// null when bought = 0, recent capped at 50 with recent_truncated.

const P = 'project-3';
const ADOPTION = {
  window_days: 7,
  since: '2026-09-19T00:00:00Z',
  projects: [{ project: P, adopted: 4, stale: 8, miss: 3, off: 1, bought: 12, rate: 4 / 12 }],
  days: [
    { project: P, day: '2026-09-25', adopted: 1, stale: 1, miss: 0, off: 0, rate: 0.5 },
    { project: P, day: '2026-09-23', adopted: 3, stale: 7, miss: 1, off: 0, rate: 0.3 },
    { project: P, day: '2026-09-24', adopted: 0, stale: 0, miss: 2, off: 1, rate: null }
  ],
  recent: [
    { job_id: 'job-b', ticket_id: 'TK-2', project: P, verdict: 'STALE', detail: 'plan older than main', created_at: '2026-09-25T09:00:00Z' },
    { job_id: 'job-a', ticket_id: 'TK-9', project: P, verdict: 'ADOPTED', detail: 'plan used', created_at: '2026-09-25T10:00:00Z' },
    { job_id: 'job-c', ticket_id: 'TK-5', project: P, verdict: 'MISS', detail: 'no plan on disk', created_at: '2026-09-24T08:00:00Z' }
  ],
  recent_truncated: false,
  as_of: '2026-09-25T10:05:00Z'
};
const EMPTY = { window_days: 7, since: '2026-09-19T00:00:00Z', projects: [], days: [], recent: [], recent_truncated: false, as_of: 'x' };
const KNOBS = { ...ADOPT_DEFAULTS, source: {}, unreadable: false };

// Answers by URL; `routes` maps a URL prefix to [status, body] (longest wins).
function fakeFetch(routes) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    calls.push({ url: u, method: init.method || 'GET' });
    const key = Object.keys(routes).filter((k) => u.startsWith(k)).sort((a, b) => b.length - a.length)[0];
    if (!key) return { ok: false, status: 599, text: async () => JSON.stringify({ error: `unrouted ${u}` }) };
    const [status, body] = routes[key];
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}

const view = (state, knobs = KNOBS) =>
  render(h(PreplanAdoptionView, { state, knobs, project: P, onRetry: () => {} }));
const count = (s, re) => (s.match(re) || []).length;

// ---- 1: api ---------------------------------------------------------------

test('1: api.preplanAdoption URL-encodes project and days and GETs the coord route', async () => {
  const calls = fakeFetch({ '/api/coord/': [200, EMPTY] });
  await api.preplanAdoption('a b&c', 7);
  await api.preplanAdoption('project-3', 30);
  assert.deepEqual(calls, [
    { url: '/api/coord/preplans/adoption?project=a+b%26c&days=7', method: 'GET' }, // determinism: ok days= only goes to a faked fetch that answers the frozen fixture on any date; nothing under test reads the clock
    { url: '/api/coord/preplans/adoption?project=project-3&days=30', method: 'GET' } // determinism: ok days= only goes to a faked fetch that answers the frozen fixture on any date; nothing under test reads the clock
  ]);
});

// ---- 2-6: the pure lib ----------------------------------------------------

test('2: rateLabel shows a dash for no rate and a percent of the fraction otherwise', () => {
  assert.equal(rateLabel(null), '—');
  assert.equal(rateLabel(undefined), '—');
  assert.equal(rateLabel(NaN), '—');
  assert.equal(rateLabel(0), '0%');
  assert.equal(rateLabel(0.333), '33%');
  assert.equal(rateLabel(0.5), '50%');
  assert.equal(rateLabel(1), '100%');
});

test('3: adoptionState: loading, error, unexpected answer, empty, rows', () => {
  assert.equal(adoptionState({ loading: true, data: null, error: null }, P).kind, 'loading');
  const e = adoptionState({ data: null, error: new Error('http_404'), loading: false }, P);
  assert.equal(e.kind, 'error');
  assert.equal(e.error.message, 'http_404');
  const odd = adoptionState({ data: {}, error: null, loading: false }, P);
  assert.equal(odd.kind, 'error');
  assert.match(odd.error.message, /unexpected answer/);
  assert.equal(adoptionState({ data: { projects: [], days: 'x', recent: [] } }, P).kind, 'error');
  const empty = adoptionState({ data: EMPTY, error: null, loading: false }, P);
  assert.equal(empty.kind, 'empty');
  assert.equal(empty.windowDays, 7);
  assert.notEqual(e.kind, empty.kind);

  const rows = adoptionState({ data: ADOPTION, error: null, loading: false }, P);
  assert.equal(rows.kind, 'rows');
  assert.equal(rows.stats.bought, 12);
  assert.deepEqual(rows.days.map((d) => d.day), ['2026-09-23', '2026-09-24', '2026-09-25']);
  assert.equal(rows.recent.length, 3);
  assert.equal(rows.truncated, false);
  assert.equal(rows.windowDays, 7);

  // Events but no bought pre-plans and no projects row: rows with zeros and
  // no rate, never empty.
  const onlyMiss = adoptionState({ data: { ...EMPTY, recent: [ADOPTION.recent[2]] } }, P);
  assert.equal(onlyMiss.kind, 'rows');
  assert.equal(onlyMiss.stats.bought, 0);
  assert.equal(onlyMiss.stats.rate, null);
  // Another project's rows are not this one's.
  const other = adoptionState({ data: { ...ADOPTION, projects: [{ ...ADOPTION.projects[0], project: 'x' }],
    days: ADOPTION.days.map((d) => ({ ...d, project: 'x' })), recent: [] } }, P);
  assert.equal(other.kind, 'empty');
});

test('4: underFloor mirrors the cadence rule and never fires on thin or absent numbers', () => {
  assert.equal(underFloor({ bought: 9, adopted: 0 }, 50, 10), false);
  assert.equal(underFloor({ bought: 10, adopted: 5 }, 50, 10), false);
  assert.equal(underFloor({ bought: 12, adopted: 4 }, 50, 10), true);
  assert.equal(underFloor({ bought: 10, adopted: 4 }, 50, 10), true);
  assert.equal(underFloor({ bought: 12, adopted: 0 }, 0, 10), false);
  assert.equal(underFloor({}, 50, 10), false);
  assert.equal(underFloor(null, 50, 10), false);
  assert.equal(underFloor({ bought: null, adopted: null }, 50, 0), false);
  assert.equal(underFloor({ bought: 0, adopted: 0, rate: null }, 50, 1), false);
});

test('5: dayBars gives one entry per day, a null-rate day a gap with no height', () => {
  const s = adoptionState({ data: ADOPTION }, P);
  const bars = dayBars(s.days, { width: 300, height: 100 });
  assert.equal(bars.length, 3);
  assert.deepEqual(bars.map((b) => b.gap), [false, true, false]);
  assert.equal(bars[1].h, 0);
  assert.equal(bars[0].h, 30);
  assert.equal(bars[2].h, 50);
  assert.equal(bars[2].y, 50);
  assert.ok(bars[0].x < bars[1].x && bars[1].x < bars[2].x);
  assert.ok(bars.every((b) => b.w > 0 && b.w <= 24));
});

test('6: adoptKnobs: project row beats the lane row, out of range clamps as lane_knob does, junk falls back, unreadable is defaults', () => {
  const k = adoptKnobs({ settings: [
    { key: 'lane.preplan-tick.preplan_adopt_floor_pct', value: '30' },
    { key: 'lane.preplan-tick.project-3.preplan_adopt_floor_pct', value: '70' },
    { key: 'lane.preplan-tick.preplan_adopt_min_samples', value: '5' },
    { key: 'lane.preplan-tick.project-3.preplan_adopt_window_days', value: '45' }
  ] }, P);
  assert.equal(k.floorPct, 70);
  assert.equal(k.minSamples, 5);
  assert.equal(k.windowDays, 30, 'a settings row over the registry max is clamped, as lane_knob clamps it');
  assert.equal(k.unreadable, false);
  assert.equal(k.source.floorPct, 'settings');
  assert.equal(k.source.windowDays, 'settings');
  assert.equal(adoptKnobs({ settings: [] }, P).source.minSamples, 'default');
  const junk = adoptKnobs({ settings: [{ key: 'lane.preplan-tick.project-3.preplan_adopt_floor_pct', value: 'lots' },
    { key: 'lane.preplan-tick.preplan_adopt_min_samples', value: '2.5' }] }, P);
  assert.equal(junk.floorPct, 50);
  assert.equal(junk.minSamples, 10);
  const lane = adoptKnobs({ settings: [{ key: 'lane.preplan-tick.project-3.preplan_adopt_floor_pct', value: 'lots' },
    { key: 'lane.preplan-tick.preplan_adopt_floor_pct', value: '0' }] }, P);
  assert.equal(lane.floorPct, 50, 'a junk project row is the default, as the box reads a set row');
  assert.equal(adoptKnobs({ settings: [{ key: 'lane.preplan-tick.preplan_adopt_min_samples', value: '0' }] }, P).minSamples, 1);
  const u = adoptKnobs({}, P);
  assert.deepEqual([u.floorPct, u.minSamples, u.windowDays, u.unreadable], [50, 10, 7, true]);
  assert.equal(adoptKnobs(null, P).unreadable, true);
});

// ---- 7-12: the rendered view ------------------------------------------------

test('7: rows render the five KV labels and link every row to its job', () => {
  const out = view(adoptionState({ data: ADOPTION }, P));
  for (const label of ['7D RATE', 'BOUGHT', 'ADOPTED', 'STALE', 'MISS']) assert.match(out, new RegExp(label));
  assert.match(out, /kv__val">33% /);
  assert.match(out, />12</);
  for (const id of ['job-a', 'job-b', 'job-c']) {
    assert.equal(count(out, new RegExp(`href="/jobs/${id}"`, 'g')), 2, `AT and TICKET link to /jobs/${id}`);
  }
  const rows = recentRows(ADOPTION.recent);
  assert.deepEqual(rows[0], { id: 'job-b|2026-09-25T09:00:00Z', at: '2026-09-25T09:00:00Z', ticket: 'TK-2',
    verdict: 'STALE', detail: 'plan older than main', job_id: 'job-b' });
});

// Minimal DOM for mounting (the BH-2328 routing-panel pattern).
class FakeNode {
  constructor(nodeType, name, data) {
    this.nodeType = nodeType;
    this.localName = name;
    this.nodeName = name ? name.toUpperCase() : '#text';
    this.data = data;
    this.childNodes = [];
    this.parentNode = null;
    this.attrs = {};
    this.style = {};
    this.listeners = {};
  }
  get onclick() { return null; }
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
  removeChild(n) {
    this.childNodes.splice(this.childNodes.indexOf(n), 1);
    n.parentNode = null;
    return n;
  }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  removeAttribute(k) { delete this.attrs[k]; }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(t, fn) { this.listeners[t] = fn; }
  removeEventListener(t) { delete this.listeners[t]; }
  focus() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}

function installDom() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  return doc;
}

const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const ev = (el, type) => ({ type, target: el, currentTarget: el, preventDefault() {}, stopPropagation() {} });
const mounted = [];
afterEach(() => { while (mounted.length) mount(null, mounted.pop()); });

test('8: AT sorts descending first; clicking TICKET sorts ascending by ticket and reorders the rows', async () => {
  const state = adoptionState({ data: ADOPTION }, P);
  const ssr = view(state);
  assert.match(ssr, /<th aria-sort="descending"[^>]*><button[^>]*>\s*AT/);
  const doc = installDom();
  const root = doc.createElement('div');
  mount(h(PreplanAdoptionView, { state, knobs: KNOBS, project: P, onRetry: () => {} }), root);
  mounted.push(root);
  const ths = () => all(root).filter((n) => n.localName === 'th');
  const th = (label) => ths().find((n) => n.textContent.trim().startsWith(label));
  const tickets = () => all(root).filter((n) => n.localName === 'tr').slice(1).map((tr) => tr.childNodes[1].textContent.trim());
  assert.equal(th('AT').attrs['aria-sort'], 'descending');
  assert.deepEqual(tickets(), ['TK-9', 'TK-2', 'TK-5']);
  const btn = all(th('TICKET')).find((n) => n.localName === 'button');
  btn.listeners.click.call(btn, ev(btn, 'click'));
  await flush();
  assert.equal(th('TICKET').attrs['aria-sort'], 'ascending');
  assert.deepEqual(tickets(), ['TK-2', 'TK-5', 'TK-9']);
});

test('9: a failed read and an empty window render differently, and neither shows 0%', () => {
  const err = view(adoptionState({ error: new Error('http_404') }, P));
  const odd = view(adoptionState({ data: {} }, P));
  const empty = view(adoptionState({ data: EMPTY }, P));
  assert.match(err, /could not load/);
  assert.match(err, /http_404/);
  assert.match(odd, /could not load/);
  assert.match(empty, /no pre-plan events for project-3 in the last 7 days/);
  assert.notEqual(err, empty);
  for (const s of [err, odd, empty]) assert.doesNotMatch(s, /0%/);
  assert.match(view(adoptionState({ loading: true }, P)), /class="skel"/);
});

test('10: the chart draws a bar or a gap for every day, a 50% line, inside its own scroll wrapper', () => {
  const out = view(adoptionState({ data: ADOPTION }, P));
  assert.equal(count(out, /class="adopt-bar"/g), 2);
  assert.equal(count(out, /class="adopt-gap"/g), 1);
  assert.match(out, /<title>2026-09-24: no bought pre-plans<\/title>/);
  assert.match(out, /<title>2026-09-23: 30% \(3\/10\)<\/title>/);
  assert.match(out, /class="adopt-ref"/);
  assert.match(out, />50%<\/text>/);
  assert.match(out, /<div style="overflow-x:auto[^"]*"><svg[^>]*role="img"[^>]*aria-label="daily pre-plan adopt rate, 7 days"/);
});

test('11: a truncated recent list says so', () => {
  const out = view(adoptionState({ data: { ...ADOPTION, recent_truncated: true } }, P));
  assert.match(out, /newest 50 shown; older events exist/);
  assert.doesNotMatch(view(adoptionState({ data: ADOPTION }, P)), /newest 50 shown/);
});

test('12: CADENCE CUT shows only under the box rule; a defaults note when settings were unreadable', () => {
  assert.match(view(adoptionState({ data: ADOPTION }, P)), /CADENCE CUT/);
  const thin = { ...ADOPTION, projects: [{ project: P, adopted: 0, stale: 9, miss: 0, off: 0, bought: 9, rate: 0 }] };
  assert.doesNotMatch(view(adoptionState({ data: thin }, P)), /CADENCE CUT/);
  assert.doesNotMatch(view(adoptionState({ data: ADOPTION }, P), { ...KNOBS, floorPct: 0 }), /CADENCE CUT/);
  assert.doesNotMatch(view(adoptionState({ data: ADOPTION }, P)), /settings unreadable/);
  assert.match(view(adoptionState({ data: ADOPTION }, P), { ...KNOBS, unreadable: true }), /floor from defaults: settings unreadable/);
});

// ---- 13: the production entry point ---------------------------------------

function sectionText(root, title) {
  const t = all(root).find((n) => n.nodeType === 3 && String(n.data) === title);
  assert.ok(t, `a ${title} section is on the page`);
  return t.parentNode.parentNode.parentNode.textContent;
}

async function mountProject(adoption) {
  const { ProjectScreen } = await import('../src/screens/Project.js');
  const doc = installDom();
  const calls = fakeFetch({
    '/api/dash/p/project-3': [200, { board: {}, runs: [], builds: [], alerts: [], events: [] }],
    '/api/dash/costs': [200, { volume: [] }],
    '/api/coord/settings': [200, { settings: [] }],
    '/api/coord/preplans/adoption': adoption,
    '/api/': [200, {}]
  });
  const root = doc.createElement('div');
  mount(h(ProjectScreen, { project: P }), root);
  mounted.push(root);
  await flush();
  await flush();
  return { root, calls };
}

test('13: the real Project page mounts PREPLAN ADOPTION and reads the route with the knob window', async () => {
  const ok = await mountProject([200, ADOPTION]);
  const text = sectionText(ok.root, 'PREPLAN ADOPTION');
  assert.match(text, /7D RATE/);
  assert.match(text, /33%/);
  assert.match(text, /TK-9/);
  const reads = ok.calls.filter((c) => c.url.startsWith('/api/coord/preplans/'));
  assert.deepEqual(reads, [{ url: '/api/coord/preplans/adoption?project=project-3&days=7', method: 'GET' }]); // determinism: ok days= only goes to a faked fetch that answers the frozen fixture on any date; nothing under test reads the clock
  // The LOG TAIL section's own log fetch (api.action) is the page's only POST;
  // this section adds none.
  const writes = ok.calls.filter((c) => c.method !== 'GET').map((c) => c.url);
  assert.ok(writes.every((u) => u === '/api/dash/action'), writes.join(' '));

  const missing = await mountProject([404, { error: 'not found' }]);
  const t = sectionText(missing.root, 'PREPLAN ADOPTION');
  assert.match(t, /could not load/);
  assert.doesNotMatch(t, /0%/);
});
