// POST / REVISE / KILL / CHAT on one idea (BH-2520), the pure half. Nothing
// new on the wire: these are the console action types bin/poll-commands.sh
// already handles, sent through api.action (POST /api/dash/action):
//   chat_proposal                                {slug, message, origin}
//   post_proposal | kill_proposal | revise_proposal   {slug, notes}
// The poller runs bin/product-cmd.sh on the project's owning box: kill writes
// status=vetoed + notes to the ledger, revise runs one drafting pass and puts
// the row back at the gate at rev+1, post runs bin/post-proposal.sh, and chat
// answers in the idea chat. The Pages proxy stamps the actor; the console
// never sends one.

// The poller refuses any slug outside this class (it reaches a remote shell),
// so the screen never offers a command the poller would refuse.
export const slugOk = (slug) => typeof slug === 'string' && /^[A-Za-z0-9_-]+$/.test(slug);

// POST only at the gate: post-proposal.sh has no status check of its own and
// creates a client ticket every time it runs. KILL only before the idea left
// for the client. REVISE also takes a vetoed row back to the gate, and a
// candidate (product-cmd.sh drafts one fresh). CHAT is not gated on status.
const OFFERED = {
  post: ['gate_pending'],
  revise: ['gate_pending', 'candidate', 'vetoed'],
  kill: ['gate_pending', 'candidate'],
};
export const IDEA_ACTIONS = ['post', 'revise', 'kill', 'chat'];
export function availableIdeaActions(proposal) {
  if (!proposal || !slugOk(proposal.slug)) return [];
  return IDEA_ACTIONS.filter((a) => a === 'chat' || OFFERED[a].includes(proposal.status));
}

// An input bound for the dialog's textarea, not a business parameter: long
// enough for a paragraph of revise notes, short enough to stay a command
// payload. Over it the text is refused, never cut.
export const IDEA_TEXT_MAX = 4000;
const NEEDS_TEXT = { revise: 'Say what to change.', chat: 'Type a message.' };
export function textError(action, text) {
  if (action === 'post') return null;
  const t = typeof text === 'string' ? text.trim() : '';
  if (!t && NEEDS_TEXT[action]) return NEEDS_TEXT[action];
  if (t.length > IDEA_TEXT_MAX) return `Keep it under ${IDEA_TEXT_MAX} characters.`;
  return null;
}

// The exact payload the poller reads. Kill notes are optional and only sent
// when there are some.
export function commandFor(action, project, slug, text) {
  const t = typeof text === 'string' ? text.trim() : '';
  if (action === 'post') return { type: 'post_proposal', project, slug };
  if (action === 'kill') return t ? { type: 'kill_proposal', project, slug, notes: t } : { type: 'kill_proposal', project, slug };
  if (action === 'revise') return { type: 'revise_proposal', project, slug, notes: t };
  if (action === 'chat') return { type: 'chat_proposal', project, slug, message: t, origin: 'console' };
  throw new Error(`unknown idea action ${action}`);
}

const TITLE = { post: 'POST IDEA', revise: 'REVISE IDEA', kill: 'KILL IDEA', chat: 'CHAT ABOUT THIS IDEA' };
export const TEXT_LABEL = { revise: 'NOTES', kill: 'NOTES (OPTIONAL)', chat: 'MESSAGE' };
export const TEXT_PLACEHOLDER = {
  revise: 'what the next draft should change',
  kill: 'why this one is dead, for whoever reads the decision notes',
  chat: 'ask the idea anything',
};

export function confirmOpts(action, proposal) {
  const name = (proposal && (proposal.title || proposal.slug)) || 'this idea';
  const rev = Number(proposal && proposal.rev) || 1;
  const body = {
    post: `Post "${name}" to the client? This creates a ticket on the client's board. `
      + 'It cannot be undone from here.',
    revise: `One drafting pass applies your notes to "${name}". It comes back to the gate as rev ${rev + 1}. `
      + 'That takes a few minutes.',
    kill: `Kill "${name}"? It is marked vetoed and stays off the client board. `
      + 'Your notes, if any, are kept with it.',
    chat: `Ask about "${name}". The reply lands in the IDEA CHAT section below in 1-2 minutes.`,
  }[action];
  return {
    title: TITLE[action],
    body,
    confirmLabel: action.toUpperCase(),
    tone: action === 'kill' ? 'danger' : action === 'post' ? 'warn' : 'primary',
  };
}

// Only an answer carrying a command id means the command queued. That is all
// the screen can say: the poller acts on it later, on the owning box.
const AFTER = {
  post: ' Nothing is on the client board until the poller runs it.',
  revise: ' Reload in a few minutes for the new draft.',
  kill: '',
  chat: ' The reply lands in the IDEA CHAT in about 1-2 minutes; reload to see it.',
};
export function outcomeLine(action, { result, error } = {}) {
  const label = action.toUpperCase();
  if (error) return { tone: 'bad', text: `${label} not sent: ${error.message}` };
  const id = result && result.command_id;
  if (id === undefined || id === null || id === '') {
    return { tone: 'bad', text: `${label} not confirmed: unexpected answer (no command id).` };
  }
  return { tone: 'ok', text: `${label} queued as command #${id}.${AFTER[action]}` };
}
