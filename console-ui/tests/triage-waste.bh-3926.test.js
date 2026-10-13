import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import { TriageWasteSection, TriageWasteView, drillParams, rowKeyOf } from '../src/screens/TriageWaste.js';

// BH-3926 (BH-3921.3): the TRIAGE PAID UNCHANGED section on /costs. The payload
// shape is GET /api/metrics/triage-paid-unchanged's
// (worker/jobs/src/routes/triage-waste.js; its own test drives the server side).

const data = {
  days: 14, from: '2099-09-12T00:00:00Z', truncated: false, as_of: '2099-09-25T12:00:00.000Z',
  rows: [
    { day: '2099-09-24', project: null, paid_unchanged: 1, waste_calls: 1, triage_calls: 1, usd: null },
    { day: '2099-09-25', project: 'p2', paid_unchanged: 2, waste_calls: 1, triage_calls: 3, usd: 2 },
    { day: '2099-09-25', project: 'p1', paid_unchanged: 4, waste_calls: 2, triage_calls: 3, usd: 3.75 }
  ]
};
const noop = () => {};
const base = { data, error: null, loading: false, reload: noop, open: null, onOpen: noop, kid: null, onRetryChild: noop };
const view = (over = {}) => render(h(TriageWasteView, { ...base, ...over }));
const bodyRows = (out) => out.split('<tbody')[1].split('</tbody>')[0].split('<tr').slice(1);

test('C0: api.triagePaidUnchanged reads the coord metrics route with days', async () => {
  const seen = [];
  const prev = globalThis.fetch;
  globalThis.fetch = async (url) => { seen.push(String(url)); return new Response('{}', { status: 200 }); };
  try {
    await api.triagePaidUnchanged();
    await api.triagePaidUnchanged(7);
  } finally { globalThis.fetch = prev; }
  // determinism: ok these lines compare request URL strings; nothing in C0 or in TriageWaste.js reads the clock
  assert.deepEqual(seen, ['/api/coord/metrics/triage-paid-unchanged?days=14', // determinism: ok a URL string, no window is computed here
    '/api/coord/metrics/triage-paid-unchanged?days=7']); // determinism: ok a URL string, no window is computed here
});

test('C1: six sortable headers; newest day first, then the higher paid_unchanged; no native dialogs', () => {
  const out = view();
  assert.ok(out.includes('TRIAGE PAID UNCHANGED'));
  assert.ok(out.includes('cost_rows · stage triage · rc 0 · since 2099-09-12 · 14 days'));
  const ths = out.match(/<th[^>]*aria-sort="[a-z]+"[^>]*>[\s\S]*?<\/th>/g) || [];
  const labels = ths.map((t) => t.replace(/<[^>]+>/g, '').replace(/[↑↓]/g, '').trim());
  assert.deepEqual(labels, ['DAY', 'PROJECT', 'PAID UNCHANGED', 'WASTE CALLS', 'TRIAGE CALLS', '$']);
  assert.match(ths[0], /aria-sort="descending"/, 'DAY desc is the default sort');
  assert.ok(out.includes('tablewrap--wide'), 'the table scrolls in its own box');
  const rows = bodyRows(out);
  assert.equal(rows.length, 3);
  assert.ok(rows[0].includes('href="/p/p1"'), 'day 25, pu 4 first: ' + rows[0]);
  assert.ok(rows[1].includes('href="/p/p2"'), 'day 25, pu 2 second');
  assert.ok(rows[2].includes('2099-09-24'), 'the older day last');
  const src = readFileSync(new URL('../src/screens/TriageWaste.js', import.meta.url), 'utf8')
    .split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
  assert.doesNotMatch(src, /\b(confirm|alert|prompt)\s*\(/);
  assert.equal(rowKeyOf(data.rows[0]), '2099-09-24|');
});

test('C2: project links, the drill-down button, and the leaf rows it opens', () => {
  const out = view();
  assert.ok(out.includes('href="/p/p1"'));
  const nullRow = bodyRows(out)[2];
  assert.ok(!nullRow.includes('href="/p/'), 'a null project has no link');
  assert.ok(nullRow.includes('—'));
  assert.equal((out.match(/<button[^>]*class="btn btn--sm"[^>]*aria-expanded="false"/g) || []).length, 3);
  const p1 = data.rows[2];
  const kid = { data: { rows: [
    { ts: '2099-09-25T10:00:00Z', project: 'p1', stage: 'triage', runner: 'codex', model: 'm',
      billing_mode: 'metered', ticket: null, run_id: 'run-1', job_id: null, cost_usd: 2 }
  ], truncated: false } };
  const open = view({ open: rowKeyOf(p1), kid });
  assert.equal((open.match(/aria-expanded="true"/g) || []).length, 1);
  assert.ok(open.includes('href="/builds/run-1"'), 'the leaf rows render and link to their run');
  assert.ok(open.includes('WHEN'));
  assert.match(view({ open: rowKeyOf(p1), kid: { loading: true } }), /class="skel"/);
  const err = view({ open: rowKeyOf(p1), kid: { error: new Error('kid_down') } });
  assert.ok(err.includes('kid_down') && err.includes('RETRY'));
  assert.deepEqual(drillParams(p1), { since: '2099-09-25T00:00:00Z', until: '2099-09-25T23:59:59.999Z',
    group: 'rows', limit: 500, stage: 'triage', project: 'p1' });
  assert.equal(drillParams(data.rows[0]).project, '', 'a null project drills with project= (IS NULL)');
});

test('C2b: the drill-down request goes out as group=rows, stage=triage, the project and the day', async () => {
  const seen = [];
  const prev = globalThis.fetch;
  globalThis.fetch = async (url) => { seen.push(String(url)); return new Response('{"rows":[]}', { status: 200 }); };
  try { await api.costBreakdown(drillParams(data.rows[0])); } finally { globalThis.fetch = prev; }
  const q = new URLSearchParams(seen[0].split('?')[1]);
  assert.equal(q.get('group'), 'rows');
  assert.equal(q.get('stage'), 'triage');
  assert.equal(q.get('project'), '');
  assert.equal(q.get('since'), '2099-09-24T00:00:00Z');
  assert.equal(q.get('until'), '2099-09-24T23:59:59.999Z');
  assert.equal(q.get('limit'), '500');
});

test('C3: empty only on a 200 with zero rows; an error is an ErrorBox with RETRY; truncated says so', () => {
  const empty = view({ data: { ...data, rows: [] } });
  assert.ok(empty.includes('no triage calls in this window'));
  const err = view({ data: null, error: new Error('http_500') });
  assert.ok(err.includes('RETRY') && err.includes('http_500'));
  assert.ok(!err.includes('no triage calls in this window'));
  const loading = view({ data: null, loading: true });
  assert.ok(!loading.includes('no triage calls in this window'));
  assert.match(loading, /class="skel"/);
  assert.ok(view({ data: { ...data, truncated: true } }).includes('capped'));
});

test('C4: the production section renders, and Costs.js mounts it right after CostBreakdownSection', () => {
  assert.ok(render(h(TriageWasteSection)).includes('TRIAGE PAID UNCHANGED'));
  const costs = readFileSync(new URL('../src/screens/Costs.js', import.meta.url), 'utf8');
  assert.ok(costs.includes("import { TriageWasteSection } from './TriageWaste.js';"));
  const cb = costs.indexOf('<${CostBreakdownSection}/>');
  const tw = costs.indexOf('<${TriageWasteSection}/>');
  assert.ok(cb !== -1 && tw !== -1, 'both sections are mounted');
  assert.equal(costs.slice(cb, tw).split('\n').length, 2, 'on the line right after CostBreakdownSection');
});
