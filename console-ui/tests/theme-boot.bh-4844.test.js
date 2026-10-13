// BH-4844 (Mission Control wave 2): no flash of the wrong theme.
//
// An inline classic script, generated from src/theme/themes.js, sits in <head>
// above every stylesheet and sets the theme's tokens on :root synchronously.
// These tests run that exact script text in a vm with a fake document.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { bootScript, themeBootPlugin, injectBootScript } from '../src/theme/boot.js';
import { BUILTIN_THEMES } from '../src/theme/themes.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const INDEX = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
// What a paint writes onto :root: every colour token and (BH-4845) every shape key.
const painted = (t) => ({ ...t.tokens, ...t.shape });

function run(store, { throwing = false } = {}) {
  const set = [];
  const attrs = {};
  const metas = { 'color-scheme': { content: 'dark' }, 'theme-color': { content: '#070B08' } };
  for (const m of Object.values(metas)) m.setAttribute = (k, v) => { m[k] = v; };
  const document = {
    documentElement: {
      style: { setProperty: (k, v) => set.push([k, v]) },
      setAttribute: (k, v) => { attrs[k] = v; }
    },
    querySelector: (sel) => metas[(sel.match(/name="([^"]+)"/) || [])[1]] || null
  };
  const localStorage = {
    getItem(k) {
      if (throwing) throw new Error('SecurityError');
      return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null;
    }
  };
  const ctx = vm.createContext({ document, window: { localStorage } });
  vm.runInContext(bootScript(), ctx);
  return { set, props: Object.fromEntries(set), attrs, metas };
}

test('B1 the plugin puts one inline script after the theme metas and before any stylesheet', () => {
  const plugin = themeBootPlugin();
  assert.equal(plugin.name, 'mc-theme-boot');
  assert.equal(plugin.transformIndexHtml.order, 'pre');
  const out = plugin.transformIndexHtml.handler(INDEX);
  assert.equal(out, injectBootScript(INDEX));
  assert.equal((out.match(/<script>/g) || []).length, 1, 'exactly one inline classic script');
  const at = out.indexOf('<script>');
  assert.ok(at > out.indexOf('<meta charset'), 'charset still comes first');
  assert.ok(at > out.indexOf('<meta name="color-scheme"'));
  assert.ok(at > out.indexOf('<meta name="theme-color"'));
  assert.ok(at < out.indexOf('<link'), 'before every <link>');
  assert.ok(at < out.indexOf('<script type="module"'), 'before the app module');
  assert.ok(out.includes(bootScript()));
  assert.doesNotMatch(bootScript(), /<\/script/i);
  // An index.html with nothing to anchor on fails the build loudly.
  assert.throws(() => injectBootScript('<html><head></head></html>'), /theme-color/);
});

test('B2 empty storage paints Mill: every token, data-theme, both metas', () => {
  const r = run({});
  assert.deepEqual(r.props, painted(BUILTIN_THEMES.mill));
  assert.equal(r.attrs['data-theme'], 'mill');
  assert.equal(r.metas['color-scheme'].content, 'dark');
  assert.equal(r.metas['theme-color'].content, BUILTIN_THEMES.mill.themeColor);
});

test('B3 the viewer pick, then the cached fleet default', () => {
  const p = run({ 'ui.theme': 'phosphor', 'ui.theme.fleet': 'mill-light' });
  assert.deepEqual(p.props, painted(BUILTIN_THEMES.phosphor));
  assert.equal(p.attrs['data-theme'], 'phosphor');
  const f = run({ 'ui.theme.fleet': 'mill-light' });
  assert.deepEqual(f.props, painted(BUILTIN_THEMES.paper));
  assert.equal(f.attrs['data-theme'], 'paper');
  assert.equal(f.metas['color-scheme'].content, 'light');
  assert.equal(f.metas['theme-color'].content, BUILTIN_THEMES.paper.themeColor);
});

test('B4 storage that throws gives Mill, and the script does not throw', () => {
  const r = run({ 'ui.theme': 'phosphor' }, { throwing: true });
  assert.equal(r.attrs['data-theme'], 'mill');
  assert.deepEqual(r.props, painted(BUILTIN_THEMES.mill));
});

test('B5 an unknown pick falls through to the fleet cache, then to Mill', () => {
  assert.equal(run({ 'ui.theme': 'garbage', 'ui.theme.fleet': 'phosphor' }).attrs['data-theme'], 'phosphor');
  assert.equal(run({ 'ui.theme': 'garbage', 'ui.theme.fleet': 'nope' }).attrs['data-theme'], 'mill');
  assert.equal(run({ 'ui.theme': ' Mill-Light ' }).attrs['data-theme'], 'paper');
});

test('B6 it is synchronous: everything is set before the script returns, nothing deferred', () => {
  const r = run({});
  assert.equal(r.set.length, Object.keys(painted(BUILTIN_THEMES.mill)).length);
  assert.doesNotMatch(bootScript(), /setTimeout|requestAnimationFrame|fetch\(|addEventListener|import\(|async /);
});
