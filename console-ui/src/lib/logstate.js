import { fmtBytes } from './format.js';

// A `fetch_log` / `fetch_artifact` poll has more outcomes than "worked" and
// "broke", and collapsing them is how a pane that will never fill looks like a
// pane that is still loading:
//
//   missing      the file was never written (a box that never built has no
//                cost.csv) — real information, not an error, never retry
//   empty        the file exists and is empty — a different fact entirely
//   refused      the fleet rejected the request (unregistered project, wrong
//                `which`) — retrying queues another doomed command
//   fetch_failed the box was unreachable — the one case a retry can fix
//   dead_letter  the command died in the queue — retryable via retry_command

const ERROR_STATES = {
  refused: {
    state: 'refused',
    title: 'request refused',
    note: 'The fleet rejected this fetch — the project or the log kind is not one it recognises. Retrying queues another doomed command.',
    retryable: false
  },
  fetch_failed: {
    state: 'fetch_failed',
    title: 'box unreachable',
    note: 'The box did not answer the fetch. This is the case a retry can fix.',
    retryable: true
  }
};

function readError(payload) {
  const candidates = [
    payload && payload.log && payload.log.error,
    payload && payload.error,
    payload && payload.command && payload.command.result
  ];
  for (const c of candidates) {
    if (typeof c === 'string' && ERROR_STATES[c]) return c;
  }
  return null;
}

export function logOutcome(payload) {
  const commandId = payload && payload.command ? payload.command.id : null;
  const base = { commandId, retryable: false, content: '', log: (payload && payload.log) || null };

  if (!payload) return { ...base, state: 'pending', title: 'waiting for the box' };

  if (payload.status === 'auth') {
    return { ...base, state: 'auth', title: 'session expired', note: 'Sign in again to keep polling.' };
  }
  if (payload.status === 'timeout') {
    return {
      ...base, state: 'timeout', retryable: true, title: 'no answer in time',
      note: 'The command is still queued but nothing has come back. It may still land later.'
    };
  }
  if (payload.status === 'dead_letter') {
    return {
      ...base, state: 'dead_letter', retryable: true, title: 'command died in the queue',
      note: 'No box finished this command. Retry resets it on the same ckey, so the dedup is preserved.'
    };
  }
  if (payload.status !== 'ready') {
    return { ...base, state: 'pending', title: 'waiting for the box', note: payload.poll_error || null };
  }

  const log = payload.log || {};
  // A tail that actually arrived is shown, whatever else tagged along.
  if (typeof log.content === 'string' && log.content.length > 0) {
    return { ...base, state: 'ready', title: null, content: log.content, log };
  }

  const err = readError(payload);
  if (err) return { ...base, ...ERROR_STATES[err], commandId, log };

  if (log.missing) {
    return {
      ...base, state: 'missing', title: 'never written',
      note: 'The file does not exist on the box — this build or run never produced it. That is an answer, not a failure.',
      log
    };
  }
  return {
    ...base, state: 'empty', title: 'file exists but is empty',
    note: 'The box found the file and it holds nothing. Distinct from a file that was never written.',
    log
  };
}

// `truncated` is re-derived, never trusted: the producer's flag only means the
// source was longer than ITS cap. If we stored less than the source held, the
// text on screen is cut regardless of what the beat said.
export function truncationNote(log) {
  if (!log) return null;
  const bytes = Number(log.bytes);
  const stored = Number(log.stored_bytes);
  const cut = Boolean(log.truncated) || (Number.isFinite(bytes) && Number.isFinite(stored) && stored < bytes);
  if (!cut) return null;
  return `showing ${fmtBytes(Number.isFinite(stored) ? stored : null)} of ${fmtBytes(Number.isFinite(bytes) ? bytes : null)} — cut`;
}
