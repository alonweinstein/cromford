// A poller for a screen that sits open on a wall display. lib/hooks.js's useApi
// refreshes on a FIXED cadence, which is right for a table somebody is reading
// for thirty seconds; the WORLD scene is the one screen people leave up all
// day, so it needs two things useApi does not do:
//
//   1. back off when the API is failing, instead of hammering a worker that is
//      already down at a steady 20s forever, and
//   2. stop entirely while the tab is hidden — a backgrounded phone should not
//      be spending the fleet's request budget on a scene nobody is looking at.
//
// Everything else (the loading/error/data shape, the AuthError hand-off to the
// app's lock screen) is deliberately identical to useApi so a screen can move
// between them without changing a line of its render.

import { useState, useEffect, useCallback, useRef } from 'preact/hooks';
import { AuthError } from '../api.js';
import { nextDelay } from './backoff.js';

export function usePolledApi(fetcher, deps = [], { intervalMs = 20000, enabled = true } = {}) {
  const [state, setState] = useState({ data: null, error: null, loading: true, fetchedAt: null, failures: 0 });
  const [nonce, setNonce] = useState(0);
  const alive = useRef(true);
  const reload = useCallback(() => setNonce((n) => n + 1), []);

  useEffect(() => {
    alive.current = true;
    let timer = null;
    let failures = 0;

    const run = async (isRefresh) => {
      if (!isRefresh) setState((s) => ({ ...s, loading: true }));
      try {
        const data = await fetcher();
        if (!alive.current) return;
        failures = 0;
        setState({ data, error: null, loading: false, fetchedAt: Date.now(), failures: 0 });
      } catch (e) {
        if (!alive.current) return;
        if (e instanceof AuthError) window.dispatchEvent(new CustomEvent('dash:unauthorized'));
        failures += 1;
        // The last good data stays on screen; the caller is told it is stale by
        // `error` and `fetchedAt`, and says so rather than pretending it is live.
        setState((s) => ({ data: s.data, error: e, loading: false, fetchedAt: s.fetchedAt, failures }));
      }
      if (alive.current && enabled) timer = setTimeout(() => run(true), nextDelay(intervalMs, failures));
    };

    if (enabled) run(false);
    return () => { alive.current = false; if (timer) clearTimeout(timer); };
    // eslint-disable-next-line
  }, [...deps, nonce, intervalMs, enabled]);

  return { ...state, reload };
}
