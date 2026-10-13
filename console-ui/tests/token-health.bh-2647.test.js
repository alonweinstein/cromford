import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { healthRows, warnNote, truncatedNote, expiresText } from '../src/lib/token-health.js';
import { TokenHealthView } from '../src/screens/TokenHealth.js';
import { SettingsView } from '../src/screens/Settings.js';
import { tabsFrom } from '../src/lib/settings.js';
import { api } from '../src/api.js';

// BH-2647 (BH-2516.3): the read-only ACCOUNT & TOKEN HEALTH panel on the hub
// tab of /settings. Fixtures follow the response shape in the JSDoc on the
// stub route, worker/jobs/src/routes/account-leases.js (GET
// /api/account-leases/health). Red is the worker's `expiring`, never a clock
// rule re-derived here.

const acct = (over) => ({
  kind: 'oauth', subject: 'x', box: 'hub', live_leases: 0, leases: [],
  expires_at: null, expires_in_s: null, expiring: false,
  last_ok_at: null, last_attempt_at: null, last_ok: null, fail_count: 0, last_error: null,
  reported: true, ...over,
});

const accounts = [
  acct({ subject: 'two-h', expires_in_s: 7200, expiring: true, expires_at: '2026-09-27T04:00:00Z',
    last_ok_at: '2026-09-27T01:00:00Z', box: 'project-3',
    live_leases: 1, leases: [{ machine_id: 'm-1', box: 'project-3', project: 'project-3', ticket_key: 'TK-9', expires_at: '2026-09-27T02:10:00Z' }] }),
  acct({ subject: 'forty-eight-h', kind: 'gh_app', expires_in_s: 172800, expiring: false, fail_count: 3, last_error: 'http_401' }),
  acct({ subject: 'expired', expires_in_s: -1200, expiring: true }),
  acct({ subject: 'unknown', expires_in_s: null, expiring: false }),
  acct({ subject: 'lease-only', reported: false, expiring: false, fail_count: undefined, box: null }),
];

// Invariant (c): the adversarial negatives and the inverse. The client does
// not re-derive red from expires_in_s, in either direction.
const adversarial = [
  acct({ subject: 'false-but-close', expires_in_s: 7200, expiring: false }),
  acct({ subject: 'undef', expires_in_s: 60, expiring: undefined }),
  acct({ subject: 'string-true', expires_in_s: 60, expiring: 'true' }),
  acct({ subject: 'null-null', expires_in_s: null, expiring: null }),
  acct({ subject: 'far-but-true', expires_in_s: 172800, expiring: true }),
];

const data = { accounts, warn_h: 24, warn_h_source: 'default', as_of: '2026-09-27T02:00:00Z', truncated: { leases: false, tokens: false } };

test('A1: red is exactly the worker\'s expiring === true; kind labels', () => {
  const rows = healthRows({ ...data, accounts: [...accounts, ...adversarial] });
  const want = [...accounts, ...adversarial];
  assert.equal(rows.length, want.length);
  rows.forEach((r, i) => assert.equal(r.red, want[i].expiring === true, r.subject));
  const by = Object.fromEntries(rows.map((r) => [r.subject, r]));
  assert.equal(by['far-but-true'].red, true, 'the worker wins over a far expiry');
  assert.equal(by['false-but-close'].red, false, 'no client clock rule');
  assert.equal(by['two-h'].kindLabel, 'OAuth');
  assert.equal(by['forty-eight-h'].kindLabel, 'GH App');
  assert.equal(healthRows({ accounts: [acct({ kind: 'weird' })] })[0].kindLabel, 'weird');
  assert.equal(by['two-h'].leaseCount, 1);
});

test('A2: expiry text', () => {
  assert.equal(expiresText(11400), 'in 3h 10m');
  assert.equal(expiresText(-1200), 'expired 20m ago');
  assert.equal(expiresText(null), '—');
  assert.equal(expiresText(600), 'in 10m');
  const by = Object.fromEntries(healthRows(data).map((r) => [r.subject, r]));
  assert.equal(by.unknown.expiresText, '—');
  assert.equal(by.unknown.expiresInS, null);
  assert.equal(by.expired.expiresText, 'expired 20m ago');
});

test('A3: fail count 0 is 0, absent is —; last refresh null is never', () => {
  const by = Object.fromEntries(healthRows(data).map((r) => [r.subject, r]));
  assert.equal(by['two-h'].failCount, 0);
  assert.equal(by['lease-only'].failCount, null);
  const html = render(h(TokenHealthView, { data: { ...data, accounts: [accounts[0]] } }));
  const cells = [...html.matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map((m) => m[1].replace(/<[^>]+>/g, '').trim());
  assert.equal(cells[5], '0', 'FAILS cell renders 0');
  const html2 = render(h(TokenHealthView, { data: { ...data, accounts: [accounts[4]] } }));
  const cells2 = [...html2.matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map((m) => m[1].replace(/<[^>]+>/g, '').trim());
  assert.equal(cells2[5], '—', 'absent fail count is unknown, not zero');
  assert.equal(cells2[4], 'never', 'no last_ok_at');
});

test('A4: last_error, noReport, and junk input is an empty list', () => {
  const by = Object.fromEntries(healthRows(data).map((r) => [r.subject, r]));
  assert.equal(by['forty-eight-h'].lastError, 'http_401');
  assert.equal(by['two-h'].lastError, null);
  assert.equal(by['lease-only'].noReport, true);
  assert.equal(by['two-h'].noReport, false);
  for (const d of [null, undefined, 'x', {}, { accounts: 'x' }]) assert.deepEqual(healthRows(d), []);
});

test('A5: warnNote', () => {
  assert.equal(warnNote({ warn_h: 24, warn_h_source: 'default' }), 'Red = under 24 h to expiry (default)');
  assert.equal(warnNote({ warn_h: 6, warn_h_source: 'settings' }), 'Red = under 6 h to expiry (set in settings)');
  assert.equal(warnNote({}), null);
  assert.equal(warnNote(null), null);
});

const view = (over = {}) => render(h(TokenHealthView, { data, error: null, loading: false, onRetry: () => {}, ...over }));
const rowsOf = (html) => [...html.matchAll(/<tr[^>]*>[\s\S]*?<\/tr>/g)].map((m) => m[0]).slice(1);

test('R1: title, column order, red marker, warn note, own scroll box', () => {
  const html = view();
  assert.ok(html.includes('ACCOUNT &amp; TOKEN HEALTH'));
  const heads = [...html.split('</thead>')[0].matchAll(/<th[\s\S]*?<\/th>/g)]
    .map((m) => m[0].replace(/<[^>]+>/g, '').replace(/[↑↓]/g, '').trim());
  assert.deepEqual(heads, ['KIND', 'ACCOUNT', 'LEASES', 'EXPIRES', 'LAST REFRESH', 'FAILS', 'LAST ERROR', 'BOX']);
  const tr = rowsOf(html);
  const red = tr.find((t) => t.includes('two-h'));
  const green = tr.find((t) => t.includes('forty-eight-h'));
  assert.match(red, /<tr[^>]*class="[^"]*cell--red/);
  assert.ok(red.includes('EXPIRING'));
  assert.doesNotMatch(green, /cell--red/);
  assert.ok(!green.includes('EXPIRING'));
  assert.ok(html.includes('Red = under 24 h to expiry (default)'));
  assert.ok(html.includes('tablewrap tablewrap--wide'));
  assert.ok(red.includes('href="/machines"'), 'BOX is not a dead cell');
});

test('R2: default sort is expiry ascending, unknown last', () => {
  const order = rowsOf(view()).map((t) => ['two-h', 'forty-eight-h', 'expired', 'unknown', 'lease-only'].find((s) => t.includes(`>${s}<`)));
  assert.deepEqual(order.slice(0, 3), ['expired', 'two-h', 'forty-eight-h']);
  assert.deepEqual(order.slice(3).sort(), ['lease-only', 'unknown']);
});

test('R3: EXPIRES is the default sort header, aria-sort ascending (fallback: no DOM harness)', () => {
  const ths = [...view().matchAll(/<th[^>]*aria-sort="([a-z]+)"[\s\S]*?<\/th>/g)];
  const exp = ths.find((m) => m[0].includes('EXPIRES'));
  assert.equal(exp[1], 'ascending');
  assert.equal(ths.filter((m) => m[1] !== 'none').length, 1);
});

test('R4: an expanded ACCOUNT shows its leases with a /p/<project> link', () => {
  const closed = view();
  assert.match(closed, /<button[^>]*aria-expanded="false"[^>]*>[\s\S]*?two-h/);
  assert.ok(!closed.includes('href="/p/project-3"'));
  const open = view({ initialExpanded: ['oauth:two-h'] });
  assert.match(open, /<button[^>]*aria-expanded="true"[^>]*>[\s\S]*?two-h/);
  assert.ok(open.includes('href="/p/project-3"'));
  assert.ok(open.includes('TK-9') && open.includes('m-1'));
  for (const hdr of ['MACHINE', 'PROJECT', 'TICKET']) assert.ok(open.includes(hdr), hdr);
  const none = view({ initialExpanded: ['oauth:unknown'] });
  assert.ok(none.includes('no live leases'));
});

test('R5: loading shows a skeleton only', () => {
  const html = view({ loading: true, data: null });
  assert.ok(html.includes('class="skel"'));
  assert.ok(!html.includes('<table'));
  assert.ok(!html.includes('no accounts reported'));
});

test('R6: a failed read is RETRY, never the empty copy; an empty read is the empty copy', () => {
  const err = view({ error: new Error('boom'), data: null });
  assert.ok(err.includes('RETRY') && err.includes('boom'));
  assert.ok(!err.includes('no accounts reported'));
  const empty = view({ data: { ...data, accounts: [] } });
  assert.ok(empty.includes('no accounts reported'));
  assert.ok(!empty.includes('RETRY'));
  const stale = view({ error: new Error('http_502') });
  assert.ok(stale.includes('http_502') && stale.includes('<table'), 'a refresh failure keeps the table');
});

test('R7: truncated footnote', () => {
  assert.equal(truncatedNote({ truncated: { leases: true } }), true);
  assert.equal(truncatedNote({ truncated: { leases: false, tokens: false } }), false);
  assert.ok(view({ data: { ...data, truncated: { leases: true, tokens: false } } }).includes('list truncated'));
  assert.ok(!view().includes('list truncated'));
});

test('R8: no write controls, no confirm, no native dialogs', () => {
  const html = view({ initialExpanded: ['oauth:two-h'] }) + view({ error: new Error('x'), data: null });
  assert.ok(!html.includes('<form'));
  assert.ok(!html.includes('method='));
  assert.ok(!html.includes('<input'));
  const src = new URL('../src/screens/TokenHealth.js', import.meta.url);
  assert.ok(existsSync(src), 'TokenHealth.js exists');
  const text = readFileSync(src, 'utf8');
  assert.ok(text.includes('TokenHealthView'), 'read the real module');
  assert.doesNotMatch(text, /useConfirm|confirm\(|alert\(|prompt\(/);
});

test('R9: api.tokenHealth GETs the coord health route', async () => {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), method: init && init.method });
    return { ok: true, status: 200, text: async () => JSON.stringify({ accounts: [] }) };
  };
  await api.tokenHealth();
  assert.equal(calls.length, 1);
  assert.ok(calls[0].url.endsWith('/api/coord/account-leases/health'));
  assert.ok(calls[0].method === undefined || calls[0].method === 'GET');
});

test('R10: SettingsView mounts the panel on the hub tab below PROJECT ACCOUNTS', () => {
  const status = { scope: 'hub', projects: ['project-3'], lanes: [] };
  const base = {
    tabs: tabsFrom(status), rows: [], status, error: null, loading: false, busy: null,
    note: null, actions: {}, dialog: null, onTab: () => {}, onReload: () => {},
    accountActions: { set: async () => ({ status: 'written' }) },
  };
  const hub = render(h(SettingsView, { ...base, activeTab: 'hub' }));
  const a = hub.indexOf('PROJECT ACCOUNTS');
  const b = hub.indexOf('ACCOUNT &amp; TOKEN HEALTH');
  assert.ok(a >= 0 && b > a, `PROJECT ACCOUNTS at ${a}, TOKEN HEALTH at ${b}`);
  assert.ok(!render(h(SettingsView, { ...base, activeTab: 'project-3' })).includes('TOKEN HEALTH'));
});
