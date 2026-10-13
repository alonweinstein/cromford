// The scene's drawn parts: one hexagon per project, one little person per live
// claim. Everything is inline SVG in the existing phosphor palette — no image
// assets, no canvas, no third-party renderer, so the whole planet is text this
// repo can diff and a screen reader can still walk.
//
// Motion lives in styles.css (.wsprite--working etc.) rather than in SMIL, so a
// reader with prefers-reduced-motion gets a still scene from one media query
// instead of from a prop threaded through every sprite.

import { html, Link } from '../router.js';
import { SPRITE_LABEL } from '../lib/world.js';

const TONE_COLOR = { ok: 'var(--green)', warn: 'var(--amber)', dead: 'var(--red)', idle: 'var(--faint)' };
export const toneColor = (t) => TONE_COLOR[t] || TONE_COLOR.idle;

// The keyboard cursor's colour. Deliberately NOT one of the four tone colours:
// where the reader is standing is not a fact about the fleet and must not be
// read as one. On this black scene that leaves plain white, backed by the
// scene's own dark so the ring reads over a lit hexagon too.
const SELECT_INK = 'var(--select-ink)';
const SELECT_BACK = 'var(--panel)';

// Pointy-top hexagon, centred on the origin.
export function hexPoints(size) {
  const pts = [];
  for (let i = 0; i < 6; i++) {
    const a = (Math.PI / 180) * (60 * i - 30);
    pts.push(`${(size * Math.cos(a)).toFixed(2)},${(size * Math.sin(a)).toFixed(2)}`);
  }
  return pts.join(' ');
}

// A project tile. The whole hexagon is the link — the tap target is the tile,
// not a word inside it, which is what makes this usable with a thumb.
export function ProjectHex({ hex, selected = false }) {
  const busy = hex.live > 0;
  const trouble = hex.raised > 0 || hex.needs_high > 0;
  const stroke = hex.paused ? 'var(--amber)' : trouble ? 'var(--red)' : busy ? 'var(--green)' : 'var(--line-active)';
  const title = [
    hex.project,
    `${hex.live} live claim${hex.live === 1 ? '' : 's'}`,
    hex.needs ? `${hex.needs} waiting on a person` : null,
    hex.queue ? `queue ${hex.queue}` : null,
    hex.paused ? 'PAUSED' : null
  ].filter(Boolean).join(' · ');

  return html`
    <${Link} to=${hex.to}
      class=${`whex${busy ? ' whex--busy' : ''}${trouble ? ' whex--trouble' : ''}${selected ? ' whex--selected' : ''}`}
      aria-label=${`${hex.project} — ${title}${selected ? ' — selected' : ''}`}>
      <title>${title}</title>
      <g transform=${`translate(${hex.x.toFixed(1)} ${hex.y.toFixed(1)})`}>
        <polygon class="whex__fill" points=${hexPoints(hex.size)}
          fill=${`hsl(${hex.hue} 30% 8%)`} style=${`stroke:${stroke}`} stroke-width="1.5"/>
        <polygon class="whex__rim" points=${hexPoints(hex.size * 0.94)} fill="none"
          style=${`stroke:${stroke}`} stroke-width="0.5" opacity="0.35"/>
        ${/* The keyboard's cursor: the tile's own outline, redrawn a little
             wider in white. */ null}
        ${selected ? html`
          <polygon class="wsel wsel--hex" points=${hexPoints(hex.size + 5)}
            fill="none" style=${`stroke:${SELECT_INK}`} stroke-width="3" stroke-linejoin="round"/>` : null}
        <text class="whex__name" x="0" y=${(hex.size * 0.74).toFixed(1)} text-anchor="middle">${hex.project}</text>
        <text class="whex__meta" x="0" y=${(hex.size * 0.9).toFixed(1)} text-anchor="middle">
          ${hex.live ? `${hex.live} live` : 'idle'}${hex.needs ? ` · ${hex.needs} need` : ''}${hex.paused ? ' · paused' : ''}
        </text>
      </g>
    <//>`;
}

// Eyes and antenna vary by a hash of the BOX name, so project-1-1 always wears
// the same face and two sprites side by side are tellable apart at a glance.
function Face({ seed, color, asleep }) {
  const eye = seed % 3;
  const antenna = seed % 2 === 0;
  const eyes = asleep
    ? html`<path d="M-4.2 -9.5 q2 1.6 4 0 M0.2 -9.5 q2 1.6 4 0" style=${`stroke:${color}`} stroke-width="1.2" fill="none" stroke-linecap="round"/>`
    : eye === 0
      ? html`<g style=${`fill:${color}`}><circle cx="-2.6" cy="-9.4" r="1.3"/><circle cx="2.6" cy="-9.4" r="1.3"/></g>`
      : eye === 1
        ? html`<g style=${`stroke:${color}`} stroke-width="1.3" stroke-linecap="round"><path d="M-3.8 -9.4 h2.4"/><path d="M1.4 -9.4 h2.4"/></g>`
        : html`<g fill="none" style=${`stroke:${color}`} stroke-width="1.1"><circle cx="-2.6" cy="-9.4" r="1.9"/><circle cx="2.6" cy="-9.4" r="1.9"/></g>`;
  return html`
    <g>
      ${antenna ? html`<path d="M0 -16.5 v-3.4" style=${`stroke:${color}`} stroke-width="1.1" stroke-linecap="round"/>
        <circle cx="0" cy="-21" r="1.4" style=${`fill:${color}`}/>` : null}
      <rect x="-7.5" y="-16.5" width="15" height="13" rx="4" style=${`fill:var(--panel);stroke:${color}`} stroke-width="1.3"/>
      ${eyes}
      ${asleep
        ? html`<path d="M-2 -6.4 h4" style=${`stroke:${color}`} stroke-width="1.1" stroke-linecap="round"/>`
        : html`<path d="M-2.6 -6.2 q2.6 2 5.2 0" style=${`stroke:${color}`} stroke-width="1.1" fill="none" stroke-linecap="round"/>`}
    </g>`;
}

// An invisible circle, not the drawing, is the tap target: the body is ~26
// scene units across and a thumb is not.
export function AgentSprite({ sprite, selected = false }) {
  const color = toneColor(sprite.tone);
  const asleep = sprite.state === 'asleep';
  const raised = Boolean(sprite.raised);
  const working = sprite.state === 'working';
  const stateLabel = SPRITE_LABEL[sprite.state] || sprite.state;
  const cls = [
    'wsprite',
    `wsprite--${sprite.state}`,
    working ? 'wsprite--working' : '',
    raised ? 'wsprite--raised' : '',
    selected ? 'wsprite--selected' : ''
  ].filter(Boolean).join(' ');

  return html`
    <${Link} to=${sprite.to} class=${cls}
      aria-label=${`${sprite.label} — ${stateLabel}${selected ? ' — selected' : ''}`}>
      <title>${sprite.label} — ${stateLabel}</title>
      <g transform=${`translate(${(sprite.x || 0).toFixed(1)} ${(sprite.y || 0).toFixed(1)})`}>
        <circle class="wsprite__hit" cx="0" cy="-4" r="26" fill="transparent"/>
        ${/* The keyboard's cursor. A ring AROUND the whole body so it can never
             be confused with the tone the body is drawn in — that one says what
             the fleet is doing, this one says where you are. Drawn under the
             body so a face is never behind a line. */ null}
        ${selected ? html`
          <g class="wsel wsel--body">
            <circle cx="0" cy="-2" r="23" fill="none" style=${`stroke:${SELECT_BACK}`} stroke-width="6" opacity="0.9"/>
            <circle cx="0" cy="-2" r="23" fill="none" style=${`stroke:${SELECT_INK}`} stroke-width="2.6"/>
          </g>` : null}
        <ellipse cx="0" cy="15.5" rx="9" ry="2.6" style="fill:var(--shadow)" opacity="0.45"/>
        <g class="wsprite__body" transform=${asleep ? 'translate(0 5) rotate(-72)' : ''}>
          <path d="M-6 14 v-8 a6 6 0 0 1 12 0 v8" style=${`fill:var(--panel);stroke:${color}`} stroke-width="1.3" stroke-linejoin="round"/>
          <${Face} seed=${sprite.face} color=${color} asleep=${asleep}/>
          ${raised
            ? html`<g class="wsprite__arm"><path d="M5.5 4 L11 -8" style=${`stroke:${color}`} stroke-width="1.6" stroke-linecap="round"/>
                <circle cx="11.6" cy="-9.4" r="1.9" style=${`fill:${color}`}/></g>`
            : working
              ? html`<g class="wsprite__arm"><path d="M-5.5 5 L-9.5 9" style=${`stroke:${color}`} stroke-width="1.5" stroke-linecap="round"/>
                  <path d="M5.5 5 L9.5 9" style=${`stroke:${color}`} stroke-width="1.5" stroke-linecap="round"/></g>`
              : html`<g><path d="M-5.5 4.5 L-8 10" style=${`stroke:${color}`} stroke-width="1.4" stroke-linecap="round"/>
                  <path d="M5.5 4.5 L8 10" style=${`stroke:${color}`} stroke-width="1.4" stroke-linecap="round"/></g>`}
        </g>
        ${raised ? html`
          <g class="wsprite__bubble">
            <rect x="12" y="-24" width="13" height="12" rx="2" style=${`fill:var(--panel);stroke:${color}`} stroke-width="1"/>
            <text x="18.5" y="-15" text-anchor="middle" style=${`fill:${color}`} font-size="9" font-weight="700">!</text>
          </g>` : null}
        ${asleep ? html`<text class="wsprite__zzz" x="11" y="-12" style="fill:var(--faint)" font-size="8">z</text>` : null}
        ${working ? html`<circle class="wsprite__beat" cx="0" cy="-24" r="2.2" style=${`fill:${color}`}/>` : null}
        <text class="wsprite__label" x="0" y=${24 + (sprite.labelDy || 0)} text-anchor="middle">${sprite.label}</text>
      </g>
    <//>`;
}
