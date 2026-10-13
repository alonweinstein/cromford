// The top bar (BH-4990, wave 1 of BH-4947): brand, the section nav, the
// snapshot age and refresh countdown, who this session writes as, the
// watchdog, and a theme switch. The nav scrolls sideways inside itself on a
// phone; the body never does.
//
// The switch is the same pick /settings/appearance makes (the viewer's own
// ui.theme, then a repaint), for the three built-ins only. Custom themes stay
// on /settings/appearance. Its pressed button follows the page: a pick made
// anywhere else (APPEARANCE, the fleet default arriving) re-reads data-theme
// on THEME_CHANGE_EVENT.
//
// `nav` is the NAV table from src/app.js, handed in so this file does not
// import the app that renders it.

import { useState, useEffect } from 'preact/hooks';
import { html, Link } from '../router.js';
import { snapshotLabel, healthFromAge } from '../lib/format.js';
import { identityPill } from '../lib/identity.js';
import { Logo, Dot } from './icons.js';
import { healthColor } from './primitives.js';
import { BUILTIN_THEMES, THEME_ORDER } from '../theme/themes.js';
import { applyTheme, currentThemeId, writeViewerPick, writeThemeCache, themeFor } from '../theme/apply.js';
import { onThemeChange } from '../theme/tokens.js';

const pageTheme = () => (typeof document !== 'undefined' && document.documentElement ? currentThemeId(document) : null);

export function ThemeSwitch() {
  const [active, setActive] = useState(pageTheme);
  useEffect(() => onThemeChange(() => setActive(pageTheme())), []);
  const pick = (id) => {
    const theme = themeFor(id);
    writeViewerPick(id);
    writeThemeCache(theme);
    applyTheme(document, theme);
    setActive(id);
  };
  return html`
    <div class="themeswitch" role="group" aria-label="Theme">
      ${THEME_ORDER.map((id) => html`
        <button key=${id} type="button" class=${active === id ? 'themeswitch__btn themeswitch__btn--on' : 'themeswitch__btn'}
          data-theme-switch=${id} aria-pressed=${active === id ? 'true' : 'false'}
          onClick=${() => pick(id)}>${BUILTIN_THEMES[id].name}</button>`)}
    </div>`;
}

export function TopBar({ nav = [], path, snap, openAlerts, loading, secondsLeft, watchdogDown, identity }) {
  const health = healthFromAge(snap.snapshot_age_min);
  const who = identityPill(identity ? identity.data : null, identity ? identity.error : null);
  return html`
    <div class="topbar">
      <${Link} to="/" class="topbar__brand">
        <${Logo}/>
        <span class="topbar__title">MISSION CONTROL</span>
        <span class="topbar__sub hide-sm">cromford</span>
      <//>
      <nav class="topbar__nav" aria-label="sections">
        ${nav.map((n) => html`
          <${Link} key=${n.to} to=${n.to} class=${n.match(path) ? 'navlink navlink--on' : 'navlink'}>
            ${n.label}
            ${n.badge && openAlerts > 0 ? html`<span class="navlink__badge">${openAlerts}</span>` : null}
          <//>`)}
      </nav>
      <div class="topbar__right">
        <span class="topbar__snap">
          ${loading && snap.snapshot_age_min === undefined
            ? 'loading…'
            : html`<span class=${`topbar__age topbar__age--${health === 'ok' ? 'ok' : health === 'warn' ? 'warn' : 'bad'}`}>${snapshotLabel(snap.snapshot_age_min)}</span>`}
        </span>
        <span class="topbar__refresh hide-sm" title="the fleet poll refreshes on this cadence">
          refresh ${secondsLeft}s
        </span>
        <span class=${who.tone === 'ok' ? 'pill' : who.tone === 'warn' ? 'pill pill--warn' : 'pill pill--muted'}
          style="display:inline-block;min-width:0;max-width:40vw;overflow:hidden;text-overflow:ellipsis"
          title=${who.title}>${who.text}</span>
        <span class=${watchdogDown ? 'pill pill--warn' : 'pill'}>
          <${Dot} color=${watchdogDown ? 'var(--amber)' : healthColor(health)} size=${8}/>
          ${watchdogDown ? 'WATCHDOG DOWN' : 'WATCHDOG OK'}
        </span>
        <${ThemeSwitch}/>
      </div>
    </div>`;
}
