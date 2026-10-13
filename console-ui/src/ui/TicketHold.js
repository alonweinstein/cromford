import { useState, useEffect, useRef } from 'preact/hooks';
import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useConfirm } from './Modal.js';
import { holdTarget, holdCommand, holdFromLedger, HOLD_REASON_MAX } from '../lib/ticket-hold.js';

// HOLD / UNHOLD for one ticket on the Build screen (BH-2326.3), built only
// from the BH-2326.0 contract. A click asks in the in-app dialog with an
// optional reason and, on confirm, queues one hold_ticket / unhold_ticket
// command through /api/dash/action. The hub handler does the label change, so
// the hold read is asked again once, HOLD_RELOAD_MS after a command is queued.

export const HOLD_RELOAD_MS = 20000;

// The one hold read a screen makes, shared by its HELD tag and the control.
// hold is null while the first answer is on its way, {unknown:true} when the
// read failed (never "not held", D23), and holdFromLedger's answer otherwise.
export function useTicketHold(project, ticket, apiObj = api) {
  const target = holdTarget(project, ticket);
  const r = useApi(
    () => (target ? apiObj.ticketHold(project, target.issue) : Promise.resolve(null)),
    [project, ticket]
  );
  const hold = !target ? null
    : r.error ? holdFromLedger(r.error)
      : r.data ? holdFromLedger(r.data)
        : null;
  return { target, hold, reload: r.reload };
}

// The dialog body. The reason is kept in its own state and written into
// `form`, so the Build screen's 5 s poll never resets what was typed (D39).
export function HoldReason({ text, form }) {
  const [v, setV] = useState(form.reason);
  const onInput = (e) => { form.reason = e.target.value; setV(form.reason); };
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span>${text}</span>
      <label class="knob" style="width:100%">
        <span class="knob__label">REASON (OPTIONAL)</span>
        <textarea class="knob__input" style="width:100%;box-sizing:border-box;min-height:4em" rows="3"
          aria-label="Reason" maxlength=${HOLD_REASON_MAX}
          placeholder="why, for whoever reads the ticket" value=${v} onInput=${onInput}></textarea>
      </label>
    </div>`;
}

const LABEL = { hold: 'HOLD', unhold: 'UNHOLD' };

export function holdConfirmOpts(action, ticket) {
  return action === 'hold'
    ? {
      title: 'HOLD TICKET',
      body: `Adds the hold label as the App; every build, rebuild and requeue of ${ticket} stops until it is removed.`,
      confirmLabel: 'HOLD',
      tone: 'warn'
    }
    : {
      title: 'UNHOLD TICKET',
      body: 'Removes the label; a HOLD comment or a (HOLD) title from a person still holds it.',
      confirmLabel: 'UNHOLD',
      tone: 'warn'
    };
}

// The whole click: ask, build the body, send it, and say what came back.
// null when nothing was sent. A queued banner needs a positive integer id.
export async function runTicketHold({ apiObj, confirm, action, target, reasonForm }) {
  const form = { reason: '' };
  const opts = holdConfirmOpts(action, target.ticket);
  const ok = await confirm({ ...opts, body: reasonForm(opts.body, form) });
  if (ok !== true) return null;
  const body = holdCommand(action, target, form.reason);
  if (!body) return null;
  let res;
  try {
    res = await apiObj.action(body);
  } catch (e) {
    return { tone: 'bad', text: `${LABEL[action]} failed: ${e && e.message ? e.message : String(e)}` };
  }
  const id = res ? res.command_id : undefined;
  if (Number.isInteger(id) && id > 0) {
    return { tone: 'ok', text: `${LABEL[action]} queued as command #${id}`, id };
  }
  return { tone: 'warn', text: `${LABEL[action]} sent, but no command id came back` };
}

const TONE = { ok: 'tag tag--green', warn: 'tag tag--warn', bad: 'tag tag--bad' };
const reasonBody = (text, form) => html`<${HoldReason} text=${text} form=${form}/>`;

export function TicketHoldControl({ project, ticket, hold, reload, apiObj = api, reloadMs = HOLD_RELOAD_MS }) {
  const [dialog, confirm] = useConfirm();
  const [busy, setBusy] = useState(false);
  const [outcome, setOutcome] = useState(null);
  const timer = useRef(null);
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);

  const target = holdTarget(project, ticket);
  if (!target) return null;

  const run = async (action) => {
    if (busy) return;
    setBusy(true);
    try {
      const out = await runTicketHold({ apiObj, confirm, action, target, reasonForm: reasonBody });
      if (out) {
        setOutcome(out);
        if (out.id) {
          if (timer.current) clearTimeout(timer.current);
          timer.current = setTimeout(() => { timer.current = null; if (reload) reload(); }, reloadMs);
        }
      }
    } finally {
      setBusy(false);
    }
  };

  const unknown = Boolean(hold && hold.unknown);
  const actions = !hold ? []
    : unknown ? ['hold', 'unhold']
      : hold.held ? ['unhold'] : ['hold'];

  return html`<div class="ticket-hold" style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:0 0 10px">
    ${actions.map((a) => html`
      <button key=${a} type="button" class="btn btn--warn" style="min-height:36px"
        disabled=${busy} onClick=${() => run(a)}>${LABEL[a]}</button>`)}
    ${!hold ? html`<span class="knob__note">checking hold state</span>` : null}
    ${unknown ? html`<span class="knob__note knob__note--bad">hold state unknown</span>` : null}
    ${outcome ? html`<span class=${TONE[outcome.tone]} role="status" style="overflow-wrap:anywhere">${outcome.text}${outcome.id
      ? html` · <${Link} to=${`/history/commands?id=${outcome.id}`}>command #${outcome.id}<//>`
      : null}</span>` : null}
    ${dialog}
  </div>`;
}
