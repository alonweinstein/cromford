// BH-4843 (Mission Control wave 1): the token layer.
//
// The console's colours, fonts and radii live in ONE place, the :root block of
// src/styles.css, under semantic names (--surface-0, --ok, --text-dim ...). The
// old names (--bg, --green, --muted ...) still work and still resolve to the
// exact value they held before, so nothing on screen moves. JS holds no colour
// literal of its own outside src/theme/: it writes var(--token) strings, or,
// for three.js on /world, reads the token through getComputedStyle.
//
// This suite pins all of that from the files themselves, so wave 2 (the theme
// engine) can change a token and know every surface follows it.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  SEMANTIC_TOKENS, LEGACY_ALIASES, EXTENDED_TOKENS, THEME_CHANGE_EVENT,
  onThemeChange, readToken, parseColor
} from '../src/theme/tokens.js';
import { PHOSPHOR_FALLBACK } from '../src/theme/phosphor.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SRC = path.join(root, 'src');
const CSS = fs.readFileSync(path.join(SRC, 'styles.css'), 'utf8');

// ---------------------------------------------------------------- helpers

// Every declaration inside the first `:root { ... }` block, comments stripped.
function rootVars(css) {
  const m = css.match(/:root\s*\{([\s\S]*?)\n\}/);
  assert.ok(m, 'styles.css has no :root block');
  const body = m[1].replace(/\/\*[\s\S]*?\*\//g, '');
  const vars = new Map();
  for (const d of body.matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) vars.set(d[1], d[2].trim());
  return vars;
}

// Follow var() chains to a concrete value. A cycle or a dangling name throws.
function resolve(vars, name, seen = new Set()) {
  if (seen.has(name) || seen.size > 16) throw new Error(`cycle resolving ${name}`);
  if (!vars.has(name)) throw new Error(`undeclared ${name}`);
  seen.add(name);
  return vars.get(name).replace(/var\(\s*(--[\w-]+)\s*(?:,[^)]*)?\)/g,
    (_, ref) => resolve(vars, ref, new Set(seen)));
}

const norm = (v) => String(v).toLowerCase().replace(/\s+/g, ' ').replace(/\s*([(),])\s*/g, '$1').trim();

function walk(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(p));
    else if (e.name.endsWith('.js')) out.push(p);
  }
  return out;
}

// Comments out, line count kept, so a hit still names the right line. String
// contents are left alone: a '//' inside a URL string is rare in this tree and
// would only hide text after it on that one line.
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
    .replace(/(^|[^:'"`\\])\/\/[^\n]*/g, (m, pre) => pre + ' '.repeat(m.length - pre.length));
}

// A hex colour, told apart from an issue ref like (#401), #1132 or #1510.0:
// not glued to a word char, & or # on the left (so &#9650; is an entity), not
// followed by a word char, '.' or '-', and EITHER it carries a letter a-f OR it
// sits straight after a quote, backtick, ':' or '=' (where a colour goes).
const HEX_RE = /(?<![\w&#])#([0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4})(?![\w.-])/g;
const INT_RE = /(?<![\w.])0x[0-9a-fA-F]{6}\b/g;

function scanHex(line) {
  const hits = [];
  for (const m of line.matchAll(HEX_RE)) {
    const before = line[m.index - 1];
    const hasLetter = /[a-fA-F]/.test(m[1]);
    if (hasLetter || (before && `'"\`:=`.includes(before))) hits.push(m[0]);
  }
  for (const m of line.matchAll(INT_RE)) hits.push(m[0]);
  return hits;
}

const jsFiles = walk(SRC);
const vars = rootVars(CSS);

// ------------------------------------------------------------------ tests

test('no hex colour literal in src/**/*.js outside src/theme/', () => {
  const theme = path.join(SRC, 'theme') + path.sep;
  const hits = [];
  for (const f of jsFiles) {
    if (f.startsWith(theme)) continue;
    const lines = stripComments(fs.readFileSync(f, 'utf8')).split('\n');
    lines.forEach((l, i) => {
      for (const h of scanHex(l)) hits.push(`${path.relative(root, f)}:${i + 1}: ${h}`);
    });
  }
  assert.deepEqual(hits, [], `colour literals outside src/theme/:\n${hits.join('\n')}`);
});

test('the scanner flags real colours and stays quiet on issue refs', () => {
  for (const line of ['fill="#4AF37A"', "const c = '#000';", 'style="color:#070B08"', 'new Color(0x9fd8b0)',
    'stroke=${x ? "#fff" : y}', '{ ok: `#1E3325` }']) {
    assert.ok(scanHex(stripComments(line)).length > 0, `should flag: ${line}`);
  }
  for (const line of ["'Standby: none (#401)'", 'seed value #1510.0', '// see #1132', '&#9650;',
    'see BH-#2326 in the log', '/* #FFB000 in a comment */', 'issue #147, then']) {
    assert.deepEqual(scanHex(stripComments(line)), [], `should not flag: ${line}`);
  }
});

// The value every legacy name held at c019d393c, before the token layer.
const LEGACY_PINNED = [
  ['--bg', '#070B08'], ['--panel', '#0A110B'], ['--panel-head', '#0C140E'], ['--panel-active', '#0B130D'],
  ['--terminal', '#060906'], ['--artifact', '#090F0A'], ['--line', '#16241A'], ['--line-active', '#1E3325'],
  ['--line-btn', '#26402E'], ['--line-row', '#101A12'], ['--line-warn', '#3A2B10'], ['--line-dead', '#3A1515'],
  ['--line-cyan', '#123A4A'], ['--bg-warn', '#100D06'], ['--bg-warn-2', '#120E06'], ['--bg-dead', '#100808'],
  ['--bg-cyan', '#081014'], ['--text', '#C9DCC9'], ['--select-ink', '#FFFFFF'],
  ['--select-ink-soft', 'rgba(255, 255, 255, 0.55)'], ['--bright', '#E8F5E8'], ['--soft', '#8FA996'],
  ['--soft-2', '#A8C9AE'], ['--muted', '#6E8F77'], ['--faint', '#4E6B55'], ['--fainter', '#3D5744'],
  ['--dim', '#2B3D30'], ['--green', '#4AF37A'], ['--green-lt', '#8CFFB0'], ['--green-mid', '#2E5A3A'],
  ['--green-dk', '#1E3D26'], ['--track', '#101A12'], ['--amber', '#FFB000'], ['--amber-lt', '#FFD780'],
  ['--amber-txt', '#C9A24B'], ['--amber-dk', '#8A6A2A'], ['--amber-dim', '#B8860B'], ['--red', '#FF4D4D'],
  ['--red-lt', '#FF7B7B'], ['--red-ltr', '#FF9B9B'], ['--red-txt', '#C97B7B'], ['--red-dim', '#8F7070'],
  ['--cyan', '#55D7E8'], ['--cyan-lt', '#C9EFF7'], ['--cyan-dk', '#3E7A8A'],
  ['--glow', 'rgba(74, 243, 122, 0.35)'], ['--fs-3xs', '9px'], ['--fs-2xs', '11px'], ['--fs-xs', '12px'],
  ['--fs-sm', '13px'], ['--fs-md', '14px'], ['--fs-lg', '15px'], ['--fs-xl', '16px'], ['--fs-2xl', '18px'],
  ['--fs-3xl', '20px'], ['--fs-4xl', '25px'], ['--r', '2px'], ['--nav-h', '64px']
];

test('every legacy variable still resolves to its original value', () => {
  for (const [name, want] of LEGACY_PINNED) {
    assert.equal(norm(resolve(vars, name)), norm(want), `${name} moved`);
  }
  // The eleven that became aliases really are aliases now, not copies.
  for (const [legacy, semantic] of Object.entries(LEGACY_ALIASES)) {
    assert.equal(norm(vars.get(legacy)), norm(`var(${semantic})`), `${legacy} should read ${semantic}`);
  }
  assert.equal(Object.keys(LEGACY_ALIASES).length, 11);
  // Every pinned legacy name is either an alias, a semantic token kept under
  // its own name, a type step, or listed as extended: nothing is unaccounted for.
  const covered = new Set([...Object.keys(LEGACY_ALIASES), ...EXTENDED_TOKENS, ...SEMANTIC_TOKENS]);
  for (const [name] of LEGACY_PINNED) {
    if (name.startsWith('--fs-')) continue;
    assert.ok(covered.has(name), `${name} is neither aliased, semantic nor extended`);
  }
  for (const name of EXTENDED_TOKENS) assert.ok(vars.has(name), `extended ${name} is not declared`);
});

const TICKET_SEMANTIC = [
  '--surface-0', '--surface-1', '--surface-2', '--rule', '--text', '--text-strong', '--text-dim',
  '--accent', '--ok', '--warn', '--err', '--info', '--glow',
  '--font-display', '--font-body', '--font-mono', '--radius-sm', '--radius-md', '--radius-lg'
];

test('the semantic set exists and resolves to today\'s Phosphor values', () => {
  assert.deepEqual([...SEMANTIC_TOKENS].sort(), [...TICKET_SEMANTIC].sort());
  for (const name of TICKET_SEMANTIC) {
    assert.ok(vars.has(name), `${name} not declared in :root`);
    assert.doesNotMatch(resolve(vars, name), /var\(/, `${name} does not resolve`);
  }
  const want = {
    '--surface-0': '#070B08', '--surface-1': '#0A110B', '--surface-2': '#0C140E', '--rule': '#16241A',
    '--text-strong': '#E8F5E8', '--text-dim': '#6E8F77', '--accent': '#4AF37A', '--ok': '#4AF37A',
    '--warn': '#FFB000', '--err': '#FF4D4D', '--info': '#55D7E8',
    '--radius-sm': '2px', '--radius-md': '2px', '--radius-lg': '2px'
  };
  for (const [k, v] of Object.entries(want)) assert.equal(norm(resolve(vars, k)), norm(v), k);
  const stack = "'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";
  for (const k of ['--font-display', '--font-body', '--font-mono']) assert.equal(norm(resolve(vars, k)), norm(stack), k);
  // The page font reads the token, so a theme that moves --font-body moves the page.
  assert.match(CSS, /html, body \{[^}]*font-family:\s*var\(--font-body\);/);
});

test('no var() names an undeclared variable', () => {
  // Both were already undefined on main (c019d393c) and render through their
  // fallback / inheritance today; defining them here would change pixels.
  const ALLOW = new Set(['--fg', '--mono']);
  const misses = [];
  const check = (text, where) => {
    for (const m of text.matchAll(/var\(\s*(--[\w-]+)/g)) {
      if (!vars.has(m[1]) && !ALLOW.has(m[1])) misses.push(`${where}: ${m[1]}`);
    }
  };
  check(CSS.replace(/\/\*[\s\S]*?\*\//g, ''), 'styles.css');
  for (const f of jsFiles) check(stripComments(fs.readFileSync(f, 'utf8')), path.relative(root, f));
  assert.deepEqual(misses, []);
});

test('the Phosphor fallback matches what the CSS resolves to', () => {
  assert.ok(Object.keys(PHOSPHOR_FALLBACK).length > 0);
  for (const [name, value] of Object.entries(PHOSPHOR_FALLBACK)) {
    assert.ok(vars.has(name), `${name} is not a :root token`);
    assert.equal(norm(resolve(vars, name)), norm(value), name);
  }
});

test('readToken trims, falls back on empty, and falls back with no DOM', () => {
  const saved = { document: globalThis.document, getComputedStyle: globalThis.getComputedStyle };
  try {
    delete globalThis.document;
    delete globalThis.getComputedStyle;
    assert.equal(readToken('--warn', '#ABCDEF'), '#ABCDEF');

    let value = '  #FFB000';
    globalThis.document = { documentElement: {} };
    globalThis.getComputedStyle = (el) => {
      assert.equal(el, globalThis.document.documentElement);
      return { getPropertyValue: (n) => (n === '--warn' ? value : '') };
    };
    assert.equal(readToken('--warn', '#000000'), '#FFB000');
    value = '';
    assert.equal(readToken('--warn', '#123456'), '#123456');
  } finally {
    if (saved.document === undefined) delete globalThis.document; else globalThis.document = saved.document;
    if (saved.getComputedStyle === undefined) delete globalThis.getComputedStyle; else globalThis.getComputedStyle = saved.getComputedStyle;
  }
});

test('onThemeChange hears the theme event until unsubscribed', () => {
  const saved = globalThis.window;
  try {
    delete globalThis.window;
    const noop = onThemeChange(() => { throw new Error('no window, no listener'); });
    assert.equal(typeof noop, 'function');
    noop();

    globalThis.window = new EventTarget();
    let n = 0;
    const off = onThemeChange(() => { n += 1; });
    window.dispatchEvent(new Event(THEME_CHANGE_EVENT));
    assert.equal(n, 1);
    off();
    window.dispatchEvent(new Event(THEME_CHANGE_EVENT));
    assert.equal(n, 1);
    assert.equal(THEME_CHANGE_EVENT, 'mc:themechange');
  } finally {
    if (saved === undefined) delete globalThis.window; else globalThis.window = saved;
  }
});

test('parseColor reads #rgb, #rrggbb and rgb(), and refuses junk', () => {
  assert.deepEqual(parseColor('#4AF37A'), [74, 243, 122]);
  assert.deepEqual(parseColor('#fff'), [255, 255, 255]);
  assert.deepEqual(parseColor(' #7FA98A '), [127, 169, 138]);
  assert.deepEqual(parseColor('rgb(1, 2, 3)'), [1, 2, 3]);
  assert.equal(parseColor('junk'), null);
  assert.equal(parseColor(''), null);
  assert.equal(parseColor(null), null);
  assert.equal(parseColor('#12'), null);
});

// The production surface: an icon rendered through preact carries its colour
// as a var() the stylesheet resolves, not a literal it carries itself.
test('rendered icons and dots take their colour from tokens', async () => {
  const { render } = await import('preact-render-to-string');
  const { html } = await import('../src/router.js');
  const { Dot, Logo, IconSettings } = await import('../src/ui/icons.js');
  const { healthColor } = await import('../src/ui/primitives.js');
  const { ProjectHex } = await import('../src/ui/sprites.js');

  const dot = render(html`<${Dot} color=${healthColor('warn')}/>`);
  assert.match(dot, /var\(--amber\)/);
  assert.doesNotMatch(dot, /#[0-9a-f]{6}/i);
  const logo = render(html`<${Logo}/>`);
  assert.match(logo, /var\(--green\)/);
  assert.doesNotMatch(render(html`<${IconSettings}/>`), /#[0-9a-f]{6}/i);
  const hexSvg = render(html`<svg>${html`<${ProjectHex} hex=${{ project: 'p', live: 0, raised: 0, needs_high: 0, x: 0, y: 0, size: 20, hue: 120, to: '/p' }} selected=${true}/>`}</svg>`);
  assert.match(hexSvg, /var\(--line-active\)/);
  assert.match(hexSvg, /var\(--select-ink\)/);
  assert.doesNotMatch(hexSvg, /#[0-9a-f]{6}/i);
});
