// The Project page's QUEUES panel (BH-2510), the pure half: what a reason must
// be before an action is offered, and what each of the three reads means.
// BH-3150 (BH-2510.0) ships this contract; the tables that read it land in the
// BH-2510 siblings.

// The worker's own clamps: GET /api/queue and /api/deploy-queue answer at most
// 500 rows, GET /api/merge-trains at most 200. A read that came back AT its
// clamp may have more behind it, so it is `capped`, never a complete list.
export const QUEUE_LIMIT = 500;
export const TRAINS_LIMIT = 200;

// RELEASE / DROP / HOLD each need a reason: blocked while it is blank or
// whitespace (the proxy refuses the same body with a 400).
export function actionFormState(reason) {
  const trimmed = typeof reason === 'string' ? reason.trim() : '';
  return { blocked: trimmed === '', reason: trimmed };
}

// reads = { build, deploy, trains }, each a useApi state {data, error}. A failed
// read, or a body without its array, is kind:'error' for that table only: it
// is never shown as an empty queue.
const TABLES = [
  ['build', 'queue', QUEUE_LIMIT],
  ['deploy', 'deploy_queue', QUEUE_LIMIT],
  ['trains', 'merge_trains', TRAINS_LIMIT]
];

export function panelState(reads) {
  const out = {};
  for (const [name, field, limit] of TABLES) {
    const r = (reads && reads[name]) || {};
    const rows = r.data && r.data[field];
    out[name] = r.error || !Array.isArray(rows)
      ? { kind: 'error', error: r.error || new Error(`no ${field} in the answer`), rows: [], capped: false }
      : { kind: 'ok', rows, capped: rows.length >= limit };
  }
  return out;
}
