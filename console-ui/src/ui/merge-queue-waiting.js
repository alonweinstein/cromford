// BH-5669 (BH-5008 child 3): the PRs waiting to be batched, on /merge-queue
// under the batch section (screens/MergeQueue.js). The rows are the worker's
// `waiting` list: each PR whose newest stage row is `queued (<n>)`, n being
// its place in the line. Position order by default; every header sorts.
//
// Renders nothing while loading or when nobody waits: the batch section above
// owns that copy. A load failure with no rows is an error box, never an empty
// line (D23). A capped answer says the list may be incomplete (D12).

import { html, Link } from '../router.js';
import { Section, ErrorBox } from './primitives.js';
import { SortableTable } from './SortableTable.js';
import { clockTime } from '../lib/format.js';
import { ticketPath } from '../lib/line.js';
import { useMergeQueueLive } from './merge-queue-live-data.js';

const TITLE = 'WAITING TO BE BATCHED';

const COLUMNS = [
  { key: 'position', label: 'POSITION', sort: (r) => r.position, cell: (r) => html`<span>#${r.position}</span>` },
  {
    key: 'pr', label: 'PR', sort: (r) => r.pr,
    cell: (r) => html`
      <a href=${`https://github.com/${r.repo}/pull/${r.pr}`} target="_blank" rel="noopener noreferrer">#${r.pr}</a>
      ${r.key ? html` <${Link} to=${ticketPath(r.key)}>${r.key}<//>` : null}`,
  },
  { key: 'repo', label: 'REPO', sort: (r) => r.repo, cell: (r) => html`<span>${r.repo}</span>` },
  { key: 'at', label: 'QUEUED AT', sort: (r) => r.at, cell: (r) => html`<span>${clockTime(r.at)}</span>` },
];

export function MergeQueueWaiting({ project }) {
  const live = useMergeQueueLive({ project });
  if (live.state === 'error' && !live.waiting.length) {
    return html`<${Section} title=${TITLE}><${ErrorBox} error=${live.error} onRetry=${live.reload}/><//>`;
  }
  if (live.state === 'loading' || !live.waiting.length) return null;
  return html`
    <${Section} title=${TITLE} note="Waiting to be batched, in queue order">
      ${live.complete === false ? html`<div class="section__note">List may be incomplete: the worker capped its read.</div>` : null}
      <${SortableTable} columns=${COLUMNS} rows=${live.waiting} rowKey=${(r) => `${r.repo}#${r.pr}`} defaultSort="position"/>
    <//>`;
}
