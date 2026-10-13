// BH-5668 (BH-5008 child 2): the running-batch table at the top of
// /merge-queue and the one-line strip at the top of /jobs. Both read
// useMergeQueueLive (ui/merge-queue-live-data.js, a 5 s poll while the tab is
// visible); the *View halves take its answer as `res`, so every state renders
// without a fetch.
//
// States are kept apart (D23): loading, a load error with nothing to show,
// no batch running, and batches. A later failed poll over good data shows the
// data with one "Last update failed" line, never as live. `complete: false`
// says the list is capped (D12).

import { html, Link } from '../router.js';
import { SortableTable } from './SortableTable.js';
import { Section, Empty, ErrorBox, Skeleton } from './primitives.js';
import { clockTime } from '../lib/format.js';
import { useMergeQueueLive } from './merge-queue-live-data.js';

export function etaWords(batch) {
  const b = batch || {};
  if (b.eta_basis === 'done') return 'finished';
  if (b.eta_s === null || b.eta_s === undefined) return 'no estimate yet';
  if (b.eta_s < 60) return 'under 1 min left';
  return `about ${Math.round(b.eta_s / 60)} min left`;
}

export const pct = (progress) => (typeof progress === 'number' && Number.isFinite(progress)
  ? Math.round(Math.min(1, Math.max(0, progress)) * 100) : 0);

const repoName = (b) => {
  if (b.repo && String(b.repo).includes('/')) return String(b.repo).split('/')[1];
  const m = /^https:\/\/github\.com\/[^/]+\/([^/]+)\/pull\//.exec(String(b.url || ''));
  return m ? m[1] : null;
};

// The member's PR screen. The screen's project wins (every batch on a
// filtered screen is that project's), then the batch's, then the repo name.
export const prHref = (batch, n, project) => `/pr/${encodeURIComponent(project || batch.project || repoName(batch) || '')}/${n}`;

const byDraft = (a, b) => a.draft - b.draft;

function Bar({ batch }) {
  const p = pct(batch.progress);
  return html`
    <div data-mq-batch=${batch.draft} role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow=${p}
      aria-label=${`Batch #${batch.draft} progress`}
      style="background: var(--rule); min-width: 6rem; height: 8px">
      <div style=${`width:${p}%; background: var(--live); height: 100%`}></div>
    </div>`;
}

function columns(project) {
  return [
    {
      key: 'draft', label: 'BATCH', sort: (b) => b.draft,
      cell: (b) => html`<a href=${b.url} target="_blank" rel="noopener" class="cell-name">#${b.draft}</a>`,
    },
    {
      key: 'members', label: 'MEMBERS', sort: (b) => (b.members || []).length,
      cell: (b) => html`<span style="display:flex;flex-wrap:wrap;gap:6px">
        ${(b.members || []).map((n) => html`<${Link} key=${n} to=${prHref(b, n, project)}>#${n}<//>`)}
      </span>`,
    },
    {
      key: 'stage', label: 'STAGE', sort: (b) => b.stage,
      cell: (b) => (b.stage ? html`<span class="tag" data-mq-stage=${b.stage}>${b.stage}</span>` : null),
    },
    { key: 'progress', label: 'PROGRESS', sort: (b) => b.progress, cell: (b) => html`<${Bar} batch=${b}/>` },
    {
      key: 'checks', label: 'CHECKS', sort: (b) => (b.checks ? b.checks.done : null),
      cell: (b) => `Checks ${b.checks ? b.checks.done : 0}/${b.checks ? b.checks.total : 0}`,
    },
    { key: 'eta', label: 'ETA', sort: (b) => b.eta_s, cell: (b) => etaWords(b) },
  ];
}

function staleLine(res) {
  return res.error && res.fetchedAt
    ? html`<div class="banner" role="status"><span>Last update failed; showing data from ${clockTime(res.fetchedAt)}</span></div>`
    : null;
}

export function MergeQueueBatchesView({ res, project }) {
  const r = res || {};
  const body = () => {
    if (r.state === 'loading') return html`<${Skeleton} rows=${2}/>`;
    if (r.state === 'error') return html`<${ErrorBox} error=${r.error || 'the merge queue'} onRetry=${r.reload}/>`;
    const batches = Array.isArray(r.batches) ? r.batches : [];
    return html`
      ${staleLine(r)}
      ${batches.length
        ? html`<${SortableTable} wide columns=${columns(project)} rows=${batches} rowKey=${(b) => `${b.repo}#${b.draft}`}
            defaultSort="draft"/>`
        : html`<${Empty} title="No batch is running."/>`}
      ${r.complete === false ? html`<div class="section__note">The list is capped.</div>` : null}`;
  };
  return html`<${Section} title="RUNNING BATCHES" note="Mergify batch drafts, live every 5 s">${body()}<//>`;
}

function stripText(r) {
  if (r.state === 'loading') return 'Merge queue: loading';
  if (r.state === 'error') return 'Merge queue: could not load';
  const batches = (Array.isArray(r.batches) ? r.batches : []).slice().sort(byDraft);
  const stale = r.error ? ' · last update failed' : '';
  if (!batches.length) return `Merge queue: nothing running${stale}`;
  const b = batches[0];
  const n = batches.length;
  return `Merge queue: ${n} ${n === 1 ? 'batch' : 'batches'} running · #${b.draft} ${pct(b.progress)}% ${etaWords(b)}${stale}`;
}

export function MergeQueueStripView({ res }) {
  return html`<${Link} to="/merge-queue" class="crumb"
    style="display:inline-block;margin-top:8px;overflow-wrap:anywhere">${stripText(res || {})}<//>`;
}

export function MergeQueueBatches({ project } = {}) {
  return MergeQueueBatchesView({ res: useMergeQueueLive({ project }), project });
}

export function MergeQueueStrip({ project } = {}) {
  return MergeQueueStripView({ res: useMergeQueueLive({ project }) });
}
