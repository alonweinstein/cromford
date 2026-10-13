import { useMemo, useRef, useState } from 'preact/hooks';
import { html } from '../router.js';
import { api } from '../api.js';
import { useConfirm } from '../ui/Modal.js';
import {
  mqActions, releasable, effectText, mqFormState, makeMqAction, makeReleaseAction
} from '../lib/merge-queue-actions.js';

// BH-3159 (BH-2325.4): the merge-queue row actions and the held-page release
// button. `rowsOnly` is 'on' | 'off' | 'unread', and `onDone()` fires only
// after a confirmed successful write.
//
// The exported functions return null for a row with nothing to offer BEFORE
// any hook runs, and otherwise hand off to an inner cell, so hooks are never
// called conditionally inside one component.

export function MqRowActions({ row, rowsOnly, onDone }) {
  if (!row || !row.project || row.pr == null || !mqActions(row.status).length) return null;
  return html`<${MqRowActionsCell} row=${row} rowsOnly=${rowsOnly} onDone=${onDone}/>`;
}

export function HeldReleaseButton({ row, onDone }) {
  if (!releasable(row)) return null;
  return html`<${HeldReleaseCell} row=${row} onDone=${onDone}/>`;
}

// The shared cell state: the confirm dialog, the last message, a busy flag, and
// refs so a parent rerender with a fresh onDone or mode never rebuilds the action.
function useCell(onDone, mode) {
  const [dialog, confirm] = useConfirm();
  const [msg, setMsg] = useState(null);
  const [busy, setBusy] = useState(false);
  const doneRef = useRef(onDone);
  doneRef.current = onDone;
  const modeRef = useRef(mode);
  modeRef.current = mode;
  const wiring = {
    confirm, onMsg: setMsg, onPending: (k) => setBusy(Boolean(k)),
    onDone: () => { if (doneRef.current) doneRef.current(); }
  };
  return { dialog, msg, busy, modeRef, wiring };
}

function MqRowActionsCell({ row, rowsOnly, onDone }) {
  const { dialog, msg, busy, modeRef, wiring } = useCell(onDone, rowsOnly);
  const act = useMemo(() => makeMqAction({
    ...wiring,
    send: (body) => api.setMergeQueue(body),
    renderForm: (r, action, form, setBlocked) => html`<${MqActionForm} title=${action}
      subject=${`${r.project}#${r.pr}`} effect=${effectText(action, modeRef.current)}
      value=${form} onBlocked=${setBlocked}/>`
  }), [wiring.confirm]);
  return html`<${ActionCell} labels=${mqActions(row.status)} busy=${busy || Boolean(dialog)}
    onAct=${(a) => act(row, a)} msg=${msg} dialog=${dialog}/>`;
}

function HeldReleaseCell({ row, onDone }) {
  const { dialog, msg, busy, wiring } = useCell(onDone);
  const act = useMemo(() => makeReleaseAction({
    ...wiring,
    send: (body) => api.releaseHeldPage(body),
    renderForm: (r, action, form, setBlocked) => html`<${MqActionForm} title=${action}
      subject=${`${r.repo}#${r.number} (${r.state}, ${r.kind})`} effect=${effectText(action)}
      value=${form} onBlocked=${setBlocked}/>`
  }), [wiring.confirm]);
  return html`<${ActionCell} labels=${['RELEASE']} busy=${busy || Boolean(dialog)}
    onAct=${() => act(row)} msg=${msg} dialog=${dialog}/>`;
}

function ActionCell({ labels, busy, onAct, msg, dialog }) {
  return html`
    <span style="display:inline-flex;flex-wrap:wrap;gap:6px;align-items:center;max-width:100%">
      ${labels.map((a) => html`<button key=${a} class="btn" type="button" style="min-height:32px"
        disabled=${busy} onClick=${() => onAct(a)}>${a}</button>`)}
      ${msg ? html`<span style=${`overflow-wrap:anywhere;color:${msg.ok ? 'var(--green-lt)' : 'var(--red-txt)'}`}>${msg.text}</span>` : null}
      ${dialog}
    </span>`;
}

// The modal body. REASON is the first field, so the Modal focuses it on open
// and keeps it there through typing and a parent rerender (D39).
export function MqActionForm({ title, subject, effect, value, onBlocked }) {
  const [reason, setReason] = useState(value.reason);
  const { hint } = mqFormState({ reason });
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <label class="knob" style="width:100%">
        <span class="knob__label">REASON</span>
        <input class="knob__input" style="width:100%" type="text" value=${reason}
          placeholder="why, recorded with the change"
          onInput=${(e) => {
            value.reason = e.target.value;
            setReason(e.target.value);
            if (onBlocked) onBlocked(mqFormState({ reason: e.target.value }).blocked);
          }}/>
      </label>
      <span style="overflow-wrap:anywhere">${title} <b>${subject}</b>?</span>
      <span style="overflow-wrap:anywhere">${effect}</span>
      ${hint ? html`<span style="color:var(--faint)">${hint}</span>` : null}
    </div>`;
}
