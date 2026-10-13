// BH-3558.1: what actually limits builds, per project. The ticket/*/* rule on
// the Controls page reads like a build cap and is not one; the caps that bind
// are per box (BUILD_SLOTS, wip flags) and per pool (bin/pool-cap.sh), and
// only the hub can read them. bin/concurrency-plan.sh --json answers it there,
// and bin/fleet-status-push.sh carries that answer as the snapshot's
// `ceilings`: an array, [] for an empty fleet, null or absent when it could
// not ask. This file turns it into rows a person reads; it never shows a 0
// that means "unlimited" or "unknown".

// The jobs route's own clamp (worker routes/jobs.js). A read that comes back
// this full is a floor, not a count.
export const RUNNING_LIMIT = 500;

// bin/concurrency-plan.sh's legend: "-" = does not apply on this route,
// "?" = could not read. BUILD_SLOTS and the pool cap both use 0 for "no
// ceiling"; the script already rewrites them to "unlimited", and "0" is
// mapped too so an older hub cannot show a zero.
function capText(v, applies) {
  const s = v === null || v === undefined ? '' : String(v);
  if (applies === false || s === '-') return 'does not apply';
  if (s === '0' || s === 'unlimited') return 'unlimited';
  if (s === '' || s === '?') return 'unreadable';
  return s;
}

// The minimum of the caps that apply. A "0" here is a real zero (the script
// turns the no-ceiling zeros into "unlimited" before the minimum), so it means
// a rule is freezing builds.
function effText(v) {
  const s = v === null || v === undefined ? '' : String(v);
  if (s === 'unlimited') return 'unlimited';
  if (s === '0') return '0 (blocks every build)';
  if (s === '' || s === '?') return 'unreadable';
  return s;
}

// Sort key for a cap cell: unlimited above any number, unknown below every one.
function capSort(text) {
  if (text === 'unlimited') return Infinity;
  const n = Number.parseInt(text, 10);
  return Number.isFinite(n) ? n : -1;
}

/**
 * The BUILD CEILINGS rows from a fleet snapshot: `{message, rows, boxRead}`.
 * `message` is the one sentence to show instead of a table, or null.
 */
export function ceilingRows(snapshot) {
  const c = snapshot ? snapshot.ceilings : undefined;
  if (!Array.isArray(c)) return { message: 'The hub has not published build ceilings yet.', rows: [], boxRead: null };
  if (!c.length) return { message: 'no projects in fleet.conf', rows: [], boxRead: null };
  const rows = c.map((r) => {
    const applies = r.applies || {};
    const slots = capText(r.box_slots, applies.box_slots);
    const pool = capText(r.pool_cap, applies.pool_cap);
    const effective = effText(r.effective);
    return {
      project: String(r.project ?? ''),
      route: String(r.route || 'unknown'),
      slots, pool, effective,
      bound_by: r.bound_by || 'no data',
      // The hub read its own BUILD_SLOTS and wip flags, not this project's box.
      unverified: r.route === 'local',
      sortSlots: capSort(slots), sortPool: capSort(pool), sortEff: capSort(effective),
    };
  });
  return { message: null, rows, boxRead: (c[0] && c[0].box_read) || 'unknown box' };
}

/** One line on what is running now, from a /jobs?status=running read. */
export function runningSummary(payload, limit = RUNNING_LIMIT) {
  const jobs = payload && Array.isArray(payload.jobs) ? payload.jobs : null;
  if (!jobs) return 'running jobs could not be read';
  const n = jobs.length;
  // A full page is a floor: the build count inside it is partial, so it is left out.
  if (n >= limit) return `${limit} or more jobs running now`;
  if (n === 0) return 'no jobs running now';
  const b = jobs.filter((j) => j && j.kind === 'build').length;
  if (n === 1) return `1 job running now, ${b ? 'a build' : 'not a build'}`;
  return `${n} jobs running now, ${b} of them builds`;
}
