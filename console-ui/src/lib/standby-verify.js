// Standby VERIFY's pure half (BH-2519 / BH-2642). The shapes are the worker
// contract for the standby verify queue (standby_verify_runs in
// worker/jobs/schema.sql):
//   GET  /api/hub/standby/verify → {runs:[…last 20, newest first…], truncated, as_of}
//   POST /api/hub/standby/verify → 201 {id, status, run, deduped:false}, or
//                                  200 {deduped:true, id} when one is already open;
//                                  409 unknown_standby, 400 confirm_required.

// The worker's page size. Copy only: the console never caps anything itself.
export const STANDBY_VERIFY_LIMIT = 20;

export function verifyBody(box) {
  if (typeof box !== 'string' || !box.trim()) throw new Error('box required');
  return { box, confirm: true };
}

export const confirmOpts = (box, hub) => ({
  title: 'VERIFY STANDBY',
  body: `Runs a scratch restore of ${hub || 'the hub'}'s latest backup ON ${box} and checks it. Nothing on either live tree is touched.`,
  confirmLabel: 'VERIFY',
  cancelLabel: 'CANCEL',
  tone: 'warn'
});

// Queued is claimed only when the worker handed back a run id.
export function verifyOutcome(box, { result, error }) {
  if (error) {
    if (error.status === 409 && error.body && error.body.error === 'unknown_standby') {
      return { tone: 'bad', text: `Verify failed: ${box} is not a known standby.` };
    }
    return { tone: 'bad', text: `Verify failed: ${error.message}` };
  }
  if (result && result.deduped === true) {
    return { tone: 'warn', text: `A verify for ${box} is already queued${result.id != null ? ` (#${result.id})` : ''}.` };
  }
  if (result && result.id != null) return { tone: 'ok', text: `Queued verify #${result.id} for ${box}.` };
  return { tone: 'bad', text: 'Verify failed: unexpected answer (no run id).' };
}

// Ask in the in-app dialog, then one POST, only for an explicit true. null
// means cancelled and nothing was sent.
export async function submitVerify(ask, apiObj, box) {
  const yes = await ask();
  if (yes !== true) return null;
  try {
    return verifyOutcome(box, { result: await apiObj.standbyVerify(verifyBody(box)) });
  } catch (error) {
    return verifyOutcome(box, { error });
  }
}

// A payload without a runs array is a broken answer, never an empty history.
export function historyView(payload) {
  if (!payload || !Array.isArray(payload.runs)) throw new Error('bad response');
  return { runs: payload.runs, truncated: payload.truncated === true };
}

// {[box]: newest run}. Newest is the latest requested_at, then the higher id;
// the input order is never trusted.
export function lastVerifyByBox(runs) {
  const out = {};
  for (const r of runs) {
    const cur = out[r.box];
    const t = Date.parse(r.requested_at);
    const ct = cur ? Date.parse(cur.requested_at) : NaN;
    if (!cur || t > ct || (!(t < ct) && Number(r.id) > Number(cur.id))) out[r.box] = r;
  }
  return out;
}
