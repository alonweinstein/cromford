// The restore-lab panel's pure half (BH-1946 / BH-1909.4). The shapes are the
// worker contract in worker/jobs/src/routes/restore-lab.js:
//   GET  /api/hub/restore-lab → {runs:[…last 20, newest first…], truncated}
//   POST /api/hub/restore-lab → 201 {id, status:"requested"}, or
//                               409 {error:"already_open", id} for an open run.
// The ticket also names a `deduped:true` answer; both read as "already queued".

// The worker's page size. Copy only: the console never caps anything itself.
export const RESTORE_LAB_LIMIT = 20;

// A payload without a runs array is a broken answer, never an empty history.
export function historyView(payload) {
  if (!payload || !Array.isArray(payload.runs)) throw new Error('bad response');
  return { rows: payload.runs, truncated: payload.truncated === true };
}

// useApi keeps the last good answer through a failed refresh, so an error only
// takes over the panel when there is nothing loaded to show.
export function panelState({ view, error }) {
  if (view) return view.rows.length ? 'rows' : 'empty';
  return error ? 'error' : 'loading';
}

export function requestBody(box) {
  if (typeof box !== 'string' || !box.trim()) throw new Error('box required');
  return { box, snapshot: 'latest', confirm: true };
}

export const confirmCopy = (box) =>
  `Restores ${box}'s latest backup into a scratch dir on the hub and verifies it. Nothing on the live hub is touched.`;

export const confirmOpts = (box) =>
  ({ title: 'RESTORE LAB', body: confirmCopy(box), confirmLabel: 'RESTORE', tone: 'warn' });

// Queued is claimed only when the worker handed back a run id.
export function requestOutcome(box, { result, error }) {
  const queued = (id) => ({ tone: 'warn', text: `A restore for ${box} is already queued${id != null ? ` (#${id})` : ''}.` });
  if (error) {
    if (error.status === 409 && error.body && error.body.error === 'already_open') return queued(error.body.id);
    return { tone: 'bad', text: `Restore request failed: ${error.message}` };
  }
  if (result && result.deduped === true) return queued(result.id);
  if (result && result.id != null) return { tone: 'ok', text: `Queued restore #${result.id} for ${box}.` };
  return { tone: 'bad', text: 'Restore request failed: unexpected answer (no run id).' };
}

// One POST, only for an explicit true from the dialog. null means cancelled.
export async function submitRestore(apiObj, box, confirmed) {
  if (confirmed !== true) return null;
  try {
    return requestOutcome(box, { result: await apiObj.restoreLab(requestBody(box)) });
  } catch (error) {
    return requestOutcome(box, { error });
  }
}

// The button's whole flow: ask in the in-app dialog, send, then reload history.
export async function requestRestore({ apiObj, box, confirm, reload }) {
  const out = await submitRestore(apiObj, box, await confirm(confirmOpts(box)));
  if (out) reload();
  return out;
}
