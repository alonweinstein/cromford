// cost-breakdown route — BH-3557: the fleet's spend, grouped and labelled.
//
// Before this, the only place an operator saw "the fleet spent $1,259 today"
// was the $ TODAY cell of every lane that declared no cost stage (lanes.js now
// reports null there). This is where that number moves to: one grouped read
// over cost_rows by up to two dimensions, plus a leaf read of the rows
// themselves, so every group on /costs drills down to the calls behind it.
//
// NOTHING THE CALLER SENDS IS INTERPOLATED INTO SQL. A dimension or filter
// name is looked up in DIMS (constant column names); every value is a bind.

import { json } from "../lib/http.js";
import { str, ensureColumns } from "../lib/core.js";

// dimension -> [column, max filter length]. Lengths match the POST's str() caps.
const DIMS = {
  project: ["project", 128],
  stage: ["stage", 64],
  runner: ["runner", 64],
  model: ["model", 256],
  billing_mode: ["billing_mode", 32],
  ticket: ["ticket", 128],
};
const ISO_RE = /^\d{4}-\d{2}-\d{2}T[0-9:.]+Z$/;
// Read limits, not business parameters (same footing as account-usage's LIMITS).
const GROUP_CAP = 500;
const ROWS_MAX = 500;
const ROWS_DEFAULT = 200;

const AGG = `COUNT(*) AS calls,
       SUM(cost_usd) AS usd,
       SUM(CASE WHEN billing_mode='metered' THEN COALESCE(cost_usd,0) ELSE 0 END) AS cash_usd,
       SUM(CASE WHEN billing_mode='subscription' THEN COALESCE(cost_usd,0) ELSE 0 END) AS equiv_usd,
       SUM(cost_usd IS NULL) AS unpriced_calls`;

export const routes = [
  [
    "GET", "/api/metrics/cost-breakdown",
    async ({ env, url, t }) => {
      const q = url.searchParams;
      const since = str(q.get("since"), 64) || (t.slice(0, 10) + "T00:00:00Z");
      const until = str(q.get("until"), 64) || t;
      if (!ISO_RE.test(since)) return json(400, { error: "since must be an ISO UTC timestamp" });
      if (!ISO_RE.test(until)) return json(400, { error: "until must be an ISO UTC timestamp" });

      const groupRaw = str(q.get("group"), 64) || "project";
      const rowsMode = groupRaw === "rows";
      const group = rowsMode ? [] : groupRaw.split(",");
      if (!rowsMode) {
        if (group.length > 2) return json(400, { error: "group takes at most 2 dimensions" });
        if (group.some((d) => !Object.hasOwn(DIMS, d))) {
          return json(400, { error: `group must be rows or 1-2 of ${Object.keys(DIMS).join("|")}` });
        }
        if (new Set(group).size !== group.length) return json(400, { error: "group repeats a dimension" });
      }

      let limit = ROWS_DEFAULT;
      if (rowsMode && q.has("limit")) {
        limit = Number(q.get("limit"));
        if (!Number.isInteger(limit) || limit < 1 || limit > ROWS_MAX) {
          return json(400, { error: `limit must be an integer 1..${ROWS_MAX}` });
        }
      }

      // A filter present and EMPTY (`project=`) means "has none": NULL, '' and
      // whitespace all fold into one null group below, so a `(no project)`
      // group drills down through exactly this clause.
      const binds = [since, until];
      const where = ["ts >= ?1", "ts <= ?2"];
      const filters = {};
      for (const [k, [col, max]] of Object.entries(DIMS)) {
        if (!q.has(k)) continue;
        const v = str(q.get(k), max);
        if (v === null) {
          where.push(`(${col} IS NULL OR TRIM(${col})='')`);
          filters[k] = "";
        } else {
          binds.push(v);
          where.push(`${col}=?${binds.length}`);
          filters[k] = v;
        }
      }
      const W = where.join(" AND ");

      await ensureColumns(env, "cost_rows");

      if (rowsMode) {
        const r = await env.DB.prepare(
          `SELECT ts, box, project, stage, runner, model, billing_mode, ticket, job_id, run_id, pr,
                  cost_usd, rc, duration_s
             FROM cost_rows WHERE ${W} ORDER BY ts DESC LIMIT ${limit}`
        ).bind(...binds).all();
        const rows = r.results || [];
        return json(200, { since, until, filters, rows, truncated: rows.length === limit, as_of: t });
      }

      const sel = group.map((d) => `NULLIF(TRIM(${DIMS[d][0]}),'') AS ${d}`).join(", ");
      const by = group.map((_, i) => i + 1).join(", ");
      // For the ticket grouping the bare run_id/job_id/project come from the row
      // holding MAX(ts): SQLite's documented bare-column rule for a query with
      // exactly one min()/max() aggregate (D1 is SQLite). That is what lets a
      // ticket link to its newest build or job.
      const last = group.includes("ticket")
        ? ", run_id AS last_run_id, job_id AS last_job_id, project AS last_project" : "";
      const [g, tot] = await Promise.all([
        env.DB.prepare(
          `SELECT ${sel}, ${AGG}, MAX(ts) AS last_ts${last}
             FROM cost_rows WHERE ${W}
            GROUP BY ${by} ORDER BY SUM(COALESCE(cost_usd,0)) DESC, ${by} LIMIT ${GROUP_CAP}`
        ).bind(...binds).all(),
        // A second statement, so the total is exact even when the groups are capped.
        env.DB.prepare(`SELECT ${AGG} FROM cost_rows WHERE ${W}`).bind(...binds).first(),
      ]);
      const groups = g.results || [];
      // An aggregate with no GROUP BY always returns one row; over zero rows its
      // SUMs are NULL. usd stays null (nothing priced); the others are counts
      // and sums of a measured empty window, so 0 is the true answer.
      const total = tot;
      return json(200, {
        since, until, group, filters,
        total: {
          usd: total.usd ?? null,
          cash_usd: total.cash_usd ?? 0, equiv_usd: total.equiv_usd ?? 0,
          calls: total.calls ?? 0, unpriced_calls: total.unpriced_calls ?? 0,
        },
        groups, truncated: groups.length === GROUP_CAP, as_of: t,
      });
    },
  ],
];
