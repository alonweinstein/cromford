// The SEED REGISTRY panel's pure half (BH-2521, slice BH-2677). The shapes are
// the BH-2521 wire contract, reached through /api/coord/:
//   GET  settings/seed-registry/plan  → seedRegistryPlan (insert: keys,
//        update: [{key, from, to}], prune: keys, operator_owned, unchanged)
//        plus plan_fp, 64 lowercase hex.
//   POST settings/seed-registry/apply {plan_fp, reason} → 200 {id, actor, rows, changed,
//        pruned, changed_keys, pruned_keys}; 400 {error}; 409 {error:'fleet_gate',
//        boxes:[{box, reason}]} or {error:'plan_moved', plan}, nothing written.
//   GET  settings/seed-registry/runs  → {runs:[{id, actor, status, changed,
//        pruned, started_at, …}], truncated}, newest first.

// The worker's page size and how long a `started` run may stay open before it
// reads as "outcome unknown". Copy and display only: the console caps nothing.
export const SEED_RUNS_LIMIT = 20;
export const STALE_MS = 10 * 60 * 1000;

const FP_RE = /^[0-9a-f]{64}$/;

// A plan without its arrays or its plan_fp is a broken answer, never an empty
// plan: until the worker slice deploys, the plan GET has no plan_fp.
export function planView(payload) {
  if (!payload || typeof payload !== 'object' || !Array.isArray(payload.insert)
    || !Array.isArray(payload.update) || !Array.isArray(payload.prune)
    || typeof payload.plan_fp !== 'string' || !FP_RE.test(payload.plan_fp)) {
    throw new Error('bad response');
  }
  const { plan_fp, insert, update, prune, operator_owned, unchanged } = payload;
  return { plan_fp, insert, update, prune, operator_owned, unchanged, pending: insert.length + update.length + prune.length };
}

// The worker sends only a key for an insert or a prune, so FROM/TO stay null.
export function planRows(plan) {
  return [
    ...plan.insert.map((key) => ({ key, action: 'insert', from: null, to: null })),
    ...plan.update.map((u) => ({ key: u.key, action: 'update', from: u.from, to: u.to })),
    ...plan.prune.map((key) => ({ key, action: 'prune', from: null, to: null })),
  ];
}

// A `lane.<id>.<env>` key has a settings view at /settings/<id>; a `lib.` key
// has none, and no route is invented for it.
export function laneHref(key) {
  const m = typeof key === 'string' ? /^lane\.([^.]+)\.[^.]+$/.exec(key) : null;
  return m ? `/settings/${encodeURIComponent(m[1])}` : null;
}

export const confirmCopy = (plan) =>
  `Applies the registry seed: ${plan.insert.length} inserts, ${plan.update.length} updates, ${plan.prune.length} prunes. Rows an operator owns are never touched.`;

export const confirmOpts = (plan) =>
  ({ title: 'SEED REGISTRY', body: confirmCopy(plan), confirmLabel: 'APPLY', tone: 'warn' });

// Applied is claimed only when the worker handed back a run id.
export function applyOutcome({ result, error }) {
  if (error) {
    const body = error.status === 409 && error.body ? error.body : null;
    if (body && body.error === 'fleet_gate') {
      const boxes = Array.isArray(body.boxes) ? body.boxes : [];
      const named = boxes.map((b) => `${b && b.box} (${b && b.reason})`).join(', ');
      return { tone: 'bad', text: `Refused by the fleet gate, nothing written${named ? `: ${named}` : ''}. A retired box is excluded with harness-ctl.sh seed-registry --exclude-box <box>, run from the hub.` };
    }
    if (body && body.error === 'plan_moved') return { tone: 'warn', text: 'The plan changed, re-read it. Nothing was written.' };
    return { tone: 'bad', text: `Apply failed: ${error.message}` };
  }
  if (result && result.id != null) {
    // A count the worker did not send is unknown, never 0 or "undefined".
    const n = (v) => (typeof v === 'number' ? v : '—');
    return { tone: 'ok', text: `Applied #${result.id}: ${n(result.changed)} changed, ${n(result.pruned)} pruned.` };
  }
  return { tone: 'bad', text: 'Apply failed: unexpected answer (no run id).' };
}

// One POST, only for an explicit true from the dialog and a non-blank reason
// (BH-2995). null means cancelled or no reason.
export async function submitApply(apiObj, plan, confirmed, reason) {
  if (confirmed !== true || typeof reason !== 'string' || !reason.trim()) return null;
  try {
    return applyOutcome({ result: await apiObj.seedApply(plan.plan_fp, reason.trim()) });
  } catch (error) {
    return applyOutcome({ error });
  }
}

// The button's whole flow: ask in the in-app dialog, send, then reload.
// `form` is a fresh object per click that the dialog's REASON field writes
// through (the cost-caps makeEditAction pattern); CONFIRM starts blocked.
export async function requestApply({ apiObj, plan, confirm, reload, renderForm }) {
  const form = { reason: '' };
  const ok = await confirm({
    ...confirmOpts(plan), confirmBlocked: true, form,
    body: renderForm ? ({ setBlocked }) => renderForm(form, setBlocked) : confirmCopy(plan),
  });
  const out = await submitApply(apiObj, plan, ok, form.reason);
  if (out) reload();
  return out;
}

// ISO string or epoch; a number under 1e12 is seconds. NaN when unparseable.
function startedMs(v) {
  if (typeof v === 'number') return v < 1e12 ? v * 1000 : v;
  if (typeof v === 'string' && v) return Date.parse(v);
  return NaN;
}

// A `started` run is in progress only while it is young; an old or undated one
// may have died mid-apply, so it reads "outcome unknown", never "applied".
export function runDisplay(run, now) {
  if (run.status === 'applied' || run.status === 'failed') return run.status;
  if (run.status === 'started') {
    const age = now - startedMs(run.started_at);
    return Number.isFinite(age) && age < STALE_MS ? 'in progress' : 'outcome unknown';
  }
  return 'outcome unknown';
}

export function runsView(payload, now = Date.now()) {
  if (!payload || !Array.isArray(payload.runs)) throw new Error('bad response');
  return { rows: payload.runs.map((r) => ({ ...r, display: runDisplay(r, now) })), truncated: payload.truncated === true };
}
