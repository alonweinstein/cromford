// triage-waste route — BH-3926 (BH-3921.3): the daily, per-project count of
// triage tickets the model was paid to re-read although their inputs had not
// changed since their last verdict ("paid unchanged").
//
// The count is read off the cost-row notes the triage lane writes
// (bin/lib/triage-state-waste.sh, docs/triage-state/paid-unchanged.md):
//   - a single-session row carries `ts:new=N:chg=N:due=N:cap=N:unr=N:pu=N`, and
//     `pu=` is always that token's last field, so the number after `:pu=` is
//     read as a numeric prefix: agent-call.sh's own `;cache_ttl=…` after it
//     stops the CAST, and `pu=na` (rows unreadable) reads as 0;
//   - a shard row is one ticket, noted `ts=<class>`; `ts=unchanged` adds 1.
// Only `stage='triage' AND rc=0` rows: a failed call re-triaged nothing.
//
// NOTHING THE CALLER SENDS IS INTERPOLATED INTO SQL. `days` becomes a date
// string that is bound as ?1; the LIMIT is a constant.

import { json } from "../lib/http.js";
import { ensureColumns } from "../lib/core.js";

// Read limits, not business parameters (same footing as cost-breakdown's GROUP_CAP).
const DAYS_DEFAULT = 14;
const DAYS_MAX = 60;
const ROW_CAP = 1000;

const SQL = `WITH t AS (
    SELECT substr(ts,1,10) AS day, NULLIF(TRIM(project),'') AS project, cost_usd,
      CASE WHEN instr(note,'ts:new=') > 0 AND instr(note,':pu=') > 0
             THEN CAST(substr(note, instr(note,':pu=') + 4) AS INTEGER)
           WHEN note = 'ts=unchanged' OR note LIKE 'ts=unchanged;%' OR note LIKE '%;ts=unchanged'
                OR note LIKE '%;ts=unchanged;%' THEN 1
           ELSE 0 END AS pu
    FROM cost_rows WHERE stage = 'triage' AND rc = 0 AND ts >= ?1)
  SELECT day, project, SUM(pu) AS paid_unchanged, SUM(pu > 0) AS waste_calls, COUNT(*) AS triage_calls,
         SUM(cost_usd) AS usd
    FROM t GROUP BY day, project ORDER BY day DESC, paid_unchanged DESC, project LIMIT ${ROW_CAP}`;

// days: absent or not an integer -> 14; clamped to 1..60.
function daysOf(raw) {
  if (raw === null) return DAYS_DEFAULT;
  const n = Number(raw);
  if (raw.trim() === "" || !Number.isInteger(n)) return DAYS_DEFAULT;
  return Math.min(DAYS_MAX, Math.max(1, n));
}

export const routes = [
  [
    "GET", "/api/metrics/triage-paid-unchanged",
    async ({ env, url, t }) => {
      const days = daysOf(url.searchParams.get("days"));
      const start = Date.parse(t.slice(0, 10) + "T00:00:00Z") - (days - 1) * 86400000;
      const from = new Date(start).toISOString().slice(0, 10) + "T00:00:00Z";
      await ensureColumns(env, "cost_rows");
      const r = await env.DB.prepare(SQL).bind(from).all();
      const rows = r.results || [];
      return json(200, { days, from, rows, truncated: rows.length === ROW_CAP, as_of: t });
    },
  ],
];
