import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { assertNoRawHeaders, assertUsdLabelled } from './legibility.bh-3558.js';

// BH-3571 (BH-3558.4): /hub, /ci, /config and /config/:kind/:name legibility.
// Every View is rendered server-side from props and handed to both #3558
// helpers. Legend terms are read from the <dl class="legend"> markup with
// attributes stripped, so a term that only lives in a title="" never counts.

globalThis.window = globalThis.window || {
  location: { pathname: '/config', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { HubView, BACKUP_COLUMNS } = await import('../src/screens/Hub.js');
const { CiHealthView, repoColumns, historyColumns } = await import('../src/screens/CiHealth.js');
const { ConfigView, CONFIG_KIND_MEANING } = await import('../src/screens/Config.js');
const { ConfigDetailView } = await import('../src/screens/ConfigDetail.js');
const { CONFIG_KINDS } = await import('../../worker/jobs/src/lib/config-changes.js');
const { backupRows } = await import('../src/lib/hub.js');
const { sortRows } = await import('../src/lib/sort.js');

const NOW = Date.parse('2026-09-29T14:05:00Z');
const noop = () => {};
const both = (out) => { assertNoRawHeaders(out); assertUsdLabelled(out); };

// Visible text: attributes gone first, then the tags.
const visible = (s) => String(s).replace(/<([a-zA-Z0-9-]+)\b[^>]*>/g, '<$1>').replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
// Every legend on the page as [{term, text}], read from the markup.
function legends(out) {
  return (String(out).match(/<dl class="legend">[\s\S]*?<\/dl>/g) || []).map((dl) =>
    [...dl.matchAll(/<dt>([\s\S]*?)<\/dt>\s*<dd>([\s\S]*?)<\/dd>/g)].map((m) => ({ term: visible(m[1]), text: visible(m[2]) })));
}
const legendItem = (out, term) => legends(out).flat().find((i) => i.term === term);
const assertLegend = (out, term, textRe) => {
  const it = legendItem(out, term);
  assert.ok(it, `legend term ${term} is visible (legends: ${JSON.stringify(legends(out))})`);
  assert.ok(it.text.length > 0, `legend term ${term} has text`);
  if (textRe) assert.match(it.text, textRe, term);
  assert.ok(visible(out).includes(term), `${term} is visible text, not only an attribute`);
};

// ---------------------------------------------------------------- /ci

const BH = 'example-org/cromford';
const TS = 'example-org/project-5';
const flake = (repo, t, head, kind = 'flake', day = '2026-09-25', workflow = 'harness-ci') =>
  ({ repo, workflow, test: t, head, kind, day, created_at: `${day}T10:00:00Z` });
const qrow = (repo, t, active = 1) =>
  ({ repo, test: t, active, actor: 'console', reason: 'flaky on arm', updated_at: '2026-09-24T09:00:00Z' });
const hrow = (repo, metric, payload) => ({ repo, metric, payload, box: 'hub', as_of: '2026-09-26T10:00:00Z' });
const loaded = (data) => ({ data, error: null, loading: false, reload: noop });
const CI = {
  health: loaded({ rows: [hrow(BH, 'minutes', { est_24h: 42 }), hrow(BH, 'runners', { online: 2, total: 3 })] }),
  flakes: loaded({ flakes: [flake(BH, 't1', 'A'), flake(BH, 'job:build', 'B'), flake(TS, 't9', 'C')] }),
  quarantine: loaded({ rows: [qrow(BH, 'old-flake')] }),
};
const CHANGES_CI = [
  { id: 3, repo: BH, test: 'old-flake', before_active: 1, after_active: 0, actor: 'a', reason: 'r3', at: '2026-09-26T09:00:00Z' },
  { id: 2, repo: BH, test: 'old-flake', before_active: 0, after_active: 1, actor: 'b', reason: 'r2', at: '2026-09-24T09:00:00Z' },
  { id: 1, repo: BH, test: 'old-flake', before_active: null, after_active: 0, actor: 'c', reason: 'r1', at: '2026-09-20T09:00:00Z' },
];
const ciView = (props = {}) => render(h(CiHealthView, { onToggle: noop, onOpen: noop, pending: null, msg: null, ...CI, ...props }));
const ths = (out) => String(out).match(/<th\b[^>]*>[\s\S]*?<\/th>/g) || [];

test('H1: FLAKE RATE says its 7 day window; every CI header keeps aria-sort', () => {
  const out = ciView();
  const rate = ths(out).find((th) => visible(th).includes('FLAKE RATE'));
  assert.ok(rate, 'FLAKE RATE header present');
  assert.match(visible(rate), /FLAKE RATE\s*7 days/);
  assert.match(rate, /<span class="th-unit">7 days<\/span>/);
  both(out);

  const full = ciView({
    repo: BH,
    repoFlakes: loaded({ flakes: [flake(BH, 't1', 'A'), flake(BH, 'job:build', 'B')] }),
    repoQuarantine: loaded({ rows: [qrow(BH, 'old-flake')] }),
    open: 'old-flake',
    history: loaded({ changes: CHANGES_CI }),
  });
  const all = ths(full);
  assert.equal(all.length, 6 + 4 + 4, 'repos + flakes + history headers');
  for (const th of all) assert.match(th, /^<th\b[^>]*aria-sort="/, th);
  both(full);
});

test('H2: history CHANGE sorts on the numeric after state; MINUTES 24H sorts on a number or null', () => {
  const change = historyColumns.find((c) => c.key === 'change');
  assert.equal(typeof change.sort, 'function');
  for (const c of CHANGES_CI) assert.equal(typeof change.sort(c), 'number', `change accessor for id ${c.id}`);
  assert.deepEqual(sortRows(CHANGES_CI, change.sort, 'asc').map((c) => c.id), [3, 1, 2]);
  assert.deepEqual(sortRows(CHANGES_CI, change.sort, 'desc').map((c) => c.id), [2, 3, 1]);

  const mins = repoColumns.find((c) => c.key === 'minutes24h');
  assert.equal(typeof mins.sort, 'function', 'MINUTES 24H has an explicit accessor');
  assert.equal(mins.sort({ minutes24h: 42 }), 42);
  assert.equal(mins.sort({ minutes24h: null, minutesState: 'unread' }), null);
  for (const key of ['flakes7d', 'flakeRate', 'quarantined']) {
    const col = repoColumns.find((c) => c.key === key);
    assert.equal(typeof col.sort, 'function', `${key} has an explicit accessor`);
    assert.equal(col.sort({ [key]: 3 }), 3, key);
    assert.equal(col.sort({ [key]: null }), null, key);
  }
});

// ---------------------------------------------------------------- /hub

const HUB_NOW = Date.parse('2026-09-24T15:00:00Z');
const RECOVERY = {
  lease: { holder: 'hub-1', epoch: 7, expires_at: new Date(HUB_NOW + 90000).toISOString(), updated_at: new Date(HUB_NOW - 30000).toISOString(), live: true },
  role: { active: 'hub-1', standby: [] },
  backups: [
    { box: 'hub-1', backup_ts: '2026-09-24T14:48:00Z', backup_off: null, backup_unconfigured: null, backup_reported_at: '2026-09-24T14:50:00Z' },
    { box: 'hub-2', backup_ts: '', backup_off: null, backup_unconfigured: null, backup_reported_at: '2026-09-24T14:50:00Z' },
  ]
};
const hubView = (data) => render(h(HubView, {
  state: { data, error: null, loading: false, fetchedAt: HUB_NOW }, now: HUB_NOW, onReload: noop, onPromote: noop, promoteMsg: null
}));

test('H3: HUB passes both helpers and explains the BACKUPS columns; STATE sorts worst first', () => {
  const out = hubView(RECOVERY);
  both(out);
  assertLegend(out, 'STATE', /recent enough/);
  assertLegend(out, 'AGE', /newest backup/);
  assertLegend(out, 'LAST REPORTED', /told the hub/);

  const rows = backupRows({ backups: [
    { box: 'fresh', backup_ts: '2026-09-24T14:50:00Z', backup_reported_at: '2026-09-24T14:58:00Z' },
    { box: 'silent', backup_ts: null, backup_reported_at: null },
    { box: 'stale', backup_ts: '2026-09-24T13:00:00Z', backup_reported_at: '2026-09-24T14:58:00Z' },
    { box: 'never', backup_ts: '', backup_reported_at: '2026-09-24T14:58:00Z' },
  ] }, HUB_NOW);
  assert.deepEqual(rows.map((r) => r.badge.tone), ['ok', 'unknown', 'warn', 'dead'], 'fixture covers every tone');
  const state = BACKUP_COLUMNS.find((c) => c.key === 'state');
  assert.deepEqual(sortRows(rows, state.sort, 'asc').map((r) => r.box), ['never', 'stale', 'silent', 'fresh']);
  assert.deepEqual(sortRows(rows, state.sort, 'desc').map((r) => r.box), ['fresh', 'silent', 'stale', 'never']);
  assert.equal(state.sort({ box: 'x', badge: { tone: 'mystery' } }), 4, 'an unknown tone sinks');
});

// ---------------------------------------------------------------- /config

const AT = new Date(NOW - 5 * 60000).toISOString();
const setting = (key, value = '1', actor = 'seed') => ({ key, value, note: 'why it exists', actor, updated_at: AT });
const CONFIG = {
  settings: loaded({ settings: [setting('gh.quota.reserve', '600', 'hub-1'), setting('hub.promote_enabled')] }),
  flags: loaded({ flags: [{ name: 'pause-all', active: 0, actor: 'console', reason: 'drill over', updated_at: AT }] }),
  changes: { loading: false, error: null, data: { changes: [
    { id: 2, kind: 'cost_cap', name: 'conf.cost-caps.day', actor: 'console', reason: 'raise', at: AT },
    { id: 1, kind: 'setting', name: 'gh.quota.reserve', actor: 'hub-1', reason: null, at: AT },
  ], truncated: false } },
};
const configView = (over = {}) => render(h(ConfigView, {
  ...CONFIG, filter: '', showLane: false, onFilter: noop, onShowLane: noop, onEdit: noop, onToggle: noop, busy: false, note: null, ...over
}));

test('H4a: CONFIG_KIND_MEANING covers exactly the worker kinds, each in plain words', () => {
  assert.deepEqual(Object.keys(CONFIG_KIND_MEANING).sort(), Object.values(CONFIG_KINDS).sort());
  for (const [k, v] of Object.entries(CONFIG_KIND_MEANING)) {
    assert.equal(typeof v, 'string', k);
    assert.ok(v.length > 5, k);
    assert.doesNotMatch(v, /—/, `${k}: no em dash in new copy`);
  }
});

test('H4: /config KIND reads in words with a kind legend; the field legend names every column', () => {
  const out = configView();
  both(out);
  const cells = String(out).match(/<tr\b[^>]*>(?:(?!<\/tr>)[\s\S])*conf\.cost-caps\.day[\s\S]*?<\/tr>/)[0].match(/<td\b[^>]*>[\s\S]*?<\/td>/g);
  assert.equal(visible(cells[1]), 'cost cap', 'RECENT CHANGES KIND cell');
  assert.match(cells[1], /title="cost_cap"/, 'raw kind kept in the title');
  assertLegend(out, 'cost cap', new RegExp(CONFIG_KIND_MEANING.cost_cap));
  assertLegend(out, 'setting', new RegExp(CONFIG_KIND_MEANING.setting));
  assert.equal(legendItem(out, 'flag'), undefined, 'only kinds present in the rows are explained');
  for (const term of ['VALUE', 'LAST WRITER', 'UPDATED', 'NOTE', 'STATE']) assertLegend(out, term);
  assertLegend(out, 'STATE', /ON/);
  // The existing copy guards still hold with the legends on the page.
  assert.doesNotMatch(out, /NEW KEY|ADD KEY|>ADD</i);
  assert.doesNotMatch(out, /no flags|no settings rows|could not load/);
  assert.equal((out.match(/>EDIT</g) || []).length, 2);
});

// ---------------------------------------------------------------- /config/:kind/:name

const hist = (kind, name, res) => ({ data: { kind, name, res }, error: null, loading: false });
const detail = (props) => render(h(ConfigDetailView, { known: true, onRetryHistory: noop, onRetryCurrent: noop, ...props }));
const title = (out) => visible((String(out).match(/<span class="page-title"[^>]*>[\s\S]*?<\/span>/) || [''])[0]);

test('H5: the detail title names the kind in words, says what the kind is, and CURRENT has a legend', () => {
  const name = 'review.approve_min';
  const rg = detail({ kind: 'review_gate_threshold', name,
    history: hist('review_gate_threshold', name, { changes: [], truncated: false }), current: { data: null, error: null, loading: false } });
  assert.equal(title(rg), `review gate threshold · ${name}`);
  assert.ok(visible(rg).includes(CONFIG_KIND_MEANING.review_gate_threshold), 'meaning line');
  assert.match(rg, new RegExp(`<p class="section__note">${CONFIG_KIND_MEANING.review_gate_threshold}</p>`));
  both(rg);

  const st = detail({ kind: 'setting', name: 'k',
    history: hist('setting', 'k', { changes: [], truncated: false }),
    current: hist('setting', 'k', { key: 'k', setting: { key: 'k', value: '800', actor: 'operator', note: 'why', updated_at: AT } }) });
  assert.equal(title(st), 'setting · k');
  assert.ok(visible(st).includes(CONFIG_KIND_MEANING.setting));
  for (const term of ['VALUE', 'LAST WRITER', 'UPDATED', 'NOTE']) assertLegend(st, term);
  both(st);

  const fl = detail({ kind: 'flag', name: 'x',
    history: hist('flag', 'x', { changes: [], truncated: false }),
    current: hist('flag', 'x', { flags: [{ name: 'x', active: 1, actor: 'operator', reason: 'r', updated_at: AT }] }) });
  for (const term of ['STATE', 'LAST WRITER', 'UPDATED', 'REASON']) assertLegend(fl, term);
  both(fl);

  const bogus = detail({ kind: 'bogus', name: 'x', known: false, history: null, current: null });
  assert.equal(title(bogus), 'bogus · x');
  assert.doesNotMatch(bogus, /class="section__note"/, 'an unknown kind has no meaning line');
  assert.match(bogus, /unknown kind: bogus/);
});
