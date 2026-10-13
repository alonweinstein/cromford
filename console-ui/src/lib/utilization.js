import { agoFromMinutes } from './format.js';

// BH-4011 (BH-3988.3): the /utilization rows. GET /api/coord/utilization
// answers the newest hourly snapshot per project; this turns it into one row
// per fleet.conf project. A bucket the collector could not read is null, and
// null renders `—`, never 0: a failed ticket read is not "nothing ready".

// A snapshot older than this is flagged stale. A display rule fixed by the
// parent plan (D13), not a business parameter: it gates nothing.
export const STALE_MS = 2 * 3600 * 1000;

// Problems first, then healthy. `no snapshot` is the console's own verdict for
// a fleet project the collector has never written.
export const VERDICT_RANK = { starved: 0, blocked: 1, paused: 2, unknown: 3, 'no snapshot': 4, saturated: 5, busy: 6 };
export const verdictRank = (v) => (Object.hasOwn(VERDICT_RANK, v) ? VERDICT_RANK[v] : 7);

const VERDICT_WHY = {
  starved: 'free build slots and nothing ready to build',
  paused: 'a pause stops builds',
  blocked: 'ready work is blocked',
  saturated: 'at the build cap with ready work waiting',
  busy: 'building',
  unknown: 'not enough measured to call it',
  'no snapshot': 'the hourly collector has not written this project yet',
};

const obj = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : null);
const count = (v) => (Number.isInteger(v) && v >= 0 ? v : null);
const slots = (v) => (v === 'unlimited' ? v : count(v));

export const cellText = (v) => (v === null || v === undefined ? '—' : String(v));

export function pauseAge(since, now = Date.now()) {
  const t = since ? Date.parse(since) : NaN;
  return Number.isNaN(t) ? '—' : agoFromMinutes((now - t) / 60000);
}

const EMPTY = {
  ready: null, blocked: null, held: null, parked: null, heldComplete: null,
  running: null, cap: null, free: null, pauses: null, prReview: null, prCi: null, prMq: null,
  basis: null, payload: null, payloadError: null, asOf: null, stale: false,
};

function fromSnapshot(r, now) {
  const payload = obj(r.payload);
  const tickets = obj(payload && payload.tickets) || {};
  const builds = obj(payload && payload.builds) || {};
  const prs = obj(payload && payload.prs) || {};
  const basis = obj(payload && payload.basis);
  const verdict = typeof r.verdict === 'string' ? r.verdict : 'unknown';
  const unmeasured = basis ? Object.keys(basis).filter((k) => basis[k] === 'unmeasured') : [];
  const t = typeof r.as_of === 'string' ? Date.parse(r.as_of) : NaN;
  return {
    project: r.project,
    verdict,
    why: payload && typeof payload.why === 'string' ? payload.why
      : (VERDICT_WHY[verdict] || verdict) + (unmeasured.length ? `, unmeasured: ${unmeasured.join(', ')}` : ''),
    asOf: r.as_of || null,
    stale: Number.isNaN(t) || now - t > STALE_MS,
    ready: count(tickets.ready), blocked: count(tickets.blocked), held: count(tickets.held), parked: count(tickets.parked),
    heldComplete: typeof tickets.held_complete === 'boolean' ? tickets.held_complete : null,
    running: count(builds.running), cap: slots(builds.pool_cap), free: slots(builds.free_slots),
    pauses: payload && Array.isArray(payload.pauses)
      ? payload.pauses.filter(obj).map((p) => ({ kind: p.kind ?? null, name: p.name ?? null, since: p.since ?? null, stopsBuilds: p.stops_builds ?? null }))
      : null,
    prReview: count(prs.review), prCi: count(prs.ci), prMq: count(prs.merge_queue),
    basis,
    payload,
    payloadError: r.payload_error || null,
    snapshot: r,
  };
}

// resp: the GET body. fleetProjects: the fleet.conf list (null/empty = unread).
// Returns null when resp carries no rows[] array: that is an error, never empty.
export function utilizationRows(resp, fleetProjects, now = Date.now()) {
  if (!resp || !Array.isArray(resp.rows)) return null;
  const byProject = new Map();
  for (const r of resp.rows) {
    if (r && typeof r.project === 'string' && !byProject.has(r.project)) byProject.set(r.project, r);
  }
  const fleet = [...new Set((fleetProjects || []).map(String))];
  const fleetUnread = fleet.length === 0;
  const names = fleetUnread ? [...byProject.keys()] : fleet;
  const rows = names.map((p) => (byProject.has(p)
    ? fromSnapshot(byProject.get(p), now)
    : { ...EMPTY, project: p, verdict: 'no snapshot', why: VERDICT_WHY['no snapshot'], snapshot: null }));
  const extra = fleetUnread ? [] : [...byProject.keys()].filter((p) => !fleet.includes(p));
  return { rows, extra, fleetUnread, snapshots: byProject.size };
}
