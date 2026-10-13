// BH-3557: pure helpers for the SPEND BREAKDOWN section on /costs. The numbers
// are GET /api/metrics/cost-breakdown's (worker/jobs/src/routes/cost-breakdown.js);
// this file only names them and says how each level drills to the next. Labels
// come from the rows, never from a hardcoded model or project list.

import { fmtUsd } from './format.js';

export const BREAKDOWN_WINDOWS = [
  { key: 'today', label: 'TODAY' },
  { key: '7d', label: '7D' }
];

// `since` only: the worker defaults `until` to its own clock.
export function windowParams(key, nowMs) {
  if (key === '7d') return { since: new Date(nowMs - 7 * 86400000).toISOString() };
  return { since: new Date(nowMs).toISOString().slice(0, 10) + 'T00:00:00Z' };
}

// Each view is a list of group levels; the level after the last is the cost
// rows themselves, so every view ends at the calls behind the number.
export const BREAKDOWN_VIEWS = [
  { key: 'project', label: 'PROJECT → STAGE', levels: [['project'], ['stage']] },
  { key: 'runner', label: 'RUNNER · MODEL', levels: [['runner', 'model']] },
  { key: 'billing', label: 'BILLING', levels: [['billing_mode'], ['project']] },
  { key: 'ticket', label: 'TOP TICKETS', levels: [['ticket']] }
];
export const viewOf = (key) => BREAKDOWN_VIEWS.find((v) => v.key === key) || BREAKDOWN_VIEWS[0];

export function billingLabel(mode) {
  if (mode === 'subscription') return 'API-equivalent, not cash';
  if (mode === 'metered') return 'cash';
  return 'unknown';
}

const NULL_LABEL = { project: '(no project)', ticket: '(no ticket)' };
export function dimLabel(dim, v) {
  if (dim === 'billing_mode') return billingLabel(v);
  if (v === null || v === undefined) return NULL_LABEL[dim] || '(none)';
  return String(v);
}

export function breakdownRows(data, dims) {
  return ((data && data.groups) || []).map((g) => ({
    ...g,
    key: dims.map((d) => g[d] ?? '').join('\u0001'),
    label: dims.map((d) => dimLabel(d, g[d])).join(' · '),
    usd: g.usd ?? null,
    usdText: fmtUsd(g.usd),
    unpriced: g.unpriced_calls ?? null
  }));
}

// The child's filters: the parent's plus this row's dims. A null dim is ''
// on the wire, which the worker reads as IS NULL.
export function filtersFor(row, dims, parentFilters) {
  const f = { ...(parentFilters || {}) };
  for (const d of dims) f[d] = row[d] ?? '';
  return f;
}

// What opening `row` at `depth` of `viewKey` fetches. `key` is stable for the
// same filters and group, so a loaded child is looked up rather than refetched.
export function childRequest(viewKey, depth, row, parentFilters) {
  const levels = viewOf(viewKey).levels;
  const filters = filtersFor(row, levels[depth], parentFilters);
  const next = levels[depth + 1];
  const group = next ? next.join(',') : 'rows';
  const key = group + '?' + Object.keys(filters).sort().map((k) => `${k}=${filters[k]}`).join('&');
  return { key, filters, group, params: { ...filters, group } };
}

const buildHref = (runId, jobId) => (runId ? `/builds/${encodeURIComponent(runId)}`
  : (jobId ? `/jobs/${encodeURIComponent(jobId)}` : null));
export const ticketHref = (row) => buildHref(row && row.last_run_id, row && row.last_job_id);
export const rowHref = (r) => buildHref(r && r.run_id, r && r.job_id);

export function leafRows(data) {
  return ((data && data.rows) || []).map((r, i) => ({
    ...r, key: `${r.box || ''}|${r.ts || ''}|${i}`, href: rowHref(r), usdText: fmtUsd(r.cost_usd)
  }));
}
