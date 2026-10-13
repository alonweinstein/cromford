import { useState } from 'preact/hooks';
import { html } from '../router.js';
import { api } from '../api.js';
import { useConfirm } from './Modal.js';
import {
  availableIdeaActions, slugOk, textError, commandFor, confirmOpts, outcomeLine,
  IDEA_TEXT_MAX, TEXT_LABEL, TEXT_PLACEHOLDER
} from '../lib/idea-actions.js';

// POST / REVISE / KILL / CHAT on the Idea screen (BH-2520). Each click asks in
// the in-app dialog, sends one command on confirm, says it queued (or why it
// did not), and calls onQueued so the screen reads the idea again. REVISE and
// CHAT carry a required text field and stay disabled until it has one; KILL's
// notes are optional.

const TONE = { ok: 'tag tag--green', bad: 'tag tag--bad' };
const BTN = { post: 'btn btn--warn', revise: 'btn', kill: 'btn btn--danger', chat: 'btn' };

// The dialog's text field. It writes into `form` (a fresh object per click)
// and keeps its own copy in state, so typing never re-renders the screen. Modal
// focuses it on open and does not move focus again (D39).
export function IdeaText({ action, text, form, onBlocked }) {
  const [v, setV] = useState(form.text);
  const onInput = (e) => {
    form.text = e.target.value;
    setV(form.text);
    if (onBlocked) onBlocked(textError(action, form.text) !== null);
  };
  const err = v.length ? textError(action, v) : null;
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span>${text}</span>
      <label class="knob" style="width:100%">
        <span class="knob__label">${TEXT_LABEL[action]}</span>
        <textarea class="knob__input" style="width:100%;box-sizing:border-box;min-height:5em" rows="4"
          aria-label=${TEXT_LABEL[action]} maxlength=${IDEA_TEXT_MAX}
          placeholder=${TEXT_PLACEHOLDER[action]} value=${v} onInput=${onInput}></textarea>
      </label>
      ${err ? html`<span class="knob__note knob__note--bad" style="max-width:none" role="status">${err}</span>` : null}
    </div>`;
}

export function IdeaActions({ proposal, project, onQueued, apiObj = api }) {
  const [dialog, ask] = useConfirm();
  const [busy, setBusy] = useState(false);
  const [outcome, setOutcome] = useState(null);
  // The ledger only says `posted` once the poller has run post-proposal.sh,
  // and a second POST would put a second ticket on the client's board. So a
  // queued POST locks its button for as long as this screen is open.
  const [postQueued, setPostQueued] = useState(null);

  if (!proposal || !proposal.slug) return null;
  if (!slugOk(proposal.slug)) {
    return html`<div class="footnote" style="margin-top:12px">
      <span>This idea's slug cannot be acted on from here (the command poller only takes letters, digits, - and _).</span>
    </div>`;
  }
  const actions = availableIdeaActions(proposal);

  const run = async (action) => {
    if (busy) return;
    // busy disables every button while the dialog and the POST are in flight,
    // so a double click cannot send two commands.
    setBusy(true);
    try {
      const opts = confirmOpts(action, proposal);
      const form = { text: '' };
      if (action !== 'post') {
        const text = opts.body;
        opts.confirmBlocked = textError(action, '') !== null;
        opts.body = ({ setBlocked }) => html`<${IdeaText} action=${action} text=${text} form=${form} onBlocked=${setBlocked}/>`;
      }
      if ((await ask(opts)) !== true) return;
      const err = textError(action, form.text);
      if (err) { setOutcome({ tone: 'bad', text: `${action.toUpperCase()} not sent: ${err}` }); return; }
      let out;
      let result;
      try {
        result = await apiObj.action(commandFor(action, project, proposal.slug, form.text));
        out = outcomeLine(action, { result });
      } catch (error) {
        out = outcomeLine(action, { error });
      }
      setOutcome(out);
      if (out.tone === 'ok') {
        if (action === 'post') setPostQueued(result.command_id);
        if (onQueued) onQueued();
      }
    } finally {
      setBusy(false);
    }
  };

  return html`<div class="idea-actions" style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-top:12px">
    ${actions.map((a) => {
      const locked = a === 'post' && postQueued !== null;
      return html`
        <button key=${a} type="button" class=${`${BTN[a]} idea-action`} style="min-height:44px"
          disabled=${busy || locked} onClick=${() => { if (!locked) run(a); }}>
          ${locked ? `POST QUEUED #${postQueued}` : a.toUpperCase()}</button>`;
    })}
    ${outcome ? html`<span class=${TONE[outcome.tone]} role="status" style="overflow-wrap:anywhere">${outcome.text}</span>` : null}
    ${dialog}
  </div>`;
}
