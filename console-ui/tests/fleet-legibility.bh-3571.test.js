import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import * as Fleet from '../src/screens/Fleet.js';
import * as Machines from '../src/screens/Machines.js';
import * as Project from '../src/screens/Project.js';
import { FleetContext } from '../src/app.js';
import { runOutcome, OUTCOME_LABEL, OUTCOME_TONE } from '../src/lib/cockpit.js';
import { healthFromAge } from '../src/lib/format.js';
import { sortRows } from '../src/lib/sort.js';
import { assertNoRawHeaders, assertUsdLabelled } from './legibility.bh-3558.js';

// BH-3571 (#3558 slice 4): Fleet, Machines and Project read in words. Every
// case renders the real exported component and reads the HTML back. One pinned
// clock for the whole file; nothing here reads Date.now for an assertion.

const NOW = Date.parse('2026-09-29T14:05:00Z');

// Visible text: tags (and so every title="" attribute) stripped, entities for
// the middle dot folded back, whitespace collapsed.
const visible = (markup) => String(markup)
  .replace(/<[^>]*>/g, ' ')
  .replace(/&middot;|&#183;/g, '·')
  .replace(/\s+/g, ' ')
  .trim();

const tds = (markup) => (String(markup).match(/<td\b[^>]*>[\s\S]*?<\/td>/g) || []);
const ths = (markup) => (String(markup).match(/<th\b[^>]*>[\s\S]*?<\/th>/g) || []);
const legendOf = (markup) => {
  const m = String(markup).match(/<dl class="legend">[\s\S]*?<\/dl>/);
  return m ? m[0] : null;
};

const TONE_CLASS = { green: 'tag tag--green', dead: 'tag tag--dead', warn: 'tag tag--warn', muted: 'tag tag--idle' };

const projectRow = (over = {}) => ({
  project: 'project-5', last_run_age_min: 3, last_summary: 'ok', last_rc: 0,
  paused: false, automerge: true, fleet: { queue_depth: 1 }, ...over
});
const projectsHtml = (rows) => render(h(Fleet.ProjectsTable, { rows, recentRuns: {}, pauses: [] }));
// Column 2 (0-based) of the one row is LAST RESULT; column 3 is QUEUE.
const cell = (markup, i) => tds(markup)[i];

test('F1: LAST RESULT says how the tick ended, in the words and tone /now uses', () => {
  const ok = cell(projectsHtml([projectRow({ last_rc: 0 })]), 2);
  const okOutcome = runOutcome({ rc: 0 });
  assert.ok(ok.includes(`class="${TONE_CLASS[OUTCOME_TONE[okOutcome]]}"`), `tone class missing: ${ok}`);
  assert.equal(visible(ok), OUTCOME_LABEL[okOutcome]);

  const failed = cell(projectsHtml([projectRow({ last_rc: 1 })]), 2);
  assert.equal(visible(failed), OUTCOME_LABEL.failed);
  assert.ok(failed.includes(`class="${TONE_CLASS[OUTCOME_TONE.failed]}"`));

  const killed = cell(projectsHtml([projectRow({ last_rc: 137 })]), 2);
  assert.equal(visible(killed), OUTCOME_LABEL[runOutcome({ rc: 137 })]);

  assert.equal(visible(cell(projectsHtml([projectRow({ last_rc: '0' })]), 2)), OUTCOME_LABEL.ok);
  assert.equal(visible(cell(projectsHtml([projectRow({ last_rc: null })]), 2)), '—');
  assert.equal(visible(cell(projectsHtml([projectRow({ last_rc: 'x' })]), 2)), '—');

  const th = ths(projectsHtml([projectRow()]))[2];
  assert.match(th, /<button[^>]*>\s*LAST RESULT/i, `header button: ${th}`);
  assert.match(th, /<span class="th-raw">RC<\/span>/);
});

test('F2: QUEUE separates no data from zero, and no data sinks either way', () => {
  const q = (fleet) => visible(cell(projectsHtml([projectRow({ fleet })]), 3));
  assert.equal(q({}), 'no data');
  assert.equal(q(undefined), 'no data');
  assert.equal(q({ queue_depth: null }), 'no data');
  assert.equal(q({ queue_depth: 0 }), '0');
  assert.equal(q({ queue_depth: 4 }), '4');
  assert.equal(q({ queue_depth: 0, held: 2 }), '0 · 2 held');
  assert.equal(q({ queue_depth: 3, failed: 1 }), '3 · 1 failed');

  const th = ths(projectsHtml([projectRow()]))[3];
  assert.match(visible(th), /QUEUE builds/);

  const rows = [
    projectRow({ project: 'a', fleet: {} }),
    projectRow({ project: 'b', fleet: { queue_depth: 0 } }),
    projectRow({ project: 'c', fleet: { queue_depth: 5 } })
  ];
  assert.equal(typeof Fleet.queueSortKey, 'function', 'QUEUE sort accessor is exported');
  const asc = sortRows(rows, Fleet.queueSortKey, 'asc').map((r) => r.project);
  const desc = sortRows(rows, Fleet.queueSortKey, 'desc').map((r) => r.project);
  assert.deepEqual(asc, ['b', 'c', 'a']);
  assert.deepEqual(desc, ['c', 'b', 'a']);
});

const fleetScreen = () => render(h(FleetContext.Provider, { value: { data: null } }, h(Fleet.FleetScreen)));

test('F3: OLDEST says in queue, and the queue tile says what it counts', () => {
  const th = ths(projectsHtml([projectRow()]))[4];
  assert.match(visible(th), /OLDEST in queue/);
  const out = fleetScreen();
  assert.ok(visible(out).includes('BUILDS WAITING FOR A MACHINE'), 'tile label');
  assert.ok(!visible(out).includes('QUEUE DEPTH'), 'old tile label gone');
});

test('F4: the PROJECTS section carries a FLAGS legend; the table itself still has no PAUSED(', () => {
  const out = fleetScreen();
  const legend = legendOf(out);
  assert.ok(legend, 'a <dl class="legend"> is rendered');
  const text = visible(legend);
  for (const term of ['PAUSED', 'PAUSED (what)', 'NO AUTOMERGE', 'LAST RESULT']) {
    assert.ok(text.includes(term), `legend term ${term} missing from visible text: ${text}`);
  }
  assert.ok(Array.isArray(Fleet.FLEET_FLAGS_LEGEND) && Fleet.FLEET_FLAGS_LEGEND.length === 4);
  assert.doesNotMatch(projectsHtml([projectRow({ paused: true, automerge: false })]), /PAUSED\(/);
  assert.equal(legendOf(projectsHtml([projectRow()])), null, 'legend lives in the section, not the table');
});

const boxRow = (name, min) => ({ name, ping: min === null ? 'never' : `${min}m ago`, min });

test('F5: box STATE words and the legend agree with healthFromAge', () => {
  assert.equal(typeof Machines.BoxesTable, 'function', 'BoxesTable is exported');
  const out = render(h(Machines.BoxesTable, {
    rows: [boxRow('a', 5), boxRow('b', 15), boxRow('c', 45), boxRow('d', null)],
    onAction: () => {}
  }));
  const text = visible(out);
  for (const w of ['ANSWERING', 'OVERDUE', 'SILENT', 'NO RECORD']) assert.ok(text.includes(w), w);

  const legend = legendOf(out);
  assert.ok(legend, 'BoxesTable renders its STATE legend');
  const lt = visible(legend);
  for (const w of ['ANSWERING', 'OVERDUE', 'SILENT', 'NO RECORD']) assert.ok(lt.includes(w), `legend term ${w}`);
  assert.ok(lt.includes('under 10 minutes'));
  assert.ok(lt.includes('10 to 30 minutes'));
  assert.ok(lt.includes('30 minutes or more'));

  // The legend restates format.js's thresholds; if they move, this goes red.
  assert.equal(healthFromAge(9), 'ok');
  assert.equal(healthFromAge(10), 'warn');
  assert.equal(healthFromAge(29), 'warn');
  assert.equal(healthFromAge(30), 'dead');
  assert.equal(healthFromAge(null), 'unknown');
});

const build = (over) => ({
  id: 1, ticket_key: 'BH-1', bkey: 'bh-1', stage: 'pr_created', merged: false,
  tier: null, verdict: null, age_min: 5, pr_url: null, ...over
});

test('F6: TIER in words, and a lane the map does not know never reads as SNAKE_CASE', () => {
  const tierCell = (tier) => {
    const out = render(h(Project.BuildsTable, { builds: [build({ tier })], project: 'project-5' }));
    return visible(tds(out)[3]);
  };
  assert.equal(tierCell(1), 'auto-merge');
  assert.equal(tierCell(2), 'reviewed merge');
  assert.equal(tierCell('2'), 'reviewed merge');
  assert.equal(tierCell(null), 'no tier');

  assert.equal(typeof Project.laneLabel, 'function', 'laneLabel is exported');
  assert.equal(Project.laneLabel('review'), 'NEEDS REVIEW');
  assert.equal(Project.laneLabel('merge_queue'), 'MERGE QUEUE');
  const odd = Project.laneLabel('awaiting_deploy_slot');
  assert.doesNotMatch(odd, /_/);
  assert.equal(odd, 'AWAITING DEPLOY SLOT');
  assert.equal(Project.laneLabel(undefined), 'UNKNOWN');
});

const iso = (msAgo) => new Date(NOW - msAgo).toISOString();

test('F7: RunsTable TIME is relative under a day and dated after; helpers pass on every view', () => {
  const runs = [
    { id: 11, started_at: iso(3 * 3600e3), kind: 'build', rc: 0, summary: 'ok' },
    { id: 12, started_at: iso(4 * 86400e3), kind: 'triage', rc: 1, summary: 'no' }
  ];
  const out = render(h(Project.RunsTable, { runs, nowMs: NOW }));
  // TIME is column 0; the table sorts newest first. Exact text, so "13h ago"
  // from a real clock can not pass for "3h ago".
  const times = (String(out).match(/<tr\b[\s\S]*?<\/tr>/g) || []).slice(1).map((tr) => visible(tds(tr)[0]));
  assert.deepEqual(times, ['3h ago', 'Sep 25 14:05Z']);
  assert.match(out, /href="\/runs\/12"[^>]*>\s*Sep 25 14:05Z/);

  const views = [
    projectsHtml([projectRow(), projectRow({ project: 'x', last_rc: 1, fleet: {} })]),
    render(h(Machines.BoxesTable, { rows: [boxRow('a', 5)], onAction: () => {} })),
    out,
    render(h(Project.BuildsTable, { builds: [build({ tier: 1 })], project: 'project-5' })),
    fleetScreen()
  ];
  for (const v of views) {
    assertNoRawHeaders(v);
    assertUsdLabelled(v);
  }
});
