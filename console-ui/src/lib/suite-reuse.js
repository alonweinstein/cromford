// BH-5369 (BH-5354.3): the SUITE REUSE section's pure half. The worker answers
// GET /api/suite-results/saved and /runs; these turn the answers into rows and
// tiles so the view is a pure function of props (the CiHealth split).

export const SUITE_REUSE_DAYS = 14;
export const SUITE_REUSE_RUNS_LIMIT = 200;

const min1 = (s) => Math.round((Number(s) || 0) / 6) / 10;
const DAY_MS = 86400000;
const utcDay = (ms) => new Date(ms).toISOString().slice(0, 10);

// Null when the answer has no rows array: absent is not zero (D11).
export function savedRows(data) {
  if (!data || !Array.isArray(data.rows)) return null;
  return data.rows.map((r) => ({ ...r, key: `${r.day}|${r.repo}|${r.class}`, savedMin: min1(r.saved_s) }));
}

// CI minutes only. Builder minutes are counted apart and never added to CI.
export function savedTiles(rows, nowMs) {
  const today = utcDay(nowMs);
  const weekStart = utcDay(nowMs - 6 * DAY_MS);
  let todayS = 0; let weekS = 0; let builderWeekS = 0;
  for (const r of rows || []) {
    if (r.day < weekStart || r.day > today) continue;
    const s = Number(r.saved_s) || 0;
    if (r.class === 'ci') {
      weekS += s;
      if (r.day === today) todayS += s;
    } else if (r.class === 'builder') {
      builderWeekS += s;
    }
  }
  return { todayMin: min1(todayS), weekMin: min1(weekS), builderWeekMin: min1(builderWeekS) };
}

const ghUrl = (u) => (typeof u === 'string' && u.startsWith('https://github.com/') ? u : null);

export function runRows(data) {
  if (!data || !Array.isArray(data.rows)) return null;
  return {
    capped: data.capped === true,
    rows: data.rows.map((r) => ({
      ...r,
      savedMin: min1(r.saved_s),
      url: ghUrl(r.url),
      reused_suites: Array.isArray(r.reused_suites) ? r.reused_suites : null,
    })),
  };
}

// Null when the ledger did not record which suites the run reused.
export function reusedSuiteRows(run) {
  if (!run || !Array.isArray(run.reused_suites)) return null;
  return run.reused_suites.map((s, i) => ({
    key: `${s.suite}|${i}`,
    suite: s.suite ?? null,
    from_run: s.from_run ?? s.run_id ?? null,
    saved_s: s.saved_s ?? s.duration_s ?? null,
  }));
}

// The worker's 404 is `unknown endpoint`: the routes are not deployed there yet.
export const isNotDeployed = (err) => Boolean(err && err.status === 404);
