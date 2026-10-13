// The DORA screen's pure half. Kept out of the screen for the same reason
// lib/outcomes.js is: this is where a regression is SILENT. A duration that
// renders as "0s" because the worker sent null, a rate shown as a percentage
// when it was already one, a table sorted on the formatted string so that "2h"
// sorts above "1d" — none of those crash, and all of them are read as facts.
//
// The worker computes the metrics. Nothing here recomputes one: the screen
// FORMATS and ORDERS what the payload carries, so the panel and the endpoint
// can never disagree about what the fleet's lead time is.

// A duration we were never given is UNKNOWN, not instant. `—` and never "0s":
// zero is the single most flattering wrong answer a lead-time cell can give.
export function fmtSeconds(s) {
  if (s === null || s === undefined || !Number.isFinite(Number(s))) return '—';
  const v = Math.max(0, Math.round(Number(s)));
  if (v < 60) return `${v}s`;
  if (v < 3600) return `${Math.round(v / 60)}m`;
  if (v < 86400) {
    const h = Math.floor(v / 3600);
    const m = Math.round((v % 3600) / 60);
    return m ? `${h}h ${m}m` : `${h}h`;
  }
  const d = Math.floor(v / 86400);
  const h = Math.round((v % 86400) / 3600);
  return h ? `${d}d ${h}h` : `${d}d`;
}

// A rate the worker could not compute (nothing merged in the window) is `—`.
// Rendering it as 0% would say "nothing came back" about a window in which
// nothing went out, which is the opposite claim.
export function fmtRate(r) {
  if (r === null || r === undefined || !Number.isFinite(Number(r))) return '—';
  return `${(Number(r) * 100).toFixed(Number(r) >= 0.1 ? 0 : 1)}%`;
}

// Deploys per day: below one a day, the useful reading is the interval, not a
// fraction — "every 2.4d" is actionable where "0.42/day" is arithmetic.
export function fmtFrequency(perDay) {
  if (perDay === null || perDay === undefined || !Number.isFinite(Number(perDay))) return '—';
  const v = Number(perDay);
  if (v === 0) return 'none';
  if (v >= 1) return `${v.toFixed(v >= 10 ? 0 : 1)}/day`;
  return `every ${(1 / v).toFixed(1)}d`;
}

// A sample too small to mean anything is marked rather than hidden: a p90 over
// two PRs is the slower of the two, and a reader who does not know that will
// act on it. Same spirit as the review gate's min_merges, deliberately NOT the
// same number — that one is a DB-driven business parameter that parks repos,
// and a second copy of it here would drift from the one that binds.
export const THIN_SAMPLE = 5;
export const isThin = (n) => Number(n || 0) > 0 && Number(n) < THIN_SAMPLE;

// The rows the per-project table renders. Flattened here rather than in the
// screen so the sort accessors can be plain numbers — sorting on a formatted
// string puts "2h" above "1d", which is a table that lies about its order.
export function projectRows(payload) {
  const projects = (payload && payload.projects) || [];
  return projects.map((p) => ({
    project: p.project || null,
    repos: p.repos || [],
    merged: Number(p.merged || 0),
    leadP50: nz(p.lead_time && p.lead_time.p50_s),
    leadP90: nz(p.lead_time && p.lead_time.p90_s),
    leadN: Number((p.lead_time && p.lead_time.n) || 0),
    leadFromJob: Number((p.lead_time && p.lead_time.from_job_n) || 0),
    leadFromPrSeen: Number((p.lead_time && p.lead_time.from_pr_seen_n) || 0),
    leadUnattributed: Number((p.lead_time && p.lead_time.unattributed_n) || 0),
    deployVerified: Boolean(p.lead_time && p.lead_time.deploy_verified),
    leadToDeploy: Number((p.lead_time && p.lead_time.to_deploy_n) || 0),
    leadToMerge: Number((p.lead_time && p.lead_time.to_merge_n) || 0),
    perDay: nz(p.deployment_frequency && p.deployment_frequency.per_day),
    // The frequency row now has two possible meanings — verified departures or
    // merges — so the screen renders the basis the worker sent rather than a
    // sentence of its own that can only ever describe one of them.
    freqDeployVerified: Boolean(p.deployment_frequency && p.deployment_frequency.deploy_verified),
    freqBasis: (p.deployment_frequency && p.deployment_frequency.basis) || null,
    freqCount: Number((p.deployment_frequency && p.deployment_frequency.count) || 0),
    freqFailed: Number((p.deployment_frequency && p.deployment_frequency.failed_departures) || 0),
    cfr: nz(p.change_failure && p.change_failure.rate),
    bad: Number((p.change_failure && p.change_failure.bad) || 0),
    mainRed: Number((p.change_failure && p.change_failure.main_red) || 0),
    ttrP50: nz(p.time_to_restore && p.time_to_restore.p50_s),
    ttrP90: nz(p.time_to_restore && p.time_to_restore.p90_s),
    ttrN: Number((p.time_to_restore && p.time_to_restore.n) || 0),
    unrestored: Number((p.time_to_restore && p.time_to_restore.unrestored) || 0),
    laneP50: nz(p.merge_lane && p.merge_lane.p50_s),
    laneP90: nz(p.merge_lane && p.merge_lane.p90_s),
    laneN: Number((p.merge_lane && p.merge_lane.n) || 0),
    slowest: p.slowest || []
  }));
}

// Null, undefined and a non-finite number are all ONE thing here: not measured.
// Coercing any of them to 0 is what turns an unmeasured lane into a fast one.
function nz(v) {
  if (v === null || v === undefined) return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

// The drill-down rows: the slowest PRs across whatever is on screen, newest
// bottleneck first. Every row carries what a link needs, because a PR cell that
// cannot be opened is a dead row.
export function slowRows(rows, { limit = 10 } = {}) {
  const out = [];
  for (const r of rows) {
    for (const s of r.slowest || []) {
      out.push({
        project: r.project,
        pr: s.pr,
        repo: s.repo,
        number: s.number,
        ticketId: s.ticket_id || null,
        jobId: s.job_id || null,
        leadS: nz(s.lead_s),
        laneS: nz(s.approval_to_merge_s),
        basis: s.lead_basis || null,
        // Which clock stopped this row — 'deploy_verified' or 'merged'. Two
        // rows in one list can differ, so it cannot be read off the project.
        end: s.lead_end || null,
        deployedAt: s.deployed_at || null,
        mergedAt: s.merged_at || null
      });
    }
  }
  return out
    .sort((a, b) => (b.leadS ?? -1) - (a.leadS ?? -1))
    .slice(0, limit);
}

// What each lead-time figure was actually measured from AND to, spelled out.
// Two bases in one column is two measurements wearing one label, so the column
// says which mix it is rather than averaging the question away. The end of the
// clock is the same problem: a project can have some rows that reached a
// verified production deploy and some that only reached main.
export function basisNote(row) {
  if (!row || !row.leadN) return 'nothing measurable in this window';
  const parts = [];
  if (row.leadFromJob) parts.push(`${row.leadFromJob} from the build job`);
  if (row.leadFromPrSeen) parts.push(`${row.leadFromPrSeen} from when the conductor first saw the PR`);
  if (row.leadUnattributed) parts.push(`${row.leadUnattributed} unattributable (excluded)`);
  if (row.leadToDeploy) {
    parts.push(row.leadToMerge
      ? `${row.leadToDeploy} ending at a verified production deploy, ${row.leadToMerge} only at the merge`
      : `all ending at a verified production deploy`);
  }
  return parts.join(' · ');
}
