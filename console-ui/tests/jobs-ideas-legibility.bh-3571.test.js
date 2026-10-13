import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { JobsTable, LanesSection, BurnSection } from '../src/screens/Jobs.js';
import { JobView } from '../src/screens/Job.js';
import { ProposalsTable, IDEA_LEGEND } from '../src/screens/Ideas.js';
import { IdeaView } from '../src/screens/Idea.js';
import { jobRows } from '../src/lib/jobs.js';
import { OUTCOME_LABEL } from '../src/lib/cockpit.js';
import { assertNoRawHeaders, assertUsdLabelled } from './legibility.bh-3558.js';

// BH-3571 (#3558 slice 4): Jobs, Job, Ideas and Idea read in words. Every
// render below goes through both shared legibility helpers, and every claim is
// read off the rendered markup, never off the source.

const NOW = Date.parse('2026-09-29T14:05:00Z');
const DAY = 86400000;
const iso = (ms) => new Date(ms).toISOString();

// Visible text: every tag (and so every attribute, title= included) removed.
const visible = (markup) => String(markup).replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ');
// The text of every element that carries a $ basis.
const usdSpans = (markup) => [...String(markup).matchAll(/<span class="num" data-usd-basis="(\w+)">([^<]*)/g)]
  .map((m) => ({ basis: m[1], text: m[2].trim() }));
// One table row's markup, found by a string only that row carries.
const rowOf = (markup, needle) => (String(markup).match(/<tr\b[\s\S]*?<\/tr>/g) || []).find((r) => r.includes(needle));
const legendOf = (markup) => (String(markup).match(/<dl class="legend">[\s\S]*?<\/dl>/) || [])[0] || '';
const both = (markup) => { assertNoRawHeaders(markup); assertUsdLabelled(markup); };

const job = (over) => ({
  id: 'j-1', project: 'project-3', kind: 'build', stage: 'execute', lane: 'build', box: 'project-3',
  status: 'running', spent_usd: 1.5, budget_usd: 5, created_at: iso(NOW - 3600000), age_s: 3600,
  heartbeating: true, beat_age_s: 30, ...over
});

test('J1: SPENT / CAP labels both dollars, says "no cap" for none, and a zero cap is a cap', () => {
  const rows = jobRows({ jobs: [
    job({ id: 'j-nocap', budget_usd: null, spent_usd: 1.5 }),
    job({ id: 'j-five', budget_usd: 5, spent_usd: 2 }),
    job({ id: 'j-zero', budget_usd: 0, spent_usd: 0.25 })
  ] });
  const out = render(h(JobsTable, { rows }));
  const nocap = rowOf(out, 'j-nocap');
  assert.ok(nocap, 'the uncapped row renders');
  assert.match(visible(nocap), /no cap/);
  assert.deepEqual(usdSpans(nocap), [{ basis: 'api', text: '$1.50' }]);
  const five = rowOf(out, 'j-five');
  assert.ok(usdSpans(five).some((u) => u.text === '$5.00'), five);
  assert.doesNotMatch(visible(five), /no cap/);
  const zero = rowOf(out, 'j-zero');
  assert.ok(usdSpans(zero).some((u) => u.text === '$0.00'), zero);
  assert.doesNotMatch(visible(zero), /no cap/);
  both(out);
});

const LANE = { project: 'project-3', box: 'project-3', state: 'live', tick_age_s: 60, last_tick_kind: 'skip', stale_after_s: 1800, cadence_min: 10 };

test('J2: a LANES row links to its lane page and its jobs, says its KIND in words, and has a legend', () => {
  const out = render(h(LanesSection, { lanes: { data: { lanes: [LANE] } } }));
  const row = rowOf(out, 'project-3');
  assert.ok(row, out);
  assert.ok(row.includes('href="/settings/run-triage?project=project-3"'), row);
  assert.ok(row.includes('href="/jobs?project=project-3"'), row);
  assert.match(visible(row), /skipped, nothing new/);
  const legend = visible(legendOf(out));
  assert.match(legend, /THRESHOLD/);
  assert.match(legend, /KIND/);
  both(out);
});

test('J2: an awkward project name is encoded in both links, and an unknown kind reads plainly', () => {
  const out = render(h(LanesSection, { lanes: { data: { lanes: [{ ...LANE, project: 'a b@c', last_tick_kind: 'new_kind' }] } } }));
  assert.ok(out.includes('href="/settings/run-triage?project=a%20b%40c"'), out);
  assert.ok(out.includes('href="/jobs?project=a%20b%40c"'), out);
  assert.match(visible(rowOf(out, 'a%20b%40c')), /new kind/);
});

const BURN = { burn: { data: { days: 14, burn: [
  { day: '2026-09-29', project: 'project-3', kind: 'build', spent_usd: 3.25, jobs: 2, orphaned: 1 },
  { day: '2026-09-28', project: 'project-4', kind: 'triage', spent_usd: 1.1, jobs: 4, orphaned: 0 }
] } } };

test('J3: BURN (by day) labels every dollar and explains ORPHANED on the page', () => {
  const out = render(h(BurnSection, BURN));
  const usd = usdSpans(out);
  assert.ok(usd.length >= 4, `TOTAL, LATEST DAY and two SPENT cells carry a basis: ${JSON.stringify(usd)}`);
  assert.ok(usd.every((u) => u.basis === 'api'));
  assert.ok(usd.some((u) => u.text === '$4.35'), 'the total');
  assert.match(visible(legendOf(out)), /ORPHANED/);
  both(out);
});

test('J4: JobsTable, LanesSection and BurnSection pass both legibility helpers', () => {
  both(render(h(JobsTable, { rows: jobRows({ jobs: [job({})] }) })));
  both(render(h(LanesSection, { lanes: { data: { lanes: [LANE] } } })));
  both(render(h(BurnSection, BURN)));
});

const JOB_DATA = {
  job: { id: 'j-9', project: 'project-3', kind: 'build', stage: 'execute', box: 'project-3', status: 'done',
    spent_usd: 0.42, budget_usd: null, heartbeating: false },
  phases: [{ id: 1, phase: 'execute', status: 'done', rc: 0, spend_usd: 0.42,
    started_at: iso(NOW - 2 * DAY), finished_at: iso(NOW - 2 * DAY + 600000), runner: 'claude', model: 'm' }],
  events: [{ id: 1, created_at: iso(NOW - 2 * DAY), stage: 'execute', verdict: 'OK', actor: 'project-3', detail: '' }],
  ledgers: []
};

test('J5: JobView says the phase outcome in words, dates old stamps and labels its dollars', () => {
  const out = render(h(JobView, { data: JOB_DATA, onReload: () => {}, nowMs: NOW }));
  const row = rowOf(out, 'claude');
  assert.ok(row, out);
  const text = visible(row);
  assert.match(text, new RegExp(`\\b${OUTCOME_LABEL.ok}\\b`));
  assert.match(text, /\bexecute\b/);
  assert.match(text, /\bdone\b/);
  assert.match(text, /Sep 27 14:05Z/, 'a two-day-old start prints its date');
  assert.ok(usdSpans(row).some((u) => u.text === '$0.42'), row);
  assert.match(visible(out), /no cap/);
  both(out);
});

const PROPOSAL = {
  pkey: 'project-3/roster', project: 'project-3', slug: 'roster', title: 'Roster view', status: 'candidate',
  score: 28, impact: 8, confidence: 7, effort: 2, dus: 'unclog',
  created_at: iso(NOW - 10 * DAY), updated_at: iso(NOW - 4 * DAY)
};

test('J6: SCORE shows its parts as visible text, and the legend gives the scale and the buckets', () => {
  const out = render(h(ProposalsTable, { rows: [PROPOSAL] }));
  assert.match(visible(rowOf(out, 'Roster view')), /impact 8 × confidence 7 ÷ effort 2/);
  const legend = visible(legendOf(out));
  assert.match(legend, /SCORE[^]*1 to 10/);
  for (const b of ['DERISK', 'UNCLOG', 'SCALE']) assert.match(legend, new RegExp(b));
  assert.ok(IDEA_LEGEND.some((i) => i.term === 'BUCKET'));
  both(out);
});

test('J6: a score with a missing part shows the number alone, no half formula', () => {
  const out = render(h(ProposalsTable, { rows: [{ ...PROPOSAL, effort: null }] }));
  const text = visible(rowOf(out, 'Roster view'));
  assert.match(text, /\b28\b/);
  assert.doesNotMatch(text, /impact 8/);
});

test('J7: IdeaView gives IMPACT and EFFORT their units, dates old stamps and carries the legend', () => {
  const out = render(h(IdeaView, {
    data: { proposal: PROPOSAL, assets: [], chat: [] }, project: 'project-3', slug: 'roster',
    shot: null, onShot: () => {}, onReload: () => {}, nowMs: NOW
  }));
  const text = visible(out);
  assert.match(text, /IMPACT 8 \/10/);
  assert.match(text, /CONFIDENCE 7 \/10/);
  assert.match(text, /EFFORT 2 sessions/);
  assert.match(text, /updated Sep 25 14:05Z/);
  const legend = visible(legendOf(out));
  assert.match(legend, /SCORE[^]*1 to 10/);
  assert.match(legend, /BUCKET/);
  both(out);
});
