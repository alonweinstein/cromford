// Putting a theme on the page, and remembering the choice (BH-4844).
//
// The first paint is the boot script's job (src/theme/boot.js). This module is
// everything after it: a pick on /settings/appearance, and the fleet default
// read once the app is up. Three localStorage keys, all per browser:
//   ui.theme        the viewer's own pick (absent = follow the fleet)
//   ui.theme.fleet  the last fleet default this browser read, so the next
//                   page load's boot script knows it before any fetch
//   ui.theme.cache  BH-4846: the resolved custom theme object, when the page
//                   resolves to one, so the boot script can paint it before
//                   any fetch. Only a paint hint: syncFleetDefault re-reads
//                   the rows on every load and repaints or clears it.

import { BUILTIN_THEMES, DEFAULT_THEME_ID, THEME_ALIASES } from './themes.js';
import { normalizeStoredId, resolveTheme, fleetFromSettingResponse, CUSTOM_ID_PREFIX } from './resolve.js';
import { THEME_CHANGE_EVENT } from './tokens.js';
import { customThemesFromSettings, validateThemeDoc, baseId } from './custom.js';

export const VIEWER_KEY = 'ui.theme';
export const FLEET_CACHE_KEY = 'ui.theme.fleet';
export const THEME_CACHE_KEY = 'ui.theme.cache';
export const FLEET_SETTING_KEY = 'ui.theme.default';

// Writes a theme onto a document: every token and shape key on :root, data-theme, and the
// two metas the browser reads for its own chrome. Serialised verbatim into the
// boot script, so it stays ES5 with no inner functions and no module names.
export function paintTheme(doc, theme) {
  var root = doc.documentElement;
  for (var k in theme.tokens) {
    if (Object.prototype.hasOwnProperty.call(theme.tokens, k)) root.style.setProperty(k, theme.tokens[k]);
  }
  for (k in theme.shape) {
    if (Object.prototype.hasOwnProperty.call(theme.shape, k)) root.style.setProperty(k, theme.shape[k]);
  }
  root.setAttribute('data-theme', theme.id);
  var meta = doc.querySelector('meta[name="color-scheme"]');
  if (meta) meta.setAttribute('content', theme.scheme);
  meta = doc.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute('content', theme.themeColor);
}

// paintTheme, then tell whoever draws with tokens outside CSS (/world's
// three.js scene, src/world3d/planet.js) to read them again.
export function applyTheme(doc, theme, win = globalThis.window) {
  paintTheme(doc, theme);
  if (win && typeof win.dispatchEvent === 'function' && typeof CustomEvent === 'function') {
    win.dispatchEvent(new CustomEvent(THEME_CHANGE_EVENT, { detail: { id: theme.id } }));
  }
}

export const currentThemeId = (doc) => doc.documentElement.getAttribute('data-theme');

// localStorage can be missing or throw (private mode, storage disabled). A read
// that fails is "nothing stored"; a write that fails says so.
function defaultStorage() {
  try { return globalThis.window ? window.localStorage : null; } catch { return null; }
}
// A value stored under a retired id (`mill-light`, BH-4990) reads as its
// replacement and is written back under that id, so the browser migrates once.
function read(key, storage) {
  try {
    if (!storage) return null;
    const raw = storage.getItem(key);
    const id = normalizeStoredId(raw);
    if (id && raw !== id && THEME_ALIASES[String(raw).trim().toLowerCase()] === id) storage.setItem(key, id);
    return id;
  } catch { return null; }
}
function write(key, id, storage) {
  if (!storage) return false;
  try {
    const v = normalizeStoredId(id);
    if (v) storage.setItem(key, v); else storage.removeItem(key);
    return true;
  } catch { return false; }
}

export const readViewerPick = (storage = defaultStorage()) => read(VIEWER_KEY, storage);
export const writeViewerPick = (id, storage = defaultStorage()) => write(VIEWER_KEY, id, storage);
export const readFleetCache = (storage = defaultStorage()) => read(FLEET_CACHE_KEY, storage);
export const writeFleetCache = (id, storage = defaultStorage()) => write(FLEET_CACHE_KEY, id, storage);

export const isCustomId = (id) => typeof id === 'string' && id.startsWith(CUSTOM_ID_PREFIX);

// The cached custom theme, or null. It is re-checked here (a custom id, every
// token and shape key, the colours and contrast through the validator) so a
// hand-edited cache is never painted by the app.
export function readThemeCache(storage = defaultStorage()) {
  let t;
  try { t = storage ? JSON.parse(storage.getItem(THEME_CACHE_KEY)) : null; } catch { return null; }
  if (!t || typeof t !== 'object' || !isCustomId(t.id) || normalizeStoredId(t.id) !== t.id) return null;
  if (!BUILTIN_THEMES[baseId(t.base)] || !validateThemeDoc({ v: 1, name: String(t.name || ''), base: t.base, tokens: t.tokens, shape: t.shape }).ok) return null;
  return t;
}
// Writes the custom theme the page resolved to, or (null) removes the cache.
export function writeThemeCache(theme, storage = defaultStorage()) {
  if (!storage) return false;
  try {
    if (theme && isCustomId(theme.id)) {
      const { id, name, base, scheme, themeColor, tokens, shape } = theme;
      storage.setItem(THEME_CACHE_KEY, JSON.stringify({ id, name, base, scheme, themeColor, tokens, shape }));
    } else storage.removeItem(THEME_CACHE_KEY);
    return true;
  } catch { return false; }
}

// A theme id as an object to paint: a built-in, a custom theme in `customs`
// (customThemesFromSettings().themes), else Mill.
export function themeFor(id, customs = []) {
  if (BUILTIN_THEMES[id]) return BUILTIN_THEMES[id];
  const c = customs.find((x) => x.id === id);
  return c ? c.theme : BUILTIN_THEMES[DEFAULT_THEME_ID];
}

// Reads the fleet default row, caches what it names, and repaints when the
// viewer has no pick of their own and the page shows something else.
//
// BH-4846: it also reads every settings row for the custom themes. The page
// resolves against the built-ins plus the valid customs, so a pick or a fleet
// default naming a deleted custom theme falls through to the next step (Mill
// at the end). A viewer pick of a custom theme is repainted from the rows (the
// boot script painted the cache, which may be stale or gone); a built-in pick
// never is. The custom read failing is unknown, not absent: the theme cache
// stands in for the list, and neither the cache nor a custom page is touched.
//
// Answers { ok: true, fleet, hasRow, raw, applied, customs: {ok, themes,
// skipped, error} } after a read, or { ok: false, error } when the fleet read
// failed (signed out, network, 5xx, a body that is not a settings answer). A
// failed read is unknown, not absent: it leaves the cache and the page as
// they were. It never throws.
export async function syncFleetDefault(api, { doc = globalThis.document, storage = defaultStorage(), win = globalThis.window } = {}) {
  let res;
  try {
    res = await api.coordSetting(FLEET_SETTING_KEY);
  } catch (error) {
    return { ok: false, error };
  }
  if (!res || typeof res !== 'object' || !('setting' in res)) {
    return { ok: false, error: new Error('not a settings answer') };
  }
  const fleet = fleetFromSettingResponse(res);
  const hasRow = Boolean(res.setting && typeof res.setting === 'object');
  const raw = hasRow ? res.setting.value : null;
  writeFleetCache(fleet, storage);
  let customs;
  try {
    const all = await api.settings();
    if (!all || !Array.isArray(all.settings)) throw new Error('not a settings list');
    customs = { ok: true, ...customThemesFromSettings(all.settings), error: null };
  } catch (error) {
    const cached = readThemeCache(storage);
    customs = { ok: false, themes: cached ? [{ id: cached.id, theme: cached, cachedOnly: true }] : [], skipped: [], error };
  }
  const viewer = read(VIEWER_KEY, storage);
  const { id } = resolveTheme({ viewer, fleet, customIds: customs.themes.map((t) => t.id) });
  const theme = themeFor(id, customs.themes);
  if (customs.ok) writeThemeCache(theme, storage);
  let applied = false;
  const followsRows = !viewer || (isCustomId(viewer) && customs.ok);
  if (followsRows && doc && (currentThemeId(doc) !== id || (isCustomId(id) && customs.ok))) {
    applyTheme(doc, theme, win);
    applied = true;
  }
  return { ok: true, fleet, hasRow, raw, applied, customs };
}
