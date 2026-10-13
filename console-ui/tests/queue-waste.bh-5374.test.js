import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { readFileSync } from 'node:fs';
import { api } from '../src/api.js';
import { nextDirection, ariaSort } from '../src/lib/sort.js';
import { queueWasteTiles, queueWasteRows, draftLinks, utcDay, QUEUE_WASTE_DAYS } from '../src/lib/queue-waste.js';
import { CiHealthScreen, CiHealthView } from '../src/screens/CiHealth.js';

// BH-5374 (BH-5356.2): the QUEUE WASTE section on /ci. The worker's
// GET /api/queue-batch-minutes/daily answers one row per UTC day with the
// minutes of the batch drafts that did not merge; the section shows two tiles
// (today, 7 days), the per-day table, and a day's drafts under a DAY click,
// each linked to its GitHub PR and run.

const REPO = 'example-org/cromford';
const NOW = Date.parse('2026-10-08T12:00:00Z');
const draft = (over = {}) => ({
  repo: REPO, draft_pr: 5001, run_id: 9001, outcome: 'reset', minutes: 18, reused_min: 0, reused_known: 0,
  source: 'billable', workflow: 'harness-ci', closed_at: '2026-10-08T10:00:00Z', ...over,
});
const day = (d, over = {}) => ({
  day: d, discarded_min: 0, red_min: 0, reset_min: 0, bisect_min: 0, merged_min: 0,
  reused_min: 0, reused_known: 0, resets: 0, drafts: [], ...over,
});
const DATA = {
  days: [
    day('2026-10-08', { discarded_min: 18, reset_min: 18, merged_min: 9, resets: 1,
      drafts: [draft(), draft({ draft_pr: 5003, run_id: 9003, outcome: 'merged', minutes: 9 })] }),
    day('2026-10-07', { discarded_min: 4, red_min: 4, reused_min: 3, reused_known: 1,
      drafts: [draft({ draft_pr: 4990, run_id: 8990, outcome: 'red', minutes: 4, reused_min: 3, reused_known: 1, closed_at: '2026-10-07T09:00:00Z' })] }),
  ],
  as_of: '2026-10-08T12:00:00Z', truncated: false,
};

const loaded = (data) => ({ data, error: null, loading: false, reload: () => {} });
const failed = (msg) => ({ data: null, error: new Error(msg), loading: false, reload: () => {} });
const fleet = {
  health: loaded({ rows: [] }), flakes: loaded({ flakes: [] }), quarantine: loaded({ rows: [] }),
  onToggle: () => {}, onOpen: () => {}, pending: null, msg: null,
};
const view = (props) => render(h(CiHealthView, { ...fleet, queueWaste: loaded(DATA), openDay: null, onOpenDay: () => {}, nowMs: NOW, ...props }));
const section = (out) => {
  const i = out.indexOf('QUEUE WASTE');
  assert.ok(i >= 0, 'the QUEUE WASTE section renders');
  return out.slice(i);
};

test('1 queueWasteTiles sums discarded minutes only; merged minutes never count', () => {
  const t = queueWasteTiles(DATA, NOW);
  assert.deepEqual(t, { today: 18, week: 22, reusedKnown: false });
  assert.equal(utcDay(NOW), '2026-10-08');
  assert.equal(QUEUE_WASTE_DAYS, 7);
  // No row for today on a good read is 0 today, not unknown.
  assert.equal(queueWasteTiles({ days: [DATA.days[1]] }, NOW).today, 0);
  // An unreadable payload has no tiles at all.
  assert.equal(queueWasteTiles(null, NOW), null);
  assert.equal(queueWasteTiles({ days: 'x' }, NOW), null);
  assert.equal(queueWasteRows({ nope: 1 }), null);
  assert.equal(queueWasteRows({ days: [{ day: 3 }] }), null, 'a malformed row fails the whole shape');
  assert.equal(queueWasteRows({ days: [] }).length, 0);
});

test('2 the tiles render today and 7-day wasted minutes', () => {
  const out = section(view({}));
  assert.match(out, /WASTED TODAY[\s\S]*?18<span class="stat__unit">min<\/span>/);
  assert.match(out, /WASTED 7D[\s\S]*?22<span class="stat__unit">min<\/span>/);
});

test('3 the day table: five sortable headers that toggle aria-sort, inside its scroll container', () => {
  const out = section(view({}));
  const ths = out.match(/<th\b[^>]*>/g) || [];
  assert.equal(ths.length, 5);
  for (const th of ths) assert.match(th, /aria-sort="/);
  for (const label of ['DAY', 'DISCARDED', 'REUSED', 'RED', 'RESETS']) assert.ok(out.includes(label), label);
  assert.match(ths[0], /aria-sort="descending"/, 'newest day first');
  assert.ok(out.includes('class="tablewrap'));
  // The header click sequence the SortableTable runs: DAY desc -> asc, then DISCARDED asc -> desc.
  let dir = nextDirection('day', 'day', 'desc');
  assert.equal(ariaSort('day', 'day', dir), 'ascending');
  dir = nextDirection('discarded', 'day', dir);
  assert.equal(ariaSort('discarded', 'discarded', dir), 'ascending');
  dir = nextDirection('discarded', 'discarded', dir);
  assert.equal(ariaSort('discarded', 'discarded', dir), 'descending');
  // newest first in the rendered order
  assert.ok(out.indexOf('2026-10-08') < out.indexOf('2026-10-07'));
});

test('4 DAY expands to that day\'s drafts', () => {
  const closed = section(view({}));
  assert.ok(!closed.includes('DRAFTS ·'));
  assert.ok(!closed.includes('aria-expanded="true"'));
  const opened = [];
  const out = section(view({ openDay: '2026-10-08', onOpenDay: (d) => opened.push(d) }));
  assert.ok(out.includes('DRAFTS · 2026-10-08'));
  assert.match(out, /<button[^>]*aria-expanded="true"[^>]*>2026-10-08<\/button>/);
  assert.match(out, /<button[^>]*aria-expanded="false"[^>]*>2026-10-07<\/button>/);
  for (const label of ['DRAFT', 'RUN', 'OUTCOME', 'MIN', 'SOURCE']) assert.ok(out.includes(label), label);
  assert.ok(out.includes('#5001') && out.includes('#5003'));
  assert.ok(!out.includes('#4990'), 'only the open day\'s drafts');
});

test('5 a draft links to its GitHub PR and run', () => {
  assert.deepEqual(draftLinks(draft()), {
    pr: `https://github.com/${REPO}/pull/5001`,
    run: `https://github.com/${REPO}/actions/runs/9001`,
  });
  const out = section(view({ openDay: '2026-10-08' }));
  assert.ok(out.includes(`href="https://github.com/${REPO}/actions/runs/9001"`));
  assert.ok(out.includes(`href="https://github.com/${REPO}/pull/5001"`));
  assert.match(out, /<a[^>]*href="https:\/\/github.com\/example-org\/cromford\/pull\/5001"[^>]*rel="noopener"/);
});

test('6 a successful empty read renders the empty state', () => {
  const out = section(view({ queueWaste: loaded({ days: [], as_of: 'x', truncated: false }) }));
  assert.ok(out.includes('no queue waste recorded yet'));
  assert.match(out, /WASTED TODAY[\s\S]*?0<span class="stat__unit">min<\/span>/);
});

test('7 an unknown reuse renders a dash titled "no reuse record", never 0', () => {
  const out = section(view({ openDay: '2026-10-08' }));
  assert.ok(out.includes('title="no reuse record"'));
  const y = section(view({ openDay: '2026-10-07' }));
  // 2026-10-07 has a known reuse of 3 in the day table.
  assert.match(y, />3<\/td>/);
});

test('8 a failed read renders ErrorBox with RETRY, not the empty copy; a bad shape too', () => {
  const out = section(view({ queueWaste: failed('http_503 queue_batch_minutes schema not applied') }));
  assert.ok(out.includes('queue_batch_minutes schema not applied'));
  assert.ok(out.includes('RETRY'));
  assert.ok(!out.includes('no queue waste recorded yet'));
  assert.ok(!out.includes('WASTED TODAY'));
  const bad = section(view({ queueWaste: loaded({ rows: [] }) }));
  assert.ok(bad.includes('unreadable queue-waste payload'));
  assert.ok(bad.includes('RETRY'));
  assert.ok(!bad.includes('no queue waste recorded yet'));
  const truncated = section(view({ queueWaste: loaded({ ...DATA, truncated: true }) }));
  assert.ok(truncated.includes('first 2000 rows only'));
  const loading = section(view({ queueWaste: { data: null, error: null, loading: true } }));
  assert.ok(loading.includes('class="skel"'));
});

test('9 the view never calls a native dialog', () => {
  const src = CiHealthView.toString() + CiHealthScreen.toString()
    + readFileSync(new URL('../src/screens/CiHealth.js', import.meta.url), 'utf8')
    + readFileSync(new URL('../src/lib/queue-waste.js', import.meta.url), 'utf8');
  assert.ok(src.includes('function queueWasteBody'), 'the guard reads the edited screen, not an empty string');
  assert.equal(/window\.(confirm|alert|prompt)\s*\(/.test(src), false);
});

test('10 QUEUE WASTE is its own block after CI HEALTH; absent prop renders nothing', () => {
  const out = view({});
  assert.ok(out.indexOf('CI HEALTH') >= 0 && out.indexOf('QUEUE WASTE') > out.indexOf('CI HEALTH'));
  const none = render(h(CiHealthView, { ...fleet }));
  assert.ok(!none.includes('QUEUE WASTE'));
});

test('10b the routed /ci screen itself mounts QUEUE WASTE (loading until its read settles)', () => {
  const had = 'window' in globalThis;
  const prev = globalThis.window;
  globalThis.window = { location: { pathname: '/ci', search: '' }, addEventListener() {}, removeEventListener() {} };
  let out;
  try {
    out = render(h(CiHealthScreen, {}));
  } finally {
    if (had) globalThis.window = prev; else delete globalThis.window;
  }
  assert.ok(out.indexOf('QUEUE WASTE') > out.indexOf('CI HEALTH'), 'CiHealthScreen wires the queue-waste read into the view');
  assert.ok(section(out).includes('class="skel"'));
});

test('11 api.queueBatchMinutesDaily(7) GETs the coord daily route', async () => {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET' });
    return { ok: true, status: 200, text: async () => JSON.stringify({ days: [] }) };
  };
  try {
    await api.queueBatchMinutesDaily(7);
  } finally {
    globalThis.fetch = real;
  }
  assert.deepEqual(calls, [{ url: '/api/coord/queue-batch-minutes/daily?days=7', method: 'GET' }]); // determinism: ok clock-rolling-window compares the URL string api.js builds against a stubbed fetch; no window is evaluated
});
