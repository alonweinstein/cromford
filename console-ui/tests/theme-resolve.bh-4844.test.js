// BH-4844 (Mission Control wave 2): which theme a page gets.
//
// Order: the viewer's pick (localStorage ui.theme), then the fleet default
// (settings row ui.theme.default, cached in localStorage ui.theme.fleet), then
// Mill. Anything missing, empty, malformed or unknown at a step falls through
// to the next one. A failed read of the row is "unknown", not "absent": it
// leaves the cache alone.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  normalizeThemeId, resolveTheme, fleetFromSettingResponse
} from '../src/theme/resolve.js';
import { BUILTIN_THEMES, DEFAULT_THEME_ID } from '../src/theme/themes.js';
import {
  syncFleetDefault, readViewerPick, writeViewerPick, readFleetCache, VIEWER_KEY, FLEET_CACHE_KEY
} from '../src/theme/apply.js';
import { THEME_CHANGE_EVENT } from '../src/theme/tokens.js';
import { AuthError } from '../src/api.js';

test('R1 the viewer pick wins over the fleet default', () => {
  assert.deepEqual(resolveTheme({ viewer: 'phosphor', fleet: 'mill-light' }), { id: 'phosphor', source: 'viewer' });
});

test('R2 with no viewer pick the fleet default is next', () => {
  assert.deepEqual(resolveTheme({ viewer: null, fleet: 'mill-light' }), { id: 'paper', source: 'fleet' });
});

test('R3 with neither, Mill', () => {
  assert.equal(DEFAULT_THEME_ID, 'mill');
  assert.deepEqual(resolveTheme({ viewer: null, fleet: null }), { id: 'mill', source: 'default' });
  assert.deepEqual(resolveTheme(), { id: 'mill', source: 'default' });
});

test('R4 an unknown viewer pick falls through to the fleet default', () => {
  for (const viewer of ['neon', '', '   ', 'ui.theme.custom.x', 'constructor', '__proto__', 42, {}]) {
    assert.deepEqual(resolveTheme({ viewer, fleet: 'phosphor' }), { id: 'phosphor', source: 'fleet' }, `viewer=${JSON.stringify(viewer)}`);
  }
});

test('R5 a missing or malformed settings answer gives no fleet default, so Mill', () => {
  const answers = [
    { setting: null }, { setting: { value: '' } }, { setting: { value: 'neon' } },
    { setting: { value: '{"id":"mill"}' } }, { setting: { value: 7 } }, { setting: 'phosphor' },
    null, undefined, {}, 'phosphor'
  ];
  for (const res of answers) {
    assert.equal(fleetFromSettingResponse(res), null, JSON.stringify(res));
    assert.deepEqual(resolveTheme({ viewer: null, fleet: fleetFromSettingResponse(res) }), { id: 'mill', source: 'default' });
  }
  assert.equal(fleetFromSettingResponse({ key: 'ui.theme.default', setting: { key: 'ui.theme.default', value: 'phosphor' }, source: 'd1' }), 'phosphor');
});

test('R6 ids are trimmed and lowercased, once, the same way everywhere', () => {
  assert.equal(normalizeThemeId('  Mill-Light '), 'paper');
  assert.equal(normalizeThemeId('PHOSPHOR'), 'phosphor');
  assert.equal(normalizeThemeId('mill light'), null);
  assert.equal(fleetFromSettingResponse({ setting: { value: '  MILL ' } }), 'mill');
  assert.deepEqual(resolveTheme({ viewer: ' Phosphor', fleet: null }), { id: 'phosphor', source: 'viewer' });
  for (const id of Object.keys(BUILTIN_THEMES)) assert.equal(normalizeThemeId(id.toUpperCase()), id);
});

// ------------------------------------------------------- syncFleetDefault

function fakeStorage(init = {}) {
  const m = new Map(Object.entries(init));
  return {
    m,
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => { m.set(k, String(v)); },
    removeItem: (k) => { m.delete(k); }
  };
}

function fakeDoc(themeId) {
  const props = new Map();
  const attrs = new Map(themeId ? [['data-theme', themeId]] : []);
  const metas = { 'color-scheme': { content: 'dark' }, 'theme-color': { content: '#000000' } };
  for (const m of Object.values(metas)) m.setAttribute = (k, v) => { m[k] = v; };
  return {
    props, attrs, metas,
    documentElement: {
      style: { setProperty: (k, v) => props.set(k, v) },
      setAttribute: (k, v) => attrs.set(k, v),
      getAttribute: (k) => (attrs.has(k) ? attrs.get(k) : null)
    },
    querySelector: (sel) => metas[(sel.match(/name="([^"]+)"/) || [])[1]] || null
  };
}

function fakeWin() {
  const w = new EventTarget();
  w.events = [];
  w.addEventListener(THEME_CHANGE_EVENT, (e) => w.events.push(e.detail));
  return w;
}

const apiAnswering = (fn) => ({ calls: [], coordSetting(key) { this.calls.push(key); return fn(key); } });

test('R7a a fleet row with no viewer pick is cached and applied, and the theme event fires', async () => {
  const storage = fakeStorage();
  const doc = fakeDoc('mill');
  const win = fakeWin();
  const api = apiAnswering(async () => ({ key: 'ui.theme.default', setting: { value: 'phosphor' }, source: 'd1' }));
  const out = await syncFleetDefault(api, { doc, storage, win });
  assert.deepEqual(api.calls, ['ui.theme.default']);
  assert.equal(out.ok, true);
  assert.equal(storage.getItem(FLEET_CACHE_KEY), 'phosphor');
  assert.equal(doc.attrs.get('data-theme'), 'phosphor');
  assert.equal(doc.props.get('--surface-0'), BUILTIN_THEMES.phosphor.tokens['--surface-0']);
  assert.equal(doc.metas['theme-color'].content, BUILTIN_THEMES.phosphor.themeColor);
  assert.deepEqual(win.events, [{ id: 'phosphor' }]);

  // The same answer again changes nothing and fires nothing.
  await syncFleetDefault(api, { doc, storage, win });
  assert.equal(win.events.length, 1);
});

test('R7b with a viewer pick the cache is written but the page keeps the pick', async () => {
  const storage = fakeStorage({ [VIEWER_KEY]: 'mill-light' });
  const doc = fakeDoc('paper');
  const win = fakeWin();
  await syncFleetDefault(apiAnswering(async () => ({ setting: { value: 'phosphor' } })), { doc, storage, win });
  assert.equal(storage.getItem(FLEET_CACHE_KEY), 'phosphor');
  assert.equal(doc.attrs.get('data-theme'), 'paper');
  assert.equal(doc.props.size, 0);
  assert.deepEqual(win.events, []);

  // Even when the page shows something else (the pick was made in another tab
  // after this one painted), the fleet read does not repaint over a viewer pick.
  const other = fakeDoc('mill');
  await syncFleetDefault(apiAnswering(async () => ({ setting: { value: 'phosphor' } })), { doc: other, storage, win });
  assert.equal(other.attrs.get('data-theme'), 'mill');
  assert.equal(other.props.size, 0);
  assert.deepEqual(win.events, []);
});

test('R7c no row (or an unusable one) clears the cache, so a deleted fleet default does not stick', async () => {
  for (const answer of [{ setting: null }, { setting: { value: 'neon' } }]) {
    const storage = fakeStorage({ [FLEET_CACHE_KEY]: 'phosphor' });
    const doc = fakeDoc('phosphor');
    const out = await syncFleetDefault(apiAnswering(async () => answer), { doc, storage, win: fakeWin() });
    assert.equal(out.ok, true);
    assert.equal(storage.m.has(FLEET_CACHE_KEY), false, JSON.stringify(answer));
    assert.equal(doc.attrs.get('data-theme'), 'mill');
  }
});

test('R7d a failed read leaves the cache and the page alone, and never throws', async () => {
  const fails = [
    () => { throw new AuthError(); },
    async () => { throw new AuthError(); },
    async () => { throw new Error('network unreachable'); },
    async () => { const e = new Error('http_500'); e.status = 500; throw e; },
    async () => null,
    async () => ({ error: 'nope' })
  ];
  for (const fail of fails) {
    const storage = fakeStorage({ [FLEET_CACHE_KEY]: 'phosphor' });
    const doc = fakeDoc('phosphor');
    const win = fakeWin();
    const out = await syncFleetDefault(apiAnswering(fail), { doc, storage, win });
    assert.equal(out.ok, false);
    assert.ok(out.error instanceof Error);
    assert.equal(storage.getItem(FLEET_CACHE_KEY), 'phosphor');
    assert.equal(doc.attrs.get('data-theme'), 'phosphor');
    assert.deepEqual(win.events, []);
  }
});

test('R7e storage that throws reads as nothing and a write reports it failed', () => {
  const broken = { getItem() { throw new Error('denied'); }, setItem() { throw new Error('denied'); }, removeItem() { throw new Error('denied'); } };
  assert.equal(readViewerPick(broken), null);
  assert.equal(readFleetCache(broken), null);
  assert.equal(writeViewerPick('phosphor', broken), false);
  const ok = fakeStorage();
  assert.equal(writeViewerPick('Phosphor', ok), true);
  assert.equal(ok.getItem(VIEWER_KEY), 'phosphor');
  assert.equal(readViewerPick(ok), 'phosphor');
  assert.equal(writeViewerPick(null, ok), true);
  assert.equal(ok.m.has(VIEWER_KEY), false);
  assert.equal(readViewerPick(fakeStorage({ [VIEWER_KEY]: 'neon' })), null);
});
