// Everything the mission view derives from a /api/coord/jobs/:id/live answer,
// kept out of the screen so it can be driven on bare node with no DOM.
//
// The shape of the problem: a build page is watched while money is being spent,
// over a stream that arrives late, twice, out of order, capped, or not at all.
// Every function here exists because the honest answer in one of those states
// is not the obvious one — an absent spend is not $0.00, an absent status is
// not "running", and a build whose job row we cannot find has to say so rather
// than borrow the newest job of the project and quote its spend.

import { stageProgress, VERDICT_TONE } from './stages.js';
import { clockTime } from './format.js';

// What the route sends at most per call (#520). A page this size means there
// are probably more behind it, and the cursor drains them on the next tick.
export const LIVE_EVENT_CAP = 200;

const EMPTY = { job: null, phases: [], events: [], cursor: 0, spend_usd: null, capped: false };

// `meta` reaches the browser as whatever D1 stored — an object, a JSON string,
// or something that was never JSON. None of those may throw here.
function parseMeta(meta) {
  if (!meta) return null;
  if (typeof meta === 'object') return meta;
  try { return JSON.parse(meta); } catch { return null; }
}

// bkey is `build:<project>:<ticket>:<build-dir>`, and that last field is what
// bin/run-build.sh also writes into the job's meta.build — the only exact join
// between a console build row and a coordination job.
function buildDir(bkey) {
  const parts = String(bkey || '').split(':');
  return parts.length > 3 ? parts.slice(3).join(':') : null;
}

const numberOr = (v, fallback) => {
  if (v === null || v === undefined || v === '') return fallback;
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
};

// Which job row IS this build. The console build row carries no job id, so the
// join is made here: same ticket, same kind, and preferably the same build dir.
// A near miss returns null on purpose — showing the wrong job's spend on a
// build page is worse than showing no spend at all.
export function matchBuildJob(build, jobs) {
  if (!build || !build.ticket_key) return null;
  const rows = Array.isArray(jobs) ? jobs : [];
  const candidates = rows.filter((j) => j && j.kind === 'build' && j.ticket_id === build.ticket_key);
  if (!candidates.length) return null;

  const dir = buildDir(build.bkey);
  if (dir) {
    const exact = candidates.find((j) => {
      const m = parseMeta(j.meta);
      return m && m.build === dir;
    });
    if (exact) return exact;
  }

  // No dir on file (an older job row): the newest attempt at this ticket is the
  // best available answer. Ties and unparseable dates keep the list's own
  // order, which the jobs route already returns newest first.
  let best = candidates[0];
  let bestAt = Date.parse(best.created_at || '');
  for (const j of candidates.slice(1)) {
    const t = Date.parse(j.created_at || '');
    if (Number.isFinite(t) && (!Number.isFinite(bestAt) || t > bestAt)) { best = j; bestAt = t; }
  }
  return best;
}

// One tick folded into what is already on screen. Job, phases and spend are the
// server's current truth and get REPLACED; events are a cursor walk and
// accumulate, deduped on the server-side id that produced them.
export function mergeLive(prev, payload) {
  const base = prev && typeof prev === 'object' ? prev : EMPTY;
  const p = payload && typeof payload === 'object' ? payload : {};
  const incoming = Array.isArray(p.events) ? p.events : [];

  const seen = new Set((base.events || []).map((e) => e.id));
  const events = (base.events || []).slice();
  for (const e of incoming) {
    if (!e || seen.has(e.id)) continue;
    seen.add(e.id);
    events.push(e);
  }
  events.sort((a, b) => numberOr(a.id, 0) - numberOr(b.id, 0));

  const maxId = events.reduce((m, e) => Math.max(m, numberOr(e.id, 0)), 0);
  // A cursor the route sent wins; otherwise the highest id we hold. Never zero
  // while we hold events — that would re-fetch the whole build every 5s.
  const cursor = typeof p.cursor === 'number' && Number.isFinite(p.cursor)
    ? p.cursor
    : (maxId || numberOr(base.cursor, 0));

  return {
    job: p.job || null,
    phases: Array.isArray(p.phases) ? p.phases : [],
    events,
    cursor,
    spend_usd: p.spend_usd === undefined ? null : p.spend_usd,
    // A full page is not the end of the stream, and the pane says so.
    capped: incoming.length >= LIVE_EVENT_CAP
  };
}

// Whether another tick is worth arming. Only a job that SAYS it is running gets
// one: an absent or unrecognised status is "we do not know", and the honest
// response to that is to stop polling and show the last fact, not to hammer the
// worker forever on the chance it means running.
export function shouldPollLive(live, build) {
  if (live === null || live === undefined) return !(build && build.merged);
  if (!live.job) return false;
  return String(live.job.status || '') === 'running';
}

// The money, or nothing. Never 0 for "not on file": a rail that reads $0.00
// while a model is burning budget is the exact lie this screen exists to stop.
export function liveSpend(live) {
  if (!live) return null;
  const direct = numberOr(live.spend_usd, null);
  if (direct !== null) return direct;

  const phases = Array.isArray(live.phases) ? live.phases : [];
  let sum = 0;
  let any = false;
  for (const p of phases) {
    const v = numberOr(p && p.spend_usd, null);
    if (v === null) continue;
    sum += v;
    any = true;
  }
  return any ? sum : null;
}

const PASSING = new Set(['PASS', 'PASSED', 'APPROVE', 'GREEN']);

// How many gates this build has cleared. Counted from the verdicts rather than
// from a list of stage names, because #520 is free to name a new gate and this
// number must not quietly stop counting when it does.
export function gatesPassed(events) {
  const rows = Array.isArray(events) ? events : [];
  return rows.filter((e) => e && e.verdict && PASSING.has(String(e.verdict).toUpperCase())).length;
}

// The furthest step anything says the build has reached — the beat the hub
// wrote, or an event that has overtaken it. An unknown stage contributes
// nothing, so a stage from a future version of run-build.sh can never drag the
// strip backwards or forwards.
export function liveStep(build, events) {
  const beat = stageProgress(build && build.stage, build && build.merged);
  if (build && build.merged) return beat.step;
  let step = beat.step;
  for (const e of (Array.isArray(events) ? events : [])) {
    const p = stageProgress(e && e.stage);
    if (p.known && p.step > step) step = p.step;
  }
  return step;
}

// `at` is what #520's route sends; `created_at` is the column stage_events
// actually has. Both arrive depending on which read answered, so both are read.
const eventAt = (e) => (e && (e.at || e.created_at)) || null;

// The line under the active step: the most recent thing that happened AT that
// step, which is what a person watching the page wants to know.
export function subStage(events, step) {
  const rows = (Array.isArray(events) ? events : []).filter((e) => {
    const p = stageProgress(e && e.stage);
    return p.known && p.step === step;
  });
  if (!rows.length) return null;
  let best = rows[0];
  for (const e of rows) if (numberOr(e.id, 0) >= numberOr(best.id, 0)) best = e;
  return { detail: best.detail || null, verdict: best.verdict || null, at: eventAt(best) };
}

// The progress log, oldest first: the pane scrolls to the bottom, so ascending
// order is what puts the newest line where the eye already is.
export function logRows(events) {
  return (Array.isArray(events) ? events : [])
    .slice()
    .sort((a, b) => numberOr(a && a.id, 0) - numberOr(b && b.id, 0))
    .map((e) => ({
      id: e.id,
      when: clockTime(eventAt(e)),
      stage: e.stage || 'unknown',
      verdict: e.verdict || null,
      detail: e.detail || '',
      tone: (e.verdict && VERDICT_TONE[String(e.verdict).toUpperCase()]) || null
    }));
}

// The tone vocabulary is green/red/warn; the stylesheet's pill modifiers are
// the base (green), --dead and --warn. This is the one place they are joined,
// so a new tone cannot ship as a class name that styles nothing.
export function pillClass(tone) {
  if (tone === 'green') return 'pill';
  if (tone === 'red') return 'pill pill--dead';
  if (tone === 'warn') return 'pill pill--warn';
  return 'pill pill--muted';
}
