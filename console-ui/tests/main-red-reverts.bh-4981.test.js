import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import { mainRedRevertRows, mainRedCounters, MainRedRevertsView } from '../src/ui/MainRedReverts.js';

// BH-4981: the MAIN-RED REVERTS section on /ci. One ledger read (kind
// main_red_attrib, one row per culprit merge the safety net reverted), parsed
// defensively, counted by risk tier and queue lane, and rendered as a sortable
// table. The view is a pure function of the useApi state, so it renders here.

const SHA = 'a'.repeat(40);
const SHA2 = 'b'.repeat(40);
const SHA3 = 'c'.repeat(40);
const NOW = Date.parse('2026-10-07T04:00:00Z');

const detail = (over = {}) => JSON.stringify({
  pr: 102, pr_title: 'BH-1: a change', red: 'f'.repeat(40), run: '4242', lane: 'scoped',
  reason: 'scoped lane skipped tests/x-test.sh', risk_tier: 'high', scopes: ['tests/a.sh'],
  missed: ['tests/x-test.sh'], revert_url: 'https://github.com/o/r/pull/500',
  gap_url: 'https://github.com/o/r/issues/601', ...over
});
const ledger = (key, status, d, updated_at = '2026-10-07T03:00:00Z') =>
  ({ kind: 'main_red_attrib', key, status, detail: d, updated_at });

const data = { ledgers: [
  ledger(`o/r@${SHA}`, 'gap', detail()),
  ledger(`o/r@${SHA2}`, 'serial', detail({ pr: 103, lane: 'serial', risk_tier: 'low', revert_url: '', gap_url: '', missed: [] }), '2026-10-06T03:00:00Z'),
  ledger(`p/q@${SHA3}`, 'unknown', '{not json', '2026-10-05T03:00:00Z'),
] };

const state = (over) => ({ loading: false, error: null, data: null, reload: () => {}, ...over });
const view = (st, limit) => render(h(MainRedRevertsView, { state: st, now: NOW, ...(limit ? { limit } : {}) }));

test('C0 api.mainRedAttrib reads the ledger kind through the coord proxy', async () => {
  const seen = [];
  const prev = globalThis.fetch;
  globalThis.fetch = async (url) => {
    seen.push(String(url));
    return new Response(JSON.stringify({ ledgers: [] }), { status: 200, headers: { 'content-type': 'application/json' } });
  };
  try {
    await api.mainRedAttrib();
    await api.mainRedAttrib(5);
  } finally { globalThis.fetch = prev; }
  assert.equal(seen[0], '/api/coord/ledger?kind=main_red_attrib&limit=200');
  assert.equal(seen[1], '/api/coord/ledger?kind=main_red_attrib&limit=5');
});

test('C1 mainRedRevertRows parses the production shape; a bad detail is "-" cells, never a throw', () => {
  const rows = mainRedRevertRows(data);
  assert.equal(rows.length, 3);
  const [a, b, c] = rows;
  assert.equal(a.slug, 'o/r');
  assert.equal(a.sha, SHA);
  assert.equal(a.status, 'gap');
  assert.equal(a.pr, 102);
  assert.equal(a.lane, 'scoped');
  assert.equal(a.risk, 'high');
  assert.deepEqual(a.missed, ['tests/x-test.sh']);
  assert.equal(a.revertUrl, 'https://github.com/o/r/pull/500');
  assert.equal(a.gapUrl, 'https://github.com/o/r/issues/601');
  assert.equal(a.updatedAt, '2026-10-07T03:00:00Z');
  assert.equal(b.revertUrl, null);
  assert.equal(b.gapUrl, null);
  // The bad detail: the key still parses, every detail cell is '-'.
  assert.equal(c.slug, 'p/q');
  assert.equal(c.sha, SHA3);
  assert.equal(c.pr, null);
  for (const k of ['lane', 'risk', 'reason']) assert.equal(c[k], '-', k);
  assert.deepEqual(c.missed, []);
  // Missing / garbage inputs: no rows, no throw.
  assert.deepEqual(mainRedRevertRows(null), []);
  assert.deepEqual(mainRedRevertRows({}), []);
  assert.equal(mainRedRevertRows({ ledgers: [ledger('o/r@x', 'gap', null), null] }).length, 1);
  // A javascript: url is not a link.
  const [evil] = mainRedRevertRows({ ledgers: [ledger(`o/r@${SHA}`, 'gap', detail({ revert_url: 'javascript:alert(1)' }))] });
  assert.equal(evil.revertUrl, null);
  // The bad-detail row renders its cells as '-'.
  const html = view(state({ data: { ledgers: [data.ledgers[2]] } }));
  assert.match(html, /<td[^>]*>-<\/td>/);
});

test('C2 mainRedCounters counts risk tier, lane and map gaps', () => {
  const c = mainRedCounters(mainRedRevertRows(data));
  assert.equal(c.total, 3);
  assert.equal(c.gaps, 1);
  assert.deepEqual(c.byRisk, { high: 1, low: 1, unknown: 1 });
  assert.deepEqual(c.byLane, { scoped: 1, serial: 1, unknown: 1 });
  const z = mainRedCounters([]);
  assert.deepEqual([z.total, z.gaps, z.byRisk, z.byLane],
    [0, 0, { high: 0, low: 0, unknown: 0 }, { scoped: 0, serial: 0, unknown: 0 }]);
});

test('C3 the view links the culprit and the revert, and every header sorts with aria-sort', () => {
  const out = view(state({ data }));
  assert.match(out, /href="https:\/\/github\.com\/o\/r\/pull\/102"/);
  assert.match(out, /href="https:\/\/github\.com\/o\/r\/pull\/500"/);
  assert.match(out, /href="https:\/\/github\.com\/o\/r\/issues\/601"/);
  assert.match(out, />none</, 'no revert url reads "none"');
  for (const label of ['CULPRIT', 'REVERT', 'MAP GAP', 'LANE', 'RISK TIER', 'MISSED SUITES', 'WHEN']) {
    assert.match(out, new RegExp(`<th[^>]*aria-sort="(none|ascending|descending)"[^>]*>\\s*<button[^>]*>\\s*${label}`), label);
  }
  assert.match(out, /tablewrap/, 'the table scrolls in its own container');
  // The counter strip.
  assert.match(out, /TOTAL/);
  assert.match(out, /MAP GAPS/);
  assert.doesNotMatch(out, /newest 200 shown/);
});

test('C4 error, empty, loading and capped states', () => {
  const err = view(state({ error: new Error('boom') }));
  assert.match(err, /could not read the main-red reverts/);
  assert.doesNotMatch(err, /TOTAL|MAP GAPS|stat__value/, 'no counter strip on a failed read');
  assert.doesNotMatch(err, /\d/, 'no counter digits on a failed read');
  // useApi keeps the last data when a poll fails: the failure still wins, so
  // stale counters never read as current.
  const stale = view(state({ error: new Error('boom'), data }));
  assert.match(stale, /could not read the main-red reverts/);
  assert.doesNotMatch(stale, /TOTAL|MAP GAPS|\d/);
  const empty = view(state({ data: { ledgers: [] } }));
  assert.match(empty, /No main-red reverts recorded\./);
  assert.match(view(state({ loading: true })), /class="skel"/);
  const many = { ledgers: Array.from({ length: 200 }, (_, i) =>
    ledger(`o/r@${String(i).padStart(40, '0')}`, 'no-gap', detail({ pr: i + 1 }))) };
  assert.match(view(state({ data: many })), /newest 200 shown; counters cover these only/);
  const five = { ledgers: many.ledgers.slice(0, 5) };
  assert.match(view(state({ data: five }), 5), /newest 5 shown; counters cover these only/);
  assert.doesNotMatch(view(state({ data: five })), /newest \d+ shown/);
});
