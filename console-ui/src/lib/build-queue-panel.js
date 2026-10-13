// The BUILD QUEUE table on /p/<project> (BH-3151, BH-2510.1), the pure half:
// which rows are read, which action a row offers, the body sent for it, and
// the banner read off the worker's answer.
import { panelState } from './queue-panel.js';
import { minutesSince } from './format.js';

// One read per live status, so terminal history never pushes a live row past
// a read's 500 clamp.
export const BUILD_STATUSES = ['ready', 'queued', 'claimed'];

// reads: the three useApi states, in BUILD_STATUSES order. Any read still
// without an answer is loading; any failed read (including a failed refresh
// holding stale rows) is an error for the whole table, never an empty one.
// Capped is per read: each has its own clamp, so 3 x 499 rows is complete.
export function buildQueueState(reads) {
  if (reads.some((r) => !r || (!r.data && !r.error))) return { kind: 'loading' };
  const parts = reads.map((r) => panelState({ build: r }).build);
  const bad = parts.find((p) => p.kind === 'error');
  if (bad) return { kind: 'error', error: bad.error };
  return { kind: 'ok', rows: parts.flatMap((p) => p.rows), capped: parts.some((p) => p.capped) };
}

export function allowedActions(row) {
  const s = row && row.status;
  if (s === 'claimed') return ['release'];
  if (s === 'queued' || s === 'ready') return ['drop'];
  return [];
}

// The proxy stamps the actor; the browser never sends one.
export function actionBody(project, row, action, reason) {
  return { project, key: row.ticket_key, action, reason: String(reason || '').trim() };
}

export function buildCells(row) {
  return {
    key: row.ticket_key,
    status: row.status,
    target: row.target ?? null,
    attempt: row.attempt ?? null,
    claimed_by: row.claimed_by ?? null,
    machine: row.machine ?? null,
    enqueuedMin: minutesSince(row.enqueued_at),
    claimedMin: minutesSince(row.claimed_at)
  };
}

export const ACTION_COPY = {
  release: {
    title: 'RELEASE', confirmLabel: 'RELEASE',
    body: 'Only release a claim whose build is dead. A live build keeps running and a second one can start.'
  },
  drop: {
    title: 'DROP', confirmLabel: 'DROP',
    body: 'The row is closed as failed and nothing claims it. An explicit relaunch of the ticket can still re-queue it.'
  }
};

const DONE = {
  release: { released: (k) => `Released ${k}. It is queued again.` },
  drop: { dropped: (k) => `Dropped ${k}.`, already: (k) => `${k} was already dropped.` }
};

// Success only when the answer names a decision this action can have.
export function actionMessage(action, result, error) {
  if (error) {
    const why = (error.body && error.body.error) || error.message || String(error);
    return { ok: false, text: `${action.toUpperCase()} failed: ${why}` };
  }
  const table = DONE[action] || {};
  const say = result && Object.hasOwn(table, result.decision) ? table[result.decision] : null;
  if (!say) return { ok: false, text: `${action.toUpperCase()} answered without a decision; reload to see the row` };
  return { ok: true, text: say(result.key) };
}
