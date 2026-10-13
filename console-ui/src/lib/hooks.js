import { useState, useEffect, useCallback, useRef } from 'preact/hooks';
import { AuthError } from '../api.js';

// One loader for every screen: it exposes loading/error/data plus the moment the
// data landed, so a screen can always say how old what it is showing is.
export function useApi(fetcher, deps = [], { intervalMs = 0 } = {}) {
  const [state, setState] = useState({ data: null, error: null, loading: true, fetchedAt: null });
  const [nonce, setNonce] = useState(0);
  const alive = useRef(true);
  const lastDeps = useRef(null);

  const reload = useCallback(() => setNonce((n) => n + 1), []);

  useEffect(() => {
    alive.current = true;
    let timer = null;

    // Data fetched under the PREVIOUS deps does not describe the new ones. An
    // interval refresh keeps what is on screen (no flicker), but a deps change
    // must clear it — otherwise the old answer is presented as the new one for
    // as long as the refetch takes. That is how a screen shows a confident
    // "nothing open" while it is in fact still finding out.
    const depsKey = JSON.stringify(deps);
    const depsChanged = lastDeps.current !== null && lastDeps.current !== depsKey;
    lastDeps.current = depsKey;
    if (depsChanged) setState({ data: null, error: null, loading: true, fetchedAt: null });

    const run = async (isRefresh) => {
      if (!isRefresh) setState((s) => ({ ...s, loading: true }));
      try {
        const data = await fetcher();
        if (!alive.current) return;
        setState({ data, error: null, loading: false, fetchedAt: Date.now() });
      } catch (e) {
        if (!alive.current) return;
        if (e instanceof AuthError) { window.dispatchEvent(new CustomEvent('dash:unauthorized')); }
        setState((s) => ({ data: s.data, error: e, loading: false, fetchedAt: s.fetchedAt }));
      }
      if (alive.current && intervalMs > 0) timer = setTimeout(() => run(true), intervalMs);
    };
    run(false);
    return () => { alive.current = false; if (timer) clearTimeout(timer); };
    // eslint-disable-next-line
  }, [...deps, nonce, intervalMs]);

  return { ...state, reload };
}

// A visible countdown, so an auto-refreshing screen never looks like live data.
export function useCountdown(seconds, restartKey) {
  const [left, setLeft] = useState(seconds);
  useEffect(() => {
    setLeft(seconds);
    const t = setInterval(() => setLeft((v) => (v <= 1 ? seconds : v - 1)), 1000);
    return () => clearInterval(t);
  }, [seconds, restartKey]);
  return left;
}

// With no document (a render to a string, a test) the page counts as visible.
export function useDocumentVisible() {
  const [visible, setVisible] = useState(typeof document === 'undefined' ? true : !document.hidden);
  useEffect(() => {
    if (typeof document === 'undefined') return undefined;
    const fn = () => setVisible(!document.hidden);
    document.addEventListener('visibilitychange', fn);
    return () => document.removeEventListener('visibilitychange', fn);
  }, []);
  return visible;
}
