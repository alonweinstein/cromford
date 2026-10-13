// BH-4844 (Mission Control wave 2): every built-in theme is legible, themes
// every colour the stylesheet has, and Phosphor is today's look exactly.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { BUILTIN_THEMES, THEME_ORDER, TEXT_PAIRS } from '../src/theme/themes.js';
import { contrastRatio } from '../src/theme/resolve.js';
import { SEMANTIC_TOKENS, EXTENDED_TOKENS } from '../src/theme/tokens.js';
import { PHOSPHOR_FALLBACK } from '../src/theme/phosphor.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CSS = fs.readFileSync(path.join(root, 'src', 'styles.css'), 'utf8');

function rootBlock(css) {
  const m = css.match(/:root\s*\{([\s\S]*?)\n\}/);
  assert.ok(m, 'styles.css has no :root block');
  return m;
}
function rootVars(css) {
  const vars = new Map();
  for (const d of rootBlock(css)[1].replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) {
    vars.set(d[1], d[2].trim());
  }
  return vars;
}
const COLOUR = /^(#[0-9a-f]{3}|#[0-9a-f]{6}|rgba?\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*(,\s*(0|1|0?\.\d+)\s*)?\))$/i;
const norm = (v) => String(v).toLowerCase().replace(/\s+/g, '');
const vars = rootVars(CSS);
const literalColourKeys = [...vars].filter(([, v]) => COLOUR.test(v)).map(([k]) => k).sort();

// The pair list the ticket asks for: every text token on every surface.
const FG = ['--text', '--text-strong', '--text-dim', '--accent', '--ok', '--warn', '--err', '--info'];
const BG = ['--surface-0', '--surface-1', '--surface-2'];

function contrastFailures(theme) {
  const out = [];
  for (const [fg, bg] of TEXT_PAIRS) {
    const r = contrastRatio(theme.tokens[fg], theme.tokens[bg]);
    if (!(r >= 4.5)) out.push(`${theme.id}: ${fg} ${theme.tokens[fg]} on ${bg} ${theme.tokens[bg]} = ${r && r.toFixed(2)}`);
  }
  return out;
}

test('there are three built-ins, Mill first', () => {
  assert.deepEqual(THEME_ORDER, ['mill', 'paper', 'phosphor']);
  assert.deepEqual(Object.keys(BUILTIN_THEMES), THEME_ORDER);
  assert.deepEqual(THEME_ORDER.map((id) => BUILTIN_THEMES[id].name), ['Mill', 'Paper', 'Phosphor']);
  assert.deepEqual(THEME_ORDER.map((id) => BUILTIN_THEMES[id].scheme), ['dark', 'light', 'dark']);
});

test('C1 every text token clears 4.5:1 on every surface, in every theme', () => {
  for (const fg of FG) for (const bg of BG) {
    assert.ok(TEXT_PAIRS.some(([f, b]) => f === fg && b === bg), `TEXT_PAIRS is missing ${fg} on ${bg}`);
  }
  assert.ok(TEXT_PAIRS.some(([f, b]) => f === '--ink-on-ok' && b === '--ok'), 'the active nav ink on --ok is checked too');
  const fails = THEME_ORDER.flatMap((id) => contrastFailures(BUILTIN_THEMES[id]));
  assert.deepEqual(fails, []);
});

test('C2 contrastRatio is the WCAG formula, and C1 can go red', () => {
  assert.equal(contrastRatio('#000', '#fff'), 21);
  assert.equal(contrastRatio('#ffffff', '#000000'), 21);
  assert.ok(Math.abs(contrastRatio('#777777', '#ffffff') - 4.48) < 0.01);
  assert.equal(contrastRatio('#abcdef', '#abcdef'), 1);
  assert.equal(contrastRatio('junk', '#fff'), null);
  // A planted failing pair: same check, one token swapped to a low-contrast grey.
  const planted = { ...BUILTIN_THEMES.mill, tokens: { ...BUILTIN_THEMES.mill.tokens, '--text-dim': '#3a3833' } };
  const fails = contrastFailures(planted);
  assert.equal(fails.length, 3);
  assert.match(fails[0], /^mill: --text-dim #3a3833 on --surface-0 #0d0d0c = \d\.\d\d$/);
});

test('C3 every theme sets the same tokens, and they are every colour :root declares', () => {
  assert.ok(literalColourKeys.length > 40, 'the :root parse found the colour tokens');
  for (const id of THEME_ORDER) {
    assert.deepEqual(Object.keys(BUILTIN_THEMES[id].tokens).sort(), literalColourKeys, `${id} key set`);
  }
  // Each one is a token the wave-1 layer knows about.
  const known = new Set([...SEMANTIC_TOKENS, ...EXTENDED_TOKENS]);
  for (const k of literalColourKeys) assert.ok(known.has(k), `${k} is in :root but not in tokens.js`);
});

test('C3b no rule outside :root carries its own colour, so a theme reaches all of them', () => {
  const m = rootBlock(CSS);
  const rest = (CSS.slice(0, m.index) + CSS.slice(m.index + m[0].length)).replace(/\/\*[\s\S]*?\*\//g, '');
  const hex = rest.match(/#[0-9a-fA-F]{3,8}\b/g) || [];
  assert.deepEqual(hex, []);
  // Plain black shadows read the same on every theme; any other rgba is a colour.
  const rgba = (rest.match(/rgba?\([^)]*\)/g) || []).filter((v) => !/^rgba\(0,\s*0,\s*0,/.test(v));
  assert.deepEqual(rgba, []);
});

test('C4 Phosphor is today\'s :root, value for value', () => {
  const p = BUILTIN_THEMES.phosphor;
  for (const k of literalColourKeys) assert.equal(norm(p.tokens[k]), norm(vars.get(k)), k);
  assert.equal(p.themeColor.toLowerCase(), vars.get('--surface-0').toLowerCase());
  // wave 1's pre-CSS fallback is the same object's values
  for (const [k, v] of Object.entries(PHOSPHOR_FALLBACK)) {
    if (k in p.tokens) assert.equal(norm(p.tokens[k]), norm(v), k);
  }
});

test('C5 every token value is a colour, and themeColor is an opaque hex', () => {
  for (const id of THEME_ORDER) {
    const t = BUILTIN_THEMES[id];
    for (const [k, v] of Object.entries(t.tokens)) assert.match(v, COLOUR, `${id} ${k}=${v}`);
    assert.match(t.themeColor, /^#[0-9a-f]{6}$/i, `${id} themeColor`);
    assert.equal(t.themeColor.toLowerCase(), t.tokens['--surface-0'].toLowerCase(), `${id} themeColor is its page colour`);
  }
});
