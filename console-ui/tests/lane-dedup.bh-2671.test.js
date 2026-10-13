import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import { sortRows, nextDirection, ariaSort } from '../src/lib/sort.js';
import {
  DEDUP_WINDOWS, laneRows, fmtRatio, fpPrLink, fpCallsParams, showNoFpNote, loadFpCalls,
  LaneDedupSection, LaneDedupView, FpCallsView,
} from '../src/screens/LaneDedup.js';

// BH-2671 (BH-2537.4): CALLS PER DISTINCT INPUT · BY LANE on /costs. The
// payload follows the target `lanes[]` shape in worker/jobs/src/lib/lane-dedup.js
// (#2669 fills it; until then the route answers `lanes: []`).

const fixture = {
  days: 7,
  lanes: [
    {
      lane: 'review-prs', calls: 12, distinct_fp: 3, calls_per_fp: 4, distinct_tickets: 2, distinct_prs: 1, no_fp_calls: 0, usd: 1.5,
      fps: [
        { fp: 'abc', calls: 6, ticket: 'BH-1', pr: 'https://github.com/example-org/cromford/pull/5', project: 'cromford', usd: 0.9 },
        { fp: 'def', calls: 2, ticket: null, pr: null, project: null, usd: null },
      ],
    },
    { lane: 'triage', calls: 5, distinct_fp: 5, calls_per_fp: 1, distinct_tickets: 5, distinct_prs: 0, no_fp_calls: 0, usd: 0.2, fps: [] },
    { lane: null, calls: 3, distinct_fp: 0, calls_per_fp: null, distinct_tickets: 0, distinct_prs: 0, no_fp_calls: 3, usd: null, fps: [] },
  ],
  truncated: { fps: false },
};
const allFp = { ...fixture, lanes: fixture.lanes.filter((l) => l.lane !== null) };
const NOW = Date.parse('2026-09-27T00:00:00Z'); // determinism: ok injected clock for fpCallsParams, the function under test takes `now` as an argument
const LANE_COLS = ['LANE', 'CALLS', 'DISTINCT FPS', 'CALLS/FP', 'DISTINCT TICKETS', 'DISTINCT PRS', 'NO-FP CALLS', '$'];
const FP_COLS = ['FP', 'CALLS', 'TICKET', 'PR', 'PROJECT', '$'];
const CALL_COLS = ['TS', 'BOX', 'RUNNER', 'MODEL', 'RC', '$', 'SESSION'];
const view = (props) => render(h(LaneDedupView, { days: 7, onDays() {}, ...props }));

function stubFetch() {
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(String(url));
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, cost_rows: [] }) };
  };
  return calls;
}

test('A1 api.laneDedup and api.costRows hit the coord proxy; a null param is dropped', async () => {
  const calls = stubFetch();
  await api.laneDedup(30);
  await api.laneDedup();
  assert.deepEqual(calls, [
    '/api/coord/metrics/lane-dedup?days=30', // determinism: ok asserts the URL api.laneDedup builds against a stubbed fetch; no fixture data is read through the window
    '/api/coord/metrics/lane-dedup?days=7', // determinism: ok asserts the default window in the URL api.laneDedup builds; fetch is stubbed, no data read
  ]);
  await api.costRows({ guard_fp: 'abc', lane_id: 'review-prs', since: '2026-09-20T00:00:00Z', limit: 50 }); // determinism: ok a literal query param against a stubbed fetch, no clock read
  const u = new URL(calls[2], 'http://x');
  assert.equal(u.pathname, '/api/coord/metrics/cost-rows');
  assert.deepEqual(Object.fromEntries(u.searchParams), {
    guard_fp: 'abc', lane_id: 'review-prs', since: '2026-09-20T00:00:00Z', limit: '50', // determinism: ok literal expected query param
  });
  await api.costRows({ guard_fp: 'abc', lane_id: null, since: '', limit: 50 });
  const u2 = new URL(calls[3], 'http://x');
  assert.deepEqual([...u2.searchParams.keys()].sort(), ['guard_fp', 'limit']);
});

test('A2 fmtRatio: null reads —, a number two decimals', () => {
  assert.equal(fmtRatio(null), '—');
  assert.equal(fmtRatio(undefined), '—');
  assert.equal(fmtRatio(Number.NaN), '—');
  assert.equal(fmtRatio(4), '4.00');
  assert.equal(fmtRatio(1.234), '1.23');
});

test('A3 CALLS/FP sorts with the null-ratio lane last in both directions', () => {
  const rows = laneRows(fixture);
  assert.deepEqual(sortRows(rows, (r) => r.calls_per_fp, 'desc').map((r) => r.lane), ['review-prs', 'triage', null]);
  assert.deepEqual(sortRows(rows, (r) => r.calls_per_fp, 'asc').map((r) => r.lane), ['triage', 'review-prs', null]);
});

test('A4 laneRows: a null lane is labelled, its nulls stay null, keys are unique', () => {
  const rows = laneRows(fixture);
  const nul = rows.find((r) => r.lane === null);
  assert.equal(nul.label, '(unnamed)');
  assert.equal(nul.usd, null, 'null usd stays null, never 0');
  assert.equal(nul.calls_per_fp, null);
  assert.equal(new Set(rows.map((r) => r.key)).size, 3);
  assert.deepEqual(laneRows({}), []);
  assert.deepEqual(laneRows(null), []);
  assert.deepEqual(DEDUP_WINDOWS.map((w) => w.days), [7, 1, 30]);
});

test('A5 fpCallsParams: guard_fp, lane_id, a second-precision since, limit 50', () => {
  assert.deepEqual(fpCallsParams({ lane: 'review-prs', fp: 'abc', days: 7, now: NOW }), {
    guard_fp: 'abc', lane_id: 'review-prs', since: '2026-09-20T00:00:00Z', limit: 50, // determinism: ok literal expected value for the injected clock
  });
  assert.equal(fpCallsParams({ lane: null, fp: 'abc', days: 1, now: NOW + 123 }).lane_id, null);
  assert.equal(fpCallsParams({ lane: null, fp: 'abc', days: 1, now: NOW + 123 }).since, '2026-09-26T00:00:00Z'); // determinism: ok literal expected value for the injected clock
});

test('A6 fpPrLink: only an https github.com URL becomes a link', () => {
  assert.deepEqual(fpPrLink({ pr: 'https://github.com/o/r/pull/5' }), { kind: 'external', to: 'https://github.com/o/r/pull/5' });
  for (const pr of [null, '', '5', '#5', 'http://github.com/x', 'https://gitlab.com/o/r/pull/5']) {
    assert.equal(fpPrLink({ pr }), null, `no link for ${JSON.stringify(pr)}`);
  }
  assert.equal(showNoFpNote(laneRows(fixture)), true);
  assert.equal(showNoFpNote(laneRows(allFp)), false);
});

test('B1 the view: title, switcher with 7D pressed, the 8 sortable lane headers', () => {
  const out = view({ data: fixture });
  assert.ok(out.includes('CALLS PER DISTINCT INPUT · BY LANE'));
  assert.equal((out.match(/aria-pressed=/g) || []).length, 3);
  assert.equal((out.match(/aria-pressed="true"/g) || []).length, 1);
  assert.match(out, /aria-pressed="true"[^>]*>7D</);
  assert.match(out, /aria-pressed="false"[^>]*>1D</);
  assert.match(out, /aria-pressed="false"[^>]*>30D</);
  for (const c of LANE_COLS) assert.ok(out.includes(`title="sort by ${c.toLowerCase()}"`), `sortable header ${c}`);
  assert.ok(out.includes('cost_rows per lane_id · last 7d'));
  assert.equal((out.match(/tablewrap--wide/g) || []).length, 1);
  const thirty = view({ data: { ...fixture, days: 30 }, days: 30 });
  assert.match(thirty, /aria-pressed="true"[^>]*>30D</);
});

test('B2 CALLS/FP is the default sort, descending, null last; a second click is ascending', () => {
  const out = view({ data: fixture });
  assert.match(out, /aria-sort="descending"[^<]*<button[^>]*title="sort by calls\/fp"/);
  assert.equal((out.match(/aria-sort="descending"/g) || []).length, 1, 'only CALLS/FP is active');
  const a = out.indexOf('>review-prs<');
  const b = out.indexOf('>triage<');
  const c = out.indexOf('>(unnamed)<');
  assert.ok(a > -1 && b > -1 && c > -1);
  assert.ok(a < b && b < c, 'review-prs, triage, (unnamed)');
  assert.ok(out.includes('>4.00<'));
  assert.ok(!out.includes('$0.00'), 'a null usd is never rendered as zero');
  const dir = nextDirection('calls_per_fp', 'calls_per_fp', 'desc');
  assert.equal(ariaSort('calls_per_fp', 'calls_per_fp', dir), 'ascending');
});

test('B3 an open lane shows its fps table with project links', () => {
  const out = view({ data: fixture, initialOpen: 'review-prs' });
  assert.ok(out.includes('aria-expanded="true"'));
  assert.equal((out.match(/tablewrap--wide/g) || []).length, 2);
  for (const c of FP_COLS) assert.ok(out.includes(`title="sort by ${c.toLowerCase()}"`), `fp header ${c}`);
  assert.ok(out.includes('href="/p/cromford"'));
  assert.ok(out.includes('(no project)'));
  assert.ok(!out.includes('href="/p/null"'));
  assert.ok(out.includes('>BH-1<'));

  const closed = view({ data: fixture });
  assert.ok(!closed.includes('aria-expanded="true"'));
  assert.ok(!closed.includes('href="/p/cromford"'));
});

test('B4 the PR cell links to GitHub only when the value is a GitHub URL', () => {
  const out = view({ data: fixture, initialOpen: 'review-prs' });
  assert.ok(out.includes('href="https://github.com/example-org/cromford/pull/5"'));
  assert.equal((out.match(/href="https:\/\/github\.com/g) || []).length, 1, 'the null-pr row has no link');
  const bare = { ...fixture, lanes: [{ ...fixture.lanes[0], fps: [{ fp: 'x', calls: 1, ticket: null, pr: '5', project: null, usd: null }] }] };
  const b = view({ data: bare, initialOpen: 'review-prs' });
  assert.ok(!/href="[^"]*5"/.test(b));
  assert.ok(b.includes('>5<'), 'a bare value is shown as text');
});

test('B5 loading, error-with-retry and empty are three distinct renders', () => {
  const loading = view({ loading: true, data: null });
  assert.ok(loading.includes('class="skel"'));
  assert.ok(!loading.includes('no calls in this window'));

  const err = view({ error: new Error('boom'), data: null, reload() {} });
  assert.ok(err.includes('RETRY'));
  assert.ok(err.includes('boom'));
  assert.ok(!err.includes('no calls in this window'));

  const empty = view({ data: { days: 7, lanes: [], truncated: { fps: false } } });
  assert.ok(empty.includes('no calls in this window'));
  assert.ok(!empty.includes('RETRY'));
  assert.ok(!empty.includes('aria-sort='));
  assert.ok(!empty.includes('banner--warn'));
  assert.ok(!empty.includes('carry no fingerprint'));
});

const callRow = (i) => ({
  ts: `2026-09-26T00:00:${String(i % 60).padStart(2, '0')}Z`, box: 'hub', runner: 'review', model: 'm', rc: 0,
  cost_usd: 0.01, session_id: `s${i}`, row_hash: `h${i}`,
});

test('B6 FpCallsView: 7 headers, the newest-50 note only at exactly 50 rows', () => {
  const rows50 = Array.from({ length: 50 }, (_, i) => callRow(i));
  const out = render(h(FpCallsView, { data: { cost_rows: rows50 }, fp: 'abc', lane: 'review-prs' }));
  for (const c of CALL_COLS) assert.ok(out.includes(`title="sort by ${c.toLowerCase()}"`), `call header ${c}`);
  assert.ok(out.includes('newest 50'));
  assert.ok(out.includes('href="/machines"'));
  assert.ok(!out.includes('every lane'));
  const out49 = render(h(FpCallsView, { data: { cost_rows: rows50.slice(0, 49) }, fp: 'abc', lane: 'review-prs' }));
  assert.ok(!out49.includes('newest 50'));
  const unnamed = render(h(FpCallsView, { data: { cost_rows: rows50.slice(0, 2) }, fp: 'abc', lane: null }));
  assert.ok(unnamed.includes('in every lane'));
  const empty = render(h(FpCallsView, { data: { cost_rows: [] }, fp: 'abc', lane: 'review-prs' }));
  assert.ok(empty.includes('no calls for this input in this window'));
  const err = render(h(FpCallsView, { error: new Error('nope'), data: null, reload() {}, fp: 'abc', lane: 'x' }));
  assert.ok(err.includes('RETRY'));
  assert.ok(!err.includes('no calls for this input'));
});

test('B7 an open fp mounts the calls panel; loadFpCalls sends guard_fp and lane_id', async () => {
  const out = view({ data: fixture, initialOpen: 'review-prs', initialFp: 'abc' });
  assert.equal((out.match(/aria-expanded="true"/g) || []).length, 2, 'the lane and the fp are both open');
  assert.ok(out.includes('abc · calls'));

  const orig = api.costRows;
  const seen = [];
  api.costRows = async (p) => { seen.push(p); return { cost_rows: [] }; };
  try {
    await loadFpCalls('review-prs', 'abc', 7, NOW);
  } finally {
    api.costRows = orig;
  }
  assert.equal(seen.length, 1);
  assert.equal(seen[0].guard_fp, 'abc');
  assert.equal(seen[0].lane_id, 'review-prs');
  assert.equal(seen[0].limit, 50);
});

test('B8 the truncated banner and the no-fp note render only when true', () => {
  const trunc = view({ data: { ...fixture, truncated: { fps: true } } });
  assert.ok(trunc.includes('banner--warn'));
  assert.ok(!view({ data: fixture }).includes('banner--warn'));
  assert.ok(view({ data: fixture }).includes('carry no fingerprint'));
  assert.ok(!view({ data: allFp }).includes('carry no fingerprint'));
});

test('B9 the production entry renders its loading state and is mounted on /costs', () => {
  assert.equal(typeof LaneDedupSection, 'function');
  stubFetch();
  const out = render(h(LaneDedupSection));
  assert.ok(out.includes('CALLS PER DISTINCT INPUT · BY LANE'));
  assert.match(out, /aria-pressed="true"[^>]*>7D</);
  assert.ok(out.includes('class="skel"'));
});
