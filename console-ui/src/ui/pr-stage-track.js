// BH-5669 (BH-5008 child 3): a PR's merge-queue stage track. Mounted in the
// JobsTable TICKET cell (screens/Jobs.js), so it shows on /jobs and on
// /t/<key>, whose TicketView renders the same table.
//
// The PR comes from `repo` + `pr` when both are set, else from the ticket key:
// the worker joins pr_owners, so each prs entry of GET /api/merge-queue/live
// carries the key that owns the PR. No entry, or a stage outside the six
// queue stations (ci_red, lead_block, ...), renders nothing. So does a load
// that has not answered or failed: the batch section owns that copy.
//
// Every track on a page shares ONE poll per project: sharedLive keeps the last
// request for SHARED_MS, so a jobs table of 50 rows makes one request per 5 s.

import { html } from '../router.js';
import { usePolledApi } from '../lib/poll.js';
import { StationTrack } from './line.js';
import { liveFetcher, liveViewState, useVisible, LIVE_INTERVAL_MS } from './merge-queue-live-data.js';

export const QUEUE_STATIONS = ['Queued', 'In batch', 'Checks', 'Merging', 'Merged', 'Deploy verified'];
const STATION_OF = { queued: 0, batched: 1, checking: 2, dequeued: 2, merging: 3, merged: 4, deploy_verified: 5 };
const SHARED_MS = 4000;

const shared = new Map();

export function sharedLive(project) {
  const k = project || '';
  const now = Date.now();
  const hit = shared.get(k);
  if (hit && now - hit.at < SHARED_MS) return hit.promise;
  const promise = liveFetcher(project, 0)();
  shared.set(k, { at: now, promise });
  return promise;
}

export function __resetSharedLive() { shared.clear(); }

// → { repo, pr, entry } or null.
export function entryOf(prs, { repo, pr, ticket, project }) {
  if (!prs || typeof prs !== 'object') return null;
  if (repo && pr) {
    const entry = prs[`${repo}#${pr}`];
    return entry ? { repo, pr: Number(pr), entry } : null;
  }
  if (!ticket) return null;
  const want = String(ticket).toLowerCase();
  let best = null;
  for (const [k, entry] of Object.entries(prs)) {
    if (!entry || !entry.key || String(entry.key).toLowerCase() !== want) continue;
    if (project && entry.project && entry.project !== project) continue;
    if (!best || String(entry.at) > String(best.entry.at)) {
      const i = k.lastIndexOf('#');
      best = { repo: k.slice(0, i), pr: Number(k.slice(i + 1)), entry };
    }
  }
  return best;
}

const batchOf = (batches, repo, draft) => (draft === null || draft === undefined
  ? null
  : (batches || []).find((b) => b.draft === draft && b.repo === repo) || null);

function stationLabel(stage, entry, batch) {
  if (stage === 'queued') return entry.detail ? `Queued (#${entry.detail})` : 'Queued';
  if (stage === 'batched') {
    if (entry.batch === null || entry.batch === undefined) return 'In batch';
    if (!batch) return `In batch #${entry.batch}`;
    const k = Math.max(0, (batch.members || []).length - 1);
    return k ? `In batch #${entry.batch} with ${k} other${k === 1 ? '' : 's'}` : `In batch #${entry.batch} alone`;
  }
  if (stage === 'checking') return batch && batch.checks ? `Checks ${batch.checks.done}/${batch.checks.total}` : 'Checks';
  if (stage === 'dequeued') return 'Dequeued';
  return QUEUE_STATIONS[STATION_OF[stage]];
}

// The failure lines, in order: the failing check, the bisect split, the dequeue.
function failureLines(stage, entry, batch, batches, repo) {
  const out = [];
  if (batch) {
    const parent = batch.bisect ? batchOf(batches, repo, batch.bisect.parent) : null;
    const failing = batch.failing || (parent && parent.failing) || null;
    if (failing) out.push({ text: `Failing: ${failing.name}`, url: failing.url || null });
    if (batch.bisect) {
      const ms = batch.members || [];
      out.push({
        text: `Splitting: testing ${ms.map((n) => `#${n}`).join(', ')}${ms.length === 1 ? ' alone' : ''}, step ${batch.bisect.step} of ${batch.bisect.steps}`,
        url: batch.url || null,
      });
    }
  }
  if (stage === 'dequeued') {
    out.push({ text: `Dequeued: ${entry.detail || 'removed from the queue'}`, url: (batch && batch.failing && batch.failing.url) || null });
  }
  return out;
}

export function PrStageTrack({ repo, pr, project, ticket }) {
  const polled = usePolledApi(() => sharedLive(project), [project], { intervalMs: LIVE_INTERVAL_MS, enabled: useVisible() });
  const view = liveViewState(polled, project, 0);
  if (view.state === 'loading' || view.state === 'error') return null;
  const hit = entryOf(polled.data.body.prs, { repo, pr, ticket, project });
  if (!hit) return null;
  const stage = String(hit.entry.stage || '');
  if (!(stage in STATION_OF)) return null;
  const batch = batchOf(view.batches, hit.repo, hit.entry.batch);
  const at = STATION_OF[stage];
  const stations = QUEUE_STATIONS.slice();
  stations[at] = stationLabel(stage, hit.entry, batch);
  const state = stage === 'dequeued' || (batch && batch.failing) ? 'fail' : 'now';
  const lines = failureLines(stage, hit.entry, batch, view.batches, hit.repo);
  return html`
    <div class="track-scroll">
      <${StationTrack} at=${at} state=${state} stations=${stations} label=${`#${hit.pr}`} compact/>
    </div>
    ${lines.map((l) => html`
      <div style="font-size:var(--fs-sm);overflow-wrap:anywhere">
        ${l.url ? html`<a href=${l.url} target="_blank" rel="noopener noreferrer">${l.text}</a>` : html`<span>${l.text}</span>`}
      </div>`)}`;
}
