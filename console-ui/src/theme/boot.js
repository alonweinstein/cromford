// The first-paint theme (BH-4844): an inline classic <script> in <head>, above
// every stylesheet, that picks the theme from localStorage and writes its
// tokens and shape onto :root before the CSS paints. No flash of the wrong theme.
//
// It is generated at build time from the same objects and functions the app
// uses (themes.js, resolve.js pickThemeId, apply.js paintTheme), so no colour
// is hand-copied into index.html. It cannot fetch: the fleet default it knows
// is the one this browser cached on its last visit (ui.theme.fleet). On a
// browser's very first visit that cache is empty, so that one load paints
// Mill and syncFleetDefault (src/main.js) repaints if the fleet says otherwise.
//
// BH-4846: a custom theme cannot be known at build time, so the script also
// reads ui.theme.cache, the last custom theme this browser resolved to. It is
// offered to the pick only under a custom.* id (never in place of a built-in),
// so it paints only when the viewer's pick or the cached fleet default names
// exactly that theme. Anything else, or a cache that does not parse, is the
// built-in path unchanged.

import { BUILTIN_THEMES, THEME_ORDER, DEFAULT_THEME_ID, THEME_ALIASES } from './themes.js';
import { pickThemeId } from './resolve.js';
import { paintTheme, VIEWER_KEY, FLEET_CACHE_KEY, THEME_CACHE_KEY } from './apply.js';
import { CUSTOM_ID_PREFIX } from './resolve.js';

// JSON, safe inside a <script>: no '<' can close the element early.
const js = (v) => JSON.stringify(v).replace(/</g, '\\u003c');

export function bootScript() {
  const themes = {};
  for (const id of THEME_ORDER) {
    const t = BUILTIN_THEMES[id];
    themes[id] = { id: t.id, scheme: t.scheme, themeColor: t.themeColor, tokens: t.tokens, shape: t.shape };
  }
  return '(function(){'
    + `var T=${js(themes)},I=${js(THEME_ORDER)},D=${js(DEFAULT_THEME_ID)},A=${js(THEME_ALIASES)};`
    + `var pick=${pickThemeId.toString()};`
    + `var paint=${paintTheme.toString()};`
    + 'var id=D;'
    + 'try{var s=window.localStorage,ids=I,C=null;'
    + `try{C=JSON.parse(s.getItem(${js(THEME_CACHE_KEY)}))}catch(e){C=null}`
    + `if(C&&typeof C.id==='string'&&C.id.indexOf(${js(CUSTOM_ID_PREFIX)})===0&&C.tokens&&C.shape){T[C.id]=C;ids=I.concat([C.id])}`
    + `id=pick(ids,D,s.getItem(${js(VIEWER_KEY)}),s.getItem(${js(FLEET_CACHE_KEY)}),A).id}catch(e){id=D}`
    + 'try{paint(document,T[id])}catch(e){}'
    + '})();';
}

// Puts the script straight after <meta name="theme-color">: after the charset
// and both metas it rewrites, before the font preload, the stylesheet Vite
// injects and the app module. No anchor, no build: a page that would flash is
// a build failure, not a quiet regression.
export function injectBootScript(html) {
  const anchor = /<meta name="theme-color"[^>]*>/;
  if (!anchor.test(html)) throw new Error('theme boot: index.html has no <meta name="theme-color"> to anchor the boot script on');
  return html.replace(anchor, (m) => `${m}\n<script>${bootScript()}</script>`);
}

export function themeBootPlugin() {
  return {
    name: 'mc-theme-boot',
    transformIndexHtml: { order: 'pre', handler: injectBootScript }
  };
}
