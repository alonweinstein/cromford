import { useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useConfirm } from '../ui/Modal.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Skeleton, Empty, ErrorBox, Age } from '../ui/primitives.js';
import { actionFormState, QUEUE_LIMIT } from '../lib/queue-panel.js';
import {
  BUILD_STATUSES, ACTION_COPY, buildQueueState, allowedActions, actionBody, buildCells, actionMessage
} from '../lib/build-queue-panel.js';

// The QUEUES section's BUILD QUEUE table on /p/<project> (BH-3151, BH-2510.1):
// the ready, queued and claimed build_queue rows, with RELEASE on a dead claim
// and DROP on a waiting row. Both need a reason; the worker audits each one.

const dash = (v) => (v === null || v === undefined || v === '' ? html`<span class="na">—</span>` : v);

// Written through on every keystroke into the per-click object read on confirm
// (RoutingPanel's HaltConfirmBody pattern); confirm stays blocked while blank.
function ActionConfirmBody({ action, row, value, onBlocked }) {
  const [reason, setReason] = useState(value.reason);
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span>${action.toUpperCase()} <b>${row.ticket_key}</b> (${row.status}${row.claimed_by ? ` on ${row.claimed_by}` : ''})?</span>
      <span>${ACTION_COPY[action].body}</span>
      <label class="knob" style="width:100%">
        <span class="knob__label">REASON (REQUIRED)</span>
        <input class="knob__input" style="width:100%" type="text" aria-label=${`reason for this ${action}`}
          value=${reason} placeholder="why"
          onInput=${(e) => {
            value.reason = e.target.value;
            setReason(e.target.value);
            if (onBlocked) onBlocked(actionFormState(e.target.value).blocked);
          }} />
      </label>
    </div>`;
}

export function BuildQueueView({ project, state, busy, msg, onAction, onRetry, onDismiss }) {
  if (state.kind === 'loading') return html`<${Skeleton} rows=${3} height=${18}/>`;
  if (state.kind === 'error') return html`<${ErrorBox} error=${state.error} onRetry=${onRetry}/>`;
  const history = `/history?tab=builds&project=${encodeURIComponent(project)}`;
  const columns = [
    { key: 'key', label: 'KEY', sort: (r) => r.ticket_key, cell: (r) => html`<${Link} to=${history} class="cell-name">${r.ticket_key}<//>` },
    { key: 'status', label: 'STATUS', cell: (r) => r.status },
    { key: 'target', label: 'TARGET', cell: (r) => dash(buildCells(r).target) },
    { key: 'attempt', label: 'ATTEMPT', align: 'right', cell: (r) => dash(buildCells(r).attempt) },
    { key: 'claimed_by', label: 'CLAIMED BY', cell: (r) => dash(buildCells(r).claimed_by) },
    { key: 'machine', label: 'MACHINE', cell: (r) => dash(buildCells(r).machine) },
    { key: 'enqueued', label: 'ENQUEUED', sort: (r) => r.enqueued_at, cell: (r) => html`<${Age} min=${buildCells(r).enqueuedMin} warnAt=${Infinity}/>` },
    { key: 'claimed', label: 'CLAIMED', sort: (r) => r.claimed_at, cell: (r) => html`<${Age} min=${buildCells(r).claimedMin} warnAt=${Infinity}/>` },
    {
      key: 'action', label: 'ACTION', sort: null,
      cell: (r) => html`<span style="display:flex;gap:6px;flex-wrap:wrap">
        ${allowedActions(r).map((a) => html`<button key=${a} class="btn btn--sm" disabled=${busy}
          onClick=${() => onAction(r, a)}>${ACTION_COPY[a].confirmLabel}</button>`)}
      </span>`
    }
  ];
  return html`
    <div style="display:flex;flex-direction:column;gap:8px">
      <span class="section__note" style="margin:0">BUILD QUEUE</span>
      ${msg ? html`
        <div class="banner" role="status" style=${`flex-wrap:wrap;${msg.ok ? 'border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)' : ''}`}>
          <span>${msg.text}</span>
          <button class="btn btn--sm" style="margin-left:auto" onClick=${onDismiss}>DISMISS</button>
        </div>` : null}
      <${SortableTable} columns=${columns} rows=${state.rows} rowKey=${(r) => r.ticket_key} wide
        defaultSort="enqueued" defaultDir="asc"
        empty=${html`<${Empty} title="nothing queued" note=${`no ready, queued or claimed builds for ${project}`}/>`}/>
      ${state.capped
        ? html`<p class="section__note" style="margin:0">showing the first ${QUEUE_LIMIT} per status; more rows exist</p>`
        : null}
    </div>`;
}

export default function BuildQueuePanel({ project }) {
  const reads = BUILD_STATUSES.map((s) =>
    // Hooks in a map: BUILD_STATUSES is a fixed list, so the call order never changes.
    useApi(() => api.queueRows(project, s), [project], { intervalMs: 30000 }));
  // `ask`, not `confirm`: the shell suite forbids any bare native-dialog call name here.
  const [dialog, ask] = useConfirm();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState(null);
  const state = buildQueueState(reads);
  const reloadAll = () => reads.forEach((r) => r.reload());

  const onAction = async (row, action) => {
    if (busy || !allowedActions(row).includes(action)) return;
    // busy holds every action button disabled through the dialog and the write,
    // so a double click cannot send two.
    setBusy(true);
    setMsg(null);
    try {
      const form = { reason: '' };
      const copy = ACTION_COPY[action];
      const ok = await ask({
        title: copy.title, confirmLabel: copy.confirmLabel, tone: 'warn',
        confirmBlocked: actionFormState(form.reason).blocked,
        body: ({ setBlocked }) => html`<${ActionConfirmBody} action=${action} row=${row} value=${form} onBlocked=${setBlocked}/>`
      });
      if (!ok) return;
      try {
        setMsg(actionMessage(action, await api.queueAction(actionBody(project, row, action, form.reason))));
      } catch (e) {
        setMsg(actionMessage(action, null, e));
      }
      reloadAll();
    } finally {
      setBusy(false);
    }
  };

  return html`<div>
    ${dialog}
    <${BuildQueueView} project=${project} state=${state} busy=${busy} msg=${msg}
      onAction=${onAction} onRetry=${reloadAll} onDismiss=${() => setMsg(null)}/>
  </div>`;
}
