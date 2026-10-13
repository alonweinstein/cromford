// BH-4153 (BH-4141.1): the /flags screen's pure half. The worker's merged
// GET /api/flags answers rows from both stores (harness_flags for the ported
// families, pause_flags for the rest), each with its scope. A row is ON iff
// its cleared_at is null; a clear is soft and keeps the row for history.

import { validateReason } from './config.js';

export { validateReason };

// The worker's own alphabet and caps (worker/jobs/src/routes/flags.js). The
// worker re-checks; these only keep the confirm button honest.
export const FLAG_NAME_RE = /^[A-Za-z0-9._-]+$/;
export const FLAG_NAME_MAX = 128;
export const FLAG_SCOPE_RE = /^[A-Za-z0-9._-]{1,64}$/;
export const FLEET_SCOPE = 'fleet';

const trim = (raw) => (typeof raw === 'string' ? raw.trim() : '');

const isOn = (r) => (Object.prototype.hasOwnProperty.call(r, 'cleared_at')
  ? r.cleared_at === null || r.cleared_at === undefined
  // A worker that predates the merged shape sends no cleared_at; its
  // `active` is then the only answer there is.
  : Number(r.active) === 1);

const matches = (r, f) => !f || [r.name, r.scope, r.reason]
  .some((x) => x !== null && x !== undefined && String(x).toLowerCase().includes(f));

// A body with no flags array is a failed read (null), never an empty list.
// `hidden` is how many cleared rows the filter matched but SHOW CLEARED hid.
export function flagRowsAll(res, { filter = '', showCleared = false } = {}) {
  if (!res || !Array.isArray(res.flags)) return null;
  const f = trim(filter).toLowerCase();
  let hidden = 0;
  const rows = [];
  for (const raw of res.flags) {
    if (!raw || typeof raw !== 'object') continue;
    const r = { ...raw, scope: raw.scope || FLEET_SCOPE, on: isOn(raw) };
    if (!matches(r, f)) continue;
    if (!r.on && !showCleared) { hidden += 1; continue; }
    rows.push(r);
  }
  return { rows, truncated: res.truncated === true, hidden };
}

// The project a flag belongs to, when it names one the fleet runs:
// paused-<p> or automerge-disabled-<p>. paused-all, the bare
// automerge-disabled and a project the fleet does not list answer null.
const PROJECT_FLAG_RE = /^(?:paused|automerge-disabled)-(.+)$/;
export function flagProject(name, projects) {
  const m = PROJECT_FLAG_RE.exec(String(name || ''));
  if (!m || !Array.isArray(projects)) return null;
  return projects.includes(m[1]) ? m[1] : null;
}

// A scope other than fleet is a box name, and its drill-down is /machines.
export const isBoxScope = (scope) => Boolean(scope) && scope !== FLEET_SCOPE;

export function validateFlagName(raw) {
  const value = trim(raw);
  if (!value) return { ok: false, message: 'name is required' };
  if (value.length > FLAG_NAME_MAX) return { ok: false, message: `name must be ${FLAG_NAME_MAX} characters or fewer` };
  if (!FLAG_NAME_RE.test(value)) return { ok: false, message: 'name takes letters, digits, dot, dash and underscore only' };
  return { ok: true, value };
}

// Blank means fleet.
export function validateScope(raw) {
  const value = trim(raw) || FLEET_SCOPE;
  if (!FLAG_SCOPE_RE.test(value)) return { ok: false, message: 'scope is fleet or a box name (letters, digits, dot, dash, underscore; 64 at most)' };
  return { ok: true, value };
}

// The SET modal's PUT body. A blank value is sent as null (no value). No
// actor: the coord proxy stamps it.
export function setBody({ name, scope, value, reason } = {}) {
  const v = trim(value);
  return {
    name: trim(name),
    scope: trim(scope) || FLEET_SCOPE,
    value: v === '' ? null : v,
    active: 1,
    reason: trim(reason)
  };
}

// The CLEAR modal's DELETE query, in this order: name, scope, reason.
export function clearQuery({ name, scope, reason } = {}) {
  return new URLSearchParams({
    name: trim(name),
    scope: trim(scope) || FLEET_SCOPE,
    reason: trim(reason)
  }).toString();
}

// The SET form's state: what blocks confirm, and the one hint line that says why.
export function setFormState(draft = {}) {
  const n = validateFlagName(draft.name);
  const s = validateScope(draft.scope);
  const r = validateReason(draft.reason);
  let hint = null;
  if (!trim(draft.name) && !trim(draft.reason)) hint = 'needs a name and a reason';
  else if (!n.ok) hint = n.message;
  else if (!s.ok) hint = s.message;
  else if (!r.ok) hint = r.message;
  return { blocked: Boolean(hint), hint };
}

export function clearFormState(draft = {}) {
  const r = validateReason(draft.reason);
  return { blocked: !r.ok, hint: r.ok ? null : r.message };
}
