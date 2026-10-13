// BH-5567 (BH-5556.10): the /staff screen's pure half. The roster and the
// findings come from the jobs worker's staff-screen.js reads; the kill switch
// is a flag row written through the Flags screen's own bodies (lib/flags.js):
// staff-kill-<agent> for one staff agent, staff-kill-all for every one.
// Archie is never a staff-kill name: lane-off-archie already stops Archie.

import { flagRowsAll, setBody, clearQuery, FLEET_SCOPE } from './flags.js';

export const KILL_PREFIX = 'staff-kill-';
export const KILL_ALL = `${KILL_PREFIX}all`;
export const ARCHIE = 'archie';
export const ARCHIE_KILL_FLAG = 'lane-off-archie';

// The worker's agent identity (staff.js): trimmed, lowercased, this alphabet.
const AGENT_RE = /^[a-z][a-z0-9-]{1,39}$/;
const KILL_RE = /^staff-kill-[a-z][a-z0-9-]{1,39}$/;

export const displayName = (name) => {
  const s = typeof name === 'string' ? name.trim() : '';
  return s ? s[0].toUpperCase() + s.slice(1) : '';
};

// The one kill flag a staff agent has. null for archie, for `all` (that name
// is the all-staff flag), and for anything outside the agent alphabet.
export function killFlagName(agent) {
  const a = typeof agent === 'string' ? agent.trim().toLowerCase() : '';
  if (!AGENT_RE.test(a) || a === ARCHIE || a === 'all') return null;
  return `${KILL_PREFIX}${a}`;
}

const isKillName = (name) => name === KILL_ALL || KILL_RE.test(String(name || ''));

// The PUT body and DELETE query, the Flags screen's own. A name outside the
// staff-kill family is refused here (null), before any write.
export function killSetBody(name, reason) {
  if (!isKillName(name)) return null;
  return setBody({ name, scope: FLEET_SCOPE, value: '', reason });
}
export function killClearQuery(name, reason) {
  if (!isKillName(name)) return null;
  return clearQuery({ name, scope: FLEET_SCOPE, reason });
}

// on | off | unknown for one fleet-scope flag. A failed read is unknown, and so
// is a missing row in a list the worker truncated: absent is not off there.
export function killState(flagsRes, name) {
  const res = flagRowsAll(flagsRes, { showCleared: true });
  if (res === null) return 'unknown';
  const row = res.rows.find((r) => r.name === name && r.scope === FLEET_SCOPE);
  if (row) return row.on ? 'on' : 'off';
  return res.truncated ? 'unknown' : 'off';
}

// An absent value is "n/a", never 0. A real zero stays "0".
export const na = (v) => (v === null || v === undefined || v === '' ? 'n/a' : String(v));

// A body with no agents array is a failed read (null), never an empty roster.
export function rosterRows(res) {
  if (!res || !Array.isArray(res.agents)) return null;
  const rows = res.agents
    .filter((a) => a && typeof a === 'object' && typeof a.name === 'string')
    .map((a) => ({ ...a, display: displayName(a.name) }));
  return { rows, sources: res.sources && typeof res.sources === 'object' ? res.sources : {} };
}

export function findingRows(res) {
  if (!res || !Array.isArray(res.findings)) return null;
  return { rows: res.findings.filter((f) => f && typeof f === 'object'), truncated: res.truncated === true };
}
