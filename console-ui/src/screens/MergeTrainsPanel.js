import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Skeleton, Empty, ErrorBox, Age } from '../ui/primitives.js';
import { minutesSince } from '../lib/format.js';
import { panelState } from '../lib/queue-panel.js';
import { trainCells, trainsCapped, TRAINS_SHOWN } from '../lib/merge-trains-panel.js';

// The QUEUES section's merge trains table on /p/<project> (BH-3153): the newest
// trains bin/batch-resolve.sh recorded for this project, polled every 30 s.
// Read-only: the train PR and each member link to their PR page.
export default function MergeTrainsPanel({ project }) {
  const read = useApi(() => api.mergeTrains(project, TRAINS_SHOWN), [project], { intervalMs: 30000 });
  if (!read.data && !read.error) return html`<${Skeleton} rows=${3} height=${18}/>`;
  // A failed read, a failed refresh still holding old rows, or a body without
  // merge_trains is an error, never an empty table.
  const s = panelState({ trains: read }).trains;
  if (s.kind === 'error') return html`<${ErrorBox} error=${s.error} onRetry=${read.reload}/>`;

  const rows = s.rows.map((r) => ({ ...r, cells: trainCells(r, project) }));
  const columns = [
    { key: 'branch', label: 'BRANCH', flex: true, cell: (r) => html`<span class="mono cell-wrap">${r.branch}</span>` },
    { key: 'outcome', label: 'OUTCOME', cell: (r) => r.outcome || '—' },
    { key: 'members', label: 'MEMBERS', sort: (r) => r.cells.membersSummary, cell: (r) => {
      const { membersShown, membersMore } = r.cells;
      if (!membersShown.length) return 'none';
      return html`<span style="white-space:nowrap">${membersShown.map((m, i) => html`
        ${i ? ', ' : ''}<${Link} key=${m.number} to=${m.href}>#${m.number}<//>`)}${membersMore ? ` +${membersMore} more` : ''}</span>`;
    } },
    { key: 'member_count', label: 'MEMBER COUNT', align: 'right',
      cell: (r) => (r.member_count === null || r.member_count === undefined ? '—' : r.member_count) },
    { key: 'train_pr', label: 'TRAIN PR', sort: (r) => (r.cells.prHref ? Number(r.train_pr) : null),
      cell: (r) => (r.cells.prHref ? html`<${Link} to=${r.cells.prHref}>${r.cells.prLabel}<//>` : r.cells.prLabel) },
    { key: 'updated_at', label: 'UPDATED',
      cell: (r) => html`<${Age} min=${minutesSince(r.updated_at)} warnAt=${Infinity}/>` }
  ];
  return html`
    <div>
      <div class="section__note" style="margin:6px 0">MERGE TRAINS</div>
      <${SortableTable} columns=${columns} rows=${rows} rowKey=${(r) => r.branch} wide
        defaultSort="updated_at" defaultDir="desc"
        empty=${html`<${Empty} title="no trains yet"/>`}/>
      ${trainsCapped(s.rows)
        ? html`<p class="section__note" style="margin:6px 0 0">newest ${TRAINS_SHOWN} shown; older trains exist</p>`
        : null}
    </div>`;
}
