// BH-4990 (BH-4947 wave 1, "The Line"): the Paper theme replaces Mill Light.
//
// Paper is the reference's light Mill variant. It passes the same contrast
// check every built-in passes, and a browser or a fleet row that still says
// `mill-light` lands on Paper: on first paint (the boot script), through the
// resolver, in storage (the viewer key is rewritten) and as a custom theme's base.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { BUILTIN_THEMES, THEME_ORDER, DEFAULT_THEME_ID, TEXT_PAIRS, THEME_ALIASES } from '../src/theme/themes.js';
import { contrastRatio, resolveTheme, normalizeThemeId, fleetFromSettingResponse } from '../src/theme/resolve.js';
import { bootScript } from '../src/theme/boot.js';
import { readViewerPick, readFleetCache, readThemeCache, VIEWER_KEY, FLEET_CACHE_KEY, THEME_CACHE_KEY } from '../src/theme/apply.js';
import { validateThemeDoc, toTheme, mergedTokens } from '../src/theme/custom.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CSS = fs.readFileSync(path.join(root, 'src', 'styles.css'), 'utf8');
const REF = path.join(root, 'design-ref', 'mission-control-line.html');

function rootVars(css) {
  const m = css.match(/:root\s*\{([\s\S]*?)\n\}/);
  const vars = new Map();
  for (const d of m[1].replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) vars.set(d[1], d[2].trim());
  return vars;
}

function fakeStorage(init = {}) {
  const m = new Map(Object.entries(init));
  return {
    m,
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => { m.set(k, String(v)); },
    removeItem: (k) => { m.delete(k); }
  };
}

function boot(store) {
  const set = {};
  const attrs = {};
  const document = {
    documentElement: { style: { setProperty: (k, v) => { set[k] = v; } }, setAttribute: (k, v) => { attrs[k] = v; } },
    querySelector: () => null
  };
  const localStorage = { getItem: (k) => (Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null) };
  vm.runInContext(bootScript(), vm.createContext({ document, window: { localStorage } }));
  return { set, attrs };
}

test('P1 Paper is a light built-in on the Mill form; Mill stays first and default; Phosphor is :root', () => {
  const p = BUILTIN_THEMES.paper;
  assert.ok(p, 'BUILTIN_THEMES.paper exists');
  assert.equal(p.id, 'paper');
  assert.equal(p.name, 'Paper');
  assert.equal(p.scheme, 'light');
  assert.deepEqual(p.shape, BUILTIN_THEMES.mill.shape);
  assert.deepEqual(THEME_ORDER, ['mill', 'paper', 'phosphor']);
  assert.equal(THEME_ORDER[0], 'mill');
  assert.equal(DEFAULT_THEME_ID, 'mill');
  assert.equal(BUILTIN_THEMES['mill-light'], undefined, 'Mill Light is replaced, not kept beside Paper');
  assert.deepEqual(THEME_ALIASES, { 'mill-light': 'paper' });
  const vars = rootVars(CSS);
  for (const [k, v] of Object.entries(BUILTIN_THEMES.phosphor.tokens)) {
    assert.equal(String(v).toLowerCase().replace(/\s+/g, ''), String(vars.get(k)).toLowerCase().replace(/\s+/g, ''), k);
  }
  // The two tokens the line screen draws with exist in every built-in.
  for (const id of THEME_ORDER) {
    for (const k of ['--grid', '--live-soft']) assert.ok(BUILTIN_THEMES[id].tokens[k], `${id} sets ${k}`);
  }
});

test('P2 every text pair on Paper clears 4.5:1', () => {
  const t = BUILTIN_THEMES.paper.tokens;
  const fails = TEXT_PAIRS
    .map(([fg, bg]) => [fg, bg, contrastRatio(t[fg], t[bg])])
    .filter(([, , r]) => !(r >= 4.5))
    .map(([fg, bg, r]) => `${fg} ${t[fg]} on ${bg} ${t[bg]} = ${r && r.toFixed(2)}`);
  assert.deepEqual(fails, []);
});

// The reference's paper block, as the planner read it from cromford-web
// docs/design/mission-control-line.html. P3b parses the verbatim copy in
// design-ref/ and pins Paper against that.
const REF_PAPER = { '--surface-0': '#f1efe9', '--surface-1': '#fbfaf7', '--surface-2': '#f5f3ee', '--rule': '#d9d5cb', '--text-strong': '#161513' };

test('P3 Paper surfaces, rule and strong text are the reference paper block', () => {
  const t = BUILTIN_THEMES.paper.tokens;
  for (const [k, v] of Object.entries(REF_PAPER)) assert.equal(t[k].toLowerCase(), v, k);
  assert.equal(BUILTIN_THEMES.paper.themeColor.toLowerCase(), REF_PAPER['--surface-0']);
});

// The verbatim copy is a Scope deliverable of this ticket, so a missing copy is
// a failure, not a skip: P3 alone only proves Paper matches a transcription.
test('P3b Paper matches the design-ref copy\'s [data-theme="paper"] block', () => {
  assert.ok(fs.existsSync(REF), 'design-ref/mission-control-line.html is missing: copy cromford-web docs/design/mission-control-line.html verbatim');
  const html = fs.readFileSync(REF, 'utf8');
  const block = (html.match(/\[data-theme="paper"\]\s*\{([^}]*)\}/) || [])[1];
  assert.ok(block, 'the reference has a [data-theme="paper"] block');
  const ref = Object.fromEntries([...block.matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)].map((m) => [m[1], m[2].trim().toLowerCase()]));
  const map = { '--ink': '--surface-0', '--stage': '--surface-1', '--stage-2': '--surface-2', '--rule': '--rule', '--chalk': '--text-strong' };
  for (const [r, k] of Object.entries(map)) assert.equal(BUILTIN_THEMES.paper.tokens[k].toLowerCase(), ref[r], `${r} -> ${k}`);
});

test('P4 a stored mill-light resolves to paper, in either slot, case and space aside', () => {
  assert.deepEqual(resolveTheme({ viewer: 'mill-light' }), { id: 'paper', source: 'viewer' });
  assert.deepEqual(resolveTheme({ viewer: null, fleet: 'mill-light' }), { id: 'paper', source: 'fleet' });
  assert.equal(normalizeThemeId(' Mill-Light '), 'paper');
  assert.equal(normalizeThemeId('MILL-LIGHT'), 'paper');
  assert.equal(normalizeThemeId('paper'), 'paper');
  // The alias table is looked up by own key: prototype names are still not themes.
  assert.equal(normalizeThemeId('__proto__'), null);
  assert.equal(normalizeThemeId('constructor'), null);
  assert.equal(fleetFromSettingResponse({ setting: { value: 'mill-light' } }), 'paper');
});

test('P5 the boot script paints Paper for a stored mill-light (viewer or fleet cache)', () => {
  const v = boot({ 'ui.theme': 'mill-light' });
  assert.equal(v.attrs['data-theme'], 'paper');
  assert.equal(v.set['--surface-0'], BUILTIN_THEMES.paper.tokens['--surface-0']);
  const f = boot({ 'ui.theme.fleet': ' Mill-Light ' });
  assert.equal(f.attrs['data-theme'], 'paper');
  assert.equal(boot({ 'ui.theme': '__proto__' }).attrs['data-theme'], 'mill');
});

test('P6 reading a stored mill-light rewrites the key to paper', () => {
  const s = fakeStorage({ [VIEWER_KEY]: 'mill-light', [FLEET_CACHE_KEY]: 'MILL-LIGHT' });
  assert.equal(readViewerPick(s), 'paper');
  assert.equal(s.getItem(VIEWER_KEY), 'paper');
  assert.equal(readFleetCache(s), 'paper');
  assert.equal(s.getItem(FLEET_CACHE_KEY), 'paper');
  // A canonical value is left alone (no write at all).
  const writes = [];
  const quiet = { ...fakeStorage({ [VIEWER_KEY]: 'phosphor' }), setItem: (k, v) => writes.push([k, v]) };
  assert.equal(readViewerPick(quiet), 'phosphor');
  assert.deepEqual(writes, []);
});

test('P7 a custom theme saved on base mill-light still validates and paints on Paper', () => {
  const r = validateThemeDoc({ v: 1, name: 'Old', base: 'mill-light', tokens: {}, shape: {} });
  assert.equal(r.ok, true, r.errors.join('; '));
  assert.equal(r.doc.base, 'paper');
  assert.equal(mergedTokens({ base: 'mill-light', tokens: {} })['--surface-0'], BUILTIN_THEMES.paper.tokens['--surface-0']);
  const t = toTheme(r.doc, 'old');
  assert.equal(t.tokens['--surface-0'], BUILTIN_THEMES.paper.tokens['--surface-0']);
  assert.equal(t.scheme, 'light');
  // The boot cache a browser holds from before the rename still passes.
  const cached = { ...t, base: 'mill-light' };
  const s = fakeStorage({ [THEME_CACHE_KEY]: JSON.stringify(cached) });
  assert.ok(readThemeCache(s), 'a cached custom theme on base mill-light is still read');
  // An unknown base is still refused.
  assert.equal(validateThemeDoc({ v: 1, name: 'Bad', base: 'neon', tokens: {}, shape: {} }).ok, false);
});
