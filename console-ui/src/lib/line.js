// "The line" (BH-4990, wave 1 of BH-4947): a ticket's walk from triage to
// close drawn as eight stations, and the Jobs screen's headline. Pure: no DOM,
// no fetch. Everything here reads decorated jobRows() rows (src/lib/jobs.js).
//
// STATION_OF_* below is UI vocabulary, the same standing as STAGE_STEP in
// src/lib/stages.js: which of the eight stations a row's kind and stage mean.
// It is not a business parameter. A kind or stage it does not name maps to
// null, and the screen says "station not known" rather than guess one.

import { clockTime } from './format.js';

export const STATIONS = ['Triage', 'Plan', 'Build', 'Review', 'Merge', 'Deploy', 'Prod QA', 'Close'];

// A build row's stage or phase -> station. Plan 1, build 2, review 3.
const BUILD_STAGE = {
  plan: 1, planning: 1, size_gate: 1, squash: 1,
  execute: 2, executing: 2, fix: 2, fix_round: 2, tests_red: 2, tests_green: 2, budget_stop: 2,
  review: 3, reviewing: 3, semgrep: 3, e2e: 3, qa: 3, tier: 3, pr: 3, pr_opened: 3, pr_created: 3
};
function buildStation(stage) {
  const s = String(stage || '').toLowerCase();
  if (Object.prototype.hasOwnProperty.call(BUILD_STAGE, s)) return BUILD_STAGE[s];
  if (/^plan_/.test(s)) return 1;
  if (/^(pool|fly)_/.test(s)) return 2;
  return null;
}

// The station a row is at, or null when its kind and stage say nothing we know.
export function stationOf(row) {
  if (!row) return null;
  const kind = String(row.kind || '').toLowerCase();
  if (kind === 'triage') return 0;
  if (kind === 'build') return buildStation((row.phase && row.phase.name) || row.stage);
  if (kind === 'lead_review') return 3;
  if (kind.includes('merge')) return 4;
  if (kind === 'migration' || kind.startsWith('deploy')) return 5;
  if (kind.includes('qa')) return 6;
  if (kind.includes('close')) return 7;
  return null;
}

// A row in one of these states keeps its ticket on the line.
const ON_LINE = ['running', 'stalled', 'quiet', 'parked', 'queued_for_retry', 'orphaned'];
const HELD = ['parked', 'queued_for_retry'];
const FAILED = ['orphaned', 'stalled'];

const money = (v) => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v)) ? 0 : Number(v));
const ms = (iso) => { const t = Date.parse(iso || ''); return Number.isFinite(t) ? t : 0; };

// One entry per (project, ticket) with a row on the line: where it is (`at`),
// how it is doing there (`state`: now, held or fail), when it reached each
// station (`times`, HH:MMZ or null), what all its rows spent and how old the
// oldest is. Furthest along first, then oldest.
export function lineTickets(rows) {
  const by = new Map();
  for (const r of rows || []) {
    if (!r || !r.key) continue;
    const id = `${r.project || ''}\u0000${r.key}`;
    if (!by.has(id)) by.set(id, []);
    by.get(id).push(r);
  }
  const out = [];
  for (const group of by.values()) {
    const live = group.filter((r) => ON_LINE.includes(r.state));
    if (!live.length) continue;
    const newest = live.reduce((a, b) => (ms(b.created_at) > ms(a.created_at) ? b : a));
    const first = new Array(STATIONS.length).fill(null);
    for (const r of group) {
      const i = stationOf(r);
      if (i === null) continue;
      const t = ms(r.created_at);
      if (t && (first[i] === null || t < first[i])) first[i] = t;
    }
    const ages = group.map((r) => Number(r.age_s)).filter(Number.isFinite);
    out.push({
      key: newest.key,
      project: newest.project || null,
      box: newest.box || null,
      lane: newest.lane,
      kind: newest.kind || null,
      stage: (newest.phase && newest.phase.name) || newest.stage || null,
      at: stationOf(newest),
      state: HELD.includes(newest.state) ? 'held' : FAILED.includes(newest.state) ? 'fail' : 'now',
      times: first.map((t) => (t === null ? null : clockTime(new Date(t).toISOString()))),
      cost: group.reduce((n, r) => n + money(r.spent_usd), 0),
      age_s: ages.length ? Math.max(...ages) : null
    });
  }
  return out.sort((a, b) => ((b.at ?? -1) - (a.at ?? -1)) || ((b.age_s ?? 0) - (a.age_s ?? 0)));
}

const LOG_TONE = {
  running: 'live', done: 'ok',
  stalled: 'bad', orphaned: 'bad', failed: 'bad',
  parked: 'warn', queued_for_retry: 'warn', quiet: 'warn', budget_stopped: 'warn'
};
const stamp = (r) => r.last_beat_at || r.updated_at || r.created_at;

// The newest `n` rows as log lines: when, which stage, which ticket, what the
// last beat said (or the state in words) and a tone.
export function lineLog(rows, n = 12) {
  return [...(rows || [])]
    .sort((a, b) => ms(stamp(b)) - ms(stamp(a)))
    .slice(0, n)
    .map((r) => ({
      id: r.id,
      ts: clockTime(stamp(r)),
      stage: (r.phase && r.phase.name) || r.stage || null,
      key: r.key || null,
      project: r.project || null,
      text: r.beat_note ? String(r.beat_note) : String(r.state || 'unknown').replace(/_/g, ' '),
      tone: LOG_TONE[r.state] || 'warn'
    }));
}

const jobs = (n) => `${n} ${n === 1 ? 'job' : 'jobs'}`;
const lanes = (n) => `${n} ${n === 1 ? 'lane' : 'lanes'}`;
const num = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);

// The Jobs headline, from jobCounts() and laneCounts() and nothing else.
export function jobsHeadline(counts = {}, laneCounts = {}) {
  const c = { running: num(counts.running), parked: num(counts.parked), orphaned: num(counts.orphaned),
    stalled: num(counts.stalled), queued: num(counts.queued_for_retry) };
  const silent = num(laneCounts.stale);
  const undeclared = num(laneCounts.unexpected);
  const lede = [];
  if (c.stalled) lede.push(`${jobs(c.stalled)} stopped beating.`);
  if (c.queued) lede.push(`${jobs(c.queued)} queued for retry.`);
  if (silent) lede.push(`${lanes(silent)} silent.`);
  if (undeclared) lede.push(`${lanes(undeclared)} undeclared.`);
  // Not "every job is beating": a quiet row never beat at all, and a box on
  // an old bin/ never sends beats. What holds is that none stopped.
  if (!c.stalled && !c.orphaned) lede.unshift('No claimed job has stopped beating.');
  return {
    line1: `${jobs(c.running)} on the line.`,
    line2: `${c.parked} parked. ${c.orphaned} lost.`,
    lede: lede.join(' ')
  };
}

export const ticketPath = (key) => `/t/${encodeURIComponent(key)}`;
