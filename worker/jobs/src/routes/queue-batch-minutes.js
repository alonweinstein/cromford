// queue-batch-minutes routes — BH-5374 (BH-5356.2): the queue waste ledger, the
// CI minutes of every finished Mergify batch draft, one row per (repo,
// draft_pr, run_id).
//
// Writer: bmin_tick in bin/lib/mc-batch-minutes.sh, once per run of a draft,
// from the merge conductor's Mergify tick. A failed PUT is re-sent next tick
// with the same key, so the write is an upsert. Reader: the QUEUE WASTE section
// of the console's /ci, through GET /api/coord/queue-batch-minutes/daily.
//
// The table ships in schema.sql, which bin/harness-sync.sh applies before
// `wrangler deploy`; both handlers are d1Guarded so an unapplied table answers
// 503 "queue_batch_minutes schema not applied", never a bodiless 500.

import { json, d1Guarded } from "../lib/http.js";

const OUTCOMES = ["merged", "reset", "red", "bisect", "closed"];
const SOURCES = ["billable", "jobs"];
const DAYS_DEFAULT = 7;
const DAYS_MAX = 90;
const ROW_CAP = 2000;
const DAY_MS = 86400000;

const posInt = (v) => Number.isInteger(v) && v > 0;
const natInt = (v) => Number.isInteger(v) && v >= 0;
const optStr = (v, max) => (v === undefined || v === null || v === "" ? null : typeof v === "string" ? v.slice(0, max) : undefined);

// Strict, never clamped (D11): a value out of range is the caller's bug and is
// refused, so the ledger never stores a number nobody measured.
function validate(b) {
  if (typeof b.repo !== "string" || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(b.repo)) return "repo must be owner/name";
  if (!posInt(b.draft_pr)) return "draft_pr must be a positive integer";
  if (!posInt(b.run_id)) return "run_id must be a positive integer";
  if (!OUTCOMES.includes(b.outcome)) return `outcome must be one of: ${OUTCOMES.join(", ")}`;
  if (!natInt(b.minutes)) return "minutes must be an integer >= 0";
  if (!SOURCES.includes(b.source)) return `source must be one of: ${SOURCES.join(", ")}`;
  if (!natInt(b.reused_min)) return "reused_min must be an integer >= 0";
  if (b.reused_known !== 0 && b.reused_known !== 1) return "reused_known must be 0 or 1";
  if (typeof b.closed_at !== "string" || !/^\d{4}-\d{2}-\d{2}T/.test(b.closed_at) || Number.isNaN(Date.parse(b.closed_at))) {
    return "closed_at must be an ISO timestamp";
  }
  for (const k of ["workflow", "head_sha", "box"]) if (optStr(b[k], 256) === undefined) return `${k} must be a string`;
  return null;
}

// GET rows (newest day first) -> one entry per day that has rows.
function rollup(rows) {
  const days = new Map();
  for (const r of rows) {
    let d = days.get(r.day);
    if (!d) {
      d = { day: r.day, discarded_min: 0, red_min: 0, reset_min: 0, bisect_min: 0, merged_min: 0, reused_min: 0,
        reused_known: 1, resets: 0, drafts: [], _reset: new Set() };
      days.set(r.day, d);
    }
    if (r.outcome !== "merged") d.discarded_min += r.minutes;
    if (r.outcome === "merged") d.merged_min += r.minutes;
    if (r.outcome === "red") d.red_min += r.minutes;
    if (r.outcome === "reset") { d.reset_min += r.minutes; d._reset.add(`${r.repo}#${r.draft_pr}`); }
    if (r.outcome === "bisect") d.bisect_min += r.minutes;
    d.reused_min += r.reused_min;
    if (Number(r.reused_known) !== 1) d.reused_known = 0;
    d.drafts.push({
      repo: r.repo, draft_pr: r.draft_pr, run_id: r.run_id, outcome: r.outcome, minutes: r.minutes,
      reused_min: r.reused_min, reused_known: r.reused_known, source: r.source, workflow: r.workflow, closed_at: r.closed_at,
    });
  }
  return [...days.values()].map(({ _reset, ...d }) => ({ ...d, resets: _reset.size }));
}

export const routes = [
  [
    "PUT", "/api/queue-batch-minutes",
    async ({ env, t, body }) => {
      const b = body || {};
      const err = validate(b);
      if (err) return json(400, { error: err });
      const day = new Date(Date.parse(b.closed_at)).toISOString().slice(0, 10);
      const row = {
        repo: b.repo, draft_pr: b.draft_pr, run_id: b.run_id, outcome: b.outcome, minutes: b.minutes, source: b.source,
        reused_min: b.reused_min, reused_known: b.reused_known, workflow: optStr(b.workflow, 256),
        head_sha: optStr(b.head_sha, 256), closed_at: b.closed_at, day, box: optStr(b.box, 256), updated_at: t,
      };
      return d1Guarded("queue_batch_minutes", async () => {
        await env.DB.prepare(
          "INSERT INTO queue_batch_minutes (repo, draft_pr, run_id, outcome, minutes, source, reused_min, reused_known, " +
          "workflow, head_sha, closed_at, day, box, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14) " +
          "ON CONFLICT(repo, draft_pr, run_id) DO UPDATE SET outcome=?4, minutes=?5, source=?6, reused_min=?7, " +
          "reused_known=?8, workflow=?9, head_sha=?10, closed_at=?11, day=?12, box=?13, updated_at=?14"
        ).bind(row.repo, row.draft_pr, row.run_id, row.outcome, row.minutes, row.source, row.reused_min, row.reused_known,
          row.workflow, row.head_sha, row.closed_at, row.day, row.box, row.updated_at).run();
        return json(200, { ok: true, row });
      });
    },
  ],

  [
    "GET", "/api/queue-batch-minutes/daily",
    async ({ env, url, t }) => {
      const raw = url.searchParams.get("days");
      const n = raw === null ? DAYS_DEFAULT : /^[0-9]+$/.test(raw) ? Number(raw) : NaN;
      if (!Number.isInteger(n) || n < 1 || n > DAYS_MAX) return json(400, { error: `days must be an integer 1..${DAYS_MAX}` });
      const since = new Date(Date.parse(t) - (n - 1) * DAY_MS).toISOString().slice(0, 10);
      return d1Guarded("queue_batch_minutes", async () => {
        // One past the cap, so `truncated` says the window really was cut.
        const res = await env.DB.prepare(
          "SELECT repo, draft_pr, run_id, outcome, minutes, source, reused_min, reused_known, workflow, closed_at, day " +
          "FROM queue_batch_minutes WHERE day >= ?1 ORDER BY day DESC, draft_pr, run_id LIMIT ?2"
        ).bind(since, ROW_CAP + 1).all();
        const rows = res.results || [];
        return json(200, { days: rollup(rows.slice(0, ROW_CAP)), as_of: t, truncated: rows.length > ROW_CAP });
      });
    },
  ],
];
