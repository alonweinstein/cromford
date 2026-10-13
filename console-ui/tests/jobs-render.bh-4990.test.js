// BH-4990 (BH-4947 wave 1, "The Line"): the Jobs screen redrawn.
//
// The headline is built from the jobs payload's own numbers, the stat grid
// shows the same numbers, and every ticket key on the line board and in its
// log is a link to the ticket route /t/<KEY>, which exists. The pure view is
// rendered to a string; /jobs and /t/<KEY> are also mounted through the real
// ROUTES table into a small fake DOM against a stubbed fetch, so the screen's
// own reads go through the real api.js.

import test from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';
import { assertNoRawHeaders, assertUsdLabelled } from './legibility.bh-3558.js';

globalThis.window = globalThis.window || {
  location: { pathname: '/jobs', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { ROUTES, NAV } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { api } = await import('../src/api.js');
const { JobsScreen, JobsLine, JobsTable } = await import('../src/screens/Jobs.js');
const { TicketScreen, TicketView } = await import('../src/screens/Ticket.js');
const { jobsHeadline, lineTickets, lineLog, ticketPath } = await import('../src/lib/line.js');
const { jobRows, jobCounts, laneRows, laneCounts } = await import('../src/lib/jobs.js');
const { render } = await import('preact-render-to-string');

// One pinned clock for every fixture time (the determinism lint).
const NOW = Date.parse('2026-10-06T21:40:00Z');
const iso = (minAgo) => new Date(NOW - minAgo * 60000).toISOString();

const job = (id, over) => ({
  id, project: 'project-3', kind: 'build', box: 'box-project-3-1', stage: 'execute', status: 'running',
  heartbeating: true, activity_age_s: 30, beat_age_s: 30, age_s: 600, spent_usd: 1.25, budget_usd: 20,
  created_at: iso(10), updated_at: iso(1), last_beat_at: iso(1), beat_note: null, ...over
});

// 3 running (2 keyed, 1 keyless triage tick), 1 parked, 2 orphaned, 1 stalled, 1 done.
function payload({ running = 3 } = {}) {
  const jobs = [
    job('b-101', { ticket_id: 'BH-101', stage: 'execute', beat_note: 'tests green', created_at: iso(30), last_beat_at: iso(0) }),
    job('t-101', { ticket_id: 'BH-101', kind: 'triage', stage: 'triage', status: 'done', created_at: iso(50), spent_usd: 0.1 }),
    job('b-102', { ticket_id: 'BH-102', stage: 'execute', phase: 'review', phase_status: 'running', created_at: iso(20) }),
    job('triage-tick', { ticket_id: null, kind: 'triage', stage: 'triage', created_at: iso(2) }),
    job('b-103', { ticket_id: 'BH-103', stage: 'plan', status: 'parked', retry_reason: 'out of attempts', created_at: iso(40) }),
    job('b-104', { ticket_id: 'BH-104', status: 'orphaned', created_at: iso(60), spent_usd: 'n/a' }),
    job('lr-105', { ticket_id: 'BH-105', kind: 'lead_review', stage: 'review', status: 'orphaned', created_at: iso(70) }),
    job('b-106', { ticket_id: 'BH-106', activity_age_s: 900, beat_age_s: 900, created_at: iso(80) }),
    job('b-107', { ticket_id: 'BH-107', status: 'done', created_at: iso(90) })
  ];
  for (let i = 3; i < running; i++) jobs.push(job(`extra-${i}`, { ticket_id: `BH-2${i}`, created_at: iso(5 + i) }));
  return { jobs, as_of: new Date(NOW).toISOString() };
}
const LANES = {
  lanes: [
    { project: 'project-3', box: 'box-project-3-1', state: 'live', expected: 1, tick_age_s: 60 },
    { project: 'project-4', box: 'box-project-4-1', state: 'stale', expected: 1, tick_age_s: 9000, silence_s: 9000 }
  ]
};

const visible = (markup) => String(markup).replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
// The markup from an element's opening tag to the matching close of the same tag name.
function region(markup, openRe) {
  const s = String(markup);
  const m = openRe.exec(s);
  assert.ok(m, `no ${openRe} in the markup`);
  const tag = m[0].match(/^<([a-z0-9]+)/)[1];
  let depth = 0;
  const re = new RegExp(`<${tag}\\b[^>]*>|</${tag}>`, 'g');
  re.lastIndex = m.index;
  for (let t; (t = re.exec(s));) {
    depth += t[0].startsWith('</') ? -1 : 1;
    if (!depth) return s.slice(m.index, re.lastIndex);
  }
  return s.slice(m.index);
}
// Every key-shaped run of TEXT, with the href of the anchor it sits in (or null).
function keysWithHref(markup) {
  const out = [];
  const stack = [];
  for (const tok of String(markup).match(/<[^>]*>|[^<]+/g) || []) {
    if (tok.startsWith('</')) { stack.pop(); continue; }
    if (tok.startsWith('<')) {
      if (tok.endsWith('/>') || /^<(br|img|input|hr|meta|link)\b/i.test(tok)) continue;
      stack.push(/^<a\b/.test(tok) ? (tok.match(/\shref="([^"]*)"/) || [])[1] || '' : null);
      continue;
    }
    for (const k of tok.match(/BH[- ]\d+[^\s<]*/g) || []) out.push({ key: k, href: [...stack].reverse().find((x) => x !== null) ?? null });
  }
  return out;
}

const lineView = (jobs = payload(), lanes = LANES) => render(h(JobsLine, { jobs, lanes }));

test('J1 the headline numbers come from the payload: claimed, parked, lost', () => {
  const rows = jobRows(payload());
  const hl = jobsHeadline(jobCounts(rows), laneCounts(laneRows(LANES)));
  assert.equal(hl.line1, '3 jobs on the line.');
  assert.equal(hl.line2, '1 parked. 2 lost.');
  assert.equal(hl.lede, '1 job stopped beating. 1 lane silent.');
  const five = jobsHeadline(jobCounts(jobRows(payload({ running: 5 }))), laneCounts([]));
  assert.equal(five.line1, '5 jobs on the line.');
  // Each count lands in its own slot: no two of these inputs are equal.
  const apart = jobsHeadline({ running: 6, parked: 4, orphaned: 3, stalled: 7, queued_for_retry: 2 }, { stale: 5, unexpected: 1 });
  assert.deepEqual(apart, {
    line1: '6 jobs on the line.', line2: '4 parked. 3 lost.',
    lede: '7 jobs stopped beating. 2 jobs queued for retry. 5 lanes silent. 1 lane undeclared.'
  });
  const one = jobsHeadline({ running: 1, parked: 0, orphaned: 0, stalled: 0, queued_for_retry: 0 }, {});
  assert.equal(one.line1, '1 job on the line.');
  assert.equal(one.lede, 'No claimed job has stopped beating.');
  for (const s of [hl.line1, hl.line2, hl.lede]) assert.doesNotMatch(s, /—/, 'no em dashes');
});

test('J2 the rendered hero shows those numbers, and the stat grid agrees', () => {
  const out = lineView();
  const hero = region(out, /<section class="line-hero"/);
  assert.match(visible(region(hero, /<h1 class="line-headline"/)), /^3 jobs on the line\. 1 parked\. 2 lost\.$/);
  assert.match(hero, /<p class="lede">1 job stopped beating\. 1 lane silent\.<\/p>/);
  const cells = Object.fromEntries([...hero.matchAll(/<span class="statgrid__label">([^<]*)<\/span>\s*<span class="statgrid__value[^"]*">([\s\S]*?)<\/span>\s*(?:<span class="statgrid__sub|<\/(?:div|a)>)/g)]
    .map((m) => [m[1], visible(m[2])]));
  assert.equal(cells['Claimed now'], '3');
  assert.equal(cells.Parked, '1');
  assert.equal(cells.Orphaned, '2');
  assert.equal(cells['Stopped beating'], '1');
  assert.match(hero, /Coordination DB · as of 21:40Z/);
  assertUsdLabelled(out);
});

test('J3 every ticket key on the board and in the log is a link to /t/<KEY>', () => {
  const out = lineView();
  const board = region(out, /<div class="board"/);
  const list = region(board, /<ol class="board__list"/);
  const log = region(board, /<aside class="log"/);
  const onBoard = keysWithHref(list);
  const inLog = keysWithHref(log);
  assert.ok(onBoard.length >= 6, `the board names its tickets (${onBoard.length})`);
  assert.ok(inLog.length >= 6, `the log names its tickets (${inLog.length})`);
  for (const { key, href } of [...onBoard, ...inLog]) assert.equal(href, `/t/${key}`, `${key} is wrapped in its link`);
  // A key a URL cannot carry raw is encoded in the href.
  assert.equal(ticketPath('BH 1#2'), '/t/BH%201%232');
  const odd = render(h(JobsLine, { jobs: { jobs: [job('x', { ticket_id: 'BH 1#2' })] }, lanes: LANES }));
  assert.match(region(odd, /<ol class="board__list"/), /<a href="\/t\/BH%201%232"[^>]*>BH 1#2<\/a>/);
});

test('J4 a keyless triage row counts as claimed but makes no line row; an all-done ticket is off the line', () => {
  const rows = jobRows(payload());
  assert.equal(jobCounts(rows).running, 3, 'the keyless triage tick is one of the three claimed');
  const line = lineTickets(rows);
  assert.deepEqual(line.map((t) => t.key).sort(), ['BH-101', 'BH-102', 'BH-103', 'BH-104', 'BH-105', 'BH-106']);
  const out = lineView();
  assert.equal((out.match(/<li class="ticketrow"/g) || []).length, 6);
  assert.doesNotMatch(region(out, /<ol class="board__list"/), /BH-107/);
  // Per-ticket state, station, times and cost.
  const by = Object.fromEntries(line.map((t) => [t.key, t]));
  assert.deepEqual([by['BH-101'].at, by['BH-101'].state], [2, 'now']);
  assert.deepEqual([by['BH-102'].at, by['BH-102'].state], [3, 'now']);
  assert.deepEqual([by['BH-103'].at, by['BH-103'].state], [1, 'held']);
  assert.deepEqual([by['BH-104'].state, by['BH-106'].state], ['fail', 'fail']);
  assert.equal(by['BH-101'].times[0], '20:50Z', 'the triage row stamps station 1');
  assert.equal(by['BH-101'].times[2], '21:10Z');
  assert.equal(by['BH-101'].cost, 1.35);
  assert.equal(by['BH-104'].cost, 0, 'a non-numeric spend counts as 0');
  // Ordered by station, furthest first.
  assert.deepEqual(line.map((t) => t.at), [...line.map((t) => t.at)].sort((a, b) => (b ?? -1) - (a ?? -1)));
  // Nothing on the line is said in words, with the count of rows read.
  const none = render(h(JobsLine, { jobs: { jobs: [job('d', { ticket_id: 'BH-1', status: 'done' })] }, lanes: LANES }));
  assert.match(visible(none), /Nothing is on the line right now\. 1 row read\./);
  // Same project and key make one ticket; the same key in two projects makes two.
  const two = lineTickets(jobRows({ jobs: [job('a', { ticket_id: 'X-1' }), job('b', { ticket_id: 'X-1', project: 'project-4' })] }));
  assert.equal(two.length, 2);
  // The log is newest first and capped.
  const log = lineLog(rows, 3);
  assert.equal(log.length, 3);
  assert.deepEqual([log[0].key, log[0].text, log[0].ts], ['BH-101', 'tests green', '21:40Z'], 'the newest beat leads');
  assert.equal(lineLog(rows).length, 9, 'every row read, under the default cap');
  assert.equal(lineLog(rows).find((l) => l.key === 'BH-104').tone, 'bad');
  // No dead log lines: each one opens its job, the keyless triage tick included.
  const logMarkup = region(lineView(), /<aside class="log"/);
  for (const r of rows) assert.match(logMarkup, new RegExp(`<a href="/jobs/${r.id}"[^>]*class="log__ts"`), r.id);
});

test('J5 the jobs table TICKET cell links to /t/<KEY>, and is still a dash for none', () => {
  const out = render(h(JobsTable, { rows: jobRows(payload()) }));
  assert.match(out, /<a href="\/t\/BH-101"[^>]*>BH-101<\/a>/);
  const keyless = (out.match(/<tr\b[\s\S]*?<\/tr>/g) || []).find((r) => r.includes('>triage-tick<'));
  assert.ok(keyless, 'the keyless row renders');
  assert.doesNotMatch(keyless, /href="\/t\//);
  assert.match(keyless, /<span class="na">-<\/span>/);
  assertNoRawHeaders(out);
});

test('J6 api.jobs passes ticket_id through to the coord read', async () => {
  const calls = [];
  globalThis.fetch = async (url) => { calls.push(String(url)); return { ok: true, status: 200, text: async () => '{"jobs":[]}' }; };
  await api.jobs({ ticket_id: 'BH-1' });
  assert.deepEqual(calls, ['/api/coord/jobs?ticket_id=BH-1&limit=100']);
});

test('J7 /t/<KEY> is routed, its param reaches the screen, and the JOBS tab stays lit there', () => {
  const hit = ROUTES.find(([pat]) => matchRoute(pat, '/t/BH-4990'));
  assert.ok(hit, '/t/BH-4990 is routed');
  assert.equal(hit[1], TicketScreen);
  const params = matchRoute(hit[0], '/t/BH-4990');
  assert.deepEqual(params, { ticket: 'BH-4990' });
  // Rendered the way App renders a route: params spread, then key=path.
  assert.match(render(h(hit[1], { ...params, key: '/t/BH-4990' })), /BH-4990/);
  assert.deepEqual(matchRoute(hit[0], '/t/BH%201%232'), { ticket: 'BH 1#2' });
  assert.ok(NAV.find((n) => n.label === 'JOBS').match('/t/BH-4990'));
});

test('J8 the ticket page lists its jobs, each opening /jobs/:id, with a track; an unknown key says so', () => {
  const rows = jobRows(payload()).filter((r) => r.key === 'BH-101');
  const out = render(h(TicketView, { ticket: 'BH-101', rows, asOf: new Date(NOW).toISOString() }));
  assert.match(out, /<h1 class="line-headline">BH-101/);
  assert.match(out, /aria-label="BH-101 at Build \(now\)"/);
  assert.match(out, /<a href="\/jobs\/b-101"/);
  assert.match(out, /<a href="\/jobs\/t-101"/);
  assertNoRawHeaders(out);
  assertUsdLabelled(out);
  const empty = render(h(TicketView, { ticket: 'BH-999', rows: [], asOf: null }));
  assert.match(visible(empty), /No job has claimed BH-999\./);
  assert.match(empty, /<a href="\/jobs"/);
});

// ------------------------------------------------------- the mounted screens

class FakeNode {
  constructor(nodeType, name, data) {
    this.nodeType = nodeType; this.localName = name; this.nodeName = name ? name.toUpperCase() : '#text';
    this.data = data; this.childNodes = []; this.parentNode = null; this.attrs = {}; this.style = {}; this.listeners = {};
  }
  get firstChild() { return this.childNodes[0] || null; }
  get nextSibling() { if (!this.parentNode) return null; const s = this.parentNode.childNodes; return s[s.indexOf(this) + 1] || null; }
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
function installDom() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  doc.hidden = false;
  doc.documentElement = new FakeNode(1, 'html');
  globalThis.document = doc;
  return doc;
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const mounted = new Set();
test.afterEach(() => { for (const r of mounted) mount(null, r); mounted.clear(); });

function stubFetch(answer) {
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(String(url));
    return { ok: true, status: 200, text: async () => JSON.stringify(answer(String(url))) };
  };
  return calls;
}
async function mountPath(p) {
  const doc = installDom();
  const hit = ROUTES.map(([pat, C]) => [matchRoute(pat, p), C]).find(([params]) => params);
  assert.ok(hit, `a route matches ${p}`);
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(hit[1], { ...hit[0], key: p }), el);
  await flush();
  return { el, C: hit[1], text: () => el.textContent.replace(/\s+/g, ' ') };
}
const anchors = (el) => all(el).filter((n) => n.localName === 'a').map((n) => [n.getAttribute('href'), n.textContent.trim()]);

test('J9 /jobs mounted: the real reads feed the headline, the board links and the lanes table', async () => {
  window.location.pathname = '/jobs';
  const calls = stubFetch((url) => (url.startsWith('/api/coord/jobs') ? payload()
    : url.startsWith('/api/coord/lanes') ? LANES : url.includes('burn') ? { burn: [], days: 14 }
      : url.includes('flags') ? { flags: [] } : { projects: [] }));
  const s = await mountPath('/jobs');
  assert.equal(s.C, JobsScreen);
  assert.ok(calls.some((u) => u.startsWith('/api/coord/jobs?')), 'it read the jobs');
  assert.match(s.text(), /3 jobs on the line\.\s*1 parked\. 2 lost\./);
  assert.match(s.text(), /01\s*The line/);
  assert.match(s.text(), /02\s*Lanes/);
  const a = anchors(s.el);
  for (const k of ['BH-101', 'BH-102', 'BH-103', 'BH-104', 'BH-105', 'BH-106']) {
    assert.ok(a.some(([href, t]) => href === `/t/${k}` && t === k), `${k} links to its ticket`);
  }
  assert.ok(a.some(([href]) => href === '/jobs/b-101'), 'the jobs table still opens a job');
});

test('J10 /t/<KEY> mounted: it asks for that ticket\'s jobs and lists them', async () => {
  window.location.pathname = '/t/BH-101';
  const calls = stubFetch(() => ({ jobs: payload().jobs.filter((j) => j.ticket_id === 'BH-101'), as_of: new Date(NOW).toISOString() }));
  const s = await mountPath('/t/BH-101');
  assert.equal(s.C, TicketScreen);
  // TEST-CHANGE (BH-4991): wave 2 replaced the stub with the full ticket page,
  // which also reads the newest build job's detail, the project row and the
  // ticket's hold row. The jobs read stays first.
  // TEST-CHANGE (BH-5839): the "Step in" echo also reads the ticket's steer notes.
  assert.deepEqual(calls, [
    '/api/coord/jobs?ticket_id=BH-101&limit=100',
    '/api/coord/jobs/b-101',
    '/api/dash/projects',
    '/api/coord/ledger?kind=ticket_hold&key=project-3%23101',
    '/api/coord/steer?project=project-3&ticket=BH-101'
  ]);
  const a = anchors(s.el);
  assert.ok(a.some(([href]) => href === '/jobs/b-101'));
  assert.ok(a.some(([href]) => href === '/jobs/t-101'));
  assert.match(s.text(), /BH-101/);
});
