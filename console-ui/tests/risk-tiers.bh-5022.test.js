import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';

// BH-5022: the risk tier of each PR head in Mission Control. The pure lib is
// driven directly; the MERGE QUEUE screen's RISK TIERS section and the PR
// screen's headline facts are rendered server-side (the CiHealth / MergeQueue
// split), and the api helper is driven against a stubbed fetch.

globalThis.window = globalThis.window || {
  location: { pathname: '/merge-queue', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};

const { render } = await import('preact-render-to-string');
const { api } = await import('../src/api.js');
const { riskTierRows, TIER_ORDER, RISK_TIERS, normTier, liveHeadTier, RISK_READ_LIMIT } = await import('../src/lib/risk-tiers.js');
const { MergeQueueView } = await import('../src/screens/MergeQueue.js');
const { PRStats } = await import('../src/screens/PR.js');

const HEAD_A = 'a'.repeat(40);
const HEAD_B = 'b'.repeat(40);
const T1 = '2026-10-06T10:00:00Z';
const T2 = '2026-10-06T11:00:00Z';
const T3 = '2026-10-06T12:00:00Z';
const row = (id, tier, over = {}) => ({
  id, repo: 'example-org/cromford', pr: 4000 + id, head_sha: HEAD_A, project: 'cromford',
  tier, mode: 'enforce', action: tier === 'low' ? 'signed' : 'requested',
  reasons: `reason ${id}`, lines: 10, files: 1, created_at: T1, ...over
});
const okRes = (data) => ({ data, error: null, loading: false, reload() {} });
const errRes = (msg = 'boom') => ({ data: null, error: new Error(msg), loading: false, reload() {} });
const visible = (s) => s.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ');

// ------------------------------------------------------------ E1 the lib

test('E1 riskTierRows: a tier keeps only its rows; null / all keeps every row; no data is []', () => {
  const data = { rows: [row(1, 'low'), row(2, 'high'), row(3, 'low'), row(4, 'medium')], truncated: false };
  assert.deepEqual(riskTierRows(data, 'low').map((r) => r.id), [1, 3]);
  assert.deepEqual(riskTierRows(data, 'high').map((r) => r.id), [2]);
  assert.deepEqual(riskTierRows(data, null).map((r) => r.id), [1, 2, 3, 4]);
  assert.deepEqual(riskTierRows(data, 'all').map((r) => r.id), [1, 2, 3, 4]);
  assert.deepEqual(riskTierRows(null, 'low'), []);
  assert.deepEqual(riskTierRows({}, null), []);
  assert.deepEqual(riskTierRows({ rows: 'x' }, null), []);
  assert.ok(TIER_ORDER.low < TIER_ORDER.medium && TIER_ORDER.medium < TIER_ORDER.high);
  assert.deepEqual(RISK_TIERS, ['low', 'medium', 'high']);
  assert.equal(normTier('HIGH'), 'high');
  assert.equal(normTier('junk'), null);
  assert.equal(normTier(null), null);
  assert.equal(RISK_READ_LIMIT, 200);
});

test('E1 liveHeadTier: the row for the live head, newest first; none or no head is null', () => {
  const rows = [row(1, 'low', { head_sha: HEAD_B }), row(2, 'high', { head_sha: HEAD_A })];
  assert.equal(liveHeadTier(rows, HEAD_A).id, 2);
  assert.equal(liveHeadTier(rows, HEAD_B).id, 1);
  assert.equal(liveHeadTier(rows, 'c'.repeat(40)), null);
  assert.equal(liveHeadTier(rows, null), null);
  assert.equal(liveHeadTier(null, HEAD_A), null);
});

test('E1 api.riskTiers reads GET /api/coord/risk-tiers with only the filters given', async () => {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    seen.push({ url: String(url), method: init.method || 'GET' });
    return new Response('{"rows":[],"truncated":false}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  try {
    await api.riskTiers({ repo: 'example-org/cromford', pr: 41 });
    await api.riskTiers({ tier: 'low', limit: 200 });
    await api.riskTiers();
  } finally { globalThis.fetch = real; }
  assert.equal(seen[0].url, '/api/coord/risk-tiers?repo=example-org%2Fcromford&pr=41');
  assert.equal(seen[1].url, '/api/coord/risk-tiers?tier=low&limit=200');
  assert.equal(seen[2].url, '/api/coord/risk-tiers');
  assert.ok(seen.every((s) => s.method === 'GET'));
});

// ------------------------------------------------------------ E2 / E4 the merge-queue section

const baseProps = (over = {}) => ({
  project: null,
  mq: [okRes({ merge_queue: [] }), okRes({ merge_queue: [] }), okRes({ merge_queue: [] })],
  held: okRes({ rows: [], n_total: 0 }),
  mqChanges: okRes({ changes: [] }),
  heldChanges: okRes({ changes: [] }),
  setting: okRes({ key: 'merge_queue_rows_only', setting: null, source: 'none' }),
  reload() {},
  risk: okRes({ rows: [row(1, 'low', { created_at: T1 }), row(2, 'high', { created_at: T3, project: null, repo: 'example-org/project-3' }), row(3, 'medium', { created_at: T2 })], truncated: false }),
  tier: null,
  onTier() {},
  ...over
});
const view = (over) => render(h(MergeQueueView, baseProps(over)));
// The RISK TIERS section only: it sits between MERGE QUEUE and HELD PAGES.
const riskPart = (out) => out.slice(out.indexOf('RISK TIERS'), out.indexOf('HELD PAGES'));

test('E2 RISK TIERS: a sortable table whose PR cell links to /pr/<project>/<n>', () => {
  const out = view();
  assert.match(out, /RISK TIERS/);
  const part = riskPart(out);
  assert.match(part, /aria-sort/, 'the shared SortableTable');
  assert.match(part, /href="\/pr\/cromford\/4001"/);
  // No project on the row: the repo's name part.
  assert.match(part, /href="\/pr\/project-3\/4002"/);
  // HEAD is the first 12 characters, the full sha in title.
  assert.match(part, new RegExp(`>${'a'.repeat(12)}<`));
  assert.doesNotMatch(visible(part), new RegExp('a'.repeat(13)));
  // TIER is an uppercase tag; reasons, action and mode are shown.
  for (const s of ['HIGH', 'LOW', 'MEDIUM', 'reason 2', 'signed', 'enforce']) assert.match(visible(part), new RegExp(s));
  // WHEN desc by default: T3 (4002), T2 (4003), T1 (4001).
  const at = (n) => part.indexOf(`/${n}"`);
  assert.ok(at(4002) < at(4003) && at(4003) < at(4001), 'newest first');
  // It scrolls in its own container.
  assert.match(part, /tablewrap--wide/);
});

test('E2 the filter buttons carry aria-pressed and follow the tier prop', () => {
  const all = riskPart(view());
  for (const label of ['ALL', 'LOW', 'MEDIUM', 'HIGH']) {
    assert.match(all, new RegExp(`aria-pressed="(true|false)"[^>]*>\\s*${label}\\s*<`), label);
  }
  assert.match(all, /aria-pressed="true"[^>]*>\s*ALL\s*</);
  assert.match(all, /aria-pressed="false"[^>]*>\s*LOW\s*</);
  const low = riskPart(view({ tier: 'low' }));
  assert.match(low, /aria-pressed="true"[^>]*>\s*LOW\s*</);
  assert.match(low, /aria-pressed="false"[^>]*>\s*ALL\s*</);
  // The rows filter with it.
  assert.match(low, /\/pr\/cromford\/4001"/);
  assert.doesNotMatch(low, /\/pr\/project-3\/4002"/);
  assert.doesNotMatch(low, /\/pr\/cromford\/4003"/);
  const high = riskPart(view({ tier: 'high' }));
  assert.match(high, /\/pr\/project-3\/4002"/);
  assert.doesNotMatch(high, /\/pr\/cromford\/4001"/);
});

test('E2 truncated says so', () => {
  const out = riskPart(view({ risk: okRes({ rows: [row(1, 'low')], truncated: true }) }));
  assert.match(visible(out), /newest 200/);
  assert.doesNotMatch(visible(riskPart(view())), /newest 200/);
});

test('E4 an empty list renders the Empty text; a failed load renders the ErrorBox with RETRY', () => {
  const empty = riskPart(view({ risk: okRes({ rows: [], truncated: false }) }));
  assert.match(empty, /class="empty"/);
  assert.match(visible(empty), /no PR heads classified/);
  const filteredEmpty = riskPart(view({ tier: 'high', risk: okRes({ rows: [row(1, 'low')], truncated: false }) }));
  assert.match(visible(filteredEmpty), /no high-risk heads/);
  const failed = riskPart(view({ risk: errRes('coord 502') }));
  assert.match(visible(failed), /could not load/);
  assert.match(visible(failed), /coord 502/);
  assert.match(failed, />RETRY</);
  assert.doesNotMatch(failed, /class="empty"/);
});

// ------------------------------------------------------------ E3 the PR facts

const stats = (risk, liveHead = HEAD_A) =>
  render(h(PRStats, { builds: [], data: {}, gh: null, checks: null, risk, liveHead }));

test('E3 the PR facts show the live head\'s tier and reasons', () => {
  const rows = [row(1, 'low', { head_sha: HEAD_B, reasons: 'docs/tests/screens only, 4 lines' }),
    row(2, 'high', { head_sha: HEAD_A, reasons: 'touches .mergify.yml' })];
  const v = visible(stats(okRes({ rows, truncated: false })));
  assert.match(v, /RISK TIER/);
  assert.match(v, /HIGH/);
  assert.match(v, /touches \.mergify\.yml/);
  assert.doesNotMatch(v, /docs\/tests\/screens only/);
  const lowV = visible(stats(okRes({ rows, truncated: false }), HEAD_B));
  assert.match(lowV, /LOW/);
  assert.match(lowV, /docs\/tests\/screens only/);
});

test('E3 no row for the live head is not classified; a failed load is distinct from none', () => {
  const none = visible(stats(okRes({ rows: [row(1, 'high', { head_sha: HEAD_B })], truncated: false })));
  assert.match(none, /not classified/);
  assert.doesNotMatch(none, /HIGH/);
  assert.match(visible(stats(okRes({ rows: [] }))), /not classified/);
  const failed = visible(stats(errRes('coord 502')));
  assert.match(failed, /unreadable/);
  assert.doesNotMatch(failed, /not classified/);
});
