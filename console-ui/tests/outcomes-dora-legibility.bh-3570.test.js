import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import * as O from '../src/screens/Outcomes.js';
import { DoraProjectTable, DoraSlowestTable } from '../src/screens/DORA.js';
import { projectRows, slowRows } from '../src/lib/dora.js';
import { assertNoRawHeaders, assertUsdLabelled } from './legibility.bh-3558.js';

// BH-3570 (#3558.3): /outcomes and /dora read without hovering. Plain header
// labels (the old label survives as .th-raw), one Legend under the Outcomes
// stats, every $ figure tagged with its basis, DORA's n said as "N merges".

const NOW = Date.UTC(2026, 8, 29, 14, 5);
const ago = (ms) => new Date(NOW - ms).toISOString();
const DAY = 86400000;
const PR = (repo, n) => `https://github.com/${repo}/pull/${n}`;

// The shape functions/api/outcomes returns: merges, outcomes, pr_costs,
// burn_days, gates, thresholds, degraded, as_of.
const merge = (repo, n, ageDays) => ({
  kind: 'merge', key: PR(repo, n), status: 'merged', job_id: `build-${n}`,
  created_at: ago(ageDays * DAY), updated_at: ago(ageDays * DAY)
});
const burnDay = (ageDays, usd, calls, peak) => ({
  day: ago(ageDays * DAY).slice(0, 10), usd_equiv: usd, output: 1000, api_calls: calls, peak_cache_read: peak
});
const fixture = {
  as_of: ago(0),
  degraded: [],
  merges: [merge('example-org/project-3', 1, 2), merge('example-org/project-3', 2, 3), merge('example-org/project-4', 3, 4)],
  outcomes: [
    { repo: 'example-org/project-3', pr: PR('example-org/project-3', 1), outcome: 'reverted', day: ago(DAY).slice(0, 10), evidence: 'revert commit on main' },
    { repo: 'example-org/project-4', pr: PR('example-org/project-4', 3), outcome: 'merged_then_red', day: ago(DAY).slice(0, 10), evidence: 'main red' }
  ],
  pr_costs: [
    { pr_url: PR('example-org/project-3', 1), cost_usd: 4.5, stage_breakdown: 'execute:3.50;plan:1.00' },
    { pr_url: PR('example-org/project-3', 2), cost_usd: 1.5, stage_breakdown: 'execute:1.50' }
  ],
  burn_days: [burnDay(1, 120, 400, 180000), burnDay(2, 80, 300, 90000), burnDay(9, 60, 200, 70000)],
  gates: [
    { repo: 'example-org/project-3', tightened: 1, rate: 0.5, bad: 1, merges: 2, tighten_rate: 0.2, clear_rate: 0.1, min_merges: 2, threshold_scope: '*', window_days: 14, decision: 'tighten', evidence: '1 of 2 reverted', updated_at: ago(3600000) },
    { repo: 'example-org/project-4', tightened: 0, rate: 0, bad: 0, merges: 1, tighten_rate: 0.2, clear_rate: 0.1, min_merges: 2, threshold_scope: '*', window_days: 14, decision: 'clear', evidence: 'nothing came back', updated_at: ago(3600000) }
  ],
  thresholds: []
};

const legendTerms = (out) => {
  const dl = out.match(/<dl class="legend">[\s\S]*?<\/dl>/);
  assert.ok(dl, 'a <dl class="legend"> is rendered');
  return { dl: dl[0], terms: [...dl[0].matchAll(/<dt>([\s\S]*?)<\/dt>/g)].map((m) => m[1]) };
};
const ths = (out) => out.match(/<th\b[^>]*>[\s\S]*?<\/th>/g) || [];
const buttonText = (th) => ((th.match(/<button\b[^>]*>([\s\S]*?)<\/button>/) || [])[1] || '').replace(/<[^>]+>/g, ' ');
const withoutRaw = (out) => out.replace(/<span class="th-raw">[\s\S]*?<\/span>/g, '');

test('O1 OutcomesView: window on MAIN RED, a Legend under the stats, every $ tagged', () => {
  assert.equal(typeof O.OutcomesView, 'function', 'Outcomes.js exports a prop-driven OutcomesView');
  const out = render(h(O.OutcomesView, { out: { data: fixture }, repo: null, days: 14, nowMs: NOW, setFilter: () => {} }));

  // Every table rendered, not a skeleton.
  assert.ok((out.match(/<table/g) || []).length >= 5, 'gate, per-repo, burn, findings and cost tables render');

  const mainRed = ths(out).filter((th) => /MAIN RED/.test(th));
  assert.equal(mainRed.length, 1);
  assert.match(mainRed[0], /<span class="th-unit">14d<\/span>/, 'MAIN RED header names its window');

  const didNotHold = ths(out).filter((th) => /DID NOT HOLD/.test(buttonText(th)));
  assert.equal(didNotHold.length, 2, 'both RATE headers read DID NOT HOLD');
  for (const th of didNotHold) assert.match(th, /<span class="th-raw">RATE<\/span>/);

  const { dl, terms } = legendTerms(out);
  for (const t of ['GATE', 'THRESHOLD', 'PEAK CACHE READ', 'API CALLS', 'TREND', 'MAIN RED', 'COST PER PR']) {
    assert.ok(terms.some((x) => x.includes(t)), `${t} is a Legend term`);
  }
  assert.ok(terms.some((x) => /DID NOT HOLD/.test(x)), 'DID NOT HOLD is a Legend term');
  for (const w of ['PARKED', 'AUTO-MERGE', 'NOT MEASURED']) assert.match(dl, new RegExp(`<dd>[^<]*${w}`), `${w} is defined in the Legend`);
  // The Legend sits under the stats row, before any table.
  assert.ok(out.indexOf('<dl class="legend">') < out.indexOf('<table'), 'Legend is above the tables');

  // The RATE hover text moved into the Legend.
  // (The header's own sort button title "sort by DID NOT HOLD" is not a cell.)
  const cells = (out.match(/<td\b[\s\S]*?<\/td>/g) || []).join('');
  assert.doesNotMatch(cells, /title="[^"]*did not hold/i, 'no title= on the RATE cell carrying "did not hold"');

  // SPEND 6.00 (project-3), COST PER PR 3.00, findings/cost COST 4.50: each in a basis span.
  for (const v of ['6.00', '3.00', '4.50', '1.50']) {
    assert.match(out, new RegExp(`data-usd-basis="api"[^>]*>\\$${v.replace('.', '\\.')}`), `$${v} carries data-usd-basis="api"`);
  }
  const stat = out.match(/<span class="stat__label">COST PER PR<\/span>[\s\S]*?<\/span>\s*<\/span>/);
  assert.ok(stat, 'COST PER PR stat tile rendered');
  assert.match(stat[0], /data-usd-basis="api"/, 'COST PER PR tile is tagged');

  assertNoRawHeaders(out);
  assertUsdLabelled(out);
});

test('O1b OutcomesView while loading renders skeletons, not a crash', () => {
  assert.equal(typeof O.OutcomesView, 'function');
  const out = render(h(O.OutcomesView, { out: { loading: true, data: null }, repo: null, days: 14, nowMs: NOW, setFilter: () => {} }));
  assert.doesNotMatch(out, /<table/);
});

// The dora.test.js payload, the shape GET /api/dora returns.
const payload = {
  window: { days: 14 },
  projects: [
    {
      project: 'project-3', repos: ['example-org/project-3'], merged: 8,
      lead_time: { p50_s: 7200, p90_s: 86400 * 3, n: 8, from_job_n: 6, from_pr_seen_n: 1, unattributed_n: 1, deploy_verified: false, evidence: 'jobs.created_at → ledgers' },
      deployment_frequency: { per_day: 0.571, count: 8, days: 14, deploy_verified: false, evidence: 'ledgers(kind=merge)' },
      change_failure: { rate: 0.25, bad: 2, merges: 8, main_red: 1, evidence: 'outcome_metrics ÷ ledgers' },
      time_to_restore: { p50_s: 86400, p90_s: 86400 * 2, n: 2, unrestored: 1, evidence: 'outcome_metrics → ledgers' },
      merge_lane: { p50_s: 1800, p90_s: 7200, n: 7, evidence: 'job_artifacts(verdict) → ledgers' },
      slowest: [
        { pr: PR('example-org/project-3', 9), repo: 'example-org/project-3', number: 9, lead_s: 86400 * 3, approval_to_merge_s: 7200, job_id: 'build-project-3-9', ticket_id: 'TK-9', lead_basis: 'job_created', merged_at: ago(18 * DAY) },
        { pr: PR('example-org/project-3', 4), repo: 'example-org/project-3', number: 4, lead_s: 3600, approval_to_merge_s: null, job_id: null, ticket_id: null, lead_basis: 'pr_first_seen', merged_at: ago(19 * DAY) }
      ]
    },
    {
      project: 'project-4', repos: [], merged: 0,
      lead_time: { p50_s: null, p90_s: null, n: 0, from_job_n: 0, from_pr_seen_n: 0, unattributed_n: 0, deploy_verified: false },
      deployment_frequency: { per_day: 0, count: 0, days: 14, deploy_verified: false },
      change_failure: { rate: null, bad: 0, merges: 0, main_red: 0 },
      time_to_restore: { p50_s: null, p90_s: null, n: 0, unrestored: 3 },
      merge_lane: { p50_s: null, p90_s: null, n: 0 },
      slowest: []
    }
  ],
  totals: { merged: 8 },
  gaps: []
};

test('O2 DoraProjectTable: plain headers, old labels only as .th-raw, n as "N merges"', () => {
  const out = render(h(DoraProjectTable, { rows: projectRows(payload), days: 14, evidence: payload.projects[0], empty: h('div', null, 'EMPTY') }));
  const buttons = ths(out).map(buttonText).join(' | ');
  assert.match(buttons, /merges per day/i);
  assert.match(buttons, /slowest 1 in 10/i);
  assert.match(buttons, /time from start to merge, median/i);
  assert.match(buttons, /time to restore, median/i);
  assert.match(buttons, /approval to merge, median/i);
  assert.match(buttons, /open failures/i);
  assert.match(buttons, /failed changes/i);
  assert.match(buttons, /based on/i);

  // project-3: 8 lead samples; project-4: 0 stays a bare 0, never "0 merges".
  assert.match(out, />8 merges</);
  assert.doesNotMatch(out, /0 merges</);

  const bare = withoutRaw(out);
  for (const old of ['LEAD p50', 'LEAD p90', 'LEAD n\\b', 'LANDINGS', 'CHANGE FAIL\\b', 'RESTORE p50', 'OPEN FAIL\\b', 'APPROVE→MERGE p50', 'LANE n\\b']) {
    assert.match(out, new RegExp(`<span class="th-raw">${old}`), `${old} survives as .th-raw`);
    assert.doesNotMatch(bare, new RegExp(old), `${old} appears only inside .th-raw`);
  }

  assertNoRawHeaders(out);
  assertUsdLabelled(out);
});

test('O2b DoraSlowestTable passes both helpers with plain headers', () => {
  const out = render(h(DoraSlowestTable, { rows: slowRows(projectRows(payload)), empty: h('div', null, 'EMPTY') }));
  const buttons = ths(out).map(buttonText).join(' | ');
  assert.match(buttons, /time from start to merge/i);
  assert.match(buttons, /approval to merge/i);
  assert.doesNotMatch(withoutRaw(out), /APPROVE→MERGE/);
  assertNoRawHeaders(out);
  assertUsdLabelled(out);
});
