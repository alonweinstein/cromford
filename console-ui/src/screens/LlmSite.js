// BH-2557 (BH-2540.4): one LLM site — its catalog record and the cost rows it
// wrote, from GET /api/coord/metrics/llm-sites/rows?site=<id> (payload
// documented in worker/jobs/src/routes/llm-sites.js). Loading, failure, an
// unknown site, a site that writes no cost row and a site with no rows in the
// window are five different states, and each one says only its own thing.
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { useApi } from '../lib/hooks.js';
import { api } from '../api.js';
import { Empty, ErrorBox, Cursor } from '../ui/primitives.js';
import { SortableTable } from '../ui/SortableTable.js';
import { UsdCell } from '../ui/UsdCell.js';

const blank = (v) => v === null || v === undefined || v === '';
const text = (v) => (blank(v) ? html`<span class="na">—</span>` : String(v));
const mono = (v) => (blank(v) ? html`<span class="na">—</span>` : html`<span class="mono">${v}</span>`);

// A PR links only when the row names both halves of /pr/:project/:number; a
// half-known PR is text, never a guessed link.
const prCell = (r) => (!blank(r.project) && !blank(r.pr)
  ? html`<${Link} to=${`/pr/${encodeURIComponent(r.project)}/${encodeURIComponent(r.pr)}`}>${r.ticket ? `${r.ticket} · ` : ''}#${r.pr}<//>`
  : text(r.ticket ?? (blank(r.pr) ? null : `#${r.pr}`)));

const COLUMNS = [
  { key: 'ts', label: 'ts', cell: (r) => mono(r.ts) },
  { key: 'box', label: 'box', cell: (r) => text(r.box) },
  { key: 'project', label: 'project', cell: (r) => text(r.project) },
  { key: 'stage', label: 'stage', cell: (r) => text(r.stage) },
  { key: 'runner', label: 'runner', cell: (r) => text(r.runner) },
  { key: 'model', label: 'model', cell: (r) => text(r.model) },
  { key: 'billing_mode', label: 'billing', cell: (r) => text(r.billing_mode) },
  { key: 'rc', label: 'rc', align: 'right', cell: (r) => text(r.rc) },
  { key: 'cost_usd', label: '$', align: 'right', sort: (r) => r.cost_usd,
    cell: (r) => (blank(r.cost_usd) ? html`<span class="na">—</span>` : html`<${UsdCell} value=${r.cost_usd} basis="api"/>`) },
  { key: 'ticket', label: 'ticket/pr', sort: (r) => r.ticket ?? r.pr, cell: prCell },
  { key: 'row_source', label: 'source', cell: (r) => text(r.row_source) },
  { key: 'note', label: 'note', flex: true, cell: (r) => text(r.note) }
];

function SiteFacts({ rec }) {
  if (!rec) return html`<div class="banner banner--warn">catalog record not returned for this site</div>`;
  const runners = Array.isArray(rec.runners) && rec.runners.length ? rec.runners.join(', ') : null;
  return html`
    <dl class="lanekv">
      <dt>id</dt><dd>${mono(rec.id)}</dd>
      <dt>script</dt><dd>${mono(rec.script)}</dd>
      <dt>marker</dt><dd>${mono(rec.marker)}</dd>
      <dt>kind</dt><dd>${text(rec.kind)}</dd>
      <dt>lane</dt><dd>${typeof rec.lane === 'string' && rec.lane
        ? html`<${Link} to=${`/settings/${encodeURIComponent(rec.lane)}`}>${rec.lane}<//>`
        : html`<span class="na">—</span>`}</dd>
      <dt>stage</dt><dd>${text(rec.stage)}</dd>
      <dt>runners</dt><dd>${text(runners)}</dd>
      <dt>note</dt><dd>${text(rec.note)}</dd>
    </dl>`;
}

function Body({ data }) {
  if (data.reason === 'no-stage') {
    return html`<${Empty} title="this site writes no cost row"
      note="its calls are not recorded in the cost ledger, so there is nothing to list here"/>`;
  }
  return html`
    ${data.truncated ? html`<div class="section__note">showing the newest 200</div>` : null}
    <${SortableTable} wide columns=${COLUMNS} rows=${data.rows} defaultSort="ts" defaultDir="desc"
      empty=${html`<${Empty} title="no cost rows for this site in the window"/>`}/>`;
}

export function LlmSiteView({ site, state, onRetry }) {
  const { data, error, loading } = state;
  let body;
  if (error && error.status === 400) {
    body = html`<${Empty} title="no such site" note=${`${site} is not in the LLM site catalog`}>
      <${Link} to="/llm-sites">back to LLM sites<//>
    <//>`;
  } else if (!data) {
    body = error ? html`<${ErrorBox} error=${error} onRetry=${onRetry}/>`
      : loading ? html`<${Cursor}/>` : null;
  } else if (!Array.isArray(data.rows)) {
    body = html`<${ErrorBox} error="bad response: no rows array" onRetry=${onRetry}/>`;
  } else {
    const inc = Array.isArray(data.incomplete) ? data.incomplete : [];
    body = html`
      ${error ? html`<${ErrorBox} error=${error} onRetry=${onRetry}/>` : null}
      <${SiteFacts} rec=${data.site}/>
      ${inc.length ? html`<div class="banner banner--warn">incomplete: ${inc.join(', ')}</div>` : null}
      <${Body} data=${data}/>`;
  }
  return html`
    <div class="page">
      <div style="display:flex;align-items:center;gap:14px;flex-wrap:wrap">
        <${Link} to="/llm-sites" class="crumb">← LLM sites<//>
        <span class="crumb-sep">/</span>
      </div>
      <${PageHeadline} chip="LLM site" line1=${site} line2="One place in the code that calls a model."/>
      ${body}
    </div>`;
}

export function LlmSiteScreen({ site }) {
  const st = useApi(() => api.llmSiteRows(site), [site]);
  return html`<${LlmSiteView} site=${site} state=${st} onRetry=${st.reload}/>`;
}
