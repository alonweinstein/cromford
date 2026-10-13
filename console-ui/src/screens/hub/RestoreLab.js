import { useState } from 'preact/hooks';
import { html } from '../../router.js';
import { api } from '../../api.js';
import { useApi } from '../../lib/hooks.js';
import { useConfirm } from '../../ui/Modal.js';
import { SortableTable } from '../../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../../ui/primitives.js';
import { historyView, panelState, requestRestore, RESTORE_LAB_LIMIT } from '../../lib/restore-lab.js';

// The restore-lab panel of the HUB screen (BH-1946 / BH-1909.4): the last runs
// of the restore lab, and a request that restores a box's latest backup into a
// scratch dir on the hub. `boxes` is an array of box-name strings.
//
// Loading, load error, empty and rows are four different renders: until the
// worker route lands it answers 501, and that is a load error, not "no runs".
// The load is useApi's, whose alive guard drops an answer that lands after the
// panel unmounts or reloads (api.restoreLabRuns takes no abort signal).

const NA = html`<span class="na">—</span>`;
const orNa = (v) => (v === null || v === undefined || v === '' ? NA : v);
const TONE = { ok: 'tag tag--green', warn: 'tag tag--warn', bad: 'tag tag--bad' };
const DETAIL = ['id', 'box', 'snapshot', 'status', 'verdict_detail', 'sha256', 'snapshot_ts',
  'requested_by', 'requested_at', 'claimed_by', 'claimed_at', 'finished_at'];

function RunDetail({ run }) {
  return html`
    <dl class="restore-lab__detail"
      style="display:grid;grid-template-columns:max-content minmax(0,1fr);gap:4px 12px;margin:10px 0 0;font-size:var(--fs-xs)">
      ${DETAIL.map((k) => html`
        <dt key=${`t-${k}`} style="color:var(--muted)">${k}</dt>
        <dd key=${`d-${k}`} style="margin:0;min-width:0;overflow-wrap:anywhere;word-break:break-all">${orNa(run[k])}</dd>`)}
    </dl>`;
}

export function RestoreLabView({ state, view, error, boxes, box, onBox, onRequest, busy, openId, onToggle, outcome, onRetry }) {
  const columns = [
    { key: 'box', label: 'BOX', cell: (r) => html`
      <button type="button" class="cell-name" aria-expanded=${openId === r.id ? 'true' : 'false'}
        style="background:none;border:0;padding:0;font:inherit;cursor:pointer;text-align:left"
        onClick=${() => onToggle(r.id)}>${r.box}</button>` },
    { key: 'snapshot', label: 'SNAPSHOT', cell: (r) => orNa(r.snapshot) },
    { key: 'status', label: 'STATUS', cell: (r) => orNa(r.status) },
    { key: 'requested_by', label: 'REQUESTED BY', cell: (r) => orNa(r.requested_by) },
    { key: 'requested_at', label: 'REQUESTED', cell: (r) => orNa(r.requested_at) },
    { key: 'finished_at', label: 'FINISHED', cell: (r) => orNa(r.finished_at) },
  ];
  const open = view && openId !== null ? view.rows.find((r) => r.id === openId) : null;
  const blocked = !boxes.length || busy;

  return html`<${Section} title="RESTORE LAB">
    <div style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:10px">
      <select class="knob__input" style="width:auto;max-width:100%" aria-label="box"
        value=${box || ''} disabled=${blocked} onChange=${(e) => onBox(e.currentTarget.value)}>
        ${boxes.map((b) => html`<option key=${b} value=${b}>${b}</option>`)}
      </select>
      <button type="button" class="btn btn--warn" disabled=${blocked} onClick=${onRequest}>Restore latest into scratch</button>
      ${!boxes.length ? html`<span class="section__note">no boxes known yet</span>` : null}
      ${outcome ? html`<span class=${TONE[outcome.tone]} role="status">${outcome.text}</span>` : null}
    </div>
    ${state === 'loading' ? html`<${Skeleton} rows=${3} />` : null}
    ${state === 'error' ? html`<${ErrorBox} error=${error} onRetry=${onRetry} />` : null}
    ${state === 'empty' ? html`<${Empty} title="No restore runs yet" />` : null}
    ${state === 'rows' ? html`
      <${SortableTable} columns=${columns} rows=${view.rows} rowKey=${(r) => r.id}
        defaultSort="requested_at" defaultDir="desc" />
      ${view.truncated ? html`<p class="section__note" style="margin:6px 0 0">showing the last ${RESTORE_LAB_LIMIT} runs</p>` : null}
      ${open ? html`<${RunDetail} run=${open} />` : null}` : null}
    ${error && (state === 'rows' || state === 'empty')
      ? html`<p class="section__note" style="margin:6px 0 0">refresh failed: ${error.message}; showing the last answer</p>`
      : null}
  <//>`;
}

export function RestoreLabPanel({ boxes }) {
  const list = Array.isArray(boxes) ? boxes : [];
  const { data, error, reload } = useApi(() => api.restoreLabRuns(), []);
  const [dialog, confirm] = useConfirm();
  const [picked, setPicked] = useState(null);
  const [busy, setBusy] = useState(false);
  const [outcome, setOutcome] = useState(null);
  const [openId, setOpenId] = useState(null);
  // The pick follows `boxes`: a box that left the list falls back to the first.
  const box = list.includes(picked) ? picked : (list[0] ?? null);

  let view = null;
  let loadError = error;
  if (data) {
    try { view = historyView(data); } catch (e) { loadError = e; }
  }

  const onRequest = async () => {
    if (busy || !box) return;
    // busy disables the button while the dialog and the POST are in flight, so
    // a double click cannot send two requests.
    setBusy(true);
    try {
      const out = await requestRestore({ apiObj: api, box, confirm, reload });
      if (out) setOutcome(out);
    } finally {
      setBusy(false);
    }
  };

  return html`<div>
    <${RestoreLabView} state=${panelState({ view, error: loadError })} view=${view} error=${loadError}
      boxes=${list} box=${box} onBox=${setPicked} onRequest=${onRequest} busy=${busy}
      openId=${openId} onToggle=${(id) => setOpenId((cur) => (cur === id ? null : id))}
      outcome=${outcome} onRetry=${reload} />
    ${dialog}
  </div>`;
}
