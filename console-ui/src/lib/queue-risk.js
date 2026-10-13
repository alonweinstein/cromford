// BH-5430: the merge-queue break-risk score of each enqueued PR head, as GET
// /api/queue-risk answers it ({rows:[{repo, pr, head_sha, project, score,
// threshold, route, mode, reasons, created_at, updated_at}], truncated}). Pure,
// so the tests feed it payloads and the MERGE QUEUE screen only lays it out.

import { riskProject } from './risk-tiers.js';

// The worker's GET cap: a full page of this many is answered `truncated`.
export const QR_READ_LIMIT = 200;

const ROUTES = ['solo', 'batch'];
const keyOf = (repo, pr) => `${String(repo).toLowerCase()}#${Number(pr)}`;
const newer = (a, b) => {
  const c = String(a.updated_at || '').localeCompare(String(b.updated_at || ''));
  return c !== 0 ? c > 0 : (Number(a.id) || 0) > (Number(b.id) || 0);
};

// repo#pr (repo lowercased) -> the newest row for that PR, by updated_at and
// then id, whatever order the rows came in. A row with no repo or pr is skipped.
export function latestByPr(rows) {
  const m = new Map();
  if (!Array.isArray(rows)) return m;
  for (const r of rows) {
    const pr = r ? Number(r.pr) : NaN;
    if (!r || typeof r.repo !== 'string' || !r.repo || !(Number.isInteger(pr) && pr > 0)) continue;
    const k = keyOf(r.repo, r.pr);
    const cur = m.get(k);
    if (!cur || newer(r, cur)) m.set(k, r);
  }
  return m;
}

// The score row for one merge-queue row, or null. A queue row carries project
// and pr, and repo when the writer knew it: repo + pr when it is there, else
// the project name the way the RISK TIERS section names a row (riskProject).
export function scoreFor(latest, qrow) {
  if (!latest || !qrow) return null;
  if (qrow.repo) return latest.get(keyOf(qrow.repo, qrow.pr)) || null;
  for (const r of latest.values()) {
    if (Number(r.pr) === Number(qrow.pr) && riskProject(r) === qrow.project) return r;
  }
  return null;
}

// Split on the commas between tokens, not the ones inside an evidence (…).
function tokens(s) {
  const out = [];
  let depth = 0;
  let cur = '';
  for (const ch of s) {
    if (ch === '(') depth++;
    else if (ch === ')' && depth > 0) depth--;
    if (ch === ',' && depth === 0) { out.push(cur); cur = ''; } else cur += ch;
  }
  out.push(cur);
  return out.map((t) => t.trim()).filter(Boolean);
}

const words = (s) => s.replace(/[_-]+/g, ' ').trim();

// The shell's `signal:+w(evidence)` tokens in plain words, one per signal:
// shared_lib:+30(bin/lib/x.sh) -> "shared lib +30 (bin/lib/x.sh)". A token
// that is not a weighted signal (rows-unreadable, files-unavailable, train)
// is a note: its words, no weight, no path.
export function reasonLines(reasons) {
  if (typeof reasons !== 'string' || !reasons.trim()) return [];
  return tokens(reasons).map((t) => {
    const m = t.match(/^([A-Za-z0-9_-]+):\+(\d+)(?:\((.*)\))?$/);
    if (!m) return { signal: words(t), weight: null, path: null, text: words(t) };
    const signal = words(m[1]);
    const weight = Number(m[2]);
    const path = m[3] === undefined || m[3] === '' ? null : m[3];
    return { signal, weight, path, text: `${signal} +${weight}${path ? ` (${path})` : ''}` };
  });
}

// The badge for one score row. No row is '—' (unknown), never "low" or
// "batch": a PR the scorer never saw has no route to report.
export function riskBadge(row) {
  if (!row) return { label: '—', score: null, title: 'no break-risk score recorded for this PR' };
  const label = ROUTES.includes(row.route) ? row.route : '—';
  const score = Number.isInteger(row.score) ? row.score : null;
  const lines = reasonLines(row.reasons).map((l) => l.text);
  return { label, score, title: lines.length ? lines.join(', ') : 'no signal fired' };
}

// ?risk=<repo> and the #<pr> fragment -> the PR whose reasons are open, or null.
export function riskTarget(risk, hash) {
  const repo = typeof risk === 'string' ? risk.trim() : '';
  const m = typeof hash === 'string' ? hash.match(/^#?(\d+)$/) : null;
  if (!repo || !m) return null;
  return { repo, pr: Number(m[1]) };
}

// The badge's link: the project's queue with this PR's reasons open.
export function riskHref(project, repo, pr) {
  const q = new URLSearchParams();
  if (project) q.set('project', project);
  q.set('risk', repo);
  return `/merge-queue?${q.toString()}#${encodeURIComponent(pr)}`;
}
