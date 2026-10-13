import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { whenLabel, countOrNull, usdBasis } from '../src/lib/format.js';
import { plainLabel, tierLabel, TIER_LABEL } from '../src/lib/labels.js';
import { UsdCell } from '../src/ui/UsdCell.js';
import { Legend } from '../src/ui/primitives.js';
import { SortableTable } from '../src/ui/SortableTable.js';
import { assertNoRawHeaders, assertUsdLabelled } from './legibility.bh-3558.js';

// BH-3567 (#3558 child 1): the shared legibility primitives the screen tickets
// adopt. One pinned clock, so no case depends on when the suite runs.
const NOW = Date.UTC(2026, 8, 29, 14, 5);
const ago = (ms) => new Date(NOW - ms).toISOString();

test('H1 whenLabel: relative under a day, dated from a day on', () => {
  assert.equal(whenLabel(ago(3 * 3600e3), NOW), '3h ago');
  assert.equal(whenLabel(ago(4 * 86400e3), NOW), 'Sep 25 14:05Z');
  assert.equal(whenLabel(null, NOW), 'never');
  assert.equal(whenLabel(undefined, NOW), 'never');
  assert.equal(whenLabel('', NOW), 'never');
  assert.equal(whenLabel(new Date(NOW + 60e3).toISOString(), NOW), 'just now');
  assert.equal(whenLabel(ago(59e3), NOW), 'just now');
  assert.equal(whenLabel('not a date', NOW), 'unreadable');
  assert.equal(whenLabel(ago(86400e3), NOW), 'Sep 28 14:05Z');
  assert.equal(whenLabel(ago(86400e3 - 60e3), NOW), '23h ago');
  assert.equal(whenLabel(ago(5 * 60e3), NOW), '5m ago');
  assert.equal(whenLabel(ago(59 * 60e3), NOW), '59m ago');
  assert.equal(whenLabel('2026-09-05T09:03:00Z', NOW), 'Sep 5 09:03Z');
});

test('H2 usdBasis + UsdCell: a dollar figure always carries its basis', () => {
  assert.deepEqual(usdBasis(1.234, 'api'), { text: '$1.23', basis: 'api', label: 'API-eq' });
  assert.equal(usdBasis(2, 'cash').label, 'cash');
  assert.equal(usdBasis(2, 'cash').basis, 'cash');
  assert.equal(usdBasis(3, 'bogus').basis, 'api');
  assert.equal(usdBasis(null).text, 'no data');
  assert.equal(usdBasis('abc').text, 'no data');
  assert.equal(usdBasis(0).text, '$0.00');

  const out = render(h(UsdCell, { value: 1.234, basis: 'api' }));
  assert.match(out, /data-usd-basis="api"/);
  assert.match(out, /\$1\.23/);
  assert.match(out, /<a href="\/costs" class="usd-basis">API-eq<\/a>/);
  assertUsdLabelled(out);

  const cash = render(h(UsdCell, { value: 5, basis: 'cash' }));
  assert.match(cash, /data-usd-basis="cash"/);
  assert.match(cash, />cash<\/a>/);

  const none = render(h(UsdCell, { value: null }));
  assert.match(none, /no data/);
  assert.doesNotMatch(none, /\$/);
});

test('H3 countOrNull: nothing measured, zero and uncapped are three facts', () => {
  assert.equal(countOrNull(null), 'no data');
  assert.equal(countOrNull(undefined), 'no data');
  assert.equal(countOrNull(0), '0');
  assert.equal(countOrNull(null, { uncapped: true }), 'no cap');
  assert.equal(countOrNull(0, { uncapped: true }), '0');
  assert.equal(countOrNull('7'), '7');
  assert.equal(countOrNull('abc'), 'no data');
});

test('H4 labels: tiers and field names in plain words', () => {
  assert.equal(tierLabel(1), 'auto-merge');
  assert.equal(tierLabel(2), 'reviewed merge');
  assert.equal(tierLabel(null), 'no tier');
  assert.equal(tierLabel('2'), 'reviewed merge');
  assert.equal(tierLabel(3), 'tier 3');
  assert.equal(tierLabel(0), 'tier 0');
  assert.equal(TIER_LABEL[1], 'auto-merge');
  assert.equal(plainLabel('MAX_CONCURRENT'), 'max concurrent');
  assert.equal(plainLabel('max_concurrent'), 'max concurrent');
  assert.equal(plainLabel('max concurrent'), 'max concurrent');
  assert.equal(plainLabel('RC'), 'exit code');
  assert.equal(plainLabel(null), '');
});

const ROWS = [{ max: 2, s: 'b', n: 'x' }, { max: 1, s: 'a', n: 'y' }];
const RAW_COLS = [
  { key: 'max', label: 'max concurrent', raw: 'MAX_CONCURRENT', unit: 'jobs', cell: (r) => r.max },
  { key: 's', label: 'selector', cell: (r) => r.s },
  { key: 'n', label: 'note', sort: null, raw: 'NOTE_TEXT', cell: (r) => r.n }
];
// Rendered by SortableTable on main 466cb947 (before raw/unit existed), captured
// verbatim: a table that sets neither field must still render exactly this.
const BASELINE = '<div class="tablewrap"><table class="tbl"><thead><tr><th aria-sort="ascending" class style><button type="button" title="sort by max concurrent">max concurrent<span class="arrow" aria-hidden="true">↑</span></button></th><th aria-sort="none" class style><button type="button" title="sort by selector">selector</button></th><th class style>note</th></tr></thead><tbody><tr class><td class style>1</td><td class style>a</td><td class style>y</td></tr><tr class><td class style>2</td><td class style>b</td><td class style>x</td></tr></tbody></table></div>';

test('H5 SortableTable raw/unit + Legend', () => {
  const out = render(h(SortableTable, { columns: RAW_COLS, rows: ROWS }));
  const ths = out.match(/<th\b[^>]*>[\s\S]*?<\/th>/g);
  assert.equal(ths.length, 3);
  const button = ths[0].match(/<button[\s\S]*?<\/button>/)[0];
  assert.match(button, /max concurrent/);
  assert.match(button, /<span class="th-unit">jobs<\/span>/);
  assert.doesNotMatch(button, /MAX_CONCURRENT/);
  assert.match(ths[0], /<\/button><span class="th-raw">MAX_CONCURRENT<\/span><\/th>/);
  assert.match(ths[0], /aria-sort="ascending"/);
  assert.match(ths[1], /aria-sort="none"/);
  assert.match(ths[0], /title="sort by max concurrent"/);
  // unsortable column still carries its raw name
  assert.match(ths[2], /^<th class style>note<span class="th-raw">NOTE_TEXT<\/span><\/th>$/);

  const plainCols = RAW_COLS.map(({ raw, unit, ...rest }) => rest);
  const plain = render(h(SortableTable, { columns: plainCols, rows: ROWS }));
  assert.equal(plain, BASELINE);
  assert.doesNotMatch(plain, /th-raw|th-unit/);

  const legend = render(h(Legend, { items: [{ term: 'API-eq', text: 'list price times tokens, not cash' }] }));
  assert.match(legend, /^<dl class="legend">/);
  assert.equal((legend.match(/<dt>/g) || []).length, 1);
  assert.equal((legend.match(/<dd>/g) || []).length, 1);
  assert.match(legend, /<dt>API-eq<\/dt><dd>list price times tokens, not cash<\/dd>/);
  assert.equal(render(h(Legend, { items: [] })), '');
  assert.equal(render(h(Legend, {})), '');
});

test('H6 the assertion helpers are not vacuous', () => {
  assert.throws(() => assertNoRawHeaders('<table><tr><th>MAX_CONCURRENT</th></tr></table>'));
  assert.doesNotThrow(() => assertNoRawHeaders('<th><button>max concurrent</button><span class="th-raw">MAX_CONCURRENT</span></th>'));
  assertNoRawHeaders(render(h(SortableTable, { columns: RAW_COLS, rows: ROWS })));

  assert.throws(() => assertUsdLabelled('<td>$1.00</td>'));
  assert.doesNotThrow(() => assertUsdLabelled('<td><span data-usd-basis="api">$1.00 <a>API-eq</a></span></td>'));
  assert.doesNotThrow(() => assertUsdLabelled('<td title="$1.00">no data</td>'));
  assert.throws(() => assertUsdLabelled('<span data-usd-basis="api">$1</span><br><td>$2.00</td>'));
  assert.doesNotThrow(() => assertUsdLabelled('<!-- c --><span data-usd-basis="api"><img src="x"/>$1</span>'));
});
