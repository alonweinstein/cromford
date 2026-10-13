import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';

// BH-2557 (BH-2540.4): /llm-sites/:site, one LLM site's catalog record plus
// its cost rows. SSR runs no effects, so the body (LlmSiteView) is rendered
// with each load state as props; the 400 is produced by the real
// api.llmSiteRows against a stubbed fetch, and the routed screen is rendered
// through the real ROUTES table.

// The router reads window.location at first render; give SSR one.
globalThis.window = globalThis.window || {
  location: { pathname: '/llm-sites/alert-triage', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { LlmSiteView } = await import('../src/screens/LlmSite.js');
const { ROUTES } = await import('../src/app.js');
const { api } = await import('../src/api.js');

// The alert-triage record as catalog/llm-sites.json carries it (the fields the
// rows route passes through).
const SITE = {
  id: 'alert-triage', script: 'bin/alert-triage.sh', marker: 'agent-call.sh" triage alert-triage',
  kind: 'agent-call', lane: 'alert-triage', stage: 'triage', runners: ['ladder'],
  note: 'The lane that burned $793 in 12h (#1039).'
};
const row = (o) => ({
  ts: '2026-09-26T10:00:00Z', box: 'hub', project: 'alert-triage', ticket: null, pr: null,
  stage: 'triage', lane_id: 'alert-triage', runner: 'claude', model: 'sonnet',
  billing_mode: 'api', rc: 0, cost_usd: 0.1, row_source: 'agent-call', note: null, ...o
});
const ROWS = [
  row({ ts: '2026-09-26T10:00:00Z', cost_usd: null, note: 'unpriced-row' }),
  row({ ts: '2026-09-26T11:00:00Z', cost_usd: 0.42 }),
  row({ ts: '2026-09-26T12:00:00Z', project: 'project-3', pr: 412, ticket: 'TK-9' }),
  row({ ts: '2026-09-26T13:00:00Z', project: null, pr: 77, ticket: 'BH-77' }),
  row({ ts: '2026-09-26T14:00:00Z', project: 'project-3', pr: null, ticket: null })
];
const data = (o = {}) => ({ site: SITE, rows: ROWS, truncated: false, incomplete: [], ...o });
const view = (state) => render(h(LlmSiteView, { site: 'alert-triage', state, onRetry: () => {} }));
const ok = (o) => view({ data: data(o), error: null, loading: false });

const EMPTY_COPIES = [/no such site/, /this site writes no cost row/, /no cost rows for this site/];
const tbody = (out) => out.split('<tbody>')[1]?.split('</tbody>')[0] ?? '';

test('C7a: header facts, lane link and the back link', () => {
  const out = ok();
  for (const s of ['alert-triage', 'bin/alert-triage.sh', 'agent-call.sh&quot; triage alert-triage',
    'agent-call', 'triage', 'ladder', 'The lane that burned $793 in 12h (#1039).']) {
    assert.ok(out.includes(s), `missing ${s}`);
  }
  assert.match(out, /href="\/settings\/alert-triage"/);
  assert.match(out, /href="\/llm-sites"/);
});

test('C7b: a site with no lane links to no settings page', () => {
  const out = ok({ site: { ...SITE, lane: null } });
  assert.match(out, /bin\/alert-triage\.sh/);
  assert.match(out, /<dt>lane<\/dt><dd><span class="na">—<\/span><\/dd>/);
  assert.doesNotMatch(out, /href="\/settings\//);
});

test('C7c: one <tr> per row, 12 sortable headers, wide scrolling wrapper', () => {
  const out = ok();
  assert.equal((tbody(out).match(/<tr[\s>]/g) || []).length, ROWS.length);
  const ths = out.match(/<th[\s>][^>]*>/g) || [];
  assert.equal(ths.length, 12);
  for (const th of ths) assert.match(th, /aria-sort="(none|ascending|descending)"/);
  assert.match(out, /tablewrap tablewrap--wide/);
  assert.match(out, /aria-sort="descending"[^>]*>\s*<button[^>]*>\s*ts/);
});

test('C7d: a null cost reads —, never $0.00; a priced row reads its dollars', () => {
  const nullOnly = view({ data: data({ rows: [ROWS[0]] }), error: null, loading: false });
  assert.doesNotMatch(nullOnly, /\$0\.00/);
  const cells = tbody(nullOnly).match(/<td[^>]*>[\s\S]*?<\/td>/g) || [];
  assert.equal(cells.length, 12);
  assert.match(cells[8], />—</);
  assert.match(ok(), /\$0\.42/);
  assert.match(view({ data: data({ rows: [row({ cost_usd: 0 })] }), error: null, loading: false }), /\$0\.00/);
});

test('C7e: the PR links only when project and pr are both present', () => {
  const out = ok();
  assert.deepEqual(out.match(/href="\/pr\/[^"]*"/g), ['href="/pr/project-3/412"']);
  assert.ok(tbody(out).includes('BH-77'));
});

test('C7f: truncated says so, untruncated does not', () => {
  assert.match(ok({ truncated: true }), /showing the newest 200/);
  assert.doesNotMatch(ok({ truncated: false }), /showing the newest 200/);
});

test('C7g: reason no-stage reads "this site writes no cost row" with no table', () => {
  const out = ok({ rows: [], reason: 'no-stage' });
  assert.match(out, /this site writes no cost row/);
  assert.doesNotMatch(out, /<table/);
  assert.doesNotMatch(out, /no cost rows for this site/);
});

test('C7g2: zero rows without a reason has its own copy, not the no-stage one', () => {
  const out = ok({ rows: [] });
  assert.match(out, /no cost rows for this site in the window/);
  assert.doesNotMatch(out, /this site writes no cost row/);
});

test('C7h: the real api 400 reads "no such site" with a way back, no RETRY', async () => {
  const real = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: false, status: 400, text: async () => '{"error":"unknown site"}' });
  let error = null;
  try { await api.llmSiteRows('nope'); } catch (e) { error = e; } finally { globalThis.fetch = real; }
  assert.ok(error, 'llmSiteRows must reject on 400');
  const out = render(h(LlmSiteView, { site: 'nope', state: { data: null, error, loading: false }, onRetry: () => {} }));
  assert.match(out, /no such site/);
  assert.match(out, /href="\/llm-sites"/);
  assert.doesNotMatch(out, /could not load/);
  assert.doesNotMatch(out, /RETRY/);
});

test('C7i: any other failure is the ErrorBox with RETRY, never an empty state', () => {
  const error = Object.assign(new Error('http_500'), { status: 500 });
  const out = view({ data: null, error, loading: false });
  assert.match(out, /could not load/);
  assert.match(out, /RETRY/);
  for (const re of EMPTY_COPIES) assert.doesNotMatch(out, re);
});

test('C7i2: a refresh failure keeps the rows on screen under the ErrorBox', () => {
  const error = Object.assign(new Error('http_502'), { status: 502 });
  const out = view({ data: data(), error, loading: false });
  assert.match(out, /could not load/);
  assert.equal((tbody(out).match(/<tr[\s>]/g) || []).length, ROWS.length);
});

test('C7j: incomplete raises the warn banner, an empty list does not', () => {
  const out = ok({ incomplete: ['cost-rows'] });
  assert.match(out, /banner banner--warn/);
  assert.match(out, /cost-rows/);
  assert.doesNotMatch(ok({ incomplete: [] }), /banner--warn/);
});

test('C7k: the routed screen names its site and shows loading, not empty or error', () => {
  const Screen = ROUTES.find(([p]) => p === '/llm-sites/:site')?.[1];
  assert.ok(Screen);
  const out = render(h(Screen, { site: 'rb-plan' }));
  assert.match(out, /rb-plan/);
  assert.match(out, /class="cursor/);
  assert.doesNotMatch(out, /could not load/);
  for (const re of EMPTY_COPIES) assert.doesNotMatch(out, re);
  assert.doesNotMatch(out, /No rows loaded/);
});

test('C7l: a body without a rows array is an error, never an empty table', () => {
  const out = view({ data: { site: SITE, truncated: false }, error: null, loading: false });
  assert.match(out, /could not load/);
  for (const re of EMPTY_COPIES) assert.doesNotMatch(out, re);
});

test('C7m: a body without the catalog record still shows its rows and says the record is missing', () => {
  // What the BH-2553 stub answers today: no `site`, empty rows, incomplete.
  const out = view({ data: { rows: [], truncated: false, incomplete: ['not-implemented'] }, error: null, loading: false });
  assert.match(out, /catalog record not returned/);
  assert.match(out, /banner--warn/);
  assert.match(out, /no cost rows for this site in the window/);
  assert.doesNotMatch(out, /href="\/settings\//);
});
