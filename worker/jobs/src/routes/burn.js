// burn routes — what a lane has spent against its cap.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";

export const routes = [
  // ── Burn rollup (phase 3) ──────────────────────────────────────────────
  // Per-day spend by project and lane, summed from the job rows themselves.
  // What this number IS: the dollars agent-call.sh posted as deltas against a
  // claimed row. What it is NOT: the fleet's whole bill — a stage that ran
  // with no claim (an unclaimed lane, a box whose worker call failed open)
  // writes cost.csv and never reaches this table. logs/orchestrator-burn.csv
  // and state/cost/ stay the accounting record; this is the coordination
  // DB's own view of it, and the console says so on the tile rather than
  // implying the two must agree.
  [
    "GET", "/api/burn",
    async ({ env, url, t }) => {
      const days = Math.min(Math.max(Number(url.searchParams.get("days")) || 14, 1), 90);
      const since = new Date(Date.parse(t) - days * 86400000).toISOString().replace(/\.\d{3}Z$/, "Z");
      const rows = await env.DB.prepare(
        `SELECT substr(created_at, 1, 10) AS day, project, kind,
                COUNT(*) AS jobs,
                SUM(COALESCE(spent_usd, 0)) AS spent_usd,
                SUM(COALESCE(budget_usd, 0)) AS budget_usd,
                SUM(CASE WHEN status='orphaned' THEN 1 ELSE 0 END) AS orphaned
           FROM jobs WHERE created_at >= ?1
          GROUP BY day, project, kind
          ORDER BY day DESC, spent_usd DESC`
      ).bind(since).all();
      return json(200, { burn: rows.results || [], days, since, as_of: t });
    },
  ],
];
