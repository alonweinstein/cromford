// What you are pointing at, named.
//
// It appears the instant a finger lands on a body and it appears the instant an
// arrow key walks onto one, so a tap and a keypress tell you the same thing in
// the same place. Both renderers use it — the planet and the flat hex map —
// which is why it lives here rather than inside either of them: a keyboard
// selection you cannot read the name of is not a selection.

import { html, Link } from '../router.js';
import { SPRITE_LABEL } from '../lib/world.js';
import { toneColor } from './sprites.js';

// The one-line summary a selection carries, whatever kind of thing it is. Also
// what the live region reads out, so the screen reader and the card agree.
export function pickDetail(pick) {
  if (!pick) return '';
  return pick.kind === 'territory'
    ? (pick.title || '')
    : (SPRITE_LABEL[pick.state] || pick.state || '');
}

export function pickTone(pick) {
  if (!pick) return 'idle';
  return pick.kind === 'territory'
    ? (pick.raised ? 'dead' : pick.paused ? 'warn' : pick.live ? 'ok' : 'idle')
    : pick.tone;
}

export function PickCard({ pick, keyed = false }) {
  if (!pick) return null;
  return html`
    <${Link} to=${pick.to} class=${`worldpick${keyed ? ' worldpick--keyed' : ''}`}>
      <span class="wdot" style=${`background:${toneColor(pickTone(pick))}`}></span>
      <span class="worldpick__name">${pick.label}</span>
      <span class="worldpick__meta">${pickDetail(pick)}</span>
      <span class="worldpick__go">${keyed ? 'ENTER ›' : 'OPEN ›'}</span>
    <//>`;
}
