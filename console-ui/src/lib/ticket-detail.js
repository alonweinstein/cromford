// The ticket page, /t/<KEY> (BH-4991, BH-4947 wave 2). Pure: no DOM, no fetch.
// Everything here reads payloads the console already fetches: the ticket's job
// rows (api.jobs({ticket_id}), decorated by jobRows), the newest build job's
// detail (api.job: phases, stage events, transcript index), the project row
// (api.projects) and the PR payload (api.pr: title, head ref, files).

import { stationOf, lineTickets, STATIONS } from './line.js';
import { prNumberFromUrl, safeHttpsUrl } from './format.js';

const ms = (iso) => { const t = Date.parse(iso || ''); return Number.isFinite(t) ? t : 0; };
const money = (v) => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v)) ? null : Number(v));
const TICKET_RE = /^[A-Za-z][A-Za-z0-9]*-([1-9][0-9]*)$/;

function parseMeta(meta) {
  if (!meta) return {};
  if (typeof meta === 'object') return meta;
  try { const m = JSON.parse(meta); return m && typeof m === 'object' ? m : {}; } catch { return {}; }
}

// The job the page is about: the newest build row, else the newest row.
export function ticketJob(rows) {
  const list = (rows || []).filter(Boolean);
  if (!list.length) return null;
  const newest = (xs) => xs.reduce((a, b) => (ms(b.created_at) > ms(a.created_at) ? b : a));
  const builds = list.filter((r) => r.kind === 'build');
  return newest(builds.length ? builds : list);
}

// A phase name -> its station, through the line's own map (lib/line.js).
const stationOfStage = (stage) => stationOf({ kind: 'build', stage });

// Cost by stage: one row per phase name, in the order the stages ran. A stage
// whose phases have not reported spend is null (not measured), never $0. The
// total is the sum of the rows, in row order, so the card and its rows agree.
export function stageCosts(phases) {
  const by = new Map();
  for (const p of [...(phases || [])].sort((a, b) => Number(a.id) - Number(b.id))) {
    const stage = String(p.phase || 'stage');
    if (!by.has(stage)) by.set(stage, { stage, station: stationOfStage(stage), model: null, cost: null, runs: 0 });
    const r = by.get(stage);
    r.runs += 1;
    if (p.model) r.model = p.model;
    const v = money(p.spend_usd);
    if (v !== null) r.cost = (r.cost ?? 0) + v;
  }
  const rows = [...by.values()];
  return { rows, total: rows.reduce((n, r) => n + (r.cost ?? 0), 0) };
}

// "What happened": the job's stage events, oldest first, each on its station.
// The first line is the event; anything longer is output, folded on the page.
export function eventTimeline(events) {
  return [...(events || [])]
    .sort((a, b) => Number(a.id) - Number(b.id))
    .map((e) => {
      const detail = e.detail === null || e.detail === undefined ? '' : String(e.detail);
      const first = detail.split('\n')[0];
      const long = detail.includes('\n') || detail.length > 200;
      return {
        id: Number(e.id),
        at: e.created_at || e.at || null,
        stage: e.stage || null,
        station: e.stage === 'steer' ? null : stationOfStage(e.stage),
        verdict: e.verdict || null,
        actor: e.actor || null,
        text: long ? first.slice(0, 200) : detail,
        output: long ? detail : null
      };
    });
}

// The id of a station's first event, or null when the station has none.
export function firstEventOf(timeline, station) {
  const hit = (timeline || []).find((e) => e.station === station);
  return hit ? hit.id : null;
}

// The facts the headline, meta line, actions and details card show.
export function ticketFacts({ ticket, rows, detail, pr, project }) {
  const list = (rows || []).filter(Boolean);
  const job = (detail && detail.job) || ticketJob(list);
  const meta = parseMeta(job && job.meta);
  const proj = (job && job.project) || (project && project.project) || null;
  const m = TICKET_RE.exec(String(ticket || ''));
  const issue = m ? Number(m[1]) : null;
  const prUrl = safeHttpsUrl(meta.pr_url || meta.pr || '') || null;
  const repoFromPr = prUrl ? (/^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/\d+/.exec(prUrl) || [])[1] || null : null;
  const repo = (project && project.repo && project.repo !== '-' ? project.repo : null) || repoFromPr;
  // A ticket is a GitHub issue only on a project with no board API (fleet.conf
  // board prefix "-"). A board-API project keeps its tickets on its own product
  // board, where the number is not an issue number; with no project row the
  // board type is not known. Neither gets a guessed issue link.
  const bp = project ? project.board_api_prefix : undefined;
  const githubIssues = Boolean(project) && (bp === null || bp === undefined || bp === '' || bp === '-');
  const phases = (detail && detail.phases) || [];
  const newestPhase = phases.length ? phases.reduce((a, b) => (Number(b.id) > Number(a.id) ? b : a)) : null;
  const gh = pr && pr.gh ? pr.gh : null;
  const running = list.filter((r) => r.kind === 'build' && r.status === 'running');
  const line = lineTickets(list);
  const costs = list.map((r) => money(r.spent_usd)).filter((v) => v !== null);
  const ages = list.map((r) => Number(r.age_s)).filter(Number.isFinite);
  return {
    project: proj,
    repo,
    issue,
    issueUrl: githubIssues && repo && issue ? `https://github.com/${repo}/issues/${issue}` : null,
    prUrl,
    prNumber: prNumberFromUrl(prUrl),
    title: gh && gh.title ? gh.title : null,
    branch: (gh && gh.head && gh.head.ref) || meta.branch || null,
    model: newestPhase ? newestPhase.model || null : null,
    box: job ? job.box || null : null,
    verdict: pr && Array.isArray(pr.builds) && pr.builds[0] ? pr.builds[0].verdict || null : null,
    cost: costs.length ? costs.reduce((n, v) => n + v, 0) : null,
    age_s: ages.length ? Math.max(...ages) : null,
    job,
    runningJobId: running.length ? ticketJob(running).id : null,
    line: line[0] || null
  };
}

// ── the agent session feed ───────────────────────────────────────────────────

const TURN = /^\[(\d\d:\d\d:\d\d|--:--:--)\] (USER|ASSISTANT|SYSTEM)\b(?: \(([^)]*)\))?\s*(.*)$/;
const WHO = { USER: 'human', ASSISTANT: 'agent', SYSTEM: 'system' };

// bin/transcript-render.sh's text, as turns: { who, at, text }. who is agent,
// human (the prompt the build was handed), tool (a call, one line), result (a
// tool's answer, one line) or system. Thinking markers are not turns. Lines
// before the first turn are the push's provenance header and are skipped.
export function parseTranscript(body) {
  if (typeof body !== 'string' || !body) return [];
  const turns = [];
  let cur = null;
  let text = null;
  const close = () => {
    if (text && text.lines.join('\n').trim()) turns.push({ who: text.who, at: text.at, text: text.lines.join('\n').trim() });
    text = null;
  };
  for (const line of body.split('\n')) {
    const h = TURN.exec(line);
    if (h) {
      close();
      cur = { who: WHO[h[2]], at: h[1] };
      if (h[4]) text = { who: cur.who, at: cur.at, lines: [h[4]] };
      continue;
    }
    if (!cur) continue;
    if (line.startsWith('  → ')) { close(); turns.push({ who: 'tool', at: cur.at, text: line.slice(4) }); continue; }
    if (line.startsWith('  ← ')) { close(); turns.push({ who: 'result', at: cur.at, text: line.slice(4) }); continue; }
    if (line.startsWith('  · [')) continue;
    if (!text) text = { who: cur.who, at: cur.at, lines: [] };
    text.lines.push(line);
  }
  close();
  return turns;
}

// The stage is live while its job runs and a phase of it is still open.
export function sessionLive(job, phases) {
  return Boolean(job && job.status === 'running' && (phases || []).some((p) => !p.finished_at));
}

export const stationName = (i) => (Number.isInteger(i) && i >= 0 && i < STATIONS.length ? STATIONS[i] : null);
