import { useState } from 'preact/hooks';
import { html } from '../router.js';
import { api } from '../api.js';
import { useConfirm } from './Modal.js';
import { availableActions, runJobAction, abandonReasonError, ABANDON_REASON_MAX } from '../lib/job-actions.js';

// RETRY / REQUEUE (BH-2323) and ABANDON (BH-2406) for one job, on the Job and
// Build screens. Renders nothing when the row allows none. Each click asks in
// the in-app dialog, sends one POST on confirm, shows the worker's decision and
// reason, and calls onDone so the page reloads the row it came from. ABANDON's
// dialog carries a required reason and stays disabled until it has one.

const TONE = { ok: 'tag tag--green', warn: 'tag tag--warn', bad: 'tag tag--bad' };
const LABEL = { retry: 'RETRY', requeue: 'REQUEUE', abandon: 'ABANDON' };
const BTN = { retry: 'btn btn--warn', requeue: 'btn btn--warn', abandon: 'btn btn--danger' };

// The reason field. It writes into `form` (a fresh object per click, owned by
// runJobAction) and keeps its own copy in state, so typing never re-renders the
// page and a page poll never resets what was typed. Modal focuses it on open
// and does not move focus again (D39).
export function AbandonReason({ text, form, onBlocked }) {
  const [v, setV] = useState(form.reason);
  const onInput = (e) => {
    form.reason = e.target.value;
    setV(form.reason);
    if (onBlocked) onBlocked(abandonReasonError(form.reason) !== null);
  };
  const err = v.length ? abandonReasonError(v) : null;
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span>${text}</span>
      <label class="knob" style="width:100%">
        <span class="knob__label">REASON</span>
        <textarea class="knob__input" style="width:100%;box-sizing:border-box;min-height:4em" rows="3"
          aria-label="Reason" maxlength=${ABANDON_REASON_MAX} required aria-required="true"
          placeholder="why this job is over, for whoever reads its events" value=${v} onInput=${onInput}></textarea>
      </label>
      ${err ? html`<span class="knob__note knob__note--bad" style="max-width:none" role="status">${err}</span>` : null}
    </div>`;
}

const reasonForm = (text, form) => ({ setBlocked }) =>
  html`<${AbandonReason} text=${text} form=${form} onBlocked=${setBlocked}/>`;

export function JobActions({ job, onDone, apiObj = api }) {
  const [dialog, confirm] = useConfirm();
  const [busy, setBusy] = useState(false);
  const [outcome, setOutcome] = useState(null);
  const actions = availableActions(job);
  // A poll can move the row on while the dialog is open; the dialog and the
  // last outcome stay on screen even when no button is left to show.
  if (!actions.length && !outcome && !dialog && !busy) return null;

  const run = async (action) => {
    if (busy) return;
    // busy disables every button while the dialog and the POST are in flight,
    // so a double click cannot send two requests.
    setBusy(true);
    try {
      const out = await runJobAction({
        apiObj, job, action, confirm, reasonForm, reload: () => { if (onDone) onDone(); }
      });
      if (out) setOutcome(out);
    } finally {
      setBusy(false);
    }
  };

  return html`<div class="job-actions" style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:0 0 10px">
    ${actions.map((a) => html`
      <button key=${a} type="button" class=${BTN[a]} disabled=${busy} onClick=${() => run(a)}>${LABEL[a]}</button>`)}
    ${outcome ? html`<span class=${TONE[outcome.tone]} role="status" style="overflow-wrap:anywhere">${outcome.text}</span>` : null}
    ${dialog}
  </div>`;
}
