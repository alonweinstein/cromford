import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { assertNoRawHeaders, assertUsdLabelled } from './legibility.bh-3558.js';
import { runnerColumns, siteViewRows } from '../src/lib/llm-sites.js';
import { sortRows } from '../src/lib/sort.js';
import * as Sites from '../src/screens/LlmSites.js';

// BH-3570 (#3558 slice 3): /llm-sites and /llm-sites/:site read without a
// glossary. Plain headers with the raw name under them, CASH and API-EQUIVALENT
// as two sortable columns, a Legend that defines notional, and every dollar
// figure tagged with its basis. Fixtures follow the payload shape of
// worker/jobs/src/routes/llm-sites.js (same shape as llm-sites.bh-2556.test.js).

// The router reads window.location at first render; give SSR one.
globalThis.window = globalThis.window || {
  location: { pathname: '/llm-sites', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};
const { LlmSiteView } = await import('../src/screens/LlmSite.js');

const NOW = Date.UTC(2026, 8, 29, 14, 5);
const ago = (ms) => new Date(NOW - ms).toISOString();
const H = 3600e3;
const D = 24 * H;

const site = (over = {}) => ({
  id: 'rb-plan', lane: 'run-build', stage: 'plan', stages: ['plan'], kind: 'agent',
  runners: ['claude'], script: 'bin/run-build.sh', note: null,
  attribution: 'stage', shared: false,
  usd_24h: { by_runner: { claude: 1.5 }, total: 1.5 },
  usd_7d: { by_runner: { claude: 10 }, total: 10 },
  cash_7d: 1, notional_7d: 2, unknown_billing_7d: 0, unpriced_7d: 0, calls_7d: 40,
  refused_7d: { gate: 1, guard: 0, context_kill: 2 },
  today_usd: 0.5, guard_k: 3, guard_enforced: true, kill_tokens: 200000, cap_usd_day: 25,
  knobs_bound: ['lane.run-build.cap_usd_day', 'lane.run-build.guard_k'],
  badges: { no_row: false, no_knob: false, no_kill: false },
  ...over
});

const fixture = (sites) => ({
  sites: sites || [
    site(),
    site({
      id: 'ask/review x', lane: null, stage: 'review', kind: 'oneshot', attribution: 'signature', shared: true,
      usd_24h: null,
      usd_7d: { by_runner: { openrouter: 0.001, zeta: 2, codex: 3 }, total: 5.001 },
      cash_7d: 0.001, notional_7d: null, unknown_billing_7d: 3,
      refused_7d: { gate: null, guard: 4, context_kill: null },
      knobs_bound: [],
      badges: { no_row: true, no_knob: true, no_kill: false }
    })
  ],
  windows: { since_7d: ago(7 * D), since_24h: ago(D), today: ago(0).slice(0, 10) },
  as_of: ago(5 * 60e3),
  incomplete: []
});

const view = (data) => render(h(Sites.LlmSitesView, { state: { data, error: null, loading: false } }));
const ths = (out) => out.match(/<th\b[^>]*>[\s\S]*?<\/th>/g) || [];
const buttonText = (th) => ((th.match(/<button[^>]*>([\s\S]*?)<\/button>/) || [])[1] || '')
  .replace(/<span class="arrow"[\s\S]*?<\/span>/g, '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
const legendDts = (out) => {
  const dl = (out.match(/<dl class="legend">[\s\S]*?<\/dl>/) || [''])[0];
  return (dl.match(/<dt>([\s\S]*?)<\/dt>/g) || []).map((d) => d.replace(/<[^>]+>/g, ''));
};

test('L1: plain headers, CASH and API-EQUIVALENT split, notional in the Legend, $ labelled', () => {
  const out = view(fixture());
  const heads = ths(out);
  const labels = heads.map(buttonText);
  assert.ok(labels.includes('CASH 7D'), `headers: ${labels.join(' | ')}`);
  assert.ok(labels.includes('API-EQUIVALENT 7D'), `headers: ${labels.join(' | ')}`);
  for (const l of labels) assert.doesNotMatch(l, /CASH \/ NOTIONAL/);

  // The old names survive only as the small raw line under the header.
  const thead = out.slice(out.indexOf('<thead>'), out.indexOf('</thead>'));
  const bare = thead.replace(/<span class="th-raw">[\s\S]*?<\/span>/g, '');
  for (const old of ['NOTIONAL', 'REFUSED G/G/K', 'K3 K', 'CAP/DAY', 'TODAY $', 'BADGES']) {
    assert.ok(thead.includes(`<span class="th-raw">${old}</span>`), `${old} in .th-raw`);
    assert.ok(!bare.includes(old), `${old} outside .th-raw`);
  }
  const kill = heads.find((t) => buttonText(t).startsWith('CONTEXT KILL'));
  assert.ok(kill, 'CONTEXT KILL header');
  assert.match(kill, /<span class="th-unit">tokens<\/span>/);
  const refused = heads.find((t) => buttonText(t).startsWith('REFUSED'));
  assert.match(refused, /<span class="th-unit">gate\/guard\/kill<\/span>/);
  const knobs = heads.find((t) => buttonText(t).startsWith('KNOBS BOUND'));
  assert.match(knobs, /<span class="th-unit">count<\/span>/);
  // Per-runner headers keep their text and say what the figure is.
  const codex = heads.find((t) => buttonText(t).startsWith('24H CODEX'));
  assert.match(codex, /<span class="th-unit">API-eq<\/span>/);

  // The split cells carry their basis.
  assert.match(out, /data-usd-basis="cash"[^>]*>\$1\.00</);
  assert.match(out, /data-usd-basis="api"[^>]*>\$2\.00</);
  assert.match(out, /data-usd-basis="cash"[^>]*>(&lt;|<)\$0\.01</);
  assert.match(out, /data-usd-basis="api"[^>]*>\$3\.00<\/span> unknown billing/);

  const dts = legendDts(out);
  for (const t of ['NOTIONAL / API-EQUIVALENT', 'CASH', 'REFUSED', 'CALL GUARD MAX', 'CONTEXT KILL', 'DAILY CAP', 'WARNINGS']) {
    assert.ok(dts.includes(t), `Legend term ${t} (have: ${dts.join(' | ')})`);
  }
  assert.match(out, /<dt>NOTIONAL \/ API-EQUIVALENT<\/dt><dd>[^<]*not cash/);

  assertNoRawHeaders(out);
  assertUsdLabelled(out);
});

test('L2: CASH 7D and API-EQUIVALENT 7D sort on different values', () => {
  assert.equal(typeof Sites.columns, 'function', 'LlmSites.js exports columns(runners)');
  const fx = fixture([
    site({ id: 'a', notional_7d: 5, cash_7d: 1 }),
    site({ id: 'b', notional_7d: 1, cash_7d: 9 }),
    site({ id: 'c', notional_7d: 3, cash_7d: 4 }),
  ]);
  const cols = Sites.columns(runnerColumns(fx));
  const notional = cols.find((c) => c.key === 'notional');
  const cash = cols.find((c) => c.key === 'cash');
  assert.ok(notional && cash, 'both columns present');
  assert.notEqual(notional.sort, null);
  const rows = siteViewRows(fx);
  assert.deepEqual(sortRows(rows, notional.sort, 'desc').map((r) => r.id), ['a', 'c', 'b']);
  assert.deepEqual(sortRows(rows, cash.sort, 'desc').map((r) => r.id), ['b', 'c', 'a']);
  // Nulls sink rather than read as zero.
  const withNull = siteViewRows(fixture([site({ id: 'n', notional_7d: null }), site({ id: 'z', notional_7d: 0 })]));
  assert.deepEqual(sortRows(withNull, notional.sort, 'desc').map((r) => r.id), ['z', 'n']);
});

test('L3: /llm-sites/:site tags its $ column, a null cost stays —', () => {
  const SITE = {
    id: 'alert-triage', script: 'bin/alert-triage.sh', marker: 'agent-call.sh" triage alert-triage',
    kind: 'agent-call', lane: 'alert-triage', stage: 'triage', runners: ['ladder'],
    note: 'Three call sites: the sonnet first pass, the fable escalation, the act turn.'
  };
  const row = (o) => ({
    ts: ago(2 * H), box: 'hub', project: 'alert-triage', ticket: null, pr: null,
    stage: 'triage', lane_id: 'alert-triage', runner: 'claude', model: 'sonnet',
    billing_mode: 'api', rc: 0, cost_usd: 0.1, row_source: 'agent-call', note: null, ...o
  });
  const rows = [row({ ts: ago(3 * H), cost_usd: null, note: 'unpriced-row' }), row({ ts: ago(H), cost_usd: 0.42 })];
  const out = render(h(LlmSiteView, {
    site: 'alert-triage', onRetry: () => {},
    state: { data: { site: SITE, rows, truncated: false, incomplete: [] }, error: null, loading: false }
  }));
  assert.match(out, /data-usd-basis="api"[^>]*>\$0\.42/);
  const body = out.split('<tbody>')[1].split('</tbody>')[0];
  const nullRow = body.split('<tr').slice(1).find((r) => r.includes('unpriced-row'));
  const cells = nullRow.match(/<td[^>]*>[\s\S]*?<\/td>/g);
  assert.match(cells[8], />—</);
  assertNoRawHeaders(out);
  assertUsdLabelled(out);
});
