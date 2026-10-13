import { html } from '../router.js';

// Inline SVG only — copied from the approved mockups. No emoji, no icon font.

export const Logo = ({ size = 18 }) => html`
  <svg width=${size} height=${size} viewBox="0 0 18 18" fill="none" aria-hidden="true" style="color:var(--green)">
    <rect x="1" y="1" width="16" height="16" rx="2" stroke="currentColor" stroke-width="1.5"/>
    <path d="M5 11L8 6L10.5 10L13 7.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
  </svg>`;

export const Dot = ({ color = 'var(--green)', size = 8 }) => html`
  <svg class="dot" width=${size} height=${size} viewBox="0 0 8 8" aria-hidden="true" style=${`color:${color}`}>
    <circle cx="4" cy="4" r="3.2" fill="currentColor"/>
  </svg>`;

export const Diamond = ({ color = 'var(--cyan)', size = 9 }) => html`
  <svg width=${size} height=${size} viewBox="0 0 10 10" fill="none" aria-hidden="true" style=${`color:${color}`}>
    <path d="M5 1L9 5L5 9L1 5Z" stroke="currentColor" stroke-width="1.4"/>
  </svg>`;

export const Clock = ({ size = 10, color = 'var(--fainter)' }) => html`
  <svg width=${size} height=${size} viewBox="0 0 12 12" fill="none" aria-hidden="true" style=${`color:${color}`}>
    <path d="M6 1V6L9 8" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>
  </svg>`;

export const TimelineDot = ({ open = false, color = 'var(--green)' }) => html`
  <svg width="9" height="9" viewBox="0 0 10 10" fill="none" aria-hidden="true" style=${`color:${color}`}>
    ${open
      ? html`<circle cx="5" cy="5" r="3.5" stroke="currentColor" stroke-width="1.3"/>`
      : html`<circle cx="5" cy="5" r="3.5" fill="currentColor"/>`}
  </svg>`;

export const IconFleet = ({ color = 'var(--faint)' }) => html`
  <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true" style=${`color:${color}`}>
    <rect x="2" y="2" width="6" height="6" rx="1" stroke="currentColor" stroke-width="1.4"/>
    <rect x="10" y="2" width="6" height="6" rx="1" stroke="currentColor" stroke-width="1.4"/>
    <rect x="2" y="10" width="6" height="6" rx="1" stroke="currentColor" stroke-width="1.4"/>
    <rect x="10" y="10" width="6" height="6" rx="1" stroke="currentColor" stroke-width="1.4"/>
  </svg>`;

export const IconKanban = ({ color = 'var(--faint)' }) => html`
  <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true" style=${`color:${color}`}>
    <rect x="2" y="3" width="4" height="12" rx="1" stroke="currentColor" stroke-width="1.4"/>
    <rect x="7" y="3" width="4" height="8" rx="1" stroke="currentColor" stroke-width="1.4"/>
    <rect x="12" y="3" width="4" height="10" rx="1" stroke="currentColor" stroke-width="1.4"/>
  </svg>`;

export const IconChat = ({ color = 'var(--faint)' }) => html`
  <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true" style=${`color:${color}`}>
    <path d="M3 4H15V12H9L5.5 15V12H3V4Z" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/>
  </svg>`;

export const IconAlerts = ({ color = 'var(--faint)' }) => html`
  <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true" style=${`color:${color}`}>
    <path d="M9 2L16 15H2L9 2Z" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/>
    <path d="M9 7V10.5" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>
    <circle cx="9" cy="12.8" r="0.8" fill="currentColor"/>
  </svg>`;

export const IconCosts = ({ color = 'var(--faint)' }) => html`
  <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true" style=${`color:${color}`}>
    <circle cx="9" cy="9" r="7" stroke="currentColor" stroke-width="1.4"/>
    <path d="M9 5.5V9L11.5 10.5" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>
  </svg>`;

export const IconIdeas = ({ color = 'var(--faint)' }) => html`
  <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true" style=${`color:${color}`}>
    <path d="M9 2C6.24 2 4 4.13 4 6.75c0 1.62.87 2.9 2 3.9V12h6v-1.35c1.13-1 2-2.28 2-3.9C14 4.13 11.76 2 9 2Z"
      stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/>
    <path d="M7 14h4" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>
  </svg>`;

// NOW — a pulse: the harness's live heartbeat, not its shape.
export const IconNow = ({ color = 'var(--faint)' }) => html`
  <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true" style=${`color:${color}`}>
    <path d="M2 9h3l2-5 4 10 2-5h3" stroke="currentColor" stroke-width="1.4"
      stroke-linecap="round" stroke-linejoin="round"/>
  </svg>`;

// NEEDS — an inbox with something still in it.
export const IconNeeds = ({ color = 'var(--faint)' }) => html`
  <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true" style=${`color:${color}`}>
    <path d="M2.5 10.5V14a1 1 0 0 0 1 1h11a1 1 0 0 0 1-1v-3.5" stroke="currentColor"
      stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/>
    <path d="M2.5 10.5 4.5 4h9l2 6.5h-4a2 2 0 0 1-4 0h-5Z" stroke="currentColor"
      stroke-width="1.4" stroke-linejoin="round"/>
  </svg>`;

// A planet with a ring: the WORLD tab is the fleet drawn as a place.
export const IconWorld = ({ color = 'var(--faint)' }) => html`
  <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true" style=${`color:${color}`}>
    <circle cx="9" cy="8.5" r="5" stroke="currentColor" stroke-width="1.4"/>
    <path d="M4 8.5h10M9 3.5c1.6 1.6 1.6 8.4 0 10M9 3.5c-1.6 1.6-1.6 8.4 0 10" stroke="currentColor"
      stroke-width="1.1" stroke-linecap="round"/>
    <path d="M2.5 11.5c2.6 1.9 10.4 1.9 13 0" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>
  </svg>`;

// DORA — a stopwatch. Every metric on that tab is an INTERVAL: how long from
// starting a change to landing it, from approval to merge, from a failure to
// the next landing. The glyph is the question, not the subject.
export const IconDora = ({ color = 'var(--faint)' }) => html`
  <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true" style=${`color:${color}`}>
    <circle cx="9" cy="10" r="6" stroke="currentColor" stroke-width="1.4"/>
    <path d="M9 7v3l2 1.5" stroke="currentColor" stroke-width="1.4"
      stroke-linecap="round" stroke-linejoin="round"/>
    <path d="M7 2h4M9 2v2" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>
  </svg>`;

// OUTCOMES — an arrow that lands and comes BACK. The tab is not about output
// (every other glyph here is); it is about the merges that returned.
export const IconOutcomes = ({ color = 'var(--faint)' }) => html`
  <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true" style=${`color:${color}`}>
    <path d="M2.5 12.5c2.5 0 4-1.5 5.5-4s3-4 5.5-4" stroke="currentColor"
      stroke-width="1.4" stroke-linecap="round"/>
    <path d="M11 4.5h2.5V7" stroke="currentColor" stroke-width="1.4"
      stroke-linecap="round" stroke-linejoin="round"/>
    <path d="M15.5 14.5H5.5a3 3 0 0 1-3-3" stroke="currentColor" stroke-width="1.4"
      stroke-linecap="round"/>
    <path d="M4 9.5 2.5 11.5 4 13.5" stroke="currentColor" stroke-width="1.4"
      stroke-linecap="round" stroke-linejoin="round"/>
  </svg>`;

// SETTINGS — sliders, not a cog. The screen is not "preferences"; it is the set
// of knobs and switches that bound what the fleet is allowed to do on its own,
// and a row of sliders is what that looks like.
export const IconSettings = ({ color = 'var(--faint)' }) => html`
  <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true" style=${`color:${color}`}>
    <path d="M3 5h12M3 9h12M3 13h12" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>
    <circle cx="6.5" cy="5" r="1.8" style="fill:var(--bg)" stroke="currentColor" stroke-width="1.4"/>
    <circle cx="11.5" cy="9" r="1.8" style="fill:var(--bg)" stroke="currentColor" stroke-width="1.4"/>
    <circle cx="7.5" cy="13" r="1.8" style="fill:var(--bg)" stroke="currentColor" stroke-width="1.4"/>
  </svg>`;

// A ladder: the primary rung on top, failover rungs below it.
export const IconModels = ({ color = 'var(--faint)' }) => html`
  <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true" style=${`color:${color}`}>
    <path d="M5 2V16M13 2V16" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>
    <path d="M5 5H13M5 9H13M5 13H13" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>
  </svg>`;
