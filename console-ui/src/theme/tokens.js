// The console's token layer (BH-4843). The values live in the :root block of
// src/styles.css; this file names them for JS and is the one way JS reads them.
//
// src/theme/ is the only place in src/ that may hold a colour literal. Anything
// else writes a `var(--token)` string (SVG, inline styles), or, where a string
// is no use (three.js on /world), calls readToken() and listens for
// THEME_CHANGE_EVENT so it can read again. The theme engine (src/theme/apply.js,
// BH-4844) dispatches it after it sets :root.

// What a theme sets.
export const SEMANTIC_TOKENS = [
  '--surface-0', '--surface-1', '--surface-2', '--rule',
  '--text', '--text-strong', '--text-dim',
  '--accent', '--ok', '--warn', '--err', '--info', '--glow',
  '--font-display', '--font-body', '--font-mono',
  '--radius-sm', '--radius-md', '--radius-lg'
];

// Pre-token names, now aliases in styles.css: legacy -> the semantic token it reads.
export const LEGACY_ALIASES = {
  '--bg': '--surface-0',
  '--panel': '--surface-1',
  '--panel-head': '--surface-2',
  '--line': '--rule',
  '--bright': '--text-strong',
  '--muted': '--text-dim',
  '--green': '--ok',
  '--amber': '--warn',
  '--red': '--err',
  '--cyan': '--info',
  '--r': '--radius-sm'
};

// Ramp steps and one-offs with no semantic twin. They keep a literal value in
// styles.css; a theme may override any of them.
export const EXTENDED_TOKENS = [
  '--panel-active', '--terminal', '--artifact',
  '--line-active', '--line-btn', '--line-row', '--line-warn', '--line-dead', '--line-cyan',
  '--bg-warn', '--bg-warn-2', '--bg-dead', '--bg-cyan',
  '--select-ink', '--select-ink-soft',
  '--soft', '--soft-2', '--faint', '--fainter', '--dim',
  '--green-lt', '--green-mid', '--green-dk', '--track',
  '--amber-lt', '--amber-txt', '--amber-dk', '--amber-dim',
  '--red-lt', '--red-ltr', '--red-txt', '--red-dim',
  '--cyan-lt', '--cyan-dk',
  '--nav-h',
  '--world-idle', '--world-label', '--world-label-live', '--world-sky', '--world-ground',
  '--world-sun', '--world-rim', '--world-ring', '--hex-sky-top', '--shadow',
  // BH-4844: literals that sat in rules outside :root until the theme engine.
  '--surface-nav', '--ink-on-ok', '--note', '--line-hover', '--line-warn-hover', '--line-cyan-hover',
  '--row-warn-hover', '--term-text', '--artifact-text', '--transcript-text', '--skeleton-hi', '--scrim',
  '--world-bg', '--world-tip-bg',
  // BH-4845: in-progress only (the running step's fill, its label). Brick in
  // Mill; Phosphor keeps today's --green-mid / --green-lt.
  '--live', '--live-text',
  // BH-4990: the line screens' blueprint grid and the current station's wash.
  '--grid', '--live-soft'
];

// The form a theme sets (BH-4845): fonts, radii, label case, title, brand,
// nav-tab and stat glow. Not
// colours, so they ride in a theme's `shape`, not its `tokens`. styles.css
// declares each in :root at its Phosphor value.
export const SHAPE_TOKENS = [
  '--font-display', '--font-body', '--font-mono',
  '--radius-sm', '--radius-md', '--radius-lg', '--radius-pill',
  '--label-case', '--display-stretch', '--title-shadow', '--brand-shadow',
  '--nav-shadow', '--stat-shadow'
];

export const THEME_CHANGE_EVENT = 'mc:themechange';

// Calls cb on every theme change; returns the unsubscribe. Without a window
// (node, SSR) there is nothing to hear and the unsubscribe does nothing.
export function onThemeChange(cb) {
  if (typeof window === 'undefined' || !window.addEventListener) return () => {};
  const handler = () => cb();
  window.addEventListener(THEME_CHANGE_EVENT, handler);
  return () => window.removeEventListener(THEME_CHANGE_EVENT, handler);
}

// The resolved value of a :root token, or `fallback` when there is no DOM or
// the stylesheet has not applied yet (the property reads as empty).
export function readToken(name, fallback) {
  if (typeof document === 'undefined' || typeof getComputedStyle !== 'function') return fallback;
  const v = String(getComputedStyle(document.documentElement).getPropertyValue(name) || '').trim();
  return v || fallback;
}

// '#rgb', '#rrggbb' or 'rgb(r, g, b)' -> [r, g, b]; anything else -> null.
export function parseColor(str) {
  const s = String(str ?? '').trim();
  let m = s.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i);
  if (m) {
    const h = m[1].length === 3 ? m[1].replace(/./g, (c) => c + c) : m[1];
    return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
  }
  m = s.match(/^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(?:,\s*[\d.]+\s*)?\)$/i);
  if (m) {
    const rgb = m.slice(1, 4).map(Number);
    return rgb.every((n) => n <= 255) ? rgb : null;
  }
  return null;
}
