// The fleet's pause rows (BH-1672), shaped for the Fleet page. The wire
// contract is the header of bin/lib/pause.sh:
//   GET /api/pauses?active=1  -> { pauses: [{ id, scope, what, reason, actor,
//                                  created_at, expires_at, ended_at,
//                                  end_reason }], truncated }
// read through the coord proxy as /api/coord/pauses?active=1.
//
// `now` is a parameter, never a clock read in here, for the same reason as
// alertrows.js: the screen reads the clock once per render and hands it down.

import { agoFromMinutes } from './format.js';

// The contract's `what` enum. A validation list, not a business parameter.
export const PAUSE_WHATS = ['triage', 'reviews', 'merges', 'builds'];

const FLEET = 'fleet';

// Whole minutes since `iso`, or null when it is missing or unparseable. Never
// 0 for a row we cannot date: zero renders as "now".
function minutesSince(iso, now) {
  if (!iso) return null;
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return null;
  return Math.max(0, Math.round((now - t) / 60000));
}

// A row is live when it has not ended and its expiry parses and is still
// ahead. Unparseable is NOT live — the same rule as the box lib's
// __PAUSE_JQ_ACTIVE, so the console and the box agree on what is paused.
function expiryMs(r) {
  if (!r || !r.expires_at) return null;
  const t = Date.parse(r.expires_at);
  return Number.isNaN(t) ? null : t;
}

export function shapePauses(payload, now) {
  const raw = payload && Array.isArray(payload.pauses) ? payload.pauses : [];
  const rows = [];
  for (const r of raw) {
    if (!r || (r.ended_at !== null && r.ended_at !== undefined)) continue;
    const exp = expiryMs(r);
    if (exp === null || exp <= now) continue;
    const reason = typeof r.reason === 'string' ? r.reason.trim() : '';
    rows.push({
      ...r,
      ageMin: minutesSince(r.created_at, now),
      // Rounded up: a row with 10s left still reads "1m", never "now".
      expiresInMin: Math.max(1, Math.ceil((exp - now) / 60000)),
      scopeLabel: r.scope === FLEET ? 'FLEET (all projects)' : r.scope,
      reasonText: reason || 'no reason given'
    });
  }
  // A missing field is NOT truncated, as in shapeAlertRows.
  return { rows, truncated: Boolean(payload) && payload.truncated === true };
}

// Every pause that covers `project`: its own rows and every fleet row.
export function pausesForProject(rows, project) {
  return (rows || [])
    .filter((r) => r.scope === FLEET || r.scope === project)
    .sort((a, b) => String(a.what).localeCompare(String(b.what)));
}

// What END sends for a row. A project's triage pause is also the box's
// flags/paused-<p> file, so it goes through resume_board, which clears the
// file AND ends the row; ending only the row would drop the tag while the box
// stayed paused.
// A fleet row has no project, so it names its scope and the console's action
// endpoint routes it to the hub, which runs every pause handler.
// With a second argument (the Fleet page's END dialog, BH-2509) the reason is
// required: a blank one is {error}, a typed one rides on the command trimmed.
export function endCommandFor(row, reason) {
  let cmd;
  if (row.scope !== FLEET && row.what === 'triage') cmd = { type: 'resume_board', project: row.scope };
  else cmd = row.scope === FLEET
    ? { type: 'pause_end', id: row.id, scope: FLEET }
    : { type: 'pause_end', id: row.id, project: row.scope };
  if (reason === undefined) return cmd;
  const text = trimmed(reason);
  return text ? { ...cmd, reason: text } : { error: 'reason required' };
}

// What the Project page's RESUME dialog sends. The reason is required.
export function resumeCommandFor(project, reason) {
  const text = trimmed(reason);
  return text ? { type: 'resume_board', project, reason: text } : { error: 'reason required' };
}

// What the Fleet page's PAUSE FLEET form sends: pause_set with scope fleet and
// no project, the same routing shape as END on a fleet row. The reason and
// the ttl are both required here; a ttl that is not a whole number of seconds
// above 0 is refused, never clamped.
export function fleetPauseCommandFor({ what, reason, ttlS } = {}) {
  if (!PAUSE_WHATS.includes(what)) return { error: `what must be one of ${PAUSE_WHATS.join(', ')}` };
  const text = trimmed(reason);
  if (!text) return { error: 'reason required' };
  const ttlRaw = typeof ttlS === 'string' ? ttlS.trim() : ttlS == null ? '' : String(ttlS);
  if (ttlRaw === '') return { error: 'ttl required' };
  if (!/^[1-9][0-9]*$/.test(ttlRaw)) return { error: 'ttl must be a whole number of seconds above 0' };
  return { type: 'pause_set', scope: FLEET, what, reason: text, ttl_s: Number(ttlRaw) };
}

function trimmed(v) {
  return typeof v === 'string' ? v.trim() : '';
}

// Who paused it, for display. 'console' is what a row records when no
// verified identity reached the poller, so it is never shown as a person.
export function pauseActorText(actor) {
  if (typeof actor !== 'string' || !actor.trim()) return 'unknown';
  return actor === 'console' ? 'console (no verified identity)' : actor;
}

// One line of why/who/when for a shaped row (shapePauses output).
export function pauseDetail(row) {
  const age = row.ageMin === null || row.ageMin === undefined ? 'age unknown' : `${agoFromMinutes(row.ageMin)} ago`;
  const when = row.created_at ? `${age} (${row.created_at})` : age;
  return `${row.reasonText} · by ${pauseActorText(row.actor)} · ${when} · ${row.scopeLabel}`;
}

export const FLAG_ONLY_LINE = 'paused by flag file: no pause row on record, reason and actor unknown';

// The why/who/when lines for one board: one per live row covering it (its own
// rows and every fleet row), each {key, what, scope, text}. `flagPaused` is the
// box's flags/paused-<p> file. That file is written by pause_board, alongside a
// triage row scoped to this project; when no such row is live, the file is
// all there is (a circuit breaker, a row that failed to land), and one line
// with what null says so instead of inventing a reason.
export function boardPauseLines(rows, project, flagPaused) {
  const live = pausesForProject(rows, project);
  const lines = live.map((r) => ({ key: `row-${r.id}`, what: r.what, scope: r.scope, text: pauseDetail(r) }));
  const flagRow = live.some((r) => r.scope === project && r.what === 'triage');
  if (flagPaused && !flagRow) lines.unshift({ key: 'flag', what: null, scope: project, text: FLAG_ONLY_LINE });
  return lines;
}

// What the Project page's PAUSE form sends. A blank ttl means the worker's
// pause_default_ttl_s settings row, so it is left out; anything else must be
// a positive whole number of seconds and is refused, never clamped. The
// reason is required: the worker 400s a blank one (PUT /api/pauses).
export function pauseCommandFor(project, { what, reason, ttlS } = {}) {
  if (!PAUSE_WHATS.includes(what)) return { error: `what must be one of ${PAUSE_WHATS.join(', ')}` };
  const text = typeof reason === 'string' ? reason.trim() : '';
  if (!text) return { error: 'reason required' };
  const ttlRaw = typeof ttlS === 'string' ? ttlS.trim() : ttlS == null ? '' : String(ttlS);
  let ttl = null;
  if (ttlRaw !== '') {
    if (!/^[1-9][0-9]*$/.test(ttlRaw)) return { error: 'ttl must be a whole number of seconds above 0' };
    ttl = Number(ttlRaw);
  }
  const cmd = what === 'triage'
    ? { type: 'pause_board', project, reason: text }
    : { type: 'pause_set', project, what, reason: text };
  if (ttl !== null) cmd.ttl_s = ttl;
  return cmd;
}
