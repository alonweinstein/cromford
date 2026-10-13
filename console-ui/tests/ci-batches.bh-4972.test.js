import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import { ROUTES } from '../src/app.js';
import { sortRows } from '../src/lib/sort.js';
import {
  runUrl, batchRows, cutoverIso, medianBatchMinutes, medianLine, BATCH_WINDOW_DAYS, MEDIAN_SIDE_DAYS
} from '../src/lib/ci-batches.js';
import { CiBatchesView, batchColumns } from '../src/screens/CiHealth.js';

// BH-4972 (BH-4964.4): the MERGE-QUEUE BATCHES section of /ci, over BH-4971's
// GET /api/ci-batches (rows ordered completed_at DESC, {rows, as_of, truncated}).

globalThis.window = globalThis.window || {
  location: { pathname: '/ci', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const BH = 'example-org/cromford';
const CUT = '2026-09-20T12:00:00Z';
const at = (days) => new Date(Date.parse(CUT) + days * 86400000).toISOString();
const row = (when, billedMin, mode = 'full-legacy') => ({ when, billedMin, mode });

// ------------------------------------------------------------ 1. the median

test('1 medianBatchMinutes: odd/even medians, empty side, null billed, window edges, null cutover', () => {
  const rows = [
    row(at(-1), 5), row(at(-2), 9), row(at(-3), 7),
    row(at(0), 2, 'batch-selected'), row(at(1), 4, 'full'), row(at(2), 6, 'batch-selected'), row(at(3), 10, 'batch-selected'),
  ];
  const m = medianBatchMinutes(rows, CUT);
  assert.equal(m.before, 7);
  assert.equal(m.nBefore, 3);
  assert.equal(m.after, 5, 'even count: mean of the two middle values');
  assert.equal(m.nAfter, 4);

  const noBefore = medianBatchMinutes(rows.filter((r) => Date.parse(r.when) >= Date.parse(CUT)), CUT);
  assert.equal(noBefore.before, null);
  assert.equal(noBefore.nBefore, 0);

  const withNull = medianBatchMinutes([...rows, row(at(-4), null), row(at(4), null, 'batch-selected')], CUT);
  assert.equal(withNull.nBefore, 3, 'a null billed_min is not a measured batch');
  assert.equal(withNull.nAfter, 4);
  assert.equal(withNull.before, 7);

  const edges = medianBatchMinutes([row(CUT, 11, 'batch-selected'), row(at(-MEDIAN_SIDE_DAYS), 3), row(at(MEDIAN_SIDE_DAYS), 99)], CUT);
  assert.deepEqual(edges, { before: 3, after: 11, nBefore: 1, nAfter: 1 }, 'cutover is after, cutover-7d is before, cutover+7d is out');
  const outside = medianBatchMinutes([row(at(-MEDIAN_SIDE_DAYS - 0.01), 3)], CUT);
  assert.equal(outside.nBefore, 0);

  assert.deepEqual(medianBatchMinutes(rows, null), { before: null, after: null, nBefore: 0, nAfter: 0 });
});

test('1b medianLine: numbers, not enough batches yet, and a before side the window cut', () => {
  const line = medianLine({ before: 40, after: 9, nBefore: 1, nAfter: 1 }, { cutover: CUT, sinceIso: '2026-09-01' });
  assert.equal(line, '7-day median batch minutes: before 40 (1) · after 9 (1)');
  const empty = medianLine({ before: null, after: 9, nBefore: 0, nAfter: 1 }, { cutover: CUT, sinceIso: '2026-09-01' });
  assert.match(empty, /before not enough batches yet · after 9 \(1\)/);
  const cut = medianLine({ before: null, after: 9, nBefore: 0, nAfter: 1 }, { cutover: CUT, sinceIso: '2026-09-18' });
  assert.match(cut, /before before the loaded window/);
  const trunc = medianLine({ before: null, after: 9, nBefore: 0, nAfter: 1 }, { cutover: CUT, sinceIso: '2026-09-01', truncated: true });
  assert.match(trunc, /before the loaded window/);
  const none = medianLine({ before: null, after: null, nBefore: 0, nAfter: 0 }, { cutover: null, sinceIso: '2026-09-01' });
  assert.match(none, /before not enough batches yet · after not enough batches yet/);
});

// ------------------------------------------------------------ 2. cutover

test('2 cutoverIso: the earliest batch-selected row, ignoring full-legacy and full', () => {
  const rows = [
    row(at(5), 1, 'batch-selected'), row(at(-10), 1, 'full-legacy'), row(at(-9), 1, 'full'),
    row(at(0), 1, 'batch-selected'), row(at(3), 1, 'batch-selected'),
  ];
  assert.equal(cutoverIso(rows), at(0));
  assert.equal(cutoverIso([row(at(-1), 1, 'full-legacy'), row(at(0), 1, 'full')]), null);
  assert.equal(cutoverIso([]), null);
});

// ------------------------------------------------------------ 3. the run link

test('3 runUrl: a readable repo and a positive integer id link; anything else is null', () => {
  assert.equal(runUrl(BH, 123456), 'https://github.com/example-org/cromford/actions/runs/123456');
  for (const repo of ['', '../x', 'a/b/c', null, 'a/..', 'a b/c']) assert.equal(runUrl(repo, 1), null, `repo ${repo}`);
  for (const id of [0, '12', -3, 1.5, null, NaN]) assert.equal(runUrl(BH, id), null, `id ${id}`);
});

// ------------------------------------------------------------ 4. shaping

test('4 batchRows: escalation "-" is null, a missing count is null not 0, a bad payload is null', () => {
  const out = batchRows({ rows: [
    { run_id: 7, repo: BH, mode: 'batch-selected', escalation: '-', total: 340, wall_s: 600, billed_min: 9, conclusion: 'success', completed_at: CUT, started_at: at(-0.01) },
    { run_id: 8, repo: BH, mode: 'full', escalation: 'full: bin/lib/x.sh', selected: 12, total: 340, started_at: at(1) },
  ], truncated: true });
  assert.equal(out.truncated, true);
  const [a, b] = out.rows;
  assert.equal(a.escalation, null);
  assert.equal(a.selected, null, 'missing selected is null, never 0');
  assert.equal(a.total, 340);
  assert.equal(a.billedMin, 9);
  assert.equal(a.wallS, 600);
  assert.equal(a.when, CUT, 'completed_at wins');
  assert.equal(a.url, 'https://github.com/example-org/cromford/actions/runs/7');
  assert.equal(b.escalation, 'full: bin/lib/x.sh');
  assert.equal(b.when, at(1), 'falls back to started_at');
  assert.equal(b.billedMin, null);
  assert.equal(b.wallS, null);
  assert.equal(b.conclusion, null);
  assert.equal(batchRows({ error: 'ci_batches schema not applied' }), null);
  assert.equal(batchRows({ rows: 'x' }), null);
  assert.equal(batchRows(null), null);
  assert.equal(batchRows({ rows: [] }).truncated, false);
});

// ------------------------------------------------------------ 5. the read

function captureFetch(reply) {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET' });
    return { ok: true, status: 200, text: async () => JSON.stringify(reply) };
  };
  return { calls, restore: () => { globalThis.fetch = real; } };
}

test('5 api.ciBatches reads /api/coord/ci-batches with repo, since and limit=5000', async () => {
  const f = captureFetch({ rows: [], truncated: false });
  try {
    await api.ciBatches(BH, '2026-09-07');
    await api.ciBatches(null, '2026-09-07');
  } finally {
    f.restore();
  }
  assert.equal(f.calls[0].url, '/api/coord/ci-batches?repo=example-org%2Fcromford&since=2026-09-07&limit=5000');
  assert.equal(f.calls[0].method, 'GET');
  assert.equal(f.calls[1].url, '/api/coord/ci-batches?since=2026-09-07&limit=5000');
});

// ------------------------------------------------------------ 6/7. the view

const loaded = (data) => ({ data, error: null, loading: false, reload: () => {} });
const failed = (msg) => ({ data: null, error: new Error(msg), loading: false, reload: () => {} });
const headers = (out) => (out.match(/<th\b[^>]*>/g) || []);
const SINCE = '2026-09-01';
const fixture = { rows: [
  { run_id: 2002, repo: BH, mode: 'batch-selected', selected: 12, total: 340, escalation: 'full: bin/lib/x.sh', wall_s: 420, billed_min: 9, conclusion: 'success', started_at: at(0.9), completed_at: at(1) },
  { run_id: 2001, repo: BH, mode: 'full-legacy', selected: null, total: 340, escalation: '-', wall_s: 1800, billed_min: 40, conclusion: 'success', started_at: at(-0.1), completed_at: CUT },
], as_of: at(2), truncated: false };

test('6 CiBatchesView: sortable headers, GitHub run link, escalation, selected/total, median numbers, in a tablewrap', () => {
  const out = render(h(CiBatchesView, { batches: loaded(fixture), sinceIso: SINCE }));
  assert.ok(out.includes('MERGE-QUEUE BATCHES'));
  const ths = headers(out);
  assert.equal(ths.length, 8);
  for (const th of ths) assert.match(th, /aria-sort="/);
  const labels = ['RUN', 'WHEN', 'MODE', 'SELECTED / TOTAL', 'ESCALATION', 'DURATION', 'BILLED', 'CONCLUSION'];
  let pos = 0;
  for (const l of labels) {
    const i = out.indexOf(`>${l}`, pos);
    assert.ok(i > pos, `${l} missing or out of order`);
    pos = i;
  }
  assert.match(out, /<a href="https:\/\/github\.com\/example-org\/cromford\/actions\/runs\/2002"[^>]*target="_blank"[^>]*>#2002<\/a>/);
  assert.ok(out.includes('full: bin/lib/x.sh'));
  assert.ok(out.includes('12 / 340'));
  assert.ok(out.includes('— / 340'), 'a null selected renders —, not 0');
  assert.ok(out.includes('7m 0s') && out.includes('30m 0s'), 'durations from wall_s');
  // The full-legacy batch finished a day before the first batch-selected one: before 40 (1), after 9 (1).
  assert.ok(out.includes('7-day median batch minutes: before 40 (1) · after 9 (1)'), out.match(/7-day[^<]*/)?.[0]);
  assert.ok(out.includes('class="tablewrap'));
});

test('6b the median counts every mode: a full-legacy batch after the cutover is on the after side', () => {
  const rows = [{ ...fixture.rows[0], completed_at: CUT }, { ...fixture.rows[1], completed_at: at(1) }];
  const out = render(h(CiBatchesView, { batches: loaded({ ...fixture, rows }), sinceIso: SINCE }));
  assert.ok(out.includes('before not enough batches yet · after 24.5 (2)'), out.match(/7-day[^<]*/)?.[0]);
});

test('7 CiBatchesView states: failed read is ErrorBox not Empty, empty read is Empty not ErrorBox, truncated is said, loading is a skeleton', () => {
  const broke = render(h(CiBatchesView, { batches: failed('ci_batches schema not applied'), sinceIso: SINCE }));
  assert.ok(broke.includes('ci_batches schema not applied'));
  assert.match(broke, /<button[^>]*>[^<]*RETRY/i);
  assert.ok(!broke.includes('no merge-queue batches recorded yet'));
  assert.ok(!broke.includes('median batch minutes'));
  const garbled = render(h(CiBatchesView, { batches: loaded({ nope: 1 }), sinceIso: SINCE }));
  assert.ok(!garbled.includes('no merge-queue batches recorded yet'), 'a payload with no rows array is not "empty"');
  assert.match(garbled, /RETRY/i);

  const empty = render(h(CiBatchesView, { batches: loaded({ rows: [], truncated: false }), sinceIso: SINCE }));
  assert.ok(empty.includes('no merge-queue batches recorded yet'));
  assert.ok(!/RETRY/i.test(empty));
  assert.ok(!empty.includes('median batch minutes'));

  const trunc = render(h(CiBatchesView, { batches: loaded({ ...fixture, truncated: true }), sinceIso: SINCE }));
  assert.ok(trunc.includes('first 5000 batches only'));
  assert.ok(!render(h(CiBatchesView, { batches: loaded(fixture), sinceIso: SINCE })).includes('first 5000 batches only'));

  const loading = render(h(CiBatchesView, { batches: { data: null, error: null, loading: true }, sinceIso: SINCE }));
  assert.ok(loading.includes('class="skel"'));
});

// ------------------------------------------------------------ 8. sort accessors

test('8 every column sorts on the value it shows; BILLED orders like sortRows on the minutes', () => {
  const { rows } = batchRows({ rows: [
    { run_id: 1, repo: BH, billed_min: 3, completed_at: at(1) },
    { run_id: 2, repo: BH, billed_min: null, completed_at: at(2) },
    { run_id: 3, repo: BH, billed_min: 1, completed_at: at(3) },
  ] });
  const billed = batchColumns.find((c) => c.key === 'billedMin');
  assert.equal(typeof billed.sort, 'function');
  assert.deepEqual(sortRows(rows, billed.sort, 'asc').map((r) => r.billedMin), [1, 3, null]);
  assert.deepEqual(sortRows(rows, billed.sort, 'desc').map((r) => r.billedMin), [3, 1, null]);
  assert.deepEqual(sortRows(rows, billed.sort, 'asc').map((r) => r.billedMin), sortRows(rows.map((r) => r.billedMin), (v) => v, 'asc'));
  for (const c of batchColumns) assert.notEqual(c.sort, null, `${c.key} must sort`);
  const run = batchColumns.find((c) => c.key === 'runId');
  assert.deepEqual(sortRows(rows, run.sort, 'desc').map((r) => r.runId), [3, 2, 1]);
  const sel = batchColumns.find((c) => c.key === 'selected');
  const st = batchRows({ rows: [{ selected: 5, total: 9 }, { selected: 5, total: 2 }, { selected: 1, total: 400 }] }).rows;
  assert.deepEqual(sortRows(st, sel.sort, 'asc').map((r) => `${r.selected}/${r.total}`), ['1/400', '5/2', '5/9']);
});

// ------------------------------------------------------------ 9. the real route

test('9 /ci through ROUTES renders the MERGE-QUEUE BATCHES section', () => {
  const f = captureFetch({ rows: [] });
  try {
    const route = ROUTES.find(([p]) => p === '/ci');
    assert.ok(route);
    const out = render(h(route[1], {}));
    assert.ok(out.includes('CI HEALTH'));
    assert.ok(out.includes('MERGE-QUEUE BATCHES'));
    assert.ok(out.indexOf('CI HEALTH') < out.indexOf('MERGE-QUEUE BATCHES'));
  } finally {
    f.restore();
  }
  assert.equal(BATCH_WINDOW_DAYS, 30);
});
