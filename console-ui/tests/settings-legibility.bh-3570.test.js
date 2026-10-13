import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { SettingsView, LaneDetailView } from '../src/screens/Settings.js';
import * as settingsLib from '../src/lib/settings.js';

// Namespace import so a missing helper fails ITS test, not the whole file.
const { settingsRows, findLaneRow, tabsFrom } = settingsLib;
const cadenceWords = (s) => settingsLib.cadenceWords(s);
const firstSentence = (s) => settingsLib.firstSentence(s);
import { assertNoRawHeaders, assertUsdLabelled } from './legibility.bh-3558.js';

// BH-3570 (#3558 slice 3): /settings and /settings/:lane read without hovering.
// Cadence in words, knobs named in plain words with their env name and meaning,
// one legend for STATE/SOURCE/ZERO, BOXES OFF names the boxes, cost rows dated,
// every $ carries its basis.

// determinism: every stamp is an offset from this one pinned instant.
const NOW = Date.UTC(2026, 8, 29, 14, 5);
const ago = (ms) => new Date(NOW - ms).toISOString();
const MIN = 60000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

// Real registry notes (catalog/lanes.d/*.json).
const NOTE_TRIAGE = 'Alert families one tick may hand to a model. 0 stops the lane spending entirely.';
const NOTE_FLOOR = "Empty by default since BH-1510.2: the floor runner is the runner on model_routes role 'housekeeping.floor' rung 0, read through bin/lib/lane-model.sh:lane_housekeeping_floor. Set this only to override that row.";

// ------------------------------------------------------------------ S1

test('S1 cadenceWords: cron in words, anything else raw with (cron), prose verbatim', () => {
  assert.equal(cadenceWords('*/10 * * * *'), 'every 10 min');
  assert.equal(cadenceWords('* * * * *'), 'every min');
  assert.equal(cadenceWords('17 * * * *'), 'hourly at :17');
  assert.equal(cadenceWords('7,37 * * * *'), 'hourly at :07, :37');
  assert.equal(cadenceWords('40 5 * * *'), 'daily at 05:40Z');
  assert.equal(cadenceWords('50 * * * *; 50 4 * * *'), 'hourly at :50; daily at 04:50Z');
  assert.equal(cadenceWords('50 6 * * 1'), 'weekly, Mon 06:50Z');
  assert.equal(cadenceWords('0 */2 * * *'), '0 */2 * * * (cron)');
  assert.equal(cadenceWords('*/5'), '*/5 (cron)');
  assert.equal(cadenceWords('on demand (via x)'), 'on demand (via x)');
  assert.equal(cadenceWords(null), null);
  assert.equal(cadenceWords(''), null);
});

// ------------------------------------------------------------------ S2

test('S2 firstSentence: cuts at the first real sentence end, not at BH-1510.2 or a file path', () => {
  assert.equal(firstSentence('Spool depth that raises one backlog alert.'), 'Spool depth that raises one backlog alert.');
  assert.equal(firstSentence(NOTE_FLOOR),
    "Empty by default since BH-1510.2: the floor runner is the runner on model_routes role 'housekeeping.floor' rung 0, read through bin/lib/lane-model.sh:lane_housekeeping_floor.");
  assert.equal(firstSentence(NOTE_TRIAGE), 'Alert families one tick may hand to a model.');
  assert.equal(firstSentence('no terminator here'), 'no terminator here');
  assert.equal(firstSentence(null), null);
  assert.equal(firstSentence('   '), null);
});

// ------------------------------------------------------------------ fixture

const registry = {
  lanes: [
    {
      id: 'alert-triage', name: 'Alert triage', scope: 'hub', script: 'bin/alert-triage.sh',
      cadence: '*/10 * * * *',
      knobs: [{ env: 'TRIAGE_MAX_FAMILIES', type: 'int', default: 4, min: 0, max: 50, unit: 'families', zero_means: 'off', note: NOTE_TRIAGE }],
      stats: { cost_stage: 'plan_review' }
    },
    {
      id: 'spool-watch', name: 'Spool watch', scope: 'hub', script: 'bin/spool-watch.sh',
      cadence: '17 * * * *', knobs: []
    },
    {
      id: 'disk-clean', name: 'Disk clean', scope: 'box', script: 'bin/disk-clean.sh',
      cadence: '40 5 * * *', knobs: []
    }
  ]
};

const status = {
  scope: 'hub', as_of: ago(1 * MIN), projects: ['project-4'], all_off: false,
  lanes: [
    {
      id: 'alert-triage', off: false, cadence: '*/10 * * * *', last_tick_at: ago(4 * MIN), last_outcome: 'ok',
      runs_today: 6, cost_today: 3.25, cost_7d: 19.5,
      knobs: { TRIAGE_MAX_FAMILIES: { value: 4, source: 'settings' } },
      cost_rows: [
        { at: ago(3 * DAY), stage: 'plan_review', ticket: null, usd: 1.25, build_dir: null },
        { at: ago(2 * HOUR), stage: 'plan_review', ticket: null, usd: 0.5, build_dir: null }
      ]
    },
    // Reported, but nothing measured its runs: null, which is not zero.
    { id: 'spool-watch', off: false, cadence: '17 * * * *', last_tick_at: ago(30 * MIN), runs_today: null, cost_today: null, cost_7d: null },
    {
      id: 'disk-clean', off: false, cadence: '40 5 * * *', last_tick_at: ago(10 * MIN),
      runs_today: 3, cost_today: null, cost_7d: null,
      boxes: [
        { box: 'hub', off: true, off_source: 'db', paused_since: ago(2 * DAY) },
        { box: 'fly-1', off: true, off_source: 'db', paused_since: ago(3 * HOUR) },
        { box: 'fly-2', off: false }
      ]
    }
  ]
};

const noop = () => {};
const actions = { toggleLane: noop, toggleBox: noop, setKnob: noop, allOff: noop, allOn: noop };

const settingsHtml = () => {
  const { rows, boxRows } = settingsRows(registry, status, 'hub');
  return render(h(SettingsView, {
    tabs: tabsFrom(status), activeTab: 'hub', rows, boxRows, status,
    error: null, loading: false, busy: null, note: null,
    actions, dialog: null, onTab: noop, onReload: noop, controlKinds: []
  }));
};

const legendText = (html) => (html.match(/<dl class="legend">[\s\S]*?<\/dl>/g) || []).join('\n');
const legendTerms = (html) => (legendText(html).match(/<dt>([\s\S]*?)<\/dt>/g) || []).map((d) => d.replace(/<[^>]+>/g, '').trim());

// ------------------------------------------------------------------ S3

test('S3 SettingsView: cadence words, BOXES OFF names, knob label/raw/meaning, legend, reset note, $ basis, no data', () => {
  const html = settingsHtml();

  assert.ok(html.includes('every 10 min'), 'cadence in words');
  assert.match(html, /title="\*\/10 \* \* \* \*"/, 'the raw cron string stays on the cell title');

  // BOXES OFF: the count stays, the off boxes are named beside it.
  assert.match(html, />2\/3</, 'the count');
  assert.match(html, /off: hub, fly-1/, 'the two off boxes by name, the on box not');
  assert.ok(!/off: [^<]*fly-2/.test(html), 'an on box is never named as off');

  // Knob: plain label, raw env under it, the note's first sentence.
  assert.match(html, /<label[^>]*>triage max families<\/label>/, 'plain label');
  assert.ok(html.includes('>TRIAGE_MAX_FAMILIES<'), 'the raw env name as its own text');
  assert.ok(html.includes('Alert families one tick may hand to a model.'), 'first sentence of the note');
  assert.ok(!html.includes('0 stops the lane spending entirely'), 'only the first sentence');

  // Legend.
  const terms = legendTerms(html);
  assert.ok(terms.includes('STATE'), `STATE is a legend term (got ${terms.join(' | ')})`);
  assert.match(legendText(html), /ON: the lane runs\. OFF: the lane skips every tick/, 'the ON/OFF/? sentence');
  assert.match(legendText(html), /\?: the box has not reported this switch/);

  assert.ok(html.includes('resets at 00:00 UTC'), 'the $ TODAY reset is said once');
  assert.match(html, /data-usd-basis="api"[^>]*>\$3\.25/, '$ TODAY carries its basis');
  assert.match(html, /data-usd-basis="api"[^>]*>\$19\.50/, '$ 7D carries its basis');

  // RUNS TODAY null reads as no data, not a dash.
  const spool = html.slice(html.indexOf('Spool watch'));
  const spoolRow = spool.slice(0, spool.indexOf('</tr>'));
  assert.ok(spoolRow.includes('no data'), 'runs_today null says no data');

  assertNoRawHeaders(html);
  assertUsdLabelled(html);
});

// ------------------------------------------------------------------ S4

test('S4 LaneDetailView: cost rows dated, stage in words, $ basis, SOURCE and ZERO in the legend', () => {
  const lane = findLaneRow(registry, status, 'hub', 'alert-triage');
  const html = render(h(LaneDetailView, {
    lane, laneId: 'alert-triage', project: null, error: null, loading: false,
    costRows: lane.cost_rows, actions, busy: null, setBusy: noop, nowMs: NOW
  }));

  assert.ok(html.includes('Sep 26 14:05Z'), 'a 3-day-old row shows its date');
  assert.ok(html.includes('2h ago'), 'a fresh row says how long ago');
  assert.ok(html.includes('plan review'), 'stage in words');
  assert.ok(!/>plan_review</.test(html), 'the raw stage is not the cell text');
  assert.match(html, /data-usd-basis="api"[^>]*>\$1\.25/, 'cost row USD carries its basis');
  assert.match(html, /cost stage plan_review/, 'section note in words');

  const terms = legendTerms(html);
  assert.ok(terms.includes('SOURCE'), `SOURCE in the legend (got ${terms.join(' | ')})`);
  assert.ok(terms.includes('ZERO'), 'ZERO in the legend');
  assert.match(html, /triage max families/, 'knob plain label in the KNOBS table');
  assert.ok(html.includes('TRIAGE_MAX_FAMILIES'), 'raw env still visible');
  assert.match(html, /cadence<\/dt><dd>[\s\S]*?every 10 min/, 'lane detail cadence in words');

  assertNoRawHeaders(html);
  assertUsdLabelled(html);
});
