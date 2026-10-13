// ACCOUNT & TOKEN HEALTH (BH-2516.3 / BH-2647): one row per credential the
// fleet uses (Claude OAuth, GitHub App), on the hub tab of /settings below
// PROJECT ACCOUNTS. Read-only: there is nothing to set here, so there is no
// form, no confirm and no write. Red is the worker's `expiring`.

import { useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox, Age, ProjectLink } from '../ui/primitives.js';
import { minutesSince, clockTime } from '../lib/format.js';
import { healthRows, warnNote, truncatedNote } from '../lib/token-health.js';

export function TokenHealthSection() {
  const q = useApi(() => api.tokenHealth(), [], { intervalMs: 60000 });
  return html`<${TokenHealthView} data=${q.data} error=${q.error}
    loading=${q.loading && !q.data} onRetry=${q.reload}/>`;
}

const keyOf = (r) => `${r.kind}:${r.subject}`;
const na = html`<span class="na">—</span>`;

// `initialExpanded` exists so a render test can see an open account without a DOM.
export function TokenHealthView({ data, error, loading, onRetry, initialExpanded = [] }) {
  const [open, setOpen] = useState(() => new Set(initialExpanded));
  const toggle = (k) => setOpen((s) => {
    const n = new Set(s);
    if (n.has(k)) n.delete(k); else n.add(k);
    return n;
  });
  const rows = healthRows(data);
  const note = warnNote(data);
  const body = () => {
    if (loading) return html`<${Skeleton}/>`;
    if (error && !data) return html`<${ErrorBox} error=${error} onRetry=${onRetry}/>`;
    if (!rows.length) return html`<${Empty} title="no accounts reported"/>`;
    return html`
      ${error ? html`
        <div class="banner">
          <span><b>could not refresh token health — ${String(error.message || error)}.</b> The rows below are the last good read.</span>
        </div>` : null}
      <${SortableTable} wide rows=${rows} rowKey=${keyOf} defaultSort="expires" defaultDir="asc"
        rowClass=${(r) => (r.red ? 'row--dead cell--red' : '')}
        columns=${[
          { key: 'kind', label: 'KIND', sort: (r) => r.kindLabel, cell: (r) => r.kindLabel },
          {
            key: 'subject', label: 'ACCOUNT', sort: (r) => r.subject,
            cell: (r) => html`<button type="button" class="cell-name" aria-expanded=${open.has(keyOf(r)) ? 'true' : 'false'}
              onClick=${() => toggle(keyOf(r))}>${r.subject}</button>${r.noReport ? html` <span class="na">(no report)</span>` : null}`
          },
          { key: 'leases', label: 'LEASES', sort: (r) => r.leaseCount, align: 'right', cell: (r) => r.leaseCount },
          {
            key: 'expires', label: 'EXPIRES', sort: (r) => r.expiresInS,
            cell: (r) => html`<span>${r.expiresText}</span>${r.red ? html` <b>EXPIRING</b>` : null}`
          },
          {
            key: 'refresh', label: 'LAST REFRESH', sort: (r) => r.lastOkAt,
            cell: (r) => (r.lastOkAt
              ? html`<span title=${r.lastOkAt}><${Age} min=${minutesSince(r.lastOkAt)} warnAt=${Infinity}/></span>`
              : html`<span class="na">never</span>`)
          },
          { key: 'fails', label: 'FAILS', sort: (r) => r.failCount, align: 'right', cell: (r) => (r.failCount === null ? na : r.failCount) },
          { key: 'error', label: 'LAST ERROR', flex: true, sort: (r) => r.lastError, cell: (r) => (r.lastError ? html`<span class="mono">${r.lastError}</span>` : na) },
          { key: 'box', label: 'BOX', sort: (r) => r.box, cell: (r) => (r.box ? html`<${Link} to="/machines" class="cell-name">${r.box}<//>` : na) },
        ]}/>
      ${rows.filter((r) => open.has(keyOf(r))).map((r) => html`<${LeaseTable} key=${keyOf(r)} row=${r}/>`)}`;
  };
  return html`
    <${Section} title="ACCOUNT & TOKEN HEALTH" note="which credentials the fleet runs on, and when each one expires">
      ${body()}
      ${!loading && data && truncatedNote(data) ? html`<div class="section__note">list truncated — the worker capped this read; not every lease/token is shown</div>` : null}
      ${!loading && note ? html`<div class="section__note">${note}</div>` : null}
    <//>`;
}

function LeaseTable({ row }) {
  return html`
    <div style="margin-top:8px">
      <div class="section__note">live leases on <b class="mono">${row.subject}</b></div>
      <${SortableTable} wide rows=${row.leases} rowKey=${(l) => `${l.machine_id}:${l.project}:${l.ticket_key}`}
        defaultSort="expires"
        empty=${html`<${Empty} title="no live leases"/>`}
        columns=${[
          { key: 'machine', label: 'MACHINE', sort: (l) => l.machine_id, cell: (l) => html`<span class="mono">${l.machine_id || '—'}</span>` },
          { key: 'box', label: 'BOX', sort: (l) => l.box, cell: (l) => (l.box ? html`<${Link} to="/machines" class="cell-name">${l.box}<//>` : na) },
          { key: 'project', label: 'PROJECT', sort: (l) => l.project, cell: (l) => (l.project ? html`<${ProjectLink} project=${l.project}/>` : na) },
          { key: 'ticket', label: 'TICKET', sort: (l) => l.ticket_key, cell: (l) => (l.ticket_key ? html`<span class="mono">${l.ticket_key}</span>` : na) },
          { key: 'expires', label: 'EXPIRES', sort: (l) => l.expires_at, cell: (l) => html`<span title=${l.expires_at || ''}>${clockTime(l.expires_at)}</span>` },
        ]}/>
    </div>`;
}
