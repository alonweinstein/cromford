import { useState } from 'preact/hooks';
import { html } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useConfirm } from '../ui/Modal.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Skeleton, Empty, ErrorBox, Age } from '../ui/primitives.js';
import { actionFormState, QUEUE_LIMIT } from '../lib/queue-panel.js';
import {
  allowedActions, actionBody, deployCells, rowsNote, deployTableState, actionOutcome
} from '../lib/deploy-queue-panel.js';

// The DEPLOY QUEUE table in the QUEUES section of /p/<project> (BH-2510,
// BH-3152, BH-3154): the project's queued, claimed and held deploy_queue rows,
// an audited RELEASE that hands a claimed departure whose train died back to
// the queue, and an audited HOLD / UNHOLD that takes a queued departure out of
// the train and puts it back.

// The prompt each action's confirm opens with. HOLD is only offered when the
// knob is on (allowedActions), so its copy is true whenever it renders.
const PROMPT = {
  release: (sha8) => html`Release <b>${sha8}</b> back to queued? Its claim is cleared and the next train claims it again.`,
  hold: (sha8) => html`Hold <b>${sha8}</b>? The train will not depart and will not self-source while this is held.`,
  unhold: (sha8) => html`Unhold <b>${sha8}</b>? It goes back to queued and the next train departs with it.`
};

// Written through on every keystroke into the per-click object the action
// reads on confirm (RoutingPanel's HaltConfirmBody pattern). onBlocked is the
// Modal's setBlocked: confirm stays disabled until the reason is non-blank.
function ActionConfirmBody({ action, sha8, note, value, onBlocked }) {
  const [reason, setReason] = useState(value.reason);
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span>${PROMPT[action](sha8)}</span>
      ${note.on === true ? null : html`<span style="color:var(--faint)">${note.on === false
        ? 'deploy_queue_rows is off, so this changes nothing a train sees.'
        : 'Whether a train reads this row is unknown: if deploy_queue_rows is off, this changes nothing a train sees.'}</span>`}
      <label class="knob" style="width:100%">
        <span class="knob__label">REASON (REQUIRED)</span>
        <input class="knob__input" style="width:100%" type="text" aria-label=${`reason for this ${action}`}
          value=${reason} placeholder=${`why this ${action}`}
          onInput=${(e) => {
            value.reason = e.target.value;
            setReason(e.target.value);
            if (onBlocked) onBlocked(actionFormState(e.target.value).blocked);
          }} />
      </label>
    </div>`;
}

function Table({ state, busy, rowsOn, onAction, onRetry }) {
  if (state.kind === 'loading') return html`<${Skeleton} rows=${3} height=${18}/>`;
  if (state.kind === 'error') return html`<${ErrorBox} error=${state.error} onRetry=${onRetry}/>`;
  const rows = state.rows.map((r) => ({ ...deployCells(r), row: r }));
  const columns = [
    { key: 'sha', label: 'SHA', cell: (c) => html`<span style="font-family:var(--mono, monospace)" title=${c.sha}>${c.sha8}</span>` },
    { key: 'status', label: 'STATUS', cell: (c) => html`<span class="tag">${c.status}</span>` },
    { key: 'claimed_by', label: 'CLAIMED BY', cell: (c) => c.claimed_by },
    { key: 'build_dir', label: 'BUILD DIR', flex: true, cell: (c) => html`<span class="cell-wrap">${c.build_dir}</span>` },
    { key: 'enqueued_at', label: 'ENQUEUED', cell: (c) => html`<${Age} min=${c.age_min} warnAt=${Infinity}/>` },
    {
      key: 'action', label: 'ACTION', sort: null,
      cell: (c) => {
        const acts = allowedActions(c.row, rowsOn);
        return acts.length
          ? acts.map((a) => html`<button class="btn btn--sm" type="button" disabled=${busy} onClick=${() => onAction(c.row, a)}>${a.toUpperCase()}</button>`)
          : html`<span class="na">—</span>`;
      }
    }
  ];
  return html`
    <${SortableTable} columns=${columns} rows=${rows} rowKey=${(c) => c.sha} wide
      defaultSort="enqueued_at" defaultDir="asc"
      empty=${html`<${Empty} title="nothing queued"/>`}/>
    ${state.capped
      ? html`<p class="section__note" style="margin:6px 0 0">first ${QUEUE_LIMIT} per status shown; more may exist</p>`
      : null}`;
}

export function DeployQueueView({ state, note, busy, msg, onAction, onRetry, onDismiss }) {
  return html`
    <div style="display:flex;flex-direction:column;gap:8px">
      <span class="kv__label">DEPLOY QUEUE</span>
      <p class=${note.on === false ? 'section__note tag--warn' : 'section__note'} style="margin:0">${note.text}</p>
      ${msg ? html`
        <div class="banner" role="status"
          style=${msg.ok ? 'border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)' : ''}>
          <span>${msg.text}</span>
          <button class="btn btn--sm" style="margin-left:auto" onClick=${onDismiss}>DISMISS</button>
        </div>` : null}
      <${Table} state=${state} busy=${busy} rowsOn=${note.on === true} onAction=${onAction} onRetry=${onRetry}/>
    </div>`;
}

export default function DeployQueuePanel({ project }) {
  const queued = useApi(() => api.deployQueueRows(project, 'queued'), [project], { intervalMs: 30000 });
  const claimed = useApi(() => api.deployQueueRows(project, 'claimed'), [project], { intervalMs: 30000 });
  const held = useApi(() => api.deployQueueRows(project, 'held'), [project], { intervalMs: 30000 });
  const knob = useApi(() => api.coordSetting('deploy_queue_rows'), [], { intervalMs: 30000 });
  const [dialog, confirm] = useConfirm();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState(null);
  const state = deployTableState(queued, claimed, held);
  const note = rowsNote(knob);
  const reload = () => { queued.reload(); claimed.reload(); held.reload(); };

  const onAction = async (row, action) => {
    if (busy || !allowedActions(row, note.on === true).includes(action)) return;
    // busy holds every action button disabled through the dialog and the
    // write, so a double click cannot send two.
    setBusy(true);
    setMsg(null);
    try {
      const form = { reason: '' };
      const sha8 = String(row.sha).slice(0, 8);
      const label = action.toUpperCase();
      const ok = await confirm({
        title: label, confirmLabel: label, tone: 'warn',
        confirmBlocked: actionFormState(form.reason).blocked,
        body: ({ setBlocked }) => html`<${ActionConfirmBody} action=${action} sha8=${sha8} note=${note} value=${form} onBlocked=${setBlocked}/>`
      });
      if (!ok) return;
      try {
        setMsg(actionOutcome(await api.deployQueueAction(actionBody(project, row, action, form.reason)), action));
      } catch (e) {
        setMsg(actionOutcome(e instanceof Error ? e : new Error(String(e)), action));
      }
      reload();
    } finally {
      setBusy(false);
    }
  };

  return html`<div>
    ${dialog}
    <${DeployQueueView} state=${state} note=${note} busy=${busy} msg=${msg}
      onAction=${onAction} onRetry=${reload} onDismiss=${() => setMsg(null)}/>
  </div>`;
}
