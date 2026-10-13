// RETRY / REQUEUE on one job (BH-2323), the pure half. The routes are the
// worker's, unchanged, in worker/jobs/src/routes/job-retry.js:
//   POST /api/jobs/:id/retry   judges a RUNNING row under the lane's retry
//                              policy: queued_for_retry / parked / orphaned.
//                              Any other row answers {already:true, decision:<status>}.
//   POST /api/jobs/:id/requeue acts on a running or orphaned row:
//                              queued_for_retry / parked / held / already;
//                              409 on a refused transition.
//   POST /api/jobs/:id/abandon (BH-2406, routes/job-abandon.js) moves any
//                              non-terminal row to the terminal `abandoned`,
//                              with a required reason: abandoned / already;
//                              409 on done or budget_stopped.
// The coord proxy stamps the actor; the console never sends one.

import { jobState } from './jobs.js';

// RETRY only where the worker would judge the row: running but silent. A
// freshly beating job gets nothing, because a retry would mark live work dead.
// REQUEUE also takes an orphaned row. Terminal, queued and parked rows get no
// buttons: the worker would answer `already` and the button would do nothing.
// ABANDON (BH-2406) goes on every row that has not ended, except a freshly
// beating one: abandon does not stop the process, so offering "final" on live
// work would be contradicted by the build finishing anyway.
export function availableActions(job) {
  if (!job) return [];
  const state = jobState(job);
  if (state === 'stalled' || state === 'quiet') return ['retry', 'requeue', 'abandon'];
  if (state === 'orphaned') return ['requeue', 'abandon'];
  if (state === 'queued_for_retry' || state === 'parked' || state === 'failed') return ['abandon'];
  return [];
}

// The worker keeps 512 characters of a reason (str(body.reason, 512)).
export const ABANDON_REASON_MAX = 512;
export function abandonReasonError(text) {
  const t = typeof text === 'string' ? text.trim() : '';
  if (!t) return 'Say why you are abandoning this job.';
  if (t.length > ABANDON_REASON_MAX) return `Keep the reason under ${ABANDON_REASON_MAX} characters.`;
  return null;
}

export const requestBody = (action, reason) => (action === 'abandon'
  ? { reason: String(reason || '').trim() }
  : { detail: `operator ${action} from Mission Control` });

const WHAT = {
  retry: 'The worker judges this claim dead under the lane\'s retry policy. It is queued for the lane\'s next tick, '
    + 'parked if its retries ran out, or orphaned if the lane has no retry policy.',
  requeue: 'The worker hands this ticket back to the lane\'s next tick, unless another live job already owns it '
    + 'or the requeue cap ran out, in which case nothing is requeued and it says why.',
  abandon: 'This is final. The job is marked abandoned, the pool will not requeue it, the resume pass will not '
    + 'relaunch it, and the blocked-resolver will not rebuild it. It does not stop a process that is still '
    + 'running, and it does not close a PR.',
};
const TITLE = { retry: 'RETRY JOB', requeue: 'REQUEUE JOB', abandon: 'ABANDON JOB' };
const VERB = { retry: 'Retry', requeue: 'Requeue', abandon: 'Abandon' };

// A quiet row never heartbeated, so silence is not proof it is dead: a box on
// pre-heartbeat bin/ may still be working it, and the watchdog leaves such rows
// running for that reason. The operator is told before the click.
const QUIET_WARNING = 'This job never heartbeated, so it may still be alive on its box. '
  + 'If it is, this can cost the running session its claim and start a second attempt.';

export const confirmOpts = (action, job) => ({
  title: TITLE[action],
  body: `${VERB[action]} ${job && job.id}? `
    + `${jobState(job) === 'quiet' ? `${QUIET_WARNING} ` : ''}${WHAT[action]}`,
  confirmLabel: action.toUpperCase(),
  tone: action === 'abandon' ? 'danger' : 'warn',
});

const DECISION_TEXT = {
  queued_for_retry: 'Queued for the lane\'s next tick',
  parked: 'Parked, it will not re-run',
  orphaned: 'Marked orphaned, it will not re-run',
  held: 'Held, not requeued',
  abandoned: 'Abandoned',
  already: 'Nothing changed',
};
// The decision that did what the button asked for. Any other decision is
// reported as a warning with the worker's own reason.
const WANTED = { retry: 'queued_for_retry', requeue: 'queued_for_retry', abandon: 'abandoned' };

// Only a 200 that carries a decision is an answer. queued_for_retry is the one
// outcome that re-runs the work; every other decision says so and gives the
// worker's own reason.
export function actionOutcome(action, { result, error }) {
  const label = action.toUpperCase();
  if (error) {
    const why = error.body && error.body.error && error.body.error !== error.message
      ? `${error.message} (${error.body.error})` : error.message;
    return { tone: 'bad', text: `${label} failed: ${why}` };
  }
  if (!result || typeof result.decision !== 'string' || !result.decision) {
    return { tone: 'bad', text: `${label} failed: unexpected answer (no decision).` };
  }
  const d = result.decision;
  const head = result.already === true ? DECISION_TEXT.already : (DECISION_TEXT[d] || `Decision: ${d}`);
  const reason = result.reason ? `: ${result.reason}` : '';
  return { tone: d === WANTED[action] && result.already !== true ? 'ok' : 'warn', text: `${label}: ${head}${reason}` };
}

// The button's whole flow: ask in the in-app dialog, one POST on an explicit
// true, then reload the page's data. null means cancelled and nothing was sent.
//
// ABANDON asks for a reason in the same dialog. `reasonForm(text, form)` is the
// component's renderer for that body; the field writes into `form`, and the
// dialog opens with ABANDON disabled. A reason that is still blank after the
// dialog confirmed never reaches the network (the button should not have let
// it through, and this is the check behind the button).
const CALL = { retry: 'retryJob', requeue: 'requeueJob', abandon: 'abandonJob' };
export async function runJobAction({ apiObj, job, action, confirm, reload, reasonForm }) {
  const opts = confirmOpts(action, job);
  const form = { reason: '' };
  if (action === 'abandon') {
    opts.confirmBlocked = true;
    if (reasonForm) opts.body = reasonForm(opts.body, form);
  }
  if ((await confirm(opts)) !== true) return null;
  if (action === 'abandon') {
    const err = abandonReasonError(form.reason);
    if (err) return { tone: 'bad', text: `ABANDON not sent: ${err}` };
  }
  const call = apiObj[CALL[action]];
  let out;
  try {
    out = actionOutcome(action, { result: await call(job.id, requestBody(action, form.reason)) });
  } catch (error) {
    out = actionOutcome(action, { error });
  }
  reload();
  return out;
}
