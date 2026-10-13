import { init, captureException } from '@sentry/browser';

// Browser error reporting for Mission Control (BH-5619). It is off unless
// VITE_SENTRY_DSN was set when `npm run build` ran: Vite inlines
// import.meta.env at build time, so the deployed bundle either carries a DSN
// or carries nothing. No replay, no default PII, no user data.
//
// `sdk` is the test seam. Production never passes it.

let active = null;

export function initSentry(env, sdk = { init, captureException }) {
  const dsn = env?.VITE_SENTRY_DSN;
  if (typeof dsn !== 'string' || !dsn.trim()) {
    active = null;
    return false;
  }
  sdk.init({
    dsn: dsn.trim(),
    sendDefaultPii: false,
    initialScope: { tags: { lane: 'console-ui' } }
  });
  active = sdk;
  return true;
}

// Called by ErrorBoundary once per caught render error. A no-op when
// initSentry found no DSN.
export function reportError(error, componentStack) {
  if (!active) return;
  active.captureException(error, { contexts: { react: { componentStack } } });
}
