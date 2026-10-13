// Steer notes (BH-5839): the ticket page's "Step in" composer and its echo.
// Pure: no DOM, no fetch. The note rows are GET /api/steer's (the jobs worker's
// routes/steer.js), and a send is POST /api/steer through the coord proxy.

import { HOLD_REASON_MAX } from './ticket-hold.js';
import { clockTime } from './format.js';

export const STEER_MODES = ['now', 'ticket', 'hold'];
// The worker's input bound (routes/steer.js STEER_TEXT_MAX). A hold note is the
// hold reason, so it is held to HOLD_REASON_MAX (500) instead.
export const STEER_TEXT_MAX = 4000;

// Only a running build reads a note "now"; the worker refuses any other job.
export const canSendNow = (job) => Boolean(job && job.kind === 'build' && job.status === 'running');

export const steerTextMax = (mode) => (mode === 'hold' ? HOLD_REASON_MAX : STEER_TEXT_MAX);

// The POST /api/steer body, or null when the worker would refuse it. A "now" or
// "hold" note names the running build, so a hold also stops that job at its
// next step. A ticket note names no job.
export function steerBody({ project, ticket, job, mode, text }) {
  if (typeof project !== 'string' || !project || typeof ticket !== 'string' || !ticket) return null;
  if (!STEER_MODES.includes(mode)) return null;
  const t = typeof text === 'string' ? text.trim() : '';
  if (!t || t.length > steerTextMax(mode)) return null;
  if (mode === 'now' && !canSendNow(job)) return null;
  const body = { project, ticket, mode, text: t };
  if (mode !== 'ticket' && canSendNow(job)) body.job_id = job.id;
  return body;
}

// The echo state of one note. `job` is the page's build job: a "now" note that
// is still pending while that job is not running (or a newer job replaced it)
// was never read. A "now" note sent with a hold stays pending, so it shows that. The row in the worker stays as it is; this is display only.
export function steerState(note, job) {
  if (!note) return '';
  if (note.status === 'failed') return `not delivered: ${note.detail || 'no detail'}`;
  if (note.mode === 'now') {
    if (note.status === 'read') return `read by the build at ${clockTime(note.build_read_at)}`;
    // Taken: a step started with it in its prompt and has not settled yet. It
    // becomes read only when that call ran.
    if (note.status === 'taken') {
      return job && job.id === note.job_id && job.status === 'running'
        ? 'in the prompt of the step running now'
        : 'taken by a step that did not report';
    }
    if (note.status === 'pending' && job && (job.id !== note.job_id || job.status !== 'running')) {
      return 'not read: the build ended before its next step';
    }
  }
  if (note.status === 'delivered') return note.mode === 'hold' ? 'held' : 'posted';
  if (note.status === 'delivering') return 'posting';
  if (note.status === 'pending') return 'waiting';
  return String(note.status || 'unknown');
}

// One SEND. A hold asks first through `ask` (the in-app useConfirm), and a
// "no" sends nothing. The answer is { ok, error, cancelled }: ok only when the
// worker answered with the stored note.
export async function sendSteer({ project, ticket, job, mode, text, apiObj, ask }) {
  const body = steerBody({ project, ticket, job, mode, text });
  if (!body) return { ok: false, error: 'This note cannot be sent.' };
  if (mode === 'hold') {
    const yes = await ask({
      title: 'HOLD TICKET',
      body: `Holds ${ticket} with this note as the reason.${body.job_id ? ' The running build stops after its current step.' : ''} Note: ${body.text}`,
      confirmLabel: 'HOLD',
      tone: 'warn'
    });
    if (!yes) return { ok: false, cancelled: true };
  }
  try {
    const res = await apiObj.steer(body);
    if (!res || !res.note) return { ok: false, error: 'bad response' };
    return { ok: true, note: res.note };
  } catch (e) {
    return { ok: false, error: (e && e.message) || 'send failed' };
  }
}
