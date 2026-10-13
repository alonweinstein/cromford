// The /hub CHAT BINDINGS panel's pure half (BH-2678 / BH-2521.3). The shapes
// are the worker contract in worker/jobs/src/routes/telegram-topics.js:
//   GET /api/telegram-topics → {topics:{project:thread}, rows:[{project,
//                               thread_id, actor, updated_at}], as_of}
//   PUT /api/telegram-topics → {topic:{project, thread_id}} (the console also
//                               sends a required reason, BH-2995)
// The console reaches both through /api/coord/telegram-topics (api.js).

// A payload without a rows array is a broken answer, never an empty table.
export function bindingsView(payload) {
  if (!payload || !Array.isArray(payload.rows)) throw new Error('bad response');
  return { rows: payload.rows };
}

// Digits only, no leading zero, no sign, no exponent, no hex: "1e3" is not a
// thread id someone typed on purpose.
export function editBody(project, raw) {
  if (typeof project !== 'string' || !project) throw new Error('project required');
  const s = String(raw ?? '').trim();
  if (!/^[1-9][0-9]*$/.test(s) || !Number.isSafeInteger(Number(s))) {
    throw new Error('thread id must be a positive integer');
  }
  return { project, thread_id: Number(s) };
}

export const confirmOpts = (project, from, to) => ({
  title: 'CHAT BINDINGS',
  body: `Move ${project} from thread ${from} to ${to}?`,
  confirmLabel: 'MOVE',
  tone: 'warn',
});

// Moved is claimed only when the worker echoed this project and an integer thread.
export function editOutcome(project, { result, error }) {
  if (error) return { tone: 'bad', text: `Could not move ${project}: ${error.message}` };
  const topic = result && result.topic;
  if (topic && topic.project === project && Number.isInteger(topic.thread_id)) {
    return { tone: 'ok', text: `${project} now posts to thread ${topic.thread_id}.` };
  }
  return { tone: 'bad', text: `Could not move ${project}: unexpected answer.` };
}

// SAVE's whole flow. {refused} sends nothing and opens no dialog, except a
// confirmed blank reason (BH-2995), which the dialog should already have
// blocked; null means the dialog was cancelled; {outcome} means one PUT went
// out. Reload only on ok. `form` is what the dialog's REASON field writes.
export async function saveEdit({ apiObj, project, from, raw, confirm, reload, renderForm }) {
  let body;
  try { body = editBody(project, raw); } catch (e) { return { refused: e.message }; }
  if (body.thread_id === from) return { refused: `already thread ${from}` };
  const opts = confirmOpts(project, from, body.thread_id);
  const form = { reason: '' };
  const ok = await confirm({
    ...opts, confirmBlocked: true, form,
    body: renderForm ? ({ setBlocked }) => renderForm(form, setBlocked, opts.body) : opts.body,
  });
  if (!ok) return null;
  const reason = typeof form.reason === 'string' ? form.reason.trim() : '';
  if (!reason) return { refused: 'a reason is required' };
  let outcome;
  try {
    outcome = editOutcome(project, { result: await apiObj.telegramTopicSet(project, body.thread_id, reason) });
  } catch (error) {
    outcome = editOutcome(project, { error });
  }
  if (outcome.tone === 'ok') reload();
  return { outcome };
}
