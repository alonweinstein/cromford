import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import { sortRows } from '../src/lib/sort.js';
import { usageRows, fmtTokens, unpricedBanner, crossCheckLine, USAGE_WINDOWS } from '../src/lib/account-usage.js';
import { AccountUsageSection, AccountUsageView } from '../src/screens/AccountUsage.js';

// BH-167.3: the ACCOUNT USAGE section on /costs. The payload follows the
// `AccountUsageEntry` JSDoc in worker/jobs/src/lib/account-usage.js; the
// no-login/unmeasured cross_check carries no gap keys, and usd is null (never 0)
// when nothing on the row is priced.

const proj = (project, usd, extra = {}) => ({
  project, calls: 4, usd, unpriced_calls: usd === null ? 4 : 0,
  input_toks: 1200, output_toks: 300, cache_read: 5000, cache_write: 40, ...extra,
});

const fixture = {
  window: '5h', from: '2026-09-24T10:00:00Z', to: '2026-09-24T15:00:00Z',
  accounts: [
    {
      account: 'own:operator', calls: 12, usd: 50, unpriced_calls: 2,
      input_toks: 12345, output_toks: 950, cache_read: 4560000, cache_write: 800, untokened_calls: 0,
      first_ts: '2026-09-24T10:05:00Z', last_ts: '2026-09-24T14:55:00Z',
      projects: [proj('project-5', 40), proj(null, null)],
      meter: { label: 'own:operator', session_pct: 42, weekly_pct: 71, weekly_resets_at: null, extra_used_usd: 50, polls: 9 },
      cross_check: {
        state: 'comparable', meter_delta_usd: 50, rows_usd: 20, unpriced_in_span: 0,
        gap_usd: 30, gap_pct: 60, span_from: '2026-09-24T10:05:00Z', span_to: '2026-09-24T14:55:00Z',
      },
    },
    {
      account: null, calls: 1, usd: null, unpriced_calls: 1,
      input_toks: 0, output_toks: 0, cache_read: 0, cache_write: 0, untokened_calls: 1,
      first_ts: '2026-09-24T11:00:00Z', last_ts: '2026-09-24T11:00:00Z',
      projects: [proj('project-3', null)],
      meter: null,
      cross_check: { state: 'no-login', reason: 'no login on this box' },
    },
    {
      account: 'shared', calls: 3, usd: 5, unpriced_calls: 0,
      input_toks: 100, output_toks: 20, cache_read: 0, cache_write: 0, untokened_calls: 0,
      first_ts: '2026-09-24T12:00:00Z', last_ts: '2026-09-24T13:00:00Z',
      projects: [proj('project-4', 5)],
      meter: { label: 'shared', session_pct: null, weekly_pct: 10, weekly_resets_at: null, extra_used_usd: null, polls: 1 },
      cross_check: { state: 'unmeasured', reason: 'fewer than two polls in span' },
    },
  ],
  totals: { calls: 16, usd: 55, unpriced_calls: 3, input_toks: 12445, output_toks: 970, cache_read: 4560000, cache_write: 800 },
  truncated: { groups: false, projects: false, snapshots: false },
};

const BANNER3 = '3 calls in this window carry no price, so the dollar figures below undercount';
const COLS = ['ACCOUNT', '$', 'CALLS', 'UNPRICED', 'IN TOK', 'OUT TOK', 'CACHE R', 'CACHE W', 'METER 5H %', 'METER WEEK %', 'CROSS-CHECK'];

test('T5a usageRows: null account labelled, null usd sorts last both ways, tokens formatted', () => {
  const rows = usageRows(fixture);
  assert.equal(rows.length, 3);
  const nul = rows.find((r) => r.raw.account === null);
  assert.equal(nul.label, 'no account label');
  assert.equal(nul.usd, null, 'null usd stays null, never 0');
  assert.equal(nul.usdText, '—');
  assert.equal(nul.sessionPct, null);
  assert.equal(nul.sessionText, '—');
  assert.equal(new Set(rows.map((r) => r.key)).size, 3, 'keys are unique, the null account included');

  const desc = sortRows(rows, (r) => r.usd, 'desc');
  assert.deepEqual(desc.map((r) => r.label), ['own:operator', 'shared', 'no account label']);
  const asc = sortRows(rows, (r) => r.usd, 'asc');
  assert.deepEqual(asc.map((r) => r.label), ['shared', 'own:operator', 'no account label']);

  const operator = rows.find((r) => r.label === 'own:operator');
  assert.equal(operator.inText, '12.3k');
  assert.equal(operator.outText, '950');
  assert.equal(operator.crText, '4.56M');
  assert.equal(operator.sessionText, '42%');
  assert.equal(operator.projects.find((p) => p.project === null).name, '(no project)');
  assert.equal(operator.projects.find((p) => p.project === null).usdText, '—');

  assert.equal(fmtTokens(null), '—');
  assert.equal(fmtTokens(undefined), '—');
  assert.equal(fmtTokens(950), '950');
  assert.equal(fmtTokens(12345), '12.3k');
  assert.equal(fmtTokens(4560000), '4.56M');
  assert.deepEqual(usageRows({}), []);
  assert.deepEqual(usageRows(null), []);
  assert.deepEqual(USAGE_WINDOWS.map((w) => w.key), ['5h', '7d']);
});

test('T5b crossCheckLine: comparable format, other states the reason verbatim', () => {
  assert.equal(crossCheckLine(fixture.accounts[0]), 'meter $50.00 vs rows $20.00, gap 60%');
  const nl = crossCheckLine(fixture.accounts[1]);
  assert.equal(nl, 'no login on this box');
  assert.ok(!nl.includes('gap'));
  assert.equal(crossCheckLine(fixture.accounts[2]), 'fewer than two polls in span');
  assert.equal(crossCheckLine({}), '—');
});

test('T5c unpricedBanner: null when nothing is unpriced, the exact sentence at 3', () => {
  assert.equal(unpricedBanner({ totals: { unpriced_calls: 0 } }), null);
  assert.equal(unpricedBanner({}), null);
  assert.equal(unpricedBanner(null), null);
  assert.equal(unpricedBanner({ totals: { unpriced_calls: 3 } }), BANNER3);
  assert.equal(unpricedBanner({ totals: { unpriced_calls: 1 } }),
    '1 call in this window carries no price, so the dollar figures below undercount');
});

test('T5d the view: sortable headers, switcher, toggle, nested project links, banner', () => {
  const out = render(h(AccountUsageView, { data: fixture, win: '5h', onWin() {}, initialOpen: 'own:operator' }));
  assert.ok((out.match(/aria-sort=/g) || []).length >= 11, 'every account column sorts');
  for (const c of COLS) assert.ok(out.includes(`title="sort by ${c.toLowerCase()}"`), `sortable header ${c}`);
  assert.equal((out.match(/aria-pressed="true"/g) || []).length, 1);
  assert.match(out, /aria-pressed="true"[^>]*>5H</);
  assert.match(out, /aria-pressed="false"[^>]*>7D</);
  assert.ok(out.includes('aria-expanded="true"'));
  assert.ok(out.includes('aria-expanded="false"'));
  assert.ok(out.includes('href="/p/project-5"'));
  assert.ok(out.includes('(no project)'));
  assert.ok(!out.includes('href="/p/null"'));
  assert.ok(out.includes(BANNER3));
  assert.equal((out.match(/tablewrap--wide/g) || []).length, 2, 'both the account and the project table are wide');
  assert.ok(!out.includes('$0.00'), 'a null usd is never rendered as zero');
  assert.ok(out.includes('meter $50.00 vs rows $20.00, gap 60%'));
  assert.ok(out.includes('own:operator · projects'));
  assert.ok(out.includes('window 5h'), 'the echoed window is shown');

  const closed = render(h(AccountUsageView, { data: fixture, win: '5h', onWin() {}, initialOpen: null }));
  assert.ok(!closed.includes('href="/p/project-5"'));
  assert.ok(!closed.includes('aria-expanded="true"'));
  assert.equal((closed.match(/tablewrap--wide/g) || []).length, 1, 'the account table alone is wide');

  const noBanner = render(h(AccountUsageView, { data: { ...fixture, totals: { ...fixture.totals, unpriced_calls: 0 } }, win: '7d', onWin() {} }));
  assert.ok(!noBanner.includes('carry no price'));
  assert.match(noBanner, /aria-pressed="true"[^>]*>7D</);

  const capped = render(h(AccountUsageView, { data: { ...fixture, truncated: { groups: false, projects: true, snapshots: false } }, win: '5h', onWin() {} }));
  assert.ok(capped.includes('capped by the worker'));
  assert.ok(!out.includes('capped by the worker'));
});

test('T5e api.accountUsage hits the coord proxy with the window', async () => {
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(String(url));
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true }) };
  };
  await api.accountUsage('7d');
  await api.accountUsage();
  assert.deepEqual(calls, [
    '/api/coord/metrics/account-usage?window=7d',  // determinism: ok asserts the URL api.accountUsage builds against a stubbed fetch; no fixture data is read through the window
    '/api/coord/metrics/account-usage?window=5h',  // determinism: ok asserts the default window in the URL api.accountUsage builds; fetch is stubbed, no data read
  ]);
});

test('T5f loading, error-with-retry and empty are three distinct renders', () => {
  const loading = render(h(AccountUsageView, { loading: true, data: null, win: '5h', onWin() {} }));
  assert.ok(loading.includes('class="skel"'));
  assert.ok(!loading.includes('no usage in this window'));

  const err = render(h(AccountUsageView, { error: new Error('HTTP 500'), data: null, reload() {}, win: '5h', onWin() {} }));
  assert.ok(err.includes('HTTP 500'));
  assert.ok(err.includes('RETRY'));
  assert.ok(!err.includes('no usage in this window'));

  const empty = render(h(AccountUsageView, { data: { ...fixture, accounts: [], totals: { unpriced_calls: 0 } }, win: '5h', onWin() {} }));
  assert.ok(empty.includes('no usage in this window'));
  assert.ok(!empty.includes('carry no price'));
  assert.ok(!empty.includes('aria-sort='));
});

test('T5g the production entry renders and Costs.js mounts it above AnchoredSection', () => {
  const out = render(h(AccountUsageSection));
  assert.ok(out.includes('ACCOUNT USAGE'));
  assert.ok(out.includes('>5H<'));
  assert.ok(out.includes('>7D<'));

  const costs = readFileSync(new URL('../src/screens/Costs.js', import.meta.url), 'utf8');
  assert.ok(costs.includes("import { AccountUsageSection } from './AccountUsage.js';"));
  const at = costs.indexOf('<${AccountUsageSection}/>');
  const anchored = costs.indexOf('<${AnchoredSection}/>');
  assert.ok(at > -1, 'AccountUsageSection is rendered');
  assert.ok(anchored > -1);
  assert.ok(at < anchored, 'directly above AnchoredSection');
  assert.equal(costs.slice(at, anchored).split('\n').length, 2, 'on the line directly above');

  for (const f of ['../src/lib/account-usage.js', '../src/screens/AccountUsage.js']) {
    const src = readFileSync(new URL(f, import.meta.url), 'utf8');
    assert.ok(!/from\s+['"][^'"]*worker\//.test(src), `${f} imports no worker code`);
  }
});
