// BH-4972 (BH-4964.4): the /ci screen's MERGE-QUEUE BATCHES section. Pure, so
// the tests feed it the GET /api/ci-batches payload (BH-4971) and the screen
// only lays it out. A count or a minute the ledger did not record stays null,
// never 0.

// The read window (days back from today) and the width of each side of the
// before/after median (the ticket's own definition: 7 days either side of the
// first batch-selected batch). Display constants of a read-only screen.
export const BATCH_WINDOW_DAYS = 30;
export const MEDIAN_SIDE_DAYS = 7;
// The route's max `limit`; a read that hit it answers `truncated`.
export const BATCHES_LIMIT = 5000;

const DAY_MS = 86400000;
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;

const num = (v) => ((typeof v === 'number' || (typeof v === 'string' && v.trim() !== '')) && Number.isFinite(Number(v)) ? Number(v) : null);
const str = (v) => (typeof v === 'string' && v !== '' ? v : null);

// The GitHub run a batch ran as. Only a readable owner/name and a positive
// integer id make a link; anything else is null, never a guessed URL.
export function runUrl(repo, runId) {
  if (typeof repo !== 'string' || !REPO_RE.test(repo) || repo.split('/').some((p) => p === '.' || p === '..')) return null;
  if (typeof runId !== 'number' || !Number.isSafeInteger(runId) || runId <= 0) return null;
  return `https://github.com/${repo}/actions/runs/${runId}`;
}

// The payload's rows, shaped for the table. A payload that is not
// {rows: [...]} is null: the screen shows it as a failed read, not as empty.
export function batchRows(data) {
  if (!data || !Array.isArray(data.rows)) return null;
  const rows = data.rows.map((r) => {
    const runId = num(r.run_id);
    const esc = str(r.escalation);
    return {
      runId,
      url: runUrl(r.repo, runId),
      repo: str(r.repo),
      when: str(r.completed_at) || str(r.started_at) || null,
      mode: str(r.mode),
      selected: num(r.selected),
      total: num(r.total),
      escalation: esc === null || esc.trim() === '-' || esc.trim() === '' ? null : esc,
      wallS: num(r.wall_s),
      billedMin: num(r.billed_min),
      conclusion: str(r.conclusion),
    };
  });
  return { rows, truncated: Boolean(data.truncated) };
}

// The cutover: the earliest batch-selected batch in the rows, or null.
export function cutoverIso(rows) {
  let best = null;
  for (const r of rows || []) {
    if (r.mode !== 'batch-selected' || !r.when || Number.isNaN(Date.parse(r.when))) continue;
    if (best === null || Date.parse(r.when) < Date.parse(best)) best = r.when;
  }
  return best;
}

const median = (xs) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
};

// Median billed minutes of every batch (any mode) in [cutover - 7d, cutover)
// and [cutover, cutover + 7d). n counts measured rows only; a side with none
// is null.
export function medianBatchMinutes(rows, cutover) {
  const c = cutover ? Date.parse(cutover) : NaN;
  if (Number.isNaN(c)) return { before: null, after: null, nBefore: 0, nAfter: 0 };
  const side = MEDIAN_SIDE_DAYS * DAY_MS;
  const before = [], after = [];
  for (const r of rows || []) {
    const t = r.when ? Date.parse(r.when) : NaN;
    if (Number.isNaN(t) || !Number.isFinite(r.billedMin)) continue;
    if (t >= c - side && t < c) before.push(r.billedMin);
    else if (t >= c && t < c + side) after.push(r.billedMin);
  }
  return { before: median(before), after: median(after), nBefore: before.length, nAfter: after.length };
}

const fmtMin = (v) => String(Math.round(v * 10) / 10);

// The line above the table. A before side the loaded window (or a truncated
// read) cut short says so, rather than claiming there were no batches.
export function medianLine(m, { cutover, sinceIso, truncated } = {}) {
  const c = cutover ? Date.parse(cutover) : NaN;
  const since = sinceIso ? Date.parse(sinceIso) : NaN;
  const beforeCut = !Number.isNaN(c) && (truncated || (!Number.isNaN(since) && c - MEDIAN_SIDE_DAYS * DAY_MS < since));
  const side = (v, n, cut) => (v === null ? (cut ? 'before the loaded window' : 'not enough batches yet') : `${fmtMin(v)} (${n})`);
  return `${MEDIAN_SIDE_DAYS}-day median batch minutes: before ${side(m.before, m.nBefore, beforeCut)} · after ${side(m.after, m.nAfter, false)}`;
}
