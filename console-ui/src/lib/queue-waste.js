// BH-5374 (BH-5356.2): the QUEUE WASTE section's shaping. Pure, so the tests
// feed it the payload GET /api/queue-batch-minutes/daily returns. A payload of
// the wrong shape is null, which the view renders as an error and never as 0.

// The window the section reads, and the most rows the worker reads per answer
// (worker/jobs/src/routes/queue-batch-minutes.js ROW_CAP).
export const QUEUE_WASTE_DAYS = 7;
export const QUEUE_WASTE_ROW_CAP = 2000;

export const utcDay = (ms) => new Date(ms).toISOString().slice(0, 10);

const isInt = (v) => Number.isInteger(v) && v >= 0;
const goodDay = (d) => d && typeof d.day === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(d.day)
  && ['discarded_min', 'red_min', 'reused_min', 'resets'].every((k) => isInt(d[k])) && Array.isArray(d.drafts);

// The day rows, or null when any row is malformed: one bad row makes every
// total on the screen suspect, so the whole read is refused.
export function queueWasteRows(data) {
  if (!data || !Array.isArray(data.days)) return null;
  if (!data.days.every(goodDay)) return null;
  return data.days.map((d) => ({
    day: d.day,
    discarded: d.discarded_min,
    red: d.red_min,
    // An unknown reuse is null, so it renders as a dash and sorts last.
    reused: Number(d.reused_known) === 1 ? d.reused_min : null,
    resets: d.resets,
    drafts: d.drafts,
  }));
}

// WASTED TODAY and WASTED 7D: discarded (non-merged) minutes only. No row for
// today on a good read is 0 today, because the read did see the whole window.
export function queueWasteTiles(data, nowMs) {
  const rows = queueWasteRows(data);
  if (!rows) return null;
  const today = utcDay(nowMs);
  const t = rows.find((r) => r.day === today);
  return {
    today: t ? t.discarded : 0,
    week: rows.reduce((s, r) => s + r.discarded, 0),
    reusedKnown: rows.length > 0 && rows.every((r) => r.reused !== null),
  };
}

// The GitHub PR and run of a draft, built only from the row's own fields.
export function draftLinks(d) {
  return {
    pr: `https://github.com/${d.repo}/pull/${d.draft_pr}`,
    run: `https://github.com/${d.repo}/actions/runs/${d.run_id}`,
  };
}
