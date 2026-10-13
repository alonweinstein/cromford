// The hub's own ticket snapshot (`GET /api/dash/tickets-snapshot`) — one call
// carrying every OS board, rather than four live calls out to the client APIs.
// It is a SNAPSHOT, so its age is always rendered alongside it.

export const TICKET_STATUSES = ['todo', 'in_progress', 'review', 'done'];

const STATUS_LABEL = {
  todo: 'TODO',
  in_progress: 'IN PROGRESS',
  review: 'REVIEW',
  done: 'DONE'
};

// `generated_at_epoch` is epoch SECONDS. Reading it as milliseconds dates the
// snapshot to 1970 and renders an age of ~29 million minutes; reading a
// millisecond value as seconds puts it 50,000 years in the future. Either way
// the banner is confidently absurd, so the unit is validated rather than
// assumed: anything outside a plausible seconds range is "unknown".
const PLAUSIBLE_MIN = 1_000_000_000;   // 2001
const PLAUSIBLE_MAX = 4_000_000_000;   // 2096

export function snapshotAgeMinFromEpochSeconds(epochSeconds) {
  const s = Number(epochSeconds);
  if (!Number.isFinite(s) || s < PLAUSIBLE_MIN || s > PLAUSIBLE_MAX) return null;
  const deltaMs = Date.now() - s * 1000;
  // A box clock a little ahead of ours is "now", never a negative age.
  return Math.max(0, Math.round(deltaMs / 60000));
}

// Group a project's tickets into columns. The four known statuses always get a
// column (an absent one reads as truncated otherwise), and anything else gets
// its own column rather than being dropped — a ticket that vanishes because its
// status is new is a silent cap, and the totals would quietly stop adding up.
export function ticketColumns(tickets) {
  const buckets = new Map(TICKET_STATUSES.map((s) => [s, []]));
  for (const ticket of tickets || []) {
    const raw = ticket && ticket.status;
    const key = raw === null || raw === undefined || raw === '' ? 'unknown' : String(raw);
    if (!buckets.has(key)) buckets.set(key, []);
    buckets.get(key).push(ticket);
  }
  return [...buckets.entries()].map(([key, rows]) => ({
    key,
    label: STATUS_LABEL[key] || key.replace(/[_-]+/g, ' ').toUpperCase(),
    known: TICKET_STATUSES.includes(key),
    tickets: rows,
    count: rows.length
  }));
}

export const ticketProjects = (snapshot) =>
  snapshot && snapshot.projects ? Object.keys(snapshot.projects) : [];

// A project with no OS board (gh-issues / jira driven) is simply not in the
// snapshot. That is a normal state, not a fetch failure.
export const projectInSnapshot = (snapshot, project) =>
  Boolean(snapshot && snapshot.projects && Object.prototype.hasOwnProperty.call(snapshot.projects, project));

export const ticketTotal = (tickets) => (tickets || []).length;

// The console answers HTTP 200 in two states that are NOT a usable snapshot:
//   {ok:false, unavailable:"..."}  the watchdog read failed
//   {ok:true,  projects:{}}        the hub's 10-min cron has not pushed yet
// Guarding only on loading/error lets both through as a successful EMPTY
// snapshot, and the per-project map then renders "no OS board for this project"
// for four projects that certainly have one. That is a confident false
// statement about the client's own boards, so it is checked before the map.
// The hub emits this named value for "nobody has assessed this yet", rather
// than an empty string, so the absence is explicit on the wire too.
export const UNTRIAGED = 'untriaged';

export function snapshotUsable(payload) {
  if (!payload || typeof payload !== 'object') {
    return { usable: false, reason: 'no snapshot payload' };
  }
  if (payload.ok === false) {
    return { usable: false, reason: payload.unavailable || 'the hub could not produce a ticket snapshot' };
  }
  if (payload.unavailable) {
    return { usable: false, reason: payload.unavailable };
  }
  if (!payload.projects || Object.keys(payload.projects).length === 0) {
    return {
      usable: false,
      reason: 'the hub has not pushed one yet (its push runs every 10 minutes)'
    };
  }
  return { usable: true, reason: null };
}

// `triage_verdict` + `waiting_on` are being added to the hub's push. Until they
// land they are simply absent, and an absent verdict must render as NOTHING —
// inferring "ready to build" from a missing field would invent the one
// distinction this surface exists to show. So both fields are required before
// anything is claimed, which works before and after the hub change ships.
export function ticketTriage(ticket) {
  // Read BOTH casings: the hub's push and the board APIs do not agree, and a
  // camelCase payload read as snake_case yields "no verdict" — which renders a
  // ticket that is blocked on the client as though nothing were wrong.
  const rawVerdict = ticket && (ticket.triage_verdict ?? ticket.triageVerdict);
  const rawWaiting = ticket && (ticket.waiting_on ?? ticket.waitingOn);

  // VALUES are normalised too, not just field names. The hub normalises the
  // names across the four board APIs but passes values through verbatim, and
  // those APIs already disagreed on key casing — so value casing is a fair bet
  // to diverge next. A board returning "Client" would otherwise classify a
  // genuine client-block as merely "assessed": a not-buildable ticket
  // downgraded into one that looks actionable, which is the direction that
  // costs. Normalising here (at the consumer) means the renderer classifies
  // correctly whatever upstream sends, and boards that disagree render alike.
  // Only a non-empty STRING is a verdict. A number or a boolean is malformed,
  // and malformed must fall to the SAFE state (untriaged) rather than coercing
  // into a real-looking verdict — `String(0)` is "0", which would otherwise
  // read as "someone assessed this".
  const norm = (v) => {
    if (typeof v !== 'string') return null;
    const t = v.trim().toLowerCase();
    return t === '' ? null : t;
  };
  const verdict = norm(rawVerdict);
  const waitingOn = norm(rawWaiting);

  // THREE states, not two. The hub now names the absence (`untriaged`) instead
  // of sending an empty string, and an unassessed ticket must be visibly
  // unassessed — never quietly indistinguishable from one that was looked at
  // and cleared. That is the invariant: untriaged is NEVER a buildable signal.
  //
  //   untriaged          no verdict at all, or the literal "untriaged"
  //   blocked_on_client  triage asked a question the client has not answered
  //   assessed           any other real verdict
  //
  // `waiting_on` alone is not an assessment: there is no verdict to act on.
  if (!verdict || verdict === UNTRIAGED) {
    return { state: 'untriaged', assessed: false, blockedOnClient: false, verdict, waitingOn };
  }

  // The standing product-board rule: needs_clarification + waiting on the
  // client means the mechanism is unconfirmed, so it is NOT buildable. It
  // needs BOTH halves — a verdict alone never invents a block.
  const blockedOnClient = verdict === 'needs_clarification' && waitingOn === 'client';
  return {
    state: blockedOnClient ? 'blocked_on_client' : 'assessed',
    assessed: true,
    blockedOnClient,
    verdict,
    waitingOn
  };
}
