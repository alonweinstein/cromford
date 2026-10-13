// Which theme a page gets (BH-4844). Pure: no DOM, no storage.
//
// Order: the viewer's pick, then the fleet default, then Mill. A value that is
// missing, empty, not a string or not a theme this page knows (a built-in, or
// a custom theme in `customIds`, BH-4846) falls through to the next.

import { THEME_ORDER, DEFAULT_THEME_ID, THEME_ALIASES } from './themes.js';
import { parseColor } from './tokens.js';

// The one implementation of the order. It is also serialised verbatim into the
// inline boot script (src/theme/boot.js), so it stays ES5 with no inner
// functions and no names from this module: everything it needs is a parameter.
// `aliases` maps a retired id to its replacement (THEME_ALIASES, BH-4990); it
// is read by own key only, so a stored '__proto__' is still nothing.
export function pickThemeId(ids, defaultId, viewer, fleet, aliases) {
  var steps = [[viewer, 'viewer'], [fleet, 'fleet']];
  for (var i = 0; i < steps.length; i++) {
    var v = typeof steps[i][0] === 'string' ? steps[i][0].trim().toLowerCase() : '';
    if (aliases && Object.prototype.hasOwnProperty.call(aliases, v)) v = aliases[v];
    if (v && ids.indexOf(v) !== -1) return { id: v, source: steps[i][1] };
  }
  return { id: defaultId, source: 'default' };
}

// A custom theme's page id (BH-4846): custom.<slug>, the settings row being
// ui.theme.custom.<slug> (src/theme/custom.js).
export const CUSTOM_ID_PREFIX = 'custom.';
const CUSTOM_ID_RE = /^custom\.[a-z0-9-]{1,40}$/;

// A theme id among the built-ins and `customIds`, trimmed and lowercased, or null.
export function normalizeThemeId(v, customIds = []) {
  const r = pickThemeId(THEME_ORDER.concat(customIds), null, v, null, THEME_ALIASES);
  return r.source === 'viewer' ? r.id : null;
}

// A built-in id, or anything shaped like a custom id, trimmed and lowercased;
// else null. What localStorage and the fleet row may hold: whether that custom
// theme still exists is resolveTheme's question, asked with the list in hand.
export function normalizeStoredId(v) {
  const b = normalizeThemeId(v);
  if (b) return b;
  const s = typeof v === 'string' ? v.trim().toLowerCase() : '';
  return CUSTOM_ID_RE.test(s) ? s : null;
}

export function resolveTheme({ viewer = null, fleet = null, customIds = [] } = {}) {
  return pickThemeId(THEME_ORDER.concat(customIds), DEFAULT_THEME_ID, viewer, fleet, THEME_ALIASES);
}

// The fleet default named by a GET /api/coord/settings/ui.theme.default answer
// ({key, setting: row|null, source}), or null when the row is absent or does
// not name a built-in or a custom-shaped id.
export function fleetFromSettingResponse(res) {
  if (!res || typeof res !== 'object') return null;
  const s = res.setting;
  if (!s || typeof s !== 'object') return null;
  return normalizeStoredId(s.value);
}

// WCAG 2.x contrast ratio of two opaque colours, or null if either is not one.
export function contrastRatio(a, b) {
  const ca = parseColor(a);
  const cb = parseColor(b);
  if (!ca || !cb) return null;
  const lum = (rgb) => {
    const [r, g, bl] = rgb.map((c) => {
      const s = c / 255;
      return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl;
  };
  const [hi, lo] = [lum(ca), lum(cb)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}
