import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { assertNoRawHeaders, assertUsdLabelled } from './legibility.bh-3558.js';
import { anchorHeadline } from '../src/lib/anchored.js';
// A namespace import, so a missing export fails its own test rather than the file.
import * as Costs from '../src/screens/Costs.js';
import { AccountUsageView } from '../src/screens/AccountUsage.js';

// BH-3570 (#3558 slice 3): /costs and its ACCOUNT USAGE section read without
// hovering. Every dollar carries its basis (API-equivalent or cash), ATTRIBUTED
// is gone from the headers, and the anchored tables explain RAW/ANCHORED/x in a
// visible legend. Fixtures follow the shapes the worker sends: GET /api/costs
// (read by lib/spend.js), GET /api/metrics/cost-anchored (computeAnchored in
// worker/jobs/src/lib/core.js) and GET /api/metrics/account-usage.

const NOW = Date.UTC(2026, 8, 29, 14, 5);
const iso = (msAgo) => new Date(NOW - msAgo).toISOString();
const H = 3600e3;

const spendRow = (project, c7, extra = {}) => ({
  project, cost_24h: c7 / 7, cost_7d: c7, cost_30d: c7 * 4, cost_per_merged_pr_7d: c7 / 5,
  merged_prs_7d: 5, triage_share_7d: 0.12, unpriced_calls_7d: 0, cash_cost_7d: 1.5,
  cash_cost_24h: 0.2, unknown_billing_calls_7d: 2, unknown_billing_calls_24h: 0,
  stages_7d: { execute: c7 * 0.7, review: c7 * 0.3 }, ...extra,
});

const costs = {
  spend: [
    spendRow('project-5', 120),
    spendRow('project-1', 80),
    spendRow('project-2', 40),
    spendRow('project-4', 10),
    { project: 'project-3', unavailable: true },
  ],
  fleet_cost_24h: 36, fleet_cost_7d: 250, fleet_cost_30d: 1000, fleet_notional_7d: 275.5,
  fleet_cash_7d_total: 18.5, fleet_cash_7d: 6, cash_overage_7d: 12.5, overage_meter_usd: 12.5,
  fleet_cost_missing: ['project-3'], fleet_cost_incomplete: true,
  fleet_unknown_billing_calls_7d: 8, fleet_unknown_billing_calls_24h: 0,
  unpriced_calls_7d: 0, spend_age_min: 30, spend_generated_at: iso(30 * 60e3), spend_stale: false,
};

// The basis attribute on the element whose text starts with the figure.
const basisOf = (markup, figure) => {
  const esc = figure.replace(/[$.]/g, (c) => `\\${c}`);
  const m = String(markup).match(new RegExp(`data-usd-basis="(\\w+)"[^>]*>${esc}(?=[\\s<])`));
  return m ? m[1] : null;
};
const ths = (markup) => String(markup).match(/<th\b[^>]*>[\s\S]*?<\/th>/g) || [];
const dts = (markup) => (String(markup).match(/<dl class="legend">[\s\S]*?<\/dl>/g) || [])
  .flatMap((dl) => [...dl.matchAll(/<dt>([\s\S]*?)<\/dt>/g)].map((m) => m[1]));

test('C1 SpendSection: API-equivalent, never ATTRIBUTED, priced tile names the gap, legend terms', () => {
  const out = render(h(Costs.SpendSection, { costs }));
  assert.ok(out.includes('API-equivalent (not cash)'), 'the 7d tile says API-equivalent (not cash)');
  for (const th of ths(out)) assert.doesNotMatch(th, /ATTRIBUTED/i, `ATTRIBUTED in a header: ${th}`);
  const labels = [...out.matchAll(/<span class="stat__label">([\s\S]*?)<\/span>/g)].map((m) => m[1]);
  assert.ok(labels.length >= 6);
  for (const l of labels) assert.doesNotMatch(l, /ATTRIBUTED/i, `ATTRIBUTED in a stat label: ${l}`);
  assert.doesNotMatch(out.replace(/<[^>]+>/g, ' '), /attributed/i, 'no visible ATTRIBUTED text at all');

  const priced = out.match(/PROJECTS PRICED<\/span>[\s\S]*?<\/div>/);
  assert.ok(priced, 'PROJECTS PRICED tile renders');
  assert.match(priced[0], /4\/5/);
  assert.match(priced[0], /project-3/, 'the tile names the project the rollup does not price');

  const terms = dts(out);
  for (const t of ['UNCLASSIFIED', 'UNPRICED', 'TRIAGE SHARE', 'API-EQUIV']) {
    assert.ok(terms.includes(t), `${t} is a legend term (got ${terms.join(' | ')})`);
  }
  assert.ok(ths(out).some((th) => th.includes('TRIAGE SHARE · 7D')), 'TRIAGE SHARE header carries its window');
  assert.ok(ths(out).some((th) => th.includes('$ PER MERGED PR · 7D')));

  // Exact money stays exact, and each figure says which basis it is.
  assert.equal(basisOf(out, '$120.00'), 'api', 'API-EQUIV 7D cell');
  assert.equal(basisOf(out, '$24.00'), 'api', '$ per merged PR cell');
  assert.equal(basisOf(out, '$1.50'), 'cash', 'CASH 7D cell');
  assert.equal(basisOf(out, '≥ $275.50'), 'api', 'the 7d API-equivalent tile');
  assert.equal(basisOf(out, '≥ $18.50'), 'cash', 'the cash out tile');
  assert.equal(basisOf(out, '$6.00'), 'cash', 'metered cash in the footnote');
  assert.equal(basisOf(out, '$12.50'), 'cash', 'overage cash in the footnote');
  assertNoRawHeaders(out);
  assertUsdLabelled(out);
});

test('C2 unavailable + unpriced banners render and carry no bare dollar prose', () => {
  const out = render(h(Costs.SpendSection, {
    costs: { ...costs, unpriced_calls_7d: 3, spend_unavailable: 'cost rollup has not run yet' },
  }));
  assert.ok(out.includes('cost rollup has not run yet'), 'the unavailable banner renders');
  assert.ok(out.includes('UNDERCOUNT'), 'the undercount banner renders');
  assert.ok(out.includes('zero dollars'), 'the $0.00 prose is reworded');
  assert.ok(out.includes('counted as zero here'));
  assertNoRawHeaders(out);
  assertUsdLabelled(out);
});

const anchored = {
  window: '24h', from: iso(24 * H), to: iso(0), limit: 50, disabled: false, gaps: [],
  accounts: [
    {
      label: 'project-6', meter_box: 'hub', meter_delta_usd: 30, rows_usd: 20, rows_calls: 40,
      rows_usd_span: 20, span_from: iso(20 * H), span_to: iso(H), snapshots: 12, weekly_pct: 100,
      weekly_resets_at: iso(-48 * H), extra_used_usd: 30, spend_limit_reached: false,
      factor: 1.5, factor_raw: 1.5, factor_capped: false, state: 'metered', reason: null,
    },
    {
      label: 'apikey', meter_box: null, meter_delta_usd: null, rows_usd: 4, rows_calls: 3,
      rows_usd_span: null, span_from: null, span_to: null, snapshots: 0, weekly_pct: null,
      weekly_resets_at: null, extra_used_usd: null, spend_limit_reached: null,
      factor: 1, factor_raw: null, factor_capped: false, state: 'no-login', reason: 'no meter for this account',
    },
  ],
  per_pr: [
    {
      pr_url: 'https://github.com/example-org/project-5/pull/12', repo: 'example-org/project-5', number: 12,
      title: null, project: 'project-5', key: 'TK-12', build_dir: 'project-5-TK-12-1', raw_usd: 10,
      anchored_usd: 15, account: 'project-6', factor: 1.5, at: iso(3 * H), merged_at: iso(2 * H),
      stage_breakdown: { execute: 7, review: 3 },
    },
    {
      pr_url: 'https://github.com/example-org/project-1/pull/7', repo: 'example-org/project-1', number: 7,
      title: null, project: 'project-1', key: null, build_dir: null, raw_usd: 4,
      anchored_usd: 4, account: 'apikey', factor: 1, at: iso(5 * H), merged_at: iso(4 * H),
      stage_breakdown: {},
    },
  ],
  totals: { rows_usd: 24, rows_anchored_usd: 34, meter_delta_usd: 30, pr_raw_usd: 14, pr_anchored_usd: 19, prs: 2 },
};

test('C3 AnchoredTable + AccountStrip: anchored is cash where metered, raw is API-equivalent', () => {
  const tbl = render(h(Costs.AnchoredTable, {
    title: '$ / PR', note: 'n', columns: Costs.prColumns, rows: anchored.per_pr, rowKey: (r) => r.pr_url,
    defaultSort: 'anchored_usd', truncated: false, limit: 50,
    totalRaw: 14, totalAnchored: 19, totalN: 2, anchoredBasis: 'cash', empty: 'none',
  }));
  const metered = tbl.match(/<tr[^>]*>(?:(?!<\/tr>)[\s\S])*project-5#12[\s\S]*?<\/tr>/);
  assert.ok(metered, 'the metered PR row renders');
  assert.equal(basisOf(metered[0], '$15.00'), 'cash', 'anchored figure of a metered row is cash');
  assert.equal(basisOf(metered[0], '$10.00'), 'api', 'RAW is the API-equivalent ledger');
  const plain = tbl.match(/<tr[^>]*>(?:(?!<\/tr>)[\s\S])*project-1#7[\s\S]*?<\/tr>/);
  assert.ok(plain);
  assert.equal((plain[0].match(/data-usd-basis="api"[^>]*>\$4\.00/g) || []).length, 2,
    'unmetered: anchored equals raw and both are API-equivalent');
  assert.equal(basisOf(tbl, '$19.00'), 'cash', 'anchored total follows the caller basis');
  assert.equal(basisOf(tbl, '$14.00'), 'api', 'raw total');
  assertNoRawHeaders(tbl);
  assertUsdLabelled(tbl);

  const strip = render(h(Costs.AccountStrip, { accounts: anchored.accounts, head: anchorHeadline(anchored) }));
  assert.equal(basisOf(strip, '$30.00'), 'cash', 'METER is the cash meter');
  assert.equal(basisOf(strip, '$20.00'), 'api', 'ROWS is the ledger');
  assertNoRawHeaders(strip);
  assertUsdLabelled(strip);
});

test('C4 AnchoredLegend defines RAW, ANCHORED, x and x vs LEDGER, and the section renders it', () => {
  const out = render(h(Costs.AnchoredLegend, {}));
  const terms = dts(out);
  for (const t of ['RAW', 'ANCHORED', '×', '× vs LEDGER']) assert.ok(terms.includes(t), `${t} is a <dt>`);
  assertUsdLabelled(out);
  const src = readFileSync(new URL('../src/screens/Costs.js', import.meta.url), 'utf8');
  const section = src.slice(src.indexOf('function AnchoredSection'), src.indexOf('function AccountStrip'));
  assert.ok(section.includes('<${AnchoredLegend}/>'), 'AnchoredSection mounts the legend');
});

const usage = {
  window: '5h', from: iso(5 * H), to: iso(0),
  accounts: [
    {
      account: 'own:operator', calls: 12, usd: 50, unpriced_calls: 0,
      input_toks: 12345, output_toks: 950, cache_read: 4560000, cache_write: 800, untokened_calls: 0,
      first_ts: iso(5 * H), last_ts: iso(10 * 60e3),
      projects: [{ project: 'project-5', calls: 4, usd: 40, unpriced_calls: 0, input_toks: 1, output_toks: 1, cache_read: 0, cache_write: 0 }],
      meter: { label: 'own:operator', session_pct: 42, weekly_pct: 71, weekly_resets_at: null, extra_used_usd: 80, polls: 9 },
      cross_check: {
        state: 'comparable', meter_delta_usd: 80, rows_usd: 20, unpriced_in_span: 0,
        gap_usd: 60, gap_pct: 75, span_from: iso(5 * H), span_to: iso(10 * 60e3),
      },
    },
    {
      account: null, calls: 1, usd: null, unpriced_calls: 1,
      input_toks: 0, output_toks: 0, cache_read: 0, cache_write: 0, untokened_calls: 1,
      first_ts: iso(3 * H), last_ts: iso(3 * H), projects: [], meter: null,
      cross_check: { state: 'no-login', reason: 'no login on this box' },
    },
  ],
  totals: { calls: 13, usd: 50, unpriced_calls: 1 },
  truncated: { groups: false, projects: false, snapshots: false },
};

test('C5 AccountUsageView: $ column API-equivalent, cross-check splits meter (cash) from rows', () => {
  const out = render(h(AccountUsageView, { data: usage, win: '5h', onWin() {}, initialOpen: 'own:operator' }));
  assert.equal(basisOf(out, '$50.00'), 'api', 'the account $ column');
  assert.equal(basisOf(out, '$40.00'), 'api', 'the project $ column');
  assert.equal(basisOf(out, '$80.00'), 'cash', 'the cross-check meter figure is cash');
  assert.equal(basisOf(out, '$20.00'), 'api', 'the cross-check rows figure is API-equivalent');
  assert.match(out, /gap 75%/);
  assert.ok(out.includes('no login on this box'), 'a non-comparable cross-check keeps its reason');
  assert.ok(out.includes('no data'), 'a null $ says no data');
  assertNoRawHeaders(out);
  assertUsdLabelled(out);
});
