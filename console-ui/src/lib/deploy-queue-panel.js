// The DEPLOY QUEUE table in the QUEUES section of /p/<project> (BH-2510,
// BH-3152, BH-3154), the pure half: which action a row offers, the body an action sends,
// the cells a row renders, whether the `deploy_queue_rows` knob means a train
// reads these rows at all, and how the per-status reads become one table.

import { minutesSince } from './format.js';
import { QUEUE_LIMIT, panelState } from './queue-panel.js';

// What a row offers, each the one state the worker's CAS accepts
// (worker/jobs/src/routes/deploy-queue-actions.js): RELEASE a claimed departure
// that never left, UNHOLD a held one, and HOLD a queued one only when rowsOn is
// true, because the worker refuses a hold while `deploy_queue_rows` is not on.
export function allowedActions(row, rowsOn) {
  if (!row || typeof row !== 'object') return [];
  if (row.status === 'claimed' && !row.departed_at) return ['release'];
  if (row.status === 'held') return ['unhold'];
  if (row.status === 'queued' && rowsOn === true) return ['hold'];
  return [];
}

// Strings only. Never an actor: the coord proxy stamps who is signed in.
export function actionBody(project, row, action, reason) {
  return { project: String(project), sha: String(row.sha), action: String(action), reason: String(reason).trim() };
}

export function deployCells(row) {
  const sha = String(row.sha || '');
  return {
    sha,
    sha8: sha.slice(0, 8),
    status: row.status,
    claimed_by: row.claimed_by || '—',
    build_dir: row.build_dir || '—',
    enqueued_at: row.enqueued_at || null,
    // null when the row has no enqueued_at: an unknown age is not "just now".
    age_min: minutesSince(row.enqueued_at)
  };
}

// knob: useApi `{data, error}` of GET settings/deploy_queue_rows. The box's own
// truth table (bin/lib/jobs/queue.sh _flag_on_row): 1|on|true|yes is on, any
// other value off, and a missing or empty row falls back to DEPLOY_QUEUE_ROWS.
const ON = new Set(['1', 'on', 'true', 'yes']);

export function rowsNote(knob) {
  const unread = { on: null, text: 'could not read deploy_queue_rows.' };
  if (!knob || knob.error || !knob.data || !('setting' in knob.data)) return unread;
  const s = knob.data.setting;
  if (s !== null && (!s || typeof s.value !== 'string')) return unread;
  if (s === null || s.value === '') {
    return { on: null, text: 'deploy_queue_rows is not set here: each box falls back to its DEPLOY_QUEUE_ROWS env (default off).' };
  }
  return ON.has(s.value)
    ? { on: true, text: 'deploy_queue_rows is on: trains read these rows, so RELEASE hands a claimed departure back to the next train.' }
    : { on: false, text: 'deploy_queue_rows is off: trains read the file dir, so a RELEASE here changes nothing a train sees.' };
}

// The per-status reads (queued, claimed, held) as the one `{data, error}`
// panelState({deploy}) reads. Any read failing makes the table an error, never
// part of a list. The cap is measured per read (each is clamped at QUEUE_LIMIT
// on its own), which the combined length panelState measures cannot tell.
export function mergeDeployReads(...reads) {
  const failed = reads.find((r) => r && r.error);
  if (failed) return { data: null, error: failed.error };
  const lists = reads.map((r) => r && r.data && r.data.deploy_queue);
  if (lists.some((l) => !Array.isArray(l))) {
    const loading = reads.some((r) => !r || !r.data);
    return loading ? { data: null, error: null } : { data: {}, error: null };
  }
  return {
    data: { deploy_queue: [].concat(...lists), capped: lists.some((l) => l.length >= QUEUE_LIMIT) },
    error: null
  };
}

// What the table renders: loading until every read has answered once, then
// panelState's verdict, with `capped` taken per read rather than from the
// combined length (300 queued + 300 claimed is 600 rows and complete).
export function deployTableState(...reads) {
  const merged = mergeDeployReads(...reads);
  if (!merged.data && !merged.error) return { kind: 'loading', rows: [], capped: false };
  const st = panelState({ deploy: merged }).deploy;
  return st.kind === 'ok' ? { ...st, capped: merged.data.capped } : st;
}

// The banner after an action: success only when the worker answered that
// action's own decision. A refusal's message (a 409's `error`) rides in the
// Error, so a hold refused while the knob is off says why.
const DONE = {
  release: ['released', (s) => `Released ${s}: back to queued.`],
  hold: ['held', (s) => `Held ${s}: the train will not depart while it is held.`],
  unhold: ['unheld', (s) => `Unheld ${s}: back to queued.`]
};
export function actionOutcome(res, action) {
  const label = String(action).toUpperCase();
  if (res instanceof Error) return { ok: false, text: `${label} failed: ${res.message}` };
  const done = DONE[action];
  if (done && res && res.decision === done[0]) {
    const sha = String((res.deploy && res.deploy.sha) || '');
    return { ok: true, text: done[1](sha.slice(0, 8)) };
  }
  return { ok: false, text: `${label}: unexpected answer from the worker; reload to see the row.` };
}

export function releaseOutcome(res) {
  return actionOutcome(res, 'release');
}
