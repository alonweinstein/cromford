import { useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { UsdCell } from '../ui/UsdCell.js';
import { USAGE_WINDOWS, usageRows, unpricedBanner } from '../lib/account-usage.js';

// BH-167.3: what each Claude account spent in a trailing 5h/7d window, from
// cost_rows grouped by auth_account, with the hub's vendor meter beside it as
// a cross-check. The numbers are the worker's; this file only lays them out.
// Split like ProjectAccounts: the section owns the fetch, the view is a pure
// function of props so it renders server-side in the tests.
export function AccountUsageSection() {
  const [win, setWin] = useState('5h');
  const a = useApi(() => api.accountUsage(win), [win], { intervalMs: 60000 });
  return html`<${AccountUsageView} data=${a.data} error=${a.error} loading=${a.loading}
    reload=${a.reload} win=${win} onWin=${setWin}/>`;
}

// The token and count columns both tables share.
const countColumns = [
  { key: 'usd', label: '$', sort: (r) => r.usd, cell: (r) => html`<${UsdCell} value=${r.usd} basis="api"/>`, align: 'right' },
  { key: 'calls', label: 'CALLS', sort: (r) => r.calls, cell: (r) => r.calls ?? '—', align: 'right' },
  { key: 'unpriced', label: 'UNPRICED', sort: (r) => r.unpriced, cell: (r) => r.unpriced ?? '—', align: 'right' },
  { key: 'in', label: 'IN TOK', sort: (r) => r.in, cell: (r) => r.inText, align: 'right' },
  { key: 'out', label: 'OUT TOK', sort: (r) => r.out, cell: (r) => r.outText, align: 'right' },
  { key: 'cr', label: 'CACHE R', sort: (r) => r.cr, cell: (r) => r.crText, align: 'right' },
  { key: 'cw', label: 'CACHE W', sort: (r) => r.cw, cell: (r) => r.cwText, align: 'right' },
];

// A comparable cross-check splits its two figures by basis: the meter is cash,
// the rows are API-equivalent. Same words as crossCheckLine, which stays the
// title so the whole line still reads on hover.
function CrossCheckCell({ row }) {
  const x = row.raw && row.raw.cross_check;
  if (!x || x.state !== 'comparable') return row.cross;
  const gap = x.gap_pct === null || x.gap_pct === undefined ? 'gap —' : `gap ${x.gap_pct}%`;
  return html`<span title=${row.cross}>meter <${UsdCell} value=${x.meter_delta_usd} basis="cash"/> vs rows <${UsdCell} value=${x.rows_usd} basis="api"/>, ${gap}</span>`;
}

const projectColumns = [
  {
    key: 'project', label: 'PROJECT', sort: (r) => r.name,
    cell: (r) => (r.project === null
      ? html`<span class="na">(no project)</span>`
      : html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`} class="cell-name">${r.project}<//>`),
  },
  ...countColumns,
];

export function AccountUsageView({ data, error, loading, reload, win, onWin, initialOpen = null }) {
  const [open, setOpen] = useState(initialOpen);
  const rows = usageRows(data);

  const switcher = html`<span style="display:inline-flex;gap:6px;flex-wrap:wrap">
    ${USAGE_WINDOWS.map((w) => html`
      <button key=${w.key} type="button" class=${w.key === win ? 'tab tab--on' : 'tab'}
        aria-pressed=${w.key === win ? 'true' : 'false'}
        onClick=${() => onWin(w.key)}>${w.label}</button>`)}
  </span>`;

  const accountColumns = [
    {
      key: 'account', label: 'ACCOUNT', sort: (r) => r.label,
      cell: (r) => html`<button type="button" class="btn btn--sm" aria-expanded=${open === r.key ? 'true' : 'false'}
        onClick=${() => setOpen(open === r.key ? null : r.key)}>${r.label}</button>`,
    },
    ...countColumns,
    { key: 'session', label: 'METER 5H %', sort: (r) => r.sessionPct, cell: (r) => r.sessionText, align: 'right' },
    { key: 'weekly', label: 'METER WEEK %', sort: (r) => r.weeklyPct, cell: (r) => r.weeklyText, align: 'right' },
    { key: 'cross', label: 'CROSS-CHECK', sort: (r) => r.cross, cell: (r) => html`<${CrossCheckCell} row=${r}/>` },
  ];

  const body = () => {
    if (loading && !data) return html`<${Skeleton} rows=${4} height=${20}/>`;
    if (error && !data) return html`<${ErrorBox} error=${error} onRetry=${reload}/>`;
    if (!rows.length) {
      return html`<${Empty} title="no usage in this window" note="No cost row carries an account in this window."/>`;
    }
    const banner = unpricedBanner(data);
    const t = data.truncated || {};
    const openRow = rows.find((r) => r.key === open);
    return html`
      ${banner ? html`<div class="banner banner--warn" style="margin-bottom:10px"><span>${banner}</span></div>` : null}
      ${t.groups || t.projects || t.snapshots ? html`
        <div class="footnote" style="margin-bottom:10px"><span style="color:var(--faint)">
          This list is capped by the worker, so it does not cover every account or project in the window.
        </span></div>` : null}
      <${SortableTable} wide columns=${accountColumns} rows=${rows} rowKey=${(r) => r.key}
        defaultSort="usd" defaultDir="desc"/>
      ${openRow ? html`
        <div style="margin-top:12px">
          <div class="section__note" style="margin-bottom:6px">${openRow.label} · projects</div>
          <${SortableTable} wide columns=${projectColumns} rows=${openRow.projects} rowKey=${(r) => r.key}
            defaultSort="usd" defaultDir="desc"
            empty=${html`<${Empty} title="no projects" note="No project carries a row for this account."/>`}/>
        </div>` : null}`;
  };

  const note = data ? `cost_rows per auth_account · window ${data.window} · ${data.from} → ${data.to}` : null;
  return html`<${Section} title="ACCOUNT USAGE" note=${note} right=${switcher}>${body()}<//>`;
}
