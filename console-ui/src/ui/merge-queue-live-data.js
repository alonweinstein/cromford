// BH-5667 (BH-5008 child 1): the live merge-queue data the BH-5008 siblings
// render (ui/merge-queue-live.js, ui/merge-queue-waiting.js,
// ui/pr-stage-track.js). It polls GET /api/coord/merge-queue/live every 5 s,
// and only while the tab is visible.
//
// Request versioning (D23): usePolledApi keeps the last answer across a deps
// change, so each answer is stamped with the project it was asked for and a
// version that moves on every project change. liveViewState drops an answer
// whose stamp is not the current one, so a slow answer for the old project
// never shows under the new one. A load error with no data is `error`, never
// `empty`.

import { useState, useEffect, useRef } from 'preact/hooks';
import { api } from '../api.js';
import { usePolledApi } from '../lib/poll.js';

export const LIVE_INTERVAL_MS = 5000;

const visibleNow = () => typeof document === 'undefined' || document.visibilityState === undefined
  || document.visibilityState === 'visible';

export function useVisible() {
  const [visible, setVisible] = useState(visibleNow);
  useEffect(() => {
    if (typeof document === 'undefined' || typeof document.addEventListener !== 'function') return undefined;
    const on = () => setVisible(visibleNow());
    document.addEventListener('visibilitychange', on);
    return () => document.removeEventListener('visibilitychange', on);
  }, []);
  return visible;
}

// The fetcher for one (project, version): its answer carries both.
export function liveFetcher(project, version) {
  return async () => ({ project: project || null, version, body: await api.mergeQueueLive({ project }) });
}

const errText = (e) => (e ? (e.message || String(e)) : null);

// polled: usePolledApi's { data, error, loading, fetchedAt }.
// → { state: 'loading'|'error'|'empty'|'ok', batches, waiting, complete, error, fetchedAt }
export function liveViewState(polled, project, version) {
  const p = polled || {};
  const d = p.data;
  const current = d && d.project === (project || null) && d.version === version;
  if (!current) {
    // No answer for THIS request yet. An error that came back for it (the
    // load is over) is an error; anything else is still loading.
    const state = !p.loading && p.error ? 'error' : 'loading';
    return { state, batches: [], waiting: [], complete: null, error: state === 'error' ? errText(p.error) : null, fetchedAt: null };
  }
  const body = d.body;
  if (!body || !Array.isArray(body.batches)) {
    return { state: 'error', batches: [], waiting: [], complete: null, error: 'bad response', fetchedAt: p.fetchedAt ?? null };
  }
  const waiting = Array.isArray(body.waiting) ? body.waiting : [];
  return {
    state: body.batches.length || waiting.length ? 'ok' : 'empty',
    batches: body.batches,
    waiting,
    complete: body.complete === true,
    error: errText(p.error),
    fetchedAt: p.fetchedAt ?? null,
  };
}

export function useMergeQueueLive({ project } = {}) {
  const visible = useVisible();
  const ver = useRef({ project: undefined, n: 0 });
  if (ver.current.project !== (project || null)) ver.current = { project: project || null, n: ver.current.n + 1 };
  const version = ver.current.n;
  const polled = usePolledApi(liveFetcher(project, version), [project], { intervalMs: LIVE_INTERVAL_MS, enabled: visible });
  return { ...liveViewState(polled, project, version), reload: polled.reload };
}
