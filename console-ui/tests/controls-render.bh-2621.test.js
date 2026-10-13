import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import { ROUTES, NAV } from '../src/app.js';
import { matchRoute } from '../src/router.js';
import { CONTROL_KINDS, controlHref, fieldLabel } from '../src/lib/controls.js';
import { configHref } from '../src/lib/config.js';
import { ControlsScreen, ControlsView, EditForm, saveControl } from '../src/screens/Controls.js';
import { SettingsView } from '../src/screens/Settings.js';
import { onRequest } from '../functions/api/coord/[[path]].js';
import { laneRows, tabsFrom } from '../src/lib/settings.js';

// BH-2621 (BH-2513.4): the CONTROLS screen, rendered over the lib's real
// CONTROL_KINDS. preact-render-to-string runs no effects or handlers:
// ControlsView is driven with each load state directly, ControlsScreen through
// the real /controls/:kind route, and the modal's confirm through saveControl
// against the real api.controlsPut and the real controlBody with fetch
// captured.

const noop = () => {};
const byKind = (k) => CONTROL_KINDS.find((d) => d.kind === k);
const GATE = byKind('review-gate');
const RULES = byKind('rules');

// One row for a descriptor: every key and edit field filled.
function rowFor(desc, n) {
  const r = {};
  for (const k of desc.keyFields) r[k] = `${k}-${n}`;
  for (const { name, type } of desc.editFields) r[name] = type === 'int' ? n : type === 'num' ? n / 10 : `${name} ${n}`;
  return r;
}

const loaded = (data) => ({ data, error: null, loading: false });
const view = (state, extra = {}) =>
  render(h(ControlsView, { desc: GATE, state, onReload: noop, onNew: noop, onEdit: noop, ...extra }));

function captureFetch(respond) {
  const calls = [];
  const orig = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url, method: init.method || 'GET', body: init.body ? JSON.parse(init.body) : null });
    return respond(url, init);
  };
  return { calls, restore: () => { globalThis.fetch = orig; } };
}
const reply = (status, obj) => new Response(JSON.stringify(obj), { status, headers: { 'content-type': 'application/json' } });

// ------------------------------------------------------------------ T1 api

// The descriptors carry the WORKER's paths (/api/review-gate). The coord
// proxy re-adds that /api (functions/api/coord/[[path]].js: `/api/${rest}`),
// so the browser URL is /api/coord/review-gate, never /api/coord/api/….

test('api helpers: controlsList GETs /api/coord + the worker path without its /api', async () => {
  const f = captureFetch(() => reply(200, { thresholds: [] }));
  try {
    const out = await api.controlsList(CONTROL_KINDS[0]);
    assert.deepEqual(out, { thresholds: [] });
    assert.deepEqual(f.calls.map((c) => [c.url, c.method]), [['/api/coord/review-gate', 'GET']]);
  } finally { f.restore(); }
});

test('api helpers: controlsPut sends PUT /api/coord + putPath without its /api, with the exact JSON body', async () => {
  const f = captureFetch(() => reply(200, { ok: true }));
  try {
    for (const desc of CONTROL_KINDS) {
      await api.controlsPut(desc, { scope: 'x', reason: 'r' });
    }
    assert.deepEqual(f.calls.map((c) => [c.url, c.method]), [
      ['/api/coord/review-gate/thresholds', 'PUT'],
      ['/api/coord/rules', 'PUT'],
      ['/api/coord/retry-policies', 'PUT'],
      ['/api/coord/contracts', 'PUT'],
      ['/api/coord/projects', 'PUT'],
    ]);
    for (const c of f.calls) assert.deepEqual(c.body, { scope: 'x', reason: 'r' });
  } finally { f.restore(); }
});

test('api helpers: the URL controlsList sends reaches the worker route through the real coord proxy', async () => {
  const JOBS = 'https://harness-jobs.operator.workers.dev';
  for (const desc of CONTROL_KINDS) {
    const seen = [];
    const real = globalThis.fetch;
    globalThis.fetch = async (input, init = {}) => {
      const url = typeof input === 'string' ? input : input.url;
      seen.push({ url, method: init.method || 'GET' });
      if (url.startsWith('/api/coord/')) {
        // The browser's call: hand it to the production proxy.
        const rest = url.slice('/api/coord/'.length);
        return onRequest({
          request: new Request('https://console.example.pages.dev' + url, { headers: { cookie: 'dash=bh2621' } }),
          env: { HARNESS_SECRET: 'test-secret' },
          params: { path: rest.split('/') },
        });
      }
      return reply(200, { [desc.listKey]: [] });
    };
    try {
      const out = await api.controlsList(desc);
      assert.deepEqual(out, { [desc.listKey]: [] }, desc.kind);
      const upstream = seen.filter((c) => c.url.startsWith(JOBS)).map((c) => new URL(c.url).pathname);
      assert.deepEqual(upstream, [desc.path], `${desc.kind}: the proxy forwarded to the wrong worker route`);
    } finally { globalThis.fetch = real; }
  }
});

// ------------------------------------------------------------------ T2 view

test('(a) every kind renders its tabs, a sortable header per field, and an EDIT per row', () => {
  assert.equal(CONTROL_KINDS.length, 5);
  for (const desc of CONTROL_KINDS) {
    const rows = [rowFor(desc, 1), rowFor(desc, 2)];
    const out = view(loaded({ [desc.listKey]: rows }), { desc });
    const fields = [...desc.keyFields, ...desc.editFields.map((e) => e.name)];
    const esc = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    for (const name of fields) {
      assert.match(out, new RegExp(`<th[^>]*aria-sort[^>]*><button[^>]*>\\s*${esc(fieldLabel(desc, name))}`), `${desc.kind}: no sortable header ${name}`);
    }
    // One header per key and edit field, plus the unsortable EDIT column (BH-3558.1).
    assert.equal((out.match(/<th /g) || []).length, fields.length + 1, `${desc.kind}: one header per key and edit field, plus EDIT`);
    for (const r of rows) assert.ok(out.includes(`href="${configHref(desc.auditKind, desc.auditName(r))}"`), `${desc.kind}: ${desc.rowName(r)} does not link to its history`);
    for (const d of CONTROL_KINDS) assert.match(out, new RegExp(`href="${controlHref(d.kind)}"`), `${desc.kind}: no tab for ${d.kind}`);
    assert.match(out, new RegExp(`href="${controlHref(desc.kind)}"[^>]*aria-current="page"|aria-current="page"[^>]*href="${controlHref(desc.kind)}"`), `${desc.kind}: active tab not marked`);
    assert.equal((out.match(/aria-current="page"/g) || []).length, 1);
    for (const r of rows) assert.ok(out.includes(`>EDIT ${desc.rowName(r)}<`), `${desc.kind}: no EDIT for ${desc.rowName(r)}`);
    assert.match(out, /tablewrap--wide/);
    assert.match(out, />NEW</);
  }
});

test('(a2) the default sort is the first key field, and a null cell renders the dash', () => {
  const rows = [{ ...rowFor(GATE, 1), scope: 'zeta', note: null }, { ...rowFor(GATE, 2), scope: 'alpha' }];
  const out = view(loaded({ thresholds: rows }));
  assert.ok(out.indexOf('EDIT alpha') < out.indexOf('EDIT zeta'), 'not sorted on scope ascending');
  assert.match(out, /class="na">—</);
});

test('(b) a load failure is the error banner with RETRY, never the empty copy', () => {
  const out = view({ data: null, error: new Error('http_502'), loading: false });
  assert.match(out, /could not load/);
  assert.match(out, /http_502/);
  assert.match(out, /RETRY/);
  assert.doesNotMatch(out, /rows on record yet/);
});

test('(b2) a response without the list key is an error, not an empty table', () => {
  const out = view(loaded({ rows: [] }));
  assert.match(out, /unexpected response from \/api\/review-gate/);
  assert.match(out, /RETRY/);
  assert.doesNotMatch(out, /rows on record yet/);
});

test('(b3) first load is the skeleton, neither empty nor error', () => {
  const out = view({ data: null, error: null, loading: true });
  assert.match(out, /class="skel"/);
  assert.doesNotMatch(out, /rows on record yet|could not load/);
});

test('(c) zero rows renders the empty copy and keeps NEW', () => {
  const out = view(loaded({ thresholds: [] }));
  assert.match(out, /no Review gate thresholds rows on record yet/);
  assert.match(out, />NEW</);
  assert.doesNotMatch(out, /could not load/);
});

// ------------------------------------------------------------------ T3 route

test('(d) ControlsScreen for an unknown kind renders NO SUCH SCREEN', () => {
  const out = render(h(ControlsScreen, { kind: 'bogus' }));
  assert.match(out, /NO SUCH SCREEN/);
  assert.match(out, /<code>\/controls\/bogus<\/code>/);
});

test('nav: the production route table serves /controls/:kind and SETTINGS owns the tab', () => {
  const route = ROUTES.find(([p]) => p === '/controls/:kind');
  assert.ok(route, 'no /controls/:kind route');
  assert.equal(route[1], ControlsScreen);
  const settings = NAV.find((n) => n.label === 'SETTINGS');
  assert.equal(settings.match('/controls/rules'), true);
  assert.equal(settings.match('/settings'), true);
  assert.equal(settings.match('/config'), true, 'the /config clause from main must stay');
  const params = matchRoute('/controls/:kind', '/controls/bogus');
  assert.deepEqual(params, { kind: 'bogus' });
  assert.match(render(h(route[1], params)), /NO SUCH SCREEN/);
  // A known kind through the real route renders that kind's page.
  const live = render(h(route[1], matchRoute('/controls/:kind', '/controls/rules')));
  assert.match(live, /Concurrency rules · every edit is recorded/);
});

// ------------------------------------------------------------------ the form

const gateDraft = () => ({ scope: 'hub', window_days: '14', min_merges: '5', tighten_rate: '0.3', clear_rate: '0.1', note: '', reason: '' });
const form = (props) => render(h(EditForm, { desc: GATE, value: gateDraft(),
  lists: {}, serverError: null, pending: false, onBlocked: noop, ...props }));

test('(g) EDIT renders the key read-only; NEW renders it editable', () => {
  const edit = form({ isNew: false });
  assert.match(edit, /<input[^>]*name="scope"[^>]*readonly/);
  assert.match(edit, /name="window_days"[^>]*type="number"|type="number"[^>]*name="window_days"/);
  assert.match(edit, /<textarea[^>]*name="reason"/);
  assert.match(edit, /reason required/, 'the controlBody error is the hint');
  const fresh = form({ isNew: true, value: { reason: '' } });
  assert.match(fresh, /<input[^>]*name="scope"/);
  assert.doesNotMatch(fresh, /name="scope"[^>]*readonly/);
});

test('(g2) a keySelect key field is a select over the GET response list on NEW', () => {
  const out = form({ desc: RULES, isNew: true, value: { reason: '' }, lists: { scopes: ['hub', 'project'] } });
  assert.match(out, /<select[^>]*name="scope"/);
  assert.match(out, /<option value="project">project<\/option>/);
});

test('(g3) the worker error renders inside the form', () => {
  const out = form({ isNew: false, serverError: 'window_days out of range' });
  assert.match(out, /class="banner"[^>]*>[\s\S]*window_days out of range/);
});

// ------------------------------------------------------------------ save

function saveHarness() {
  const log = { pending: [], serverError: [], done: 0 };
  return {
    log,
    setPending: (v) => log.pending.push(v),
    setServerError: (v) => log.serverError.push(v),
    onDone: () => { log.done++; },
  };
}

test('(e) a worker 400 lands in serverError, onDone is never called, pending ends false', async () => {
  const f = captureFetch(() => reply(400, { error: 'window_days out of range' }));
  const hx = saveHarness();
  try {
    await saveControl({ desc: GATE, draft: { ...gateDraft(), window_days: '999' }, reason: 'try it', put: api.controlsPut, ...hx });
    assert.equal(f.calls.length, 1, 'exactly one PUT, never retried');
    assert.equal(f.calls[0].url, '/api/coord/review-gate/thresholds');
    assert.deepEqual(f.calls[0].body, { scope: 'hub', window_days: 999, min_merges: 5, tighten_rate: 0.3, clear_rate: 0.1, note: '', reason: 'try it' });
    assert.equal(hx.log.serverError.at(-1), 'window_days out of range');
    assert.equal(hx.log.done, 0, 'the modal closed on a failed write');
    assert.deepEqual(hx.log.pending, [true, false]);
  } finally { f.restore(); }
});

test('(e2) a 2xx closes the modal once and resets pending', async () => {
  const f = captureFetch(() => reply(200, { ok: true }));
  const hx = saveHarness();
  try {
    await saveControl({ desc: GATE, draft: gateDraft(), reason: 'ok', put: api.controlsPut, ...hx });
    assert.equal(f.calls.length, 1);
    assert.equal(hx.log.done, 1);
    assert.deepEqual(hx.log.pending, [true, false]);
  } finally { f.restore(); }
});

test('(f) a blank reason, a blank int or a 1.5 int never calls put', async () => {
  const f = captureFetch(() => reply(200, { ok: true }));
  try {
    for (const [draft, reason] of [
      [gateDraft(), '   '],
      [gateDraft(), ''],
      [{ ...gateDraft(), window_days: '' }, 'why'],
      [{ ...gateDraft(), window_days: '1.5' }, 'why'],
      [{ ...gateDraft(), tighten_rate: 'abc' }, 'why'],
    ]) {
      const hx = saveHarness();
      await saveControl({ desc: GATE, draft, reason, put: api.controlsPut, ...hx });
      assert.equal(hx.log.done, 0);
      assert.deepEqual(hx.log.pending, [], 'no pending state for a refused body');
      assert.ok(hx.log.serverError.at(-1), 'the refusal is shown');
    }
    assert.equal(f.calls.length, 0);
  } finally { f.restore(); }
});

// ------------------------------------------------------------------ remount

test('(h) ControlsScreen keys its page by kind, so a kind switch remounts it and drops the draft', () => {
  const a = ControlsScreen({ kind: 'review-gate' });
  const b = ControlsScreen({ kind: 'rules' });
  assert.equal(a.key, 'review-gate');
  assert.equal(b.key, 'rules');
  assert.equal(a.type, b.type, 'same page component: only the key forces the remount');
  assert.equal(b.props.desc, RULES);
  // The page the second render mounts starts with no dialog open.
  const out = render(b);
  assert.doesNotMatch(out, /class="modal/);
  assert.doesNotMatch(out, /name="reason"/);
});

// ------------------------------------------------------------------ T4 settings

const settingsStatus = { scope: 'hub', projects: [], all_off: false, lanes: [] };
const settingsView = (over = {}) => render(h(SettingsView, {
  tabs: tabsFrom(settingsStatus), activeTab: 'hub', rows: laneRows({ lanes: [] }, settingsStatus, 'hub'),
  status: settingsStatus, error: null, loading: false, busy: null, note: null,
  actions: { toggleLane: noop, setKnob: noop, allOff: noop, allOn: noop }, dialog: null, onTab: noop, onReload: noop,
  ...over
}));

test('settings row: SETTINGS links each of the five control kinds by default', () => {
  const live = settingsView();
  assert.match(live, />CONTROLS</);
  assert.equal((live.match(/href="\/controls\//g) || []).length, 5);
  for (const d of CONTROL_KINDS) assert.match(live, new RegExp(`href="${controlHref(d.kind)}"[^>]*>${d.title}<`));
});

test('settings row: hidden when the kind list is empty', () => {
  const none = settingsView({ controlKinds: [] });
  assert.doesNotMatch(none, /href="\/controls\//);
  assert.doesNotMatch(none, />CONTROLS</);
});
