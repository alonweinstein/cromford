import { useState } from 'preact/hooks';
import { html } from '../../router.js';
import { SortableTable } from '../../ui/SortableTable.js';
import { Section, Empty } from '../../ui/primitives.js';
import { agoFromMinutes } from '../../lib/format.js';
import { standbyRows } from '../../lib/standby.js';
import { useStandbyVerifyRuns, StandbyVerifyCell, StandbyVerifyDetail } from './StandbyVerify.js';

// The STANDBY panel of the HUB screen (BH-2641 / BH-2519.3): one row per
// standby heartbeat, read from the recovery answer the page already loaded
// (no second fetch for the rows). The verify cell and history come from the
// BH-2519 contract in ./StandbyVerify.js.
//
// An answer that names standby boxes but carries no `standbys` rows is an
// error line, never the empty state.

const NA = html`<span class="na">—</span>`;
const orNa = (v) => (v === null || v === undefined || v === '' ? NA : v);
const streamLabel = (r) => (r.ok ? 'ok' : 'FAILING');

export const STANDBY_COLUMNS = (lastByBox, openBox, onToggle, reload) => [
  { key: 'box', label: 'BOX', cell: (r) => html`
    <button type="button" class="cell-name" aria-expanded=${openBox === r.box ? 'true' : 'false'}
      style="background:none;border:0;padding:0;font:inherit;cursor:pointer;text-align:left"
      onClick=${() => onToggle(r.box)}>${r.box}</button>` },
  { key: 'hub', label: 'HUB', sort: (r) => r.ofHub, cell: (r) => orNa(r.ofHub) },
  { key: 'snapshot', label: 'LAST SNAPSHOT', cell: (r) => orNa(r.snapshot) },
  { key: 'stream', label: 'STREAM AGE', sort: (r) => r.streamAgeMin,
    cell: (r) => (r.streamAgeMin === null ? NA : agoFromMinutes(r.streamAgeMin)) },
  { key: 'reported', label: 'LAST REPORT', sort: (r) => r.reportAgeMin,
    cell: (r) => (r.reportAgeMin === null ? NA : html`<span title=${r.reportedAt}>${agoFromMinutes(r.reportAgeMin)} ago</span>`) },
  { key: 'ok', label: 'STREAM', sort: streamLabel,
    cell: (r) => html`<span class=${r.ok ? 'pill' : 'pill pill--dead'}>${streamLabel(r)}</span>` },
  { key: 'verify', label: 'LAST VERIFY', sort: (r) => lastByBox[r.box]?.requested_at,
    cell: (r) => html`<${StandbyVerifyCell} row=${r} last=${lastByBox[r.box]} onQueued=${reload} />` },
];

function HeartbeatDetail({ row }) {
  const fields = [['box', row.box], ['of_hub', row.ofHub], ['snapshot', row.snapshot], ['ok', row.ok ? 'true' : 'false'],
    ['reported_at', row.reportedAt], ['stream_age_min', row.streamAgeMin], ['report_age_min', row.reportAgeMin]];
  return html`
    <dl class="standby__detail"
      style="display:grid;grid-template-columns:max-content minmax(0,1fr);gap:4px 12px;margin:10px 0 0;font-size:var(--fs-xs)">
      ${fields.map(([k, v]) => html`
        <dt key=${`t-${k}`} style="color:var(--muted)">${k}</dt>
        <dd key=${`d-${k}`} style="margin:0;min-width:0;overflow-wrap:anywhere;word-break:break-all">${orNa(v)}</dd>`)}
    </dl>`;
}

// Pure render: `rows` is standbyRows' answer, an array or the error marker.
export function StandbyView({ rows, openBox, onToggle, runs, lastByBox, verifyError, reload }) {
  if (!Array.isArray(rows)) {
    return html`<${Section} title="STANDBY">
      <p class="knob__note knob__note--bad" style="max-width:none" role="alert">
        The recovery answer lists standby boxes (${(rows.standby || []).join(', ')}) but carries no standby rows.
      </p>
    <//>`;
  }
  if (!rows.length) {
    return html`<${Section} title="STANDBY"><${Empty} title="No standby has reported a heartbeat yet." /><//>`;
  }
  const open = openBox === null ? null : rows.find((r) => r.box === openBox) || null;
  return html`<${Section} title="STANDBY">
    <div style="overflow-x:auto;max-width:100%"><${SortableTable} wide columns=${STANDBY_COLUMNS(lastByBox, openBox, onToggle, reload)}
      rows=${rows} rowKey=${(r) => r.box} defaultSort="box" /></div>
    ${open ? html`
      <${HeartbeatDetail} row=${open} />
      <${StandbyVerifyDetail} box=${open.box} runs=${runs.filter((r) => r.box === open.box)}
        error=${verifyError} onRetry=${reload} />` : null}
  <//>`;
}

export function StandbyPanel({ data, reloadKey }) {
  const { runs, lastByBox, error, reload } = useStandbyVerifyRuns(reloadKey);
  const [openBox, setOpenBox] = useState(null);
  return html`<${StandbyView} rows=${standbyRows(data, Date.now())} openBox=${openBox}
    onToggle=${(box) => setOpenBox((cur) => (cur === box ? null : box))}
    runs=${runs} lastByBox=${lastByBox} verifyError=${error} reload=${reload} />`;
}
