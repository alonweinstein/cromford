// BH-2375 (BH-2330.0): the /config screens' pure half.

import { SETTING_VALUE_MAX, laneHref } from './settings.js';

// The detail route for one config row. `kind` is the stored config_changes
// kind (setting, flag, cost_cap, ...). Each segment is encoded once;
// router.js matchRoute decodes it once.
export const configHref = (kind, name) =>
  `/config/${encodeURIComponent(kind)}/${encodeURIComponent(name)}`;

export const CONFIG_CHANGES_LIMIT = 100;

// The one status line a /config stub shows. Loading, a failed read, an empty
// log and a count are four different strings; a body without a changes array
// is a failed read, never "no changes".
export function changesStatus({ loading, error, data }) {
  if (error) return `Could not load the change log: ${error.message || error}`;
  if (loading || !data) return 'Loading the change log…';
  if (!Array.isArray(data.changes)) return 'Could not load the change log: unexpected response';
  const n = data.changes.length;
  if (n === 0) return 'No changes recorded yet.';
  return `${n} recent change${n === 1 ? '' : 's'}${data.truncated === true ? ' (more not shown)' : ''}`;
}

// ── BH-2378 (BH-2330.3): the /config list screen ──────────────────────────

// RECENT CHANGES reads a window, never the whole log; the heading names it.
export const RECENT_CHANGES_LIMIT = 50;
const REASON_MAX = 512;

// lane.* and lib.* rows belong to a lane's own page, where they are edited
// with their catalog context. The worker enforces lowercase keys.
export const isLaneKey = (key) => /^(lane|lib)\./.test(String(key));
// lane.<id>.<knob> → /settings/<id>; a lib.* row has no lane page.
export const laneKeyHref = (key) => {
  const m = /^lane\.([^.]+)/.exec(String(key));
  return m ? laneHref(m[1]) : '/settings';
};

const matches = (text, filter) => {
  const f = String(filter || '').trim().toLowerCase();
  return !f || String(text).toLowerCase().includes(f);
};
const byText = (field) => (a, b) => (String(a[field]) < String(b[field]) ? -1 : String(a[field]) > String(b[field]) ? 1 : 0);

// A non-array is a failed read (null), never an empty list.
export function settingRows(settings, filter, showLane) {
  if (!Array.isArray(settings)) return null;
  return settings
    .filter((r) => matches(r.key, filter) && (showLane || !isLaneKey(r.key)))
    .map((r) => (isLaneKey(r.key)
      ? { ...r, editableHere: false, href: laneKeyHref(r.key) }
      : { ...r, editableHere: true }))
    .sort(byText('key'));
}

export function flagRows(flags, filter) {
  if (!Array.isArray(flags)) return null;
  return flags
    .filter((r) => matches(r.name, filter))
    .map((r) => ({ ...r, on: Number(r.active) === 1 }))
    .sort(byText('name'));
}

// Every kind in the one audit store, each row linking to its own history.
export function recentChangeRows(data) {
  if (!data || !Array.isArray(data.changes)) return null;
  return {
    rows: data.changes.slice(0, RECENT_CHANGES_LIMIT).map((r) => ({ ...r, href: configHref(r.kind, r.name) })),
    truncated: data.truncated === true || data.changes.length > RECENT_CHANGES_LIMIT
  };
}

// The modal's checks. They mirror the worker's own; the worker re-checks.
export function validateValue(raw) {
  const value = typeof raw === 'string' ? raw.trim() : '';
  if (!value) return { ok: false, message: 'value is required' };
  if (/[\r\n]/.test(value)) return { ok: false, message: 'value must be one line' };
  if (value.length > SETTING_VALUE_MAX) return { ok: false, message: `value must be ${SETTING_VALUE_MAX} characters or fewer` };
  return { ok: true, value };
}

export function validateReason(raw) {
  const value = typeof raw === 'string' ? raw.trim() : '';
  if (!value) return { ok: false, message: 'reason is required' };
  if (value.length > REASON_MAX) return { ok: false, message: `reason must be ${REASON_MAX} characters or fewer` };
  return { ok: true, value };
}

// No `note`: the worker keeps the row's own note when none is sent.
export const settingPutBody = (key, value, reason) => ({ key, value, reason, actor: 'console' });
