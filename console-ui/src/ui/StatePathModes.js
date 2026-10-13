import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from './SortableTable.js';
import { Skeleton } from './primitives.js';
import { configHref } from '../lib/config.js';
import { STATE_PATH_KNOBS, pathModes } from '../lib/state-path-modes.js';

// BH-5000 (BH-4951.1) — the STATE PATHS panel on /settings: file, rows or
// shadow for each coordination path #5000 flips. Read-only: one flags read and
// one settings read per knob, polled like MergeQueue. Flipping one is
// bin/jobs-client.sh on the hub, and each PATH links to its /config page.

const POLL = { intervalMs: 60000 };
const settled = (r) => r && (r.data || r.error);

// `#` is the order #5000 flips them in, and the default sort.
const columns = [
  { key: 'order', label: '#', sort: (r) => r.order, cell: (r) => html`<span class="num">${r.order}</span>` },
  { key: 'name', label: 'PATH', sort: (r) => r.name,
    cell: (r) => html`<${Link} to=${configHref(r.kind, r.name)} class="cell-name">${r.name}<//>` },
  { key: 'kind', label: 'KIND', sort: (r) => r.kind, cell: (r) => html`<span>${r.kind}</span>` },
  { key: 'mode', label: 'MODE', sort: (r) => r.mode,
    cell: (r) => html`<span class=${r.mode === 'unread' ? 'tag tag--warn' : 'tag'}>${r.mode}</span>` },
  { key: 'source', label: 'SOURCE', sort: (r) => r.source, cell: (r) => html`<span class="mono">${r.source}</span>` },
  { key: 'updated_at', label: 'UPDATED', sort: (r) => r.updated_at || '',
    cell: (r) => (r.updated_at ? html`<span class="num">${r.updated_at}</span>` : html`<span class="na">—</span>`) },
  { key: 'note', label: 'NOTE', flex: true, sort: (r) => r.note,
    cell: (r) => (r.note ? html`<span>${r.note}</span>` : html`<span class="na">—</span>`) }
];

// flags: useApi answer for api.coordFlags(); settings: { <knob>: useApi answer }.
export function StatePathModesView({ flags, settings }) {
  if (![flags, ...STATE_PATH_KNOBS.map((k) => settings[k])].every(settled)) return html`<${Skeleton} rows=${4} height=${20}/>`;
  const { rows: modes, failed } = pathModes(flags, settings);
  const rows = modes.map((r, i) => ({ ...r, order: i + 1 }));
  return html`
    ${failed.length ? html`<div class="footnote" role="status" style="margin-bottom:6px">
      <span class="tag tag--warn">could not read: ${failed.join(', ')}</span>
      <span style="color:var(--faint)"> those rows show unread, not file</span></div>` : null}
    <${SortableTable} wide columns=${columns} rows=${rows} rowKey=${(r) => r.name} defaultSort="order"/>`;
}

export function StatePathModesPanel() {
  const flags = useApi(() => api.coordFlags(), [], POLL);
  const settings = {};
  // A fixed list, so the hooks run in the same order on every render.
  for (const k of STATE_PATH_KNOBS) settings[k] = useApi(() => api.coordSetting(k), [], POLL);
  return html`<${StatePathModesView} flags=${flags} settings=${settings}/>`;
}
