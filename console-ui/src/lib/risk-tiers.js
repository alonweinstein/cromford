// BH-5022: the risk tier of each PR head, as GET /api/risk-tiers answers it
// ({rows:[{repo, pr, head_sha, project, tier, mode, action, reasons, ...}],
// truncated}). Pure, so the tests feed it payloads and the screens only lay
// the rows out.

export const RISK_TIERS = ['low', 'medium', 'high'];

// low < medium < high, for the TIER column's sort.
export const TIER_ORDER = { low: 0, medium: 1, high: 2 };

// The worker's GET cap: a full page of this many is answered `truncated`.
export const RISK_READ_LIMIT = 200;

// A ?tier= value: one of the three tiers, else null (= every tier).
export function normTier(v) {
  const t = typeof v === 'string' ? v.trim().toLowerCase() : '';
  return RISK_TIERS.includes(t) ? t : null;
}

// The rows of one tier. null / 'all' keeps every row; no rows array is [].
export function riskTierRows(data, tier) {
  const rows = data && Array.isArray(data.rows) ? data.rows : [];
  if (tier === null || tier === undefined || tier === 'all') return rows;
  return rows.filter((r) => r && r.tier === tier);
}

// The row classifying the PR's live head, or null. The worker answers newest
// first, so the first match is the latest classification of that head.
export function liveHeadTier(rows, liveHead) {
  if (!Array.isArray(rows) || typeof liveHead !== 'string' || !liveHead) return null;
  return rows.find((r) => r && r.head_sha === liveHead) || null;
}

// The repo's name part, for a row the worker gave no project.
export function riskProject(row) {
  if (row && row.project) return row.project;
  const repo = row && typeof row.repo === 'string' ? row.repo : '';
  return repo.includes('/') ? repo.slice(repo.lastIndexOf('/') + 1) : repo;
}
