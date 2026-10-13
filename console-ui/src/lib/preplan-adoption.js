import { settingKey } from './settings.js';

// BH-2573 (BH-2543.2): the PREPLAN ADOPTION section's shaping. Pure, so the
// tests feed it the route's own answer (GET /api/preplans/adoption, documented
// in the header of bin/lib/preplan-cadence.sh) and the screen only lays it out.

// The registry defaults for the three knobs (catalog/lanes.d/preplan-tick.json).
// They apply when no settings row exists or the settings read failed.
export const ADOPT_DEFAULTS = { floorPct: 50, minSamples: 10, windowDays: 7 };

// knob -> [ENV, registry min, registry max]
const KNOBS = {
  floorPct: ['PREPLAN_ADOPT_FLOOR_PCT', 0, 100],
  minSamples: ['PREPLAN_ADOPT_MIN_SAMPLES', 1, 1000],
  windowDays: ['PREPLAN_ADOPT_WINDOW_DAYS', 1, 30]
};
const INT_RE = /^-?\d+$/;

// The knobs as lane_knob (bin/lib/lane-gate.sh) resolves them: the project row
// first, then the lane row; a row that is set is the answer even when it is
// junk. An integer row outside the registry bounds is clamped, as lane_knob
// clamps a settings row; anything else is the default. `unreadable` means the
// settings read itself failed, so every value is the default.
export function adoptKnobs(payload, project) {
  const out = { ...ADOPT_DEFAULTS, source: {}, unreadable: false };
  if (!payload || !Array.isArray(payload.settings)) {
    for (const k of Object.keys(KNOBS)) out.source[k] = 'default';
    return { ...out, unreadable: true };
  }
  const rows = new Map();
  for (const s of payload.settings) {
    if (s && s.key !== null && s.key !== undefined) rows.set(String(s.key).toLowerCase(), s.value);
  }
  const set = (v) => v !== null && v !== undefined && String(v).trim() !== '';
  for (const [k, [env, min, max]] of Object.entries(KNOBS)) {
    const own = rows.get(settingKey('preplan-tick', env, project));
    const raw = set(own) ? own : rows.get(settingKey('preplan-tick', env));
    const v = set(raw) ? String(raw).trim() : '';
    if (INT_RE.test(v)) {
      out[k] = Math.min(max, Math.max(min, Number(v)));
      out.source[k] = 'settings';
    } else {
      out.source[k] = 'default';
    }
  }
  return out;
}

const UNEXPECTED = 'unexpected answer from /api/preplans/adoption';
const num = (v) => (v === null || v === undefined || v === '' ? null : Number(v));
const counted = (r) => ['adopted', 'stale', 'miss', 'off'].some((k) => (num(r && r[k]) || 0) > 0);

// loading | error | empty | rows. A failed or unreadable read is an error,
// never empty and never 0%.
export function adoptionState({ data, error, loading } = {}, project) {
  if (!data) {
    if (error) return { kind: 'error', error };
    return { kind: 'loading' };
  }
  if (!Array.isArray(data.projects) || !Array.isArray(data.days) || !Array.isArray(data.recent)) {
    return { kind: 'error', error: new Error(UNEXPECTED) };
  }
  const windowDays = Number.isInteger(data.window_days) ? data.window_days : null;
  const row = data.projects.find((r) => r && r.project === project) || null;
  const days = data.days
    .filter((d) => d && d.project === project)
    .sort((a, b) => String(a.day).localeCompare(String(b.day)));
  const recent = data.recent.filter((r) => r && r.project === project);
  if (!counted(row) && !days.some(counted) && recent.length === 0) return { kind: 'empty', windowDays };
  const stats = row || { project, adopted: 0, stale: 0, miss: 0, off: 0, bought: 0, rate: null, hit_rate: null, builds: 0 };
  return { kind: 'rows', stats, days, recent, truncated: data.recent_truncated === true, windowDays };
}

// `rate` is the route's fraction (adopted/bought); null when nothing was bought.
export function rateLabel(rate) {
  if (rate === null || rate === undefined || rate === '') return '—';
  const r = Number(rate);
  if (!Number.isFinite(r)) return '—';
  return `${Math.round(r * 100)}%`;
}

// One bar slot per day. A day with no rate (nothing bought) is a gap, never a
// zero-height bar that would read as 0%.
export function dayBars(days, { width, height }) {
  const n = days.length;
  if (!n) return [];
  const slot = width / n;
  const w = Math.max(1, Math.min(24, slot - 2));
  return days.map((d, i) => {
    const r = d.rate === null || d.rate === undefined || d.rate === '' ? NaN : Number(d.rate);
    const gap = !Number.isFinite(r);
    const h = gap ? 0 : r * height;
    return { day: d.day, x: i * slot + (slot - w) / 2, w, h, y: height - h, gap, label: String(d.day).slice(5) };
  });
}

// The cadence rule: enough bought pre-plans in the window AND the adopt rate
// under the floor. Floor 0 never cuts (nothing is under 0%); absent numbers
// never cut.
export function underFloor(stats, floorPct, minSamples) {
  if (!stats) return false;
  const bought = num(stats.bought);
  const adopted = num(stats.adopted);
  if (bought === null || adopted === null || !Number.isFinite(bought) || !Number.isFinite(adopted)) return false;
  return bought >= minSamples && adopted * 100 < floorPct * bought;
}

// BH-3437: builds ran and none used a pre-plan. Absent numbers never fire.
export function zeroHits(stats) {
  if (!stats) return false;
  const builds = num(stats.builds);
  const adopted = num(stats.adopted);
  return Number.isFinite(builds) && builds > 0 && adopted === 0;
}

export function recentRows(recent) {
  return recent.map((r) => ({
    id: `${r.job_id}|${r.created_at}`,
    at: r.created_at,
    ticket: r.ticket_id,
    verdict: r.verdict,
    detail: r.detail,
    job_id: r.job_id
  }));
}
