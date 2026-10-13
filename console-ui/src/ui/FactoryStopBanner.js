import { useState } from 'preact/hooks';
import { html } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { agoFromMinutes } from '../lib/format.js';
import { shapeFactoryStop, runFactoryStop, FACTORY_STOP_KEY } from '../lib/factory-stop.js';

// BH-3687 (slice BH-3712): the factory-stop banner and toggle on the Fleet
// screen. It reads the settings row every 30 s and writes it through the coord
// proxy with a required reason. The message after a toggle comes from the
// re-read, never from the click.

// The dialog opens blocked: the reason is the audit row's reason.
export function factoryStopFormState(form) {
  if (!String((form && form.reason) ?? '').trim()) {
    return { blocked: true, hint: 'A reason is required: it is recorded with the switch.' };
  }
  return { blocked: false, hint: null };
}

// The dialog body. Every keystroke is written through to `value` (what the
// confirm reads) and reported to the dialog.
export function FactoryStopForm({ state, value, onBlocked }) {
  const [f, setF] = useState(value);
  const onInput = (e) => {
    value.reason = e.target.value;
    setF({ ...value });
    if (onBlocked) onBlocked(factoryStopFormState(value).blocked);
  };
  const { hint } = factoryStopFormState(f);
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      ${state === 'on'
        ? html`<span>Resume the factory? Launches, merges and deploys start again on their next tick.</span>`
        : html`<span>Stop the factory? Every lane tagged factory_stop (launch, merge, deploy) stops on its next tick. Paging, poll-commands and untagged lanes keep running. Resume turns it back off.</span>`}
      <label class="knob" style="width:100%">
        <span class="knob__label">REASON</span>
        <textarea class="knob__input" style="width:100%" rows="3" value=${f.reason} onInput=${onInput}
          placeholder=${state === 'on' ? 'why it is safe to resume' : 'why the factory is stopping'}
          required aria-required="true"></textarea>
      </label>
      ${hint ? html`<span class="knob__note knob__note--bad" style="max-width:none" role="status">${hint}</span>` : null}
    </div>`;
}

const wrap = 'overflow-wrap:anywhere';

// One load state, drawn. Nothing while the first read is in flight; a failed
// or unreadable read says so and offers no toggle, because a state is never
// guessed.
export function FactoryStopBannerView({ state, onToggle, busy, msg, now = Date.now() }) {
  if (!state.data && !state.error) return null;
  const fs = state.error ? { state: 'unknown' } : shapeFactoryStop(state.data, now);
  const note = msg
    ? html`<span class=${msg.ok ? '' : 'knob__note knob__note--bad'} style="max-width:none" role="status">${msg.text}</span>`
    : null;
  if (fs.state === 'unknown') {
    return html`
      <span class="muted" style="font-size:var(--fs-xs);color:var(--faint)">factory-stop status unavailable</span>
      ${note}`;
  }
  const on = fs.state === 'on';
  const button = html`
    <button class="btn btn--warn" type="button" data-testid="factory-stop-toggle" disabled=${busy}
      style="margin-left:auto" onClick=${() => onToggle(fs.state)}>
      ${busy ? (on ? 'RESUMING…' : 'STOPPING…') : (on ? 'RESUME FACTORY…' : 'FACTORY STOP…')}
    </button>`;
  if (!on) {
    return html`
      <div style="display:flex;justify-content:flex-end;flex-wrap:wrap;gap:8px">${button}</div>
      ${note}`;
  }
  return html`
    <div class="banner" role="alert" data-testid="factory-stop-banner" style="flex-wrap:wrap">
      <span style=${wrap}><b>FACTORY STOPPED</b></span>
      ${fs.sinceIso ? html`<span style=${wrap}>since ${fs.sinceIso}${fs.forMin !== null ? ` (${agoFromMinutes(fs.forMin)})` : ''}</span>` : null}
      ${fs.actor ? html`<span style=${wrap}>by ${fs.actor}</span>` : null}
      ${fs.reason ? html`<span style=${wrap}>"${fs.reason}"</span>` : null}
      ${button}
    </div>
    ${note}`;
}

export function FactoryStopBanner({ confirm }) {
  const state = useApi(() => api.coordSetting(FACTORY_STOP_KEY), [], { intervalMs: 30000 });
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState(null);
  const onToggle = async (current) => {
    const want = current === 'on' ? 'off' : 'on';
    const form = { reason: '' };
    const ok = await confirm({
      title: want === 'on' ? 'FACTORY STOP' : 'RESUME FACTORY',
      confirmLabel: want === 'on' ? 'STOP FACTORY' : 'RESUME',
      tone: 'warn', confirmBlocked: true,
      body: ({ setBlocked }) => html`<${FactoryStopForm} state=${current} value=${form} onBlocked=${setBlocked} />`
    });
    if (!ok) return;
    setBusy(true);
    try {
      setMsg(await runFactoryStop(api, want, form.reason));
    } finally {
      setBusy(false);
      state.reload();
    }
  };
  return html`<${FactoryStopBannerView} state=${state} onToggle=${onToggle} busy=${busy} msg=${msg} />`;
}
