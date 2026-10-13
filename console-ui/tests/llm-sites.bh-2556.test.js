import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { NAV } from '../src/app.js';
import {
  runnerColumns, siteViewRows, money, cashText, refusedText, badges, BADGE_TITLES, drillHref, incompleteText
} from '../src/lib/llm-sites.js';
import { LlmSitesView } from '../src/screens/LlmSites.js';
import { CostsHeader } from '../src/screens/Costs.js';

// BH-2556 (BH-2540.3): the LLM sites list. Fixtures follow the payload JSDoc in
// worker/jobs/src/routes/llm-sites.js exactly: the worker route is still the
// BH-2553 stub, so the view model and the screen are proved against these.

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

const fixture = () => ({
  sites: [
    site(),
    site({
      id: 'ask/review x', lane: null, stage: 'review', kind: 'oneshot', attribution: 'signature', shared: true,
      usd_24h: null,
      usd_7d: { by_runner: { openrouter: 0.001, zeta: 2, codex: 3 }, total: 5.001 },
      refused_7d: { gate: null, guard: 4, context_kill: null },
      knobs_bound: [],
      badges: { no_row: true, no_knob: true, no_kill: false }
    })
  ],
  windows: { since_7d: '2026-09-20T00:00:00Z', since_24h: '2026-09-26T00:00:00Z', today: '2026-09-27' },
  as_of: '2026-09-27T01:00:00Z',
  incomplete: []
});

test('C1: runner columns are the union from data, in preference order then alphabetical', () => {
  assert.deepEqual(runnerColumns(fixture()), ['claude', 'codex', 'openrouter', 'zeta']);
  assert.deepEqual(runnerColumns({ sites: [site({ usd_24h: null, usd_7d: null })] }), []);
  assert.deepEqual(runnerColumns({ sites: [] }), []);
  assert.deepEqual(runnerColumns(null), []);
  const all = { sites: [site({ usd_7d: { by_runner: { beta: 1, fireworks: 1, grok: 1, alpha: 1, claude: 1 }, total: 5 } })] };
  assert.deepEqual(runnerColumns(all), ['claude', 'grok', 'fireworks', 'alpha', 'beta']);
});

test('C2: money is exact, absent reads —, and a null window leaves every runner cell null', () => {
  assert.equal(money(1.234), '$1.23');
  assert.equal(money(null), '—');
  assert.equal(money(undefined), '—');
  assert.equal(money(''), '—');
  assert.equal(money(0.001), '<$0.01');
  const rows = siteViewRows(fixture());
  const b = rows.find((r) => r.id === 'ask/review x');
  for (const r of runnerColumns(fixture())) assert.equal(b.usd24[r], null, `24h ${r}`);
  assert.equal(b.total24, null);
  assert.equal(b.usd7.codex, 3);
  assert.equal(b.usd7.claude, null);
  assert.equal(b.total7, 5.001);
  const a = rows.find((r) => r.id === 'rb-plan');
  assert.equal(a.usd24.claude, 1.5);
  assert.equal(a.usd24.codex, null);
});

test('C3: cash vs notional, with unknown only when it is above zero', () => {
  assert.equal(cashText({ cash_7d: 1, notional_7d: 2, unknown_billing_7d: 0 }), '$1.00 cash · $2.00 notional');
  assert.equal(cashText({ cash_7d: 1, notional_7d: 2, unknown_billing_7d: 3 }), '$1.00 cash · $2.00 notional · 3 unknown');
  assert.equal(cashText({ cash_7d: null, notional_7d: null, unknown_billing_7d: null }), '— cash · — notional');
});

test('C4: refused reads gate/guard/kill, a missing part reads —', () => {
  assert.equal(refusedText({ gate: 1, guard: 0, context_kill: 2 }), '1/0/2');
  assert.equal(refusedText({ gate: null, guard: 4, context_kill: undefined }), '—/4/—');
  assert.equal(refusedText(null), '—/—/—');
  const rows = siteViewRows(fixture());
  assert.equal(rows[0].refusedText, '1/0/2');
  assert.deepEqual(rows[0].refused, { gate: 1, guard: 0, kill: 2 });
});

test('C5: badges() returns exactly the flags the worker set, in order', () => {
  const names = ['no_row', 'no_knob', 'no_kill'];
  const labels = ['no row', 'no knob', 'no kill'];
  for (let m = 0; m < 8; m++) {
    const flags = Object.fromEntries(names.map((n, i) => [n, Boolean(m & (1 << i))]));
    assert.deepEqual(badges({ badges: flags }), labels.filter((_, i) => m & (1 << i)), `mask ${m}`);
  }
  assert.deepEqual(badges({}), []);
  assert.deepEqual(badges({ badges: {} }), []);
  assert.deepEqual(badges({ badges: null }), []);
  assert.deepEqual(badges({ badges: { no_row: 'false', no_knob: 1, no_kill: 'true' } }), []);
  for (const l of labels) assert.ok(BADGE_TITLES[l], `title for ${l}`);
});

test('C5b: drillHref encodes the site id', () => {
  assert.equal(drillHref('a/b c'), '/llm-sites/a%2Fb%20c');
  assert.equal(drillHref('rb-plan'), '/llm-sites/rb-plan');
});

test('C6: the rendered list — one row per site, aria-sort everywhere, links, badges, shared', () => {
  const out = render(h(LlmSitesView, { state: { data: fixture(), error: null, loading: false } }));
  const tbody = out.slice(out.indexOf('<tbody>'));
  assert.equal((tbody.match(/<tr/g) || []).length, 2);
  const ths = out.match(/<th[\s>][^>]*>/g) || [];
  assert.ok(ths.length >= 20, `columns: ${ths.length}`);
  for (const th of ths) assert.match(th, /aria-sort=/);
  assert.match(out, /href="\/llm-sites\/rb-plan"/);
  assert.match(out, /href="\/llm-sites\/ask%2Freview%20x"/);
  assert.match(out, /href="\/settings\/run-build"/);
  assert.match(out, /24H CODEX/);
  assert.match(out, /7D ZETA/);
  assert.doesNotMatch(out, /24H GROK/);
  assert.match(out, /1\/0\/2/);
  assert.match(out, /data-usd-basis="cash"[^>]*>\$1\.00</); assert.match(out, /data-usd-basis="api"[^>]*>\$2\.00</);
  assert.match(out, /&lt;\$0\.01|<\$0\.01/);
  // Badges only on the badged row, each red with its explanation.
  const rows = tbody.split('<tr').slice(1);
  const badged = rows.find((r) => r.includes('ask%2Freview'));
  const clean = rows.find((r) => r.includes('/llm-sites/rb-plan'));
  assert.match(badged, /class="tag tag--bad badge badge--red" title="[^"]+">no row</);
  assert.match(badged, /badge--red" title="[^"]+">no knob</);
  assert.doesNotMatch(badged, />no kill</);
  assert.doesNotMatch(clean, /badge--red/);
  assert.match(badged, /tag--warn[^>]*>shared</);
  assert.doesNotMatch(clean, />shared</);
  assert.doesNotMatch(out, /banner--warn/);
  assert.match(out, /LLM SITES/);
  assert.match(out, /href="\/costs"/);
});

test('C7: incomplete renders a warn banner with the reasons', () => {
  const out = render(h(LlmSitesView, { state: { data: { ...fixture(), incomplete: ['cost_rows capped'] } } }));
  assert.match(out, /banner banner--warn[^>]*>[^<]*(<[^>]+>)*[^<]*cost_rows capped/);
  assert.equal(incompleteText({ incomplete: [] }), null);
  assert.equal(incompleteText({}), null);
  assert.equal(incompleteText({ incomplete: ['a', 'b'] }), 'a, b');
});

test('C7b: a load failure is an ErrorBox with RETRY, never the empty copy', () => {
  const out = render(h(LlmSitesView, { state: { error: new Error('boom'), data: null, loading: false, reload: () => {} } }));
  assert.match(out, /could not load/);
  assert.match(out, /boom/);
  assert.match(out, /RETRY/);
  assert.doesNotMatch(out, /no LLM sites in the catalog/);
  // A failed refresh keeps the last data and marks it.
  const stale = render(h(LlmSitesView, { state: { error: new Error('boom'), data: fixture(), reload: () => {} } }));
  assert.match(stale, /RETRY/);
  assert.match(stale, /href="\/llm-sites\/rb-plan"/);
});

test('C7c: an empty catalog renders the empty copy and no ErrorBox', () => {
  const out = render(h(LlmSitesView, { state: { data: { sites: [], incomplete: [] } } }));
  assert.match(out, /no LLM sites in the catalog/);
  assert.doesNotMatch(out, /could not load/);
  assert.doesNotMatch(out, /<tbody>/);
  const loading = render(h(LlmSitesView, { state: { loading: true, data: null } }));
  assert.doesNotMatch(loading, /no LLM sites in the catalog/);
  assert.match(loading, /class="skel"/);
});

test('C8a: the COSTS tab stays lit on /llm-sites and its drill', () => {
  const costs = NAV.find((n) => n.to === '/costs');
  assert.ok(costs);
  assert.equal(costs.match('/costs'), true);
  assert.equal(costs.match('/llm-sites'), true);
  assert.equal(costs.match('/llm-sites/x'), true);
  assert.equal(costs.match('/llm-sitesx'), false);
});

test('C8b: the COSTS header links to LLM SITES', () => {
  const out = render(h(CostsHeader, { windowDays: 7 }));
  assert.match(out, /href="\/llm-sites"/);
  assert.match(out, /LLM SITES →/);
  assert.match(out, /COSTS/);
  assert.match(out, /window 7 days/);
});

test('C8c: CostsScreen renders CostsHeader', () => {
  const src = readFileSync(new URL('../src/screens/Costs.js', import.meta.url), 'utf8');
  const start = src.indexOf('export function CostsScreen');
  assert.notEqual(start, -1);
  const end = src.indexOf('\nexport function', start + 1);
  const body = src.slice(start, end === -1 ? undefined : end);
  assert.notEqual(body.indexOf('<${CostsHeader}'), -1);
});
