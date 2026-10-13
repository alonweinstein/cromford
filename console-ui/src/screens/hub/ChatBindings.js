import { useState } from 'preact/hooks';
import { html } from '../../router.js';
import { api } from '../../api.js';
import { useApi } from '../../lib/hooks.js';
import { useConfirm } from '../../ui/Modal.js';
import { PauseReasonForm } from '../../ui/PauseForms.js';
import { SortableTable } from '../../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox, ProjectLink } from '../../ui/primitives.js';
import { panelState } from '../../lib/restore-lab.js';
import { bindingsView, saveEdit } from '../../lib/chat-bindings.js';

// The CHAT BINDINGS panel of the HUB screen (BH-2678 / BH-2521.3): which
// Telegram thread each project posts to, from the telegram_topics rows, with an
// inline edit that moves one project to another thread. No add, no delete.
//
// It loads once on mount and on REFRESH (no interval): poll-commands.sh picks
// an edit up on its own sync, so there is nothing here worth polling for.
// Loading, load error, empty and rows are four different renders.

const NA = html`<span class="na">—</span>`;
const orNa = (v) => (v === null || v === undefined || v === '' ? NA : v);
const TONE = { ok: 'tag tag--green', bad: 'tag tag--bad' };

export function ChatBindingsView({ state, view, error, editing, draft, inline, busy, outcome,
  onEdit, onDraft, onSave, onCancel, onRefresh }) {
  const columns = [
    { key: 'project', label: 'PROJECT', cell: (r) => html`<${ProjectLink} project=${r.project} />` },
    { key: 'thread_id', label: 'THREAD', sort: (r) => Number(r.thread_id), cell: (r) => (r.project === editing
      ? html`<span style="display:inline-flex;flex-wrap:wrap;gap:6px;align-items:center">
          <input class="knob__input" style="width:6em;max-width:100%" inputmode="numeric"
            aria-label=${`new thread id for ${r.project}`} value=${draft}
            onInput=${(e) => onDraft(e.currentTarget.value)} />
          ${inline ? html`<span class="section__note">${inline}</span>` : null}
        </span>`
      : r.thread_id) },
    { key: 'actor', label: 'ACTOR', cell: (r) => orNa(r.actor) },
    { key: 'updated_at', label: 'UPDATED', cell: (r) => orNa(r.updated_at) },
    { key: 'edit', label: '', sort: null, cell: (r) => (r.project === editing
      ? html`<span style="display:inline-flex;gap:6px">
          <button type="button" class="btn btn--sm btn--warn" disabled=${busy} onClick=${() => onSave(r)}>SAVE</button>
          <button type="button" class="btn btn--sm" disabled=${busy} onClick=${onCancel}>CANCEL</button>
        </span>`
      : html`<button type="button" class="btn btn--sm" disabled=${busy} onClick=${() => onEdit(r)}>EDIT</button>`) },
  ];
  const refresh = html`<button type="button" class="btn btn--sm" onClick=${onRefresh}>REFRESH</button>`;

  return html`<${Section} title="CHAT BINDINGS" right=${refresh}>
    ${outcome ? html`<p style="margin:0 0 10px"><span class=${TONE[outcome.tone]} role="status">${outcome.text}</span></p>` : null}
    ${state === 'loading' ? html`<${Skeleton} rows=${3} />` : null}
    ${state === 'error' ? html`<${ErrorBox} error=${error} onRetry=${onRefresh} />` : null}
    ${state === 'empty' ? html`<${Empty} title="No chat bindings yet" />` : null}
    ${state === 'rows' ? html`
      <${SortableTable} columns=${columns} rows=${view.rows} rowKey=${(r) => r.project} defaultSort="project" />` : null}
    ${error && (state === 'rows' || state === 'empty')
      ? html`<p class="section__note" style="margin:6px 0 0">refresh failed: ${error.message}; showing the last answer</p>`
      : null}
  <//>`;
}

export function ChatBindingsPanel() {
  const { data, error, reload } = useApi(() => api.telegramTopics(), []);
  const [dialog, confirm] = useConfirm();
  const [editing, setEditing] = useState(null);
  const [draft, setDraft] = useState('');
  const [inline, setInline] = useState(null);
  const [busy, setBusy] = useState(false);
  const [outcome, setOutcome] = useState(null);

  let view = null;
  let loadError = error;
  if (data) {
    try { view = bindingsView(data); } catch (e) { loadError = e; }
  }

  const onEdit = (row) => {
    setEditing(row.project);
    setDraft(String(row.thread_id));
    setInline(null);
    setOutcome(null);
  };
  const onCancel = () => { setEditing(null); setInline(null); };
  const onSave = async (row) => {
    if (busy) return;
    // busy disables SAVE while the dialog and the PUT are in flight, so a
    // double click cannot send two moves.
    setBusy(true);
    try {
      // BH-2995: the dialog carries a required REASON; MOVE stays disabled
      // until it is filled.
      const renderForm = (form, setBlocked, text) =>
        html`<${PauseReasonForm} text=${text} value=${form} onBlocked=${setBlocked} />`;
      const out = await saveEdit({ apiObj: api, project: row.project, from: row.thread_id, raw: draft, confirm, reload, renderForm });
      if (!out) return;
      if (out.refused) { setInline(out.refused); return; }
      setInline(null);
      setOutcome(out.outcome);
      if (out.outcome.tone === 'ok') setEditing(null);
    } finally {
      setBusy(false);
    }
  };

  return html`<div>
    <${ChatBindingsView} state=${panelState({ view, error: loadError })} view=${view} error=${loadError}
      editing=${editing} draft=${draft} inline=${inline} busy=${busy} outcome=${outcome}
      onEdit=${onEdit} onDraft=${setDraft} onSave=${onSave} onCancel=${onCancel} onRefresh=${reload} />
    ${dialog}
  </div>`;
}
