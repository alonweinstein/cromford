// Custom themes (BH-4846). A custom theme is a settings row
// ui.theme.custom.<slug> whose value is a theme doc:
//
//   { v: 1, name, base, tokens: { '--surface-0': '#…', … }, shape: { '--radius-md': '10px', … } }
//
// `base` is a built-in id. At paint time the doc is merged onto its base, so a
// token a later release adds to the built-ins still gets a value. Its page id
// is custom.<slug>, and the row's `actor` column says who saved it.
//
// validateThemeDoc is the one gate. The coord proxy runs it on every write
// (functions/api/coord/[[path]].js), import runs it on every file, and every
// read runs it again: a row that fails is listed as skipped and never painted.

import { BUILTIN_THEMES, THEME_ORDER, TEXT_PAIRS, THEME_ALIASES } from './themes.js';
import { SHAPE_TOKENS, parseColor } from './tokens.js';
import { contrastRatio, CUSTOM_ID_PREFIX } from './resolve.js';

export const CUSTOM_PREFIX = 'ui.theme.custom.';
export const CUSTOM_KEY_RE = /^ui\.theme\.custom\.[a-z0-9-]{1,40}$/;
// The worker's value cap for a custom-theme row (worker/jobs/src/routes/settings.js).
export const MAX_DOC_CHARS = 4096;
export const MIN_CONTRAST = 4.5;
const NAME_MAX = 40;
const DOC_KEYS = ['v', 'name', 'base', 'tokens', 'shape'];

export const customId = (slug) => CUSTOM_ID_PREFIX + slug;

// 'Night Shift v2!' -> 'night-shift-v2'. '' when nothing is left.
export function slugify(name) {
  return String(name ?? '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, NAME_MAX).replace(/-+$/, '');
}

// Every colour key a theme sets: the built-ins all carry the same set.
export const COLOR_KEYS = Object.keys(BUILTIN_THEMES[THEME_ORDER[0]].tokens);

// The self-hosted woff2 set (public/fonts): one stack per face, as the
// built-ins write it. Any face can fill any role.
const stacksOf = (key) => THEME_ORDER.map((id) => BUILTIN_THEMES[id].shape[key]);
export const FONT_CHOICES = [
  { label: 'Archivo', stack: BUILTIN_THEMES.mill.shape['--font-display'] },
  { label: 'Geist', stack: BUILTIN_THEMES.mill.shape['--font-body'] },
  { label: 'Geist Mono', stack: BUILTIN_THEMES.mill.shape['--font-mono'] },
  { label: 'JetBrains Mono', stack: BUILTIN_THEMES.phosphor.shape['--font-mono'] }
];
export const FONT_ROLES = ['--font-display', '--font-body', '--font-mono'];
export const RADIUS_KEYS = ['--radius-sm', '--radius-md', '--radius-lg'];
export const RADIUS_MAX = 24;

// A built-in as an editable doc: what NEW THEME FROM starts with.
export function docFromTheme(theme, name) {
  return { v: 1, name, base: theme.id, tokens: { ...theme.tokens }, shape: { ...theme.shape } };
}

const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

// A doc's `base` with a retired built-in id mapped to its replacement: a row
// saved on `mill-light` before BH-4990 is a theme on Paper.
export const baseId = (b) => (typeof b === 'string' && own(THEME_ALIASES, b) ? THEME_ALIASES[b] : b);
const baseOf = (doc) => BUILTIN_THEMES[baseId(doc && doc.base)] || BUILTIN_THEMES[THEME_ORDER[0]];
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
// A text pair needs a colour with no alpha: a ratio taken on a translucent
// colour's opaque part is a number about some other colour.
const isOpaque = (v) => /^#/.test(v.trim()) || /^rgb\(/i.test(v.trim());

// The doc's colours on top of its base's.
export function mergedTokens(doc) {
  const base = baseOf(doc);
  return { ...base.tokens, ...((doc && isObj(doc.tokens)) ? doc.tokens : {}) };
}
function mergedShape(doc) {
  const base = baseOf(doc);
  return { ...base.shape, ...((doc && isObj(doc.shape)) ? doc.shape : {}) };
}

// Every TEXT_PAIRS pair under 4.5:1, as [{fg, bg, ratio}]; ratio null when
// either side is not an opaque colour.
export function contrastFailures(tokens) {
  const out = [];
  for (const [fg, bg] of TEXT_PAIRS) {
    const a = tokens[fg];
    const b = tokens[bg];
    const ratio = typeof a === 'string' && typeof b === 'string' && isOpaque(a) && isOpaque(b) ? contrastRatio(a, b) : null;
    if (ratio === null || ratio < MIN_CONTRAST) out.push({ fg, bg, ratio });
  }
  return out;
}

const fmt = (r) => (r === null ? 'no ratio (not an opaque colour)' : `${(Math.floor(r * 100) / 100).toFixed(2)}:1`);

function shapeError(key, v) {
  if (typeof v !== 'string') return `${key} must be a string`;
  if (FONT_ROLES.includes(key)) {
    return FONT_CHOICES.some((f) => f.stack === v) ? null : `${key} must be one of the self-hosted fonts (${FONT_CHOICES.map((f) => f.label).join(', ')})`;
  }
  if (RADIUS_KEYS.includes(key)) {
    const m = /^(\d{1,2})px$/.exec(v);
    return m && Number(m[1]) <= RADIUS_MAX ? null : `${key} must be 0px to ${RADIUS_MAX}px`;
  }
  // The rest of the form (pill radius, label case, glows) is not editable:
  // a custom theme carries a value one of the built-ins has.
  return stacksOf(key).includes(v) ? null : `${key} must be one of the built-in values (${[...new Set(stacksOf(key))].join(' | ')})`;
}

// { ok, errors: [string], doc } where doc is a clean copy (own known keys
// only) when ok, else null.
export function validateThemeDoc(doc) {
  const errors = [];
  if (!isObj(doc)) return { ok: false, errors: ['a theme must be a JSON object'], doc: null };
  for (const k of Object.keys(doc)) if (!DOC_KEYS.includes(k)) errors.push(`unknown field ${k}`);
  if (doc.v !== 1) errors.push('v must be 1');
  const name = typeof doc.name === 'string' ? doc.name.trim() : '';
  if (!name || name.length > NAME_MAX) errors.push(`name must be 1 to ${NAME_MAX} characters`);
  else if (!slugify(name)) errors.push('name needs at least one letter or digit');
  const base = baseId(doc.base);
  if (typeof base !== 'string' || !THEME_ORDER.includes(base)) errors.push(`base must be a built-in theme (${THEME_ORDER.join(', ')})`);
  const tokens = {};
  if (!isObj(doc.tokens)) errors.push('tokens must be an object');
  else {
    for (const k of Object.keys(doc.tokens)) {
      const v = doc.tokens[k];
      if (!COLOR_KEYS.includes(k)) errors.push(`${k} is not a colour token`);
      else if (typeof v !== 'string' || !parseColor(v)) errors.push(`${k} must be a colour (#rgb, #rrggbb, rgb() or rgba()), not ${JSON.stringify(v)}`);
      else tokens[k] = v;
    }
  }
  const shape = {};
  if (!isObj(doc.shape)) errors.push('shape must be an object');
  else {
    for (const k of Object.keys(doc.shape)) {
      if (!SHAPE_TOKENS.includes(k)) { errors.push(`${k} is not a shape token`); continue; }
      const e = shapeError(k, doc.shape[k]);
      if (e) errors.push(e); else shape[k] = doc.shape[k];
    }
  }
  if (!errors.length) {
    for (const f of contrastFailures(mergedTokens({ base, tokens }))) {
      errors.push(`contrast: ${f.fg} on ${f.bg} is ${fmt(f.ratio)}, under ${MIN_CONTRAST}:1`);
    }
  }
  if (errors.length) return { ok: false, errors, doc: null };
  return { ok: true, errors: [], doc: { v: 1, name, base, tokens, shape } };
}

// Canonical JSON: keys sorted at every level, no whitespace. The same doc
// always exports the same bytes, and it is what a custom row stores.
function canon(v) {
  if (Array.isArray(v)) return v.map(canon);
  if (isObj(v)) return Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])]));
  return v;
}
export const exportTheme = (doc) => JSON.stringify(canon(doc));

// Text (a file, a settings value) -> { ok, errors, doc }, through the same validator.
export function importTheme(text) {
  const s = String(text ?? '');
  if (s.length > MAX_DOC_CHARS) return { ok: false, errors: [`a theme file is at most ${MAX_DOC_CHARS} characters; this one is ${s.length}`], doc: null };
  let doc;
  try { doc = JSON.parse(s); } catch { return { ok: false, errors: ['not valid JSON'], doc: null }; }
  return validateThemeDoc(doc);
}

// A valid doc as a paintable theme object, with every token and shape key set.
export function toTheme(doc, slug) {
  const base = baseOf(doc);
  const tokens = mergedTokens(doc);
  return {
    id: customId(slug), name: doc.name, scheme: base.scheme, themeColor: tokens['--surface-0'],
    tokens, shape: mergedShape(doc), base: base.id, custom: true
  };
}

// GET /api/coord/settings rows -> { themes: [{id, slug, doc, theme, actor, updatedAt}], skipped: [{key, errors}] }.
export function customThemesFromSettings(rows) {
  const themes = [];
  const skipped = [];
  for (const r of Array.isArray(rows) ? rows : []) {
    if (!r || typeof r.key !== 'string' || !r.key.startsWith(CUSTOM_PREFIX)) continue;
    if (!CUSTOM_KEY_RE.test(r.key)) { skipped.push({ key: r.key, errors: ['the key is not ui.theme.custom.<a-z0-9->'] }); continue; }
    const res = importTheme(r.value);
    if (!res.ok) { skipped.push({ key: r.key, errors: res.errors }); continue; }
    const slug = r.key.slice(CUSTOM_PREFIX.length);
    themes.push({ id: customId(slug), slug, doc: res.doc, theme: toTheme(res.doc, slug), actor: r.actor || null, updatedAt: r.updated_at || null });
  }
  return { themes, skipped };
}

// A colour as an <input type=color> takes it: #rrggbb, lowercase. null for
// anything that is not opaque hex (rgba tokens get a text field instead).
export function pickerHex(v) {
  const s = String(v ?? '').trim().toLowerCase();
  if (/^#[0-9a-f]{6}$/.test(s)) return s;
  if (/^#[0-9a-f]{3}$/.test(s)) return '#' + s.slice(1).replace(/./g, (c) => c + c);
  return null;
}

// What the editor's live preview paints: the doc on its base, keeping only
// values the validator would take one by one (a colour that parses, a shape
// value in range or in the built-in set), so a half-typed or hostile value
// never reaches an inline style. Contrast is not filtered: the preview shows it.
export function previewTheme(doc) {
  const base = baseOf(doc);
  const tokens = { ...base.tokens };
  const shape = { ...base.shape };
  const t = doc && isObj(doc.tokens) ? doc.tokens : {};
  const sh = doc && isObj(doc.shape) ? doc.shape : {};
  for (const k of COLOR_KEYS) if (own(t, k) && typeof t[k] === 'string' && parseColor(t[k])) tokens[k] = t[k];
  for (const k of SHAPE_TOKENS) if (own(sh, k) && !shapeError(k, sh[k])) shape[k] = sh[k];
  return { tokens, shape };
}
