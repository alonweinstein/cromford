// The agent session on the ticket page (BH-4991, BH-4947 wave 2; the reference
// is cromford-web docs/design/mission-control-line.html).
//
// The feed is the newest pushed transcript of the ticket's build, as turns
// (lib/ticket-detail.js parseTranscript). A transcript is pushed when a stage
// ENDS, so while a stage runs the feed shows the stage before it and the live
// marker says the build is working.
//
// "Step in" sends a steer note (lib/steer.js) in one of three modes. "now"
// needs a running build, and "hold" asks in the in-app dialog first. Below the
// box, the ticket's notes echo newest first, each with its state.

import { useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useConfirm } from './Modal.js';
import { canSendNow, steerBody, steerState, steerTextMax, sendSteer } from '../lib/steer.js';
import { clockTime } from '../lib/format.js';

export const STEP_IN_MODES = [
  { mode: 'now', label: 'Tell the agent now', note: 'Goes into the running build. It reads it before its next step.' },
  { mode: 'ticket', label: 'Add to the ticket', note: 'Posted as one comment on the issue. Every later stage reads the thread.' },
  { mode: 'hold', label: 'Hold, then tell it', note: 'Holds the ticket with your note. The build stops after its current step and waits for Resume.' }
];

const WHO = { agent: 'Agent', tool: 'Tool', result: 'Result', human: 'Prompt', system: 'System' };
const FOLD_AT = 120;

function Turn({ t }) {
  const mono = t.who === 'tool' || t.who === 'result';
  const long = mono && t.text.length > FOLD_AT;
  return html`
    <div class=${`turn turn--${t.who}`}>
      <span class="turn__who">${WHO[t.who] || t.who}</span>
      <div class="turn__body">
        ${mono
          ? (long
            ? html`<details class="turn__fold"><summary>${t.text.slice(0, FOLD_AT)}…</summary><code>${t.text}</code></details>`
            : html`<code>${t.text}</code>`)
          : html`<div class="turn__txt">${t.text}</div>`}
        <span class="turn__stamp">${t.at}</span>
      </div>
    </div>`;
}

const STATE_TONE = (st) => (st === 'posted' || st === 'held' || st.startsWith('read by')
  ? 'tag tag--green' : st.startsWith('not ') ? 'tag tag--bad' : 'tag');

function SteerNotes({ notes, error, job }) {
  if (error) return html`<p class="na">The notes did not load: ${error}</p>`;
  if (!Array.isArray(notes)) return null;
  if (!notes.length) return html`<p class="na">No notes sent on this ticket yet.</p>`;
  const rows = [...notes].sort((a, b) => Number(b.id) - Number(a.id));
  return html`
    <div class="steer-notes">
      <ul class="steer-notes__list">
        ${rows.map((n) => {
          const st = steerState(n, job);
          return html`
            <li key=${n.id} class="steer-note">
              <span class="tag tag--plain">${n.mode}</span>
              <span class="steer-note__who">${n.actor}</span>
              <span class="steer-note__at" title=${n.created_at}>${clockTime(n.created_at)}</span>
              <span class="steer-note__text">${n.text}</span>
              <span class=${STATE_TONE(st)}>${st}</span>
              ${n.job_id ? html`<${Link} to=${`/jobs/${encodeURIComponent(n.job_id)}`} class="tk">${n.job_id}<//>` : null}
            </li>`;
        })}
      </ul>
    </div>`;
}

function Composer({ project, ticket, job, onSent, apiObj, composeRef }) {
  const [text, setText] = useState('');
  const [mode, setMode] = useState('ticket');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const [dialog, ask] = useConfirm();
  const nowOk = canSendNow(job);
  const body = steerBody({ project, ticket, job, mode, text });
  const max = steerTextMax(mode);

  const send = async () => {
    if (!body || busy) return;
    setBusy(true);
    setErr(null);
    try {
      const r = await sendSteer({ project, ticket, job, mode, text, apiObj, ask });
      if (r.ok) {
        setText('');
        if (onSent) onSent();
      } else if (!r.cancelled) {
        setErr(r.error);
      }
    } finally {
      setBusy(false);
    }
  };

  return html`
    <div class="compose" ref=${composeRef}>
      <span class="compose__label">Step in</span>
      <textarea class="compose__text" rows="3" aria-label="Step in"
        placeholder="Tell the agent what to change, check or stop doing"
        value=${text} onInput=${(e) => setText(e.target.value)}></textarea>
      <div class="compose__modes" role="radiogroup" aria-label="How to send it">
        ${STEP_IN_MODES.map((m) => {
          const off = m.mode === 'now' && !nowOk;
          return html`
            <label key=${m.mode} class=${off ? 'compose__mode compose__mode--off' : 'compose__mode'}>
              <input type="radio" name="steer-mode" value=${m.mode} checked=${mode === m.mode} disabled=${off}
                onChange=${() => setMode(m.mode)}/>
              <span><b>${m.label}</b><small>${off ? 'No build is running.' : m.note}</small></span>
            </label>`;
        })}
      </div>
      <div class="compose__send">
        <span class=${text.trim().length > max ? 'compose__count compose__count--over' : 'compose__count'}>${text.trim().length} / ${max}</span>
        <button type="button" class="btn btn--primary" disabled=${!body || busy} onClick=${send}>SEND</button>
      </div>
      ${err ? html`<p class="tag tag--bad" role="alert">${err}</p>` : null}
      ${dialog}
    </div>`;
}

export function AgentSession({
  live, stage, feed = [], composeRef, project = null, ticket = null, job = null,
  notes = null, notesError = null, onSent, apiObj = api
}) {
  return html`
    <section class="tp-card agent-card" id="agent">
      <h3 class="agent__head">
        <span>Agent session${stage ? ` · ${stage}` : ''}</span>
        ${live ? html`<span class="agent__live">● live</span>` : html`<span class="agent__idle">idle</span>`}
      </h3>
      <div class="agent">
        <div class="feed" aria-live="polite">
          ${feed.length
            ? feed.map((t, i) => html`<${Turn} key=${`${i}:${t.at}`} t=${t}/>`)
            : html`<p class="na feed__empty">No session text yet. A stage's conversation appears here when the stage ends and its transcript is pushed.</p>`}
          ${live ? html`<div class="agent__typing">working<i>…</i></div>` : null}
        </div>
        <div class="agent__step">
          <${Composer} project=${project} ticket=${ticket} job=${job} onSent=${onSent} apiObj=${apiObj} composeRef=${composeRef}/>
          <${SteerNotes} notes=${notes} error=${notesError} job=${job}/>
        </div>
      </div>
    </section>`;
}
