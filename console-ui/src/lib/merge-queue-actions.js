// BH-3159 (BH-2325.4): HOLD / RESUME / DROP on a merge-queue row and RELEASE on
// a conductor held page. The pure half, so the tests drive the same code the
// cells in screens/merge-queue-actions.js run.

// The row status each action PATCHes. Only moves the worker's MERGE_TRANSITIONS
// allows are offered; `landed` offers nothing.
export const ACTION_STATUS = { HOLD: 'blocked', RESUME: 'queued', DROP: 'dropped' };

const OFFERED = { queued: ['HOLD', 'DROP'], blocked: ['RESUME', 'DROP'], dropped: ['RESUME'] };

export function mqActions(status) {
  return Object.hasOwn(OFFERED, String(status)) ? [...OFFERED[status]] : [];
}

const trimmed = (s) => String(s ?? '').trim();

// The PATCH /api/merge-queue body, or null when there is nothing to send.
export function mqActionBody(row, action, reason) {
  const r = trimmed(reason);
  if (!r || !Object.hasOwn(ACTION_STATUS, action)) return null;
  return { project: row.project, pr: row.pr, status: ACTION_STATUS[action], reason: r };
}

const HELD_KEY = ['repo', 'number', 'state', 'head', 'kind'];

// A held page is released by its full key; a row missing any part of it is not.
export function releasable(row) {
  return Boolean(row) && HELD_KEY.every((k) => row[k] !== undefined && row[k] !== null && row[k] !== '');
}

export function heldReleaseBody(row, why) {
  const w = trimmed(why);
  if (!w) return null;
  return { repo: row.repo, number: row.number, state: row.state, head: row.head, kind: row.kind, why: w };
}

// What each action actually does on the boxes, per rows-only mode. Read from
// bin/merge-queue.sh (the materialise loop and mq_queue_list) and
// bin/lib/mc/log.sh (mc_hold_page, mc_hold_flush_one); see
// docs/notes/2026-09-28-BH-2325-merge-queue-actions.md. Any mode that is not
// exactly 'on' or 'off' is the unread sentence, never a guess.
const EFFECT = {
  HOLD: {
    off: 'HOLD marks this row blocked. With rows-only off the queue is the files on each box, so this only stops a PR that has not been materialised as a file yet. A PR already materialised as a file is still merged.',
    on: 'HOLD marks this row blocked. With rows-only on the queue skips any PR whose row is blocked, even one that still has a file on a box.',
    unread: 'The rows-only mode could not be read. If it is on, HOLD stops this PR being offered. If it is off, HOLD only stops a PR not yet materialised as a file, and one already materialised as a file is still merged.'
  },
  DROP: {
    off: 'DROP marks this row dropped, so it is never materialised as a file again. It does not remove a file on a box: a PR already materialised as a file is still merged.',
    on: 'DROP marks this row dropped, so the queue stops reading it as queued. It does not remove a file on a box: a PR with a file on disk is still offered.',
    unread: 'The rows-only mode could not be read. In either mode DROP does not remove a file on a box, so a PR already materialised as a file is still offered.'
  },
  RESUME: {
    off: 'RESUME puts this row back to queued, and the next tick materialises it as a file. A box that parked it with a <pr>.blocked file skips it.',
    on: 'RESUME puts this row back to queued, and the next tick reads it as part of the queue. A box that parked it with a <pr>.blocked file skips it.',
    unread: 'The rows-only mode could not be read. RESUME puts this row back to queued and the next tick offers it again in either mode, unless a box parked it with a <pr>.blocked file.'
  }
};
const RELEASE_EFFECT = 'RELEASE deletes this held row, so the page it owes is not sent. If the PR is still aged, the next tick can hold it again.';

export function effectText(action, rowsOnly) {
  if (action === 'RELEASE') return RELEASE_EFFECT;
  const e = EFFECT[action];
  if (!e) return '';
  return rowsOnly === 'on' || rowsOnly === 'off' ? e[rowsOnly] : e.unread;
}

export function mqFormState({ reason } = {}) {
  const blank = !trimmed(reason);
  return { blocked: blank, hint: blank ? 'say why, the worker records it with the change' : '' };
}

const errText = (e) => (e && e.message ? e.message : String(e));

// The shared ask → refuse-blank → send → verify flow (the makeQuarantineAction
// shape). `form` is a fresh object per click that the modal's REASON input
// writes through. Nothing is sent on cancel, Escape or a blank reason. onDone
// (the caller's reload) runs only after `verify` accepts the worker's answer.
function makeAction({ confirm: ask, send, onMsg, onDone, onPending, renderForm, keyOf, opts, build, verify }) {
  const inFlight = new Set();
  return async (row, action) => {
    const key = keyOf(row, action);
    if (inFlight.has(key)) return;
    const form = { reason: '' };
    const confirmed = await ask({
      ...opts(action), confirmLabel: action, confirmBlocked: true, form,
      body: renderForm ? ({ setBlocked }) => renderForm(row, action, form, setBlocked) : null
    });
    if (!confirmed) return;
    const body = build(row, action, form.reason);
    if (!body) {
      onMsg({ ok: false, text: `${action} refused — a reason is required` });
      return;
    }
    inFlight.add(key);
    if (onPending) onPending(key);
    try {
      const res = await send(body);
      const text = verify(row, action, res);
      if (text === null) {
        onMsg({ ok: false, text: `${action} was not confirmed by the worker — check the list` });
        return;
      }
      onMsg({ ok: true, text });
      if (onDone) onDone();
    } catch (e) {
      onMsg({ ok: false, text: `${action} failed — ${errText(e)}` });
    } finally {
      inFlight.delete(key);
      if (onPending) onPending(null);
    }
  };
}

const TONE = { HOLD: 'warn', DROP: 'danger', RESUME: undefined };

// act(row, 'HOLD' | 'RESUME' | 'DROP'). Success is only a 200 whose
// merge.status is the status this action set.
export function makeMqAction({ confirm, send, onMsg, onDone, onPending, renderForm }) {
  return makeAction({
    confirm, send, onMsg, onDone, onPending, renderForm,
    keyOf: (row) => `${row.project}#${row.pr}`,
    opts: (action) => ({ title: `${action} PR`, tone: TONE[action] }),
    build: (row, action, reason) => mqActionBody(row, action, reason),
    verify: (row, action, res) => (res && res.merge && res.merge.status === ACTION_STATUS[action]
      ? `${row.project}#${row.pr} is now ${ACTION_STATUS[action]}`
      : null)
  });
}

// act(row). Success is only a numeric `released`; 0 means the key was already
// gone, which is said as such and still reloads, because the list is stale.
export function makeReleaseAction({ confirm, send, onMsg, onDone, onPending, renderForm }) {
  const act = makeAction({
    confirm, send, onMsg, onDone, onPending, renderForm,
    keyOf: (row) => HELD_KEY.map((k) => row[k]).join('|'),
    opts: () => ({ title: 'RELEASE HELD PAGE', tone: 'warn' }),
    build: (row, _action, why) => heldReleaseBody(row, why),
    verify: (row, _action, res) => {
      const n = res ? res.released : undefined;
      if (!Number.isInteger(n) || n < 0) return null;
      return n === 0 ? 'nothing was held under that key (already released)' : `released ${row.repo}#${row.number}`;
    }
  });
  return (row) => act(row, 'RELEASE');
}
