// Poll spacing, kept apart from the hook that uses it so the rule is testable
// without a DOM (tests/ runs on bare node, with no node_modules and no preact).

// Doubling, capped: a worker that is down for an hour is polled every two
// minutes, not 180 times. The cap is what keeps a RECOVERED API from taking ten
// minutes to be noticed — an uncapped backoff is how a screen stays wrong long
// after the thing it watches came back.
export const MAX_BACKOFF_MS = 120000;

export function nextDelay(baseMs, consecutiveErrors) {
  const n = Math.max(0, Number(consecutiveErrors) || 0);
  if (n === 0) return baseMs;
  return Math.min(baseMs * Math.pow(2, n), MAX_BACKOFF_MS);
}
