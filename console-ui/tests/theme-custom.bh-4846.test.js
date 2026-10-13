// BH-4846 (Mission Control wave 4): custom themes, the data layer.
//
// A custom theme is a settings row ui.theme.custom.<slug> holding a theme doc
// ({v:1, name, base, tokens, shape}). These tests pin the validator that gates
// every write and every read, export/import, and how a page resolves to a
// custom theme (and falls back to Mill when it is gone): resolveTheme,
// syncFleetDefault and the inline boot script.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';

import {
  CUSTOM_PREFIX, COLOR_KEYS, FONT_CHOICES, customId, slugify, docFromTheme, validateThemeDoc,
  contrastFailures, exportTheme, importTheme, customThemesFromSettings, toTheme, MAX_DOC_CHARS
} from '../src/theme/custom.js';
import { BUILTIN_THEMES, THEME_ORDER, TEXT_PAIRS } from '../src/theme/themes.js';
import { SHAPE_TOKENS } from '../src/theme/tokens.js';
import { resolveTheme, contrastRatio, fleetFromSettingResponse } from '../src/theme/resolve.js';
import {
  syncFleetDefault, THEME_CACHE_KEY, VIEWER_KEY, FLEET_CACHE_KEY, readViewerPick, writeViewerPick
} from '../src/theme/apply.js';
import { bootScript } from '../src/theme/boot.js';

const mill = () => docFromTheme(BUILTIN_THEMES.mill, 'Night Shift');
const withTokens = (over) => { const d = mill(); Object.assign(d.tokens, over); return d; };
const withShape = (over) => { const d = mill(); Object.assign(d.shape, over); return d; };
const rejects = (doc, re, why) => {
  const r = validateThemeDoc(doc);
  assert.equal(r.ok, false, `${why}: should be rejected`);
  assert.ok(r.errors.some((e) => re.test(e)), `${why}: errors ${JSON.stringify(r.errors)} should match ${re}`);
};

// ------------------------------------------------------------ the validator

test('C1 every built-in, exported as a doc, is accepted; an rgba glow is accepted', () => {
  for (const id of THEME_ORDER) {
    const r = validateThemeDoc(docFromTheme(BUILTIN_THEMES[id], BUILTIN_THEMES[id].name));
    assert.equal(r.ok, true, `${id}: ${JSON.stringify(r.errors)}`);
    assert.deepEqual(r.errors, []);
  }
  assert.equal(validateThemeDoc(withTokens({ '--glow': 'rgba(200, 87, 47, 0.35)' })).ok, true);
  // Every built-in colour key is editable, and only colour keys are.
  assert.deepEqual(COLOR_KEYS, Object.keys(BUILTIN_THEMES.mill.tokens));
  assert.ok(COLOR_KEYS.length >= 70);
});

test('C2 unknown keys are rejected by name: a non-colour token, __proto__, a stray top-level field', () => {
  rejects(withTokens({ '--nav-h': '#000000' }), /--nav-h/, 'a token that is not a colour key');
  rejects(JSON.parse(`{"v":1,"name":"x","base":"mill","tokens":{"__proto__":"#000000"},"shape":{}}`), /__proto__/, '__proto__ token');
  rejects(withShape({ '--nav-h': '10px' }), /--nav-h/, 'a shape key that is not in SHAPE_TOKENS');
  rejects({ ...mill(), extra: 1 }, /extra/, 'a top-level key');
  rejects({ ...mill(), v: 2 }, /\bv\b/, 'a doc version other than 1');
});

test('C3 bad colours are rejected: named, injected, url(), expression(), non-strings', () => {
  rejects(withTokens({ '--surface-0': 'red' }), /--surface-0/, 'a named colour');
  rejects(withTokens({ '--rule': '#0d0d0c; background:url(x)' }), /--rule/, 'a declaration smuggled after a colour');
  rejects(withTokens({ '--accent': 'url(https://x)' }), /--accent/, 'url()');
  rejects(withTokens({ '--info': 'expression(alert(1))' }), /--info/, 'expression()');
  rejects(withTokens({ '--note': 12 }), /--note/, 'a number');
  rejects(withTokens({ '--note': '#12345' }), /--note/, 'a five-digit hex');
});

test('C4 fonts come from the self-hosted set only; radii are 0-24px', () => {
  rejects(withShape({ '--font-body': "'Comic Sans'" }), /--font-body/, 'a font outside the self-hosted set');
  rejects(withShape({ '--radius-md': '200px' }), /--radius-md/, 'a radius over 24px');
  rejects(withShape({ '--radius-md': '1em' }), /--radius-md/, 'a radius not in px');
  rejects(withShape({ '--radius-sm': '25px' }), /--radius-sm/, '25px');
  rejects(withShape({ '--title-shadow': '0 0 9px red' }), /--title-shadow/, 'a shape value no built-in has');
  assert.equal(validateThemeDoc(withShape({ '--radius-md': '0px', '--radius-lg': '24px' })).ok, true);
  const names = FONT_CHOICES.map((f) => f.label);
  assert.deepEqual(names, ['Archivo', 'Geist', 'Geist Mono', 'JetBrains Mono']);
  for (const f of FONT_CHOICES) {
    assert.equal(validateThemeDoc(withShape({ '--font-display': f.stack, '--font-body': f.stack, '--font-mono': f.stack })).ok, true, f.label);
    assert.doesNotMatch(f.stack, /googleapis|https?:/);
  }
});

test('C5 the name is 1-40 characters and must make a slug; the base is a built-in', () => {
  rejects({ ...mill(), name: '' }, /name/, 'an empty name');
  rejects({ ...mill(), name: 'x'.repeat(41) }, /name/, 'a 41-char name');
  rejects({ ...mill(), name: '!!!' }, /name/, 'a name with no letters or digits');
  assert.equal(validateThemeDoc({ ...mill(), name: 'x'.repeat(40) }).ok, true);
  rejects({ ...mill(), base: 'custom.y' }, /base/, 'a custom base');
  rejects({ ...mill(), base: 'neon' }, /base/, 'an unknown base');
  for (const bad of [null, [], [mill()], 'mill', 7]) assert.equal(validateThemeDoc(bad).ok, false, JSON.stringify(bad));
  assert.equal(slugify('  Night Shift!! v2 '), 'night-shift-v2');
  assert.equal(customId('night-shift'), 'custom.night-shift');
  assert.equal(CUSTOM_PREFIX, 'ui.theme.custom.');
});

// Two text colours on a black page, one just under 4.5:1 and one at 4.5 or a
// hair over, found by search rather than hand-picked.
function boundaryGreys() {
  let under = null; let over = null;
  for (let g = 90; g < 140 && !(under && over); g++) {
    for (let b = 0; b < 256; b++) {
      const c = `rgb(${g}, ${g}, ${b})`;
      const r = contrastRatio(c, '#000000');
      if (!under && r >= 4.49 && r < 4.5) under = [c, r];
      if (!over && r >= 4.5 && r < 4.51) over = [c, r];
    }
  }
  return { under, over };
}

test('C6 contrast: 4.49:1 is rejected with the pair named, 4.5:1 is accepted', () => {
  const { under, over } = boundaryGreys();
  assert.ok(under && over, 'found both boundary colours');
  const black = { '--surface-0': '#000000', '--surface-1': '#000000', '--surface-2': '#000000' };
  const lo = withTokens({ ...black, '--text-dim': under[0] });
  const hi = withTokens({ ...black, '--text-dim': over[0] });
  rejects(lo, /--text-dim on --surface-1.*4\.4/, `${under[0]} at ${under[1]}`);
  assert.equal(validateThemeDoc(hi).ok, true, JSON.stringify(validateThemeDoc(hi).errors));
  const fails = contrastFailures(lo.tokens);
  assert.deepEqual(fails.map((f) => `${f.fg}/${f.bg}`), ['--text-dim/--surface-0', '--text-dim/--surface-1', '--text-dim/--surface-2']);
  assert.ok(fails.every((f) => f.ratio < 4.5));
  // A translucent text colour has no honest ratio, so it fails rather than passing on its opaque part.
  rejects(withTokens({ '--text': 'rgba(214, 211, 204, 0.2)' }), /--text/, 'translucent text');
  // Every pair is checked, not only the first.
  assert.equal(contrastFailures(BUILTIN_THEMES.mill.tokens).length, 0);
  assert.ok(TEXT_PAIRS.length > 20);
});

test('C7 a partial doc is merged onto its base, so every token and shape key is set', () => {
  const r = validateThemeDoc({ v: 1, name: 'Tiny', base: 'mill-light', tokens: { '--accent': '#7a2f12' }, shape: { '--radius-md': '4px' } });
  assert.equal(r.ok, true, JSON.stringify(r.errors));
  const t = toTheme(r.doc, 'tiny');
  assert.equal(t.id, 'custom.tiny');
  assert.equal(t.name, 'Tiny');
  assert.equal(t.scheme, 'light');
  assert.equal(t.tokens['--accent'], '#7a2f12');
  assert.equal(t.tokens['--surface-0'], BUILTIN_THEMES.paper.tokens['--surface-0']);
  assert.equal(t.themeColor, t.tokens['--surface-0']);
  assert.deepEqual(Object.keys(t.tokens).sort(), [...COLOR_KEYS].sort());
  assert.deepEqual(Object.keys(t.shape).sort(), [...SHAPE_TOKENS].sort());
  assert.equal(t.shape['--radius-md'], '4px');
});

// ------------------------------------------------------- export and import

test('C8 every built-in round-trips through export and import unchanged', () => {
  for (const id of THEME_ORDER) {
    const d = docFromTheme(BUILTIN_THEMES[id], `My ${BUILTIN_THEMES[id].name}`);
    const text = exportTheme(d);
    assert.ok(text.length <= MAX_DOC_CHARS, `${id} exports in ${text.length} chars`);
    const back = importTheme(text);
    assert.equal(back.ok, true, JSON.stringify(back.errors));
    assert.deepEqual(back.doc, d);
    assert.equal(exportTheme(back.doc), text, 'canonical: the same doc exports the same bytes');
    // Canonical means key order and whitespace do not matter: a doc written in
    // reverse key order exports the same compact bytes.
    const rev = (o) => Object.fromEntries(Object.keys(o).reverse().map((k) => [k, o[k]]));
    assert.equal(exportTheme({ ...rev(d), tokens: rev(d.tokens), shape: rev(d.shape) }), text);
    assert.doesNotMatch(text, /\n|": /, 'compact JSON');
  }
});

test('C9 import runs the same validator, and refuses non-JSON, arrays and oversize files', () => {
  assert.deepEqual(importTheme('not json').ok, false);
  assert.match(importTheme('not json').errors[0], /JSON/);
  assert.equal(importTheme('[]').ok, false);
  assert.equal(importTheme(JSON.stringify(withTokens({ '--surface-0': 'red' }))).ok, false);
  assert.match(importTheme(JSON.stringify(withTokens({ '--surface-0': 'red' }))).errors.join(' '), /--surface-0/);
  const big = JSON.stringify({ ...mill(), name: 'x' }) + ' '.repeat(MAX_DOC_CHARS);
  assert.equal(importTheme(big).ok, false);
  assert.match(importTheme(big).errors[0], /4096/);
});

test('C10 the settings rows: prefix filter, a bad row is skipped and reported, never painted', () => {
  const good = { key: 'ui.theme.custom.night', value: exportTheme(mill()), actor: 'operator@example.com', updated_at: 't' };
  const rows = [
    { key: 'ui.theme.default', value: 'mill' },
    { key: 'lane.x.y', value: '3' },
    good,
    { key: 'ui.theme.custom.broken', value: '{"v":1}', actor: 'api' },
    { key: 'ui.theme.custom.Bad_Slug', value: exportTheme(mill()), actor: 'api' }
  ];
  const out = customThemesFromSettings(rows);
  assert.deepEqual(out.themes.map((t) => t.id), ['custom.night']);
  assert.equal(out.themes[0].actor, 'operator@example.com');
  assert.equal(out.themes[0].theme.tokens['--surface-0'], BUILTIN_THEMES.mill.tokens['--surface-0']);
  assert.deepEqual(out.skipped.map((s) => s.key), ['ui.theme.custom.broken', 'ui.theme.custom.Bad_Slug']);
  assert.ok(out.skipped.every((s) => s.errors.length > 0));
  assert.deepEqual(customThemesFromSettings(null).themes, []);
});

// --------------------------------------------------------------- resolution

test('C11 a fleet default naming a custom theme resolves only while that theme exists', () => {
  assert.deepEqual(resolveTheme({ fleet: 'custom.x', customIds: [] }), { id: 'mill', source: 'default' });
  assert.deepEqual(resolveTheme({ fleet: 'custom.x', customIds: ['custom.x'] }), { id: 'custom.x', source: 'fleet' });
  assert.deepEqual(resolveTheme({ viewer: 'custom.x', fleet: 'phosphor', customIds: [] }), { id: 'phosphor', source: 'fleet' });
  assert.deepEqual(resolveTheme({ viewer: 'Custom.X', fleet: 'phosphor', customIds: ['custom.x'] }), { id: 'custom.x', source: 'viewer' });
  assert.equal(fleetFromSettingResponse({ setting: { value: ' custom.night ' } }), 'custom.night');
  assert.equal(fleetFromSettingResponse({ setting: { value: 'custom.' } }), null);
  assert.equal(fleetFromSettingResponse({ setting: { value: 'ui.theme.custom.x' } }), null);
  // A custom pick is stored, and read back, as an id.
  const s = fakeStorage();
  assert.equal(writeViewerPick('custom.night', s), true);
  assert.equal(readViewerPick(s), 'custom.night');
});

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
const fakeWin = () => ({ dispatchEvent() { return true; } });

const NIGHT = { ...mill(), tokens: { ...mill().tokens, '--accent': '#e07a50' } };
const nightRow = { key: 'ui.theme.custom.night', value: exportTheme(NIGHT), actor: 'operator@example.com' };
const apiWith = (fleetValue, rows) => ({
  calls: [],
  coordSetting(key) { this.calls.push(key); return Promise.resolve({ key, setting: fleetValue ? { value: fleetValue } : null }); },
  settings() { this.calls.push('*'); return Promise.resolve({ settings: rows }); }
});

test('C12 syncFleetDefault: a fleet default naming a custom theme paints it and caches it for the boot script', async () => {
  const storage = fakeStorage();
  const doc = fakeDoc('mill');
  const api = apiWith('custom.night', [nightRow]);
  const out = await syncFleetDefault(api, { doc, storage, win: fakeWin() });
  assert.deepEqual(api.calls, ['ui.theme.default', '*']);
  assert.equal(out.ok, true);
  assert.equal(out.customs.ok, true);
  assert.deepEqual(out.customs.themes.map((t) => t.id), ['custom.night']);
  assert.equal(doc.attrs.get('data-theme'), 'custom.night');
  assert.equal(doc.props.get('--accent'), '#e07a50');
  assert.equal(storage.getItem(FLEET_CACHE_KEY), 'custom.night');
  const cache = JSON.parse(storage.getItem(THEME_CACHE_KEY));
  assert.equal(cache.id, 'custom.night');
  assert.equal(cache.tokens['--accent'], '#e07a50');
});

test('C13 syncFleetDefault: the fleet default theme was deleted, so the page falls back to Mill and the cache is cleared', async () => {
  const storage = fakeStorage({ [FLEET_CACHE_KEY]: 'custom.night', [THEME_CACHE_KEY]: JSON.stringify(toTheme(NIGHT, 'night')) });
  const doc = fakeDoc('custom.night');
  const out = await syncFleetDefault(apiWith('custom.night', [{ key: 'ui.theme.default', value: 'custom.night' }]), { doc, storage, win: fakeWin() });
  assert.equal(out.ok, true);
  assert.equal(out.fleet, 'custom.night', 'the row still names it; resolution, not a rewrite, falls back');
  assert.equal(doc.attrs.get('data-theme'), 'mill');
  assert.equal(doc.props.get('--surface-0'), BUILTIN_THEMES.mill.tokens['--surface-0']);
  assert.equal(storage.m.has(THEME_CACHE_KEY), false);
});

test('C14 syncFleetDefault: a viewer pick of a deleted custom theme falls back too; a built-in pick is never repainted', async () => {
  const storage = fakeStorage({ [VIEWER_KEY]: 'custom.gone', [THEME_CACHE_KEY]: JSON.stringify(toTheme(NIGHT, 'gone')) });
  const doc = fakeDoc('custom.gone');
  await syncFleetDefault(apiWith('phosphor', []), { doc, storage, win: fakeWin() });
  assert.equal(doc.attrs.get('data-theme'), 'phosphor');
  assert.equal(storage.m.has(THEME_CACHE_KEY), false);

  const kept = fakeStorage({ [VIEWER_KEY]: 'mill-light' });
  const page = fakeDoc('paper');
  await syncFleetDefault(apiWith('custom.night', [nightRow]), { doc: page, storage: kept, win: fakeWin() });
  assert.equal(page.attrs.get('data-theme'), 'paper');
  assert.equal(page.props.size, 0);
});

test('C15 syncFleetDefault: a failed custom-theme read is unknown, not absent: the cache and page stay', async () => {
  const cached = JSON.stringify(toTheme(NIGHT, 'night'));
  const storage = fakeStorage({ [VIEWER_KEY]: 'custom.night', [THEME_CACHE_KEY]: cached });
  const doc = fakeDoc('custom.night');
  const api = apiWith('mill', []);
  api.settings = () => Promise.reject(new Error('network unreachable'));
  const out = await syncFleetDefault(api, { doc, storage, win: fakeWin() });
  assert.equal(out.ok, true);
  assert.equal(out.customs.ok, false);
  assert.match(out.customs.error.message, /network unreachable/);
  assert.equal(doc.attrs.get('data-theme'), 'custom.night');
  assert.equal(storage.getItem(THEME_CACHE_KEY), cached);
});

// ---------------------------------------------------------- the boot script

function boot(store) {
  const props = {};
  const attrs = {};
  const document = {
    documentElement: { style: { setProperty: (k, v) => { props[k] = v; } }, setAttribute: (k, v) => { attrs[k] = v; } },
    querySelector: () => null
  };
  const localStorage = { getItem: (k) => (Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null) };
  vm.runInContext(bootScript(), vm.createContext({ document, window: { localStorage } }));
  return { props, attrs };
}

test('C16 the boot script paints a cached custom theme only when the picked id matches it', () => {
  const cache = JSON.stringify(toTheme(NIGHT, 'night'));
  const hit = boot({ [VIEWER_KEY]: 'custom.night', [THEME_CACHE_KEY]: cache });
  assert.equal(hit.attrs['data-theme'], 'custom.night');
  assert.equal(hit.props['--accent'], '#e07a50');
  const fleet = boot({ [FLEET_CACHE_KEY]: 'custom.night', [THEME_CACHE_KEY]: cache });
  assert.equal(fleet.attrs['data-theme'], 'custom.night');

  const none = boot({ [VIEWER_KEY]: 'custom.night' });
  assert.equal(none.attrs['data-theme'], 'mill');
  assert.equal(none.props['--accent'], BUILTIN_THEMES.mill.tokens['--accent']);
  const other = boot({ [VIEWER_KEY]: 'custom.other', [THEME_CACHE_KEY]: cache });
  assert.equal(other.attrs['data-theme'], 'mill');
  const junk = boot({ [VIEWER_KEY]: 'custom.night', [THEME_CACHE_KEY]: '{not json' });
  assert.equal(junk.attrs['data-theme'], 'mill');
  // A cache can never stand in for a built-in.
  const spoof = boot({ [VIEWER_KEY]: 'mill', [THEME_CACHE_KEY]: JSON.stringify({ ...toTheme(NIGHT, 'x'), id: 'mill' }) });
  assert.equal(spoof.props['--accent'], BUILTIN_THEMES.mill.tokens['--accent']);
});
