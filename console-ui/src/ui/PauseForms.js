import { useState } from 'preact/hooks';
import { html } from '../router.js';
import { PAUSE_WHATS, fleetPauseCommandFor } from '../lib/pauses.js';

// Dialog bodies for the pause controls (BH-2509), on JobActions.AbandonReason's
// pattern: each writes through to `value`, the per-click object its caller
// reads on confirm, keeps its own copy in state so typing never re-renders the
// page, and tells the dialog whether confirm may be pressed (onBlocked). Modal
// focuses the first field on open and never moves focus again (D39).

const FIELD = 'knob__input';
const FULL = 'width:100%';

// The inline hint for the PAUSE FLEET form, from the same builder the confirm
// sends, so the button and the command cannot disagree.
export function fleetPauseHint(form) {
  const cmd = fleetPauseCommandFor(form);
  if (!cmd.error) return null;
  if (cmd.error === 'reason required') return 'A reason is required: it is recorded on the pause and shown on every PAUSED tag.';
  if (cmd.error === 'ttl required') return 'A TTL is required for a fleet pause: whole seconds above 0, 1800 = 30 min.';
  return cmd.error;
}

// PAUSE FLEET: what, reason and ttl, all three required.
export function FleetPauseForm({ value, onBlocked }) {
  const [f, setF] = useState(value);
  const set = (k) => (e) => {
    value[k] = e.target.value;
    setF({ ...value });
    if (onBlocked) onBlocked(fleetPauseHint(value) !== null);
  };
  const hint = fleetPauseHint(f);
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span>Pause <b>${f.what}</b> on <b>every project</b>. Lanes that honour this pause stop fleet-wide until it is ended or expires.</span>
      <label class="knob" style=${FULL}>
        <span class="knob__label">WHAT</span>
        <select class=${FIELD} style=${FULL} value=${f.what} onChange=${set('what')}>
          ${PAUSE_WHATS.map((w) => html`<option key=${w} value=${w}>${w}</option>`)}
        </select>
      </label>
      <label class="knob" style=${FULL}>
        <span class="knob__label">REASON</span>
        <input class=${FIELD} style=${FULL} type="text" value=${f.reason} onInput=${set('reason')}
          placeholder="why, for whoever sees the tag" required aria-required="true" />
      </label>
      <label class="knob" style=${FULL}>
        <span class="knob__label">TTL (SECONDS)</span>
        <input class=${FIELD} style=${FULL} type="text" inputmode="numeric" value=${f.ttlS} onInput=${set('ttlS')}
          placeholder="1800 = 30 min" required aria-required="true" />
      </label>
      ${hint ? html`<span class="knob__note knob__note--bad" style="max-width:none" role="status">${hint}</span>` : null}
    </div>`;
}

// RESUME and END: the question, plus a required reason.
export function PauseReasonForm({ text, value, onBlocked }) {
  const [v, setV] = useState(value.reason || '');
  const onInput = (e) => {
    value.reason = e.target.value;
    setV(value.reason);
    if (onBlocked) onBlocked(!value.reason.trim());
  };
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span>${text}</span>
      <label class="knob" style=${FULL}>
        <span class="knob__label">REASON</span>
        <input class=${FIELD} style=${FULL} type="text" value=${v} onInput=${onInput}
          placeholder="why, for the record" required aria-required="true" />
      </label>
      ${v.trim() ? null : html`<span class="knob__note knob__note--bad" style="max-width:none" role="status">A reason is required.</span>`}
    </div>`;
}
