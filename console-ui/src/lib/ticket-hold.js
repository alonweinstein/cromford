// The ticket-hold contract (BH-2326.0) that the hold siblings of #2326 import.
// A hold is a `ledgers(kind='ticket_hold', key='<project>#<n>')` row with
// status held|clear|unknown and detail '<verb> by <actor> at <iso>: <reason> | <why>',
// and it is set by the console command {type:'hold_ticket'|'unhold_ticket',
// project, ticket:'PREFIX-<n>', reason}. Pure: no DOM, no fetch.

export const HOLD_LEDGER_KIND = 'ticket_hold';
export const HOLD_REASON_MAX = 500;

// The same key shape as the closed-issue join in functions/api/dash/kanban/pipeline.js.
export const holdKey = (project, n) => `${project}#${n}`;

// pipeline.js's issueNumber rule, with the number held to a positive integer
// without a leading zero, so BH-0 and BH-01 are refused.
const TICKET_KEY = /^[A-Za-z][A-Za-z0-9]*-([1-9][0-9]*)$/;

export function holdTarget(project, ticketKey) {
  if (typeof project !== 'string' || !project.trim()) return null;
  if (typeof ticketKey !== 'string') return null;
  const m = TICKET_KEY.exec(ticketKey);
  return m ? { project, ticket: ticketKey, issue: Number(m[1]) } : null;
}

// The /api/dash/action body. The reason is trimmed before it is capped, so
// leading whitespace never eats into the budget. A refused target is null here too.
export function holdCommand(action, target, reason) {
  if (!target) return null;
  return {
    type: action === 'hold' ? 'hold_ticket' : 'unhold_ticket',
    project: target.project,
    ticket: target.ticket,
    reason: String(reason ?? '').trim().slice(0, HOLD_REASON_MAX)
  };
}

const DETAIL = /^\S+ by (.+?) at (\S+): (.*)$/s;

// A ledger row (or the `{ledger: row}` body GET /api/ledger answers) as what a
// card shows. null is the absent row, which is not held. A load failure, a
// status we do not know and a row that is not a ticket_hold row are unknown,
// never "not held" (D23). A held row whose detail does not parse is still held,
// with by/at/why null rather than guessed.
export function holdFromLedger(row) {
  if (row && typeof row === 'object' && !Array.isArray(row) && !(row instanceof Error) &&
      'ledger' in row && !('status' in row)) row = row.ledger;
  if (row === null) return { held: false };
  if (!row || typeof row !== 'object' || Array.isArray(row) || row instanceof Error) return { unknown: true };
  if (row.kind != null && row.kind !== HOLD_LEDGER_KIND) return { unknown: true };
  if (row.status === 'held') {
    const m = typeof row.detail === 'string' ? DETAIL.exec(row.detail) : null;
    return m ? { held: true, by: m[1], at: m[2], why: m[3] } : { held: true, by: null, at: null, why: null };
  }
  if (row.status === 'clear') return { held: false };
  return { unknown: true };
}
