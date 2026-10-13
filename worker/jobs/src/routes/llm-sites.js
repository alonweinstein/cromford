// llm-sites routes — BH-2553 (BH-2540.0) contract, filled in by BH-2554
// (BH-2540.1): GET /api/metrics/llm-sites answers one row per catalog site.
//
// The payload shape (the /rows route is still the contract stub):
//
// GET /api/metrics/llm-sites ->
//   { sites: [{ id, lane, stage, stages, kind, runners, script, note,
//               attribution, shared,
//               usd_24h: {by_runner, total} | null, usd_7d: {by_runner, total} | null,
//               cash_7d, notional_7d, unknown_billing_7d, unpriced_7d, calls_7d,
//               refused_7d: {gate, guard, context_kill},
//               today_usd, guard_k, guard_enforced, kill_tokens, cap_usd_day,
//               knobs_bound: [], badges: {no_row, no_knob, no_kill} }],
//     windows: { since_7d, since_24h, today }, as_of, incomplete: [] }
// Money is null when absent, never 0 standing in for unknown.
// `attribution`, `shared` and `stages` come from lib/llm-sites-catalog.js.
//
// GET /api/metrics/llm-sites/rows?site=<id> (routes/llm-site-rows.js) ->
//   { site: <catalog record>,
//     rows: [{ ts, box, project, ticket, pr, stage, lane_id, runner, model,
//              billing_mode, rc, cost_usd, row_source, note }],
//     truncated, reason?: 'no-stage', incomplete: [] }

import { json } from "../lib/http.js";
import { ensureColumns, LANES_REGISTRY } from "../lib/core.js";
import { LLM_SITES } from "../lib/llm-sites-catalog.js";
import { siteRows } from "../lib/llm-sites.js";
import BUDGETS from "../../../../catalog/context-budgets.json" with { type: "json" };

// ONE constant statement over the last 7 days. A group whose rows are all
// unpriced sums to NULL, so it adds no money; `unpriced` counts it instead.
// Refusal classes: gate is a refused row that is not the call guard's; guard
// is the call guard's own prefix; context_kill is a kill or a cliff avoided.
const AGG_SQL = `SELECT stage, lane_id, runner, billing_mode, COUNT(*) AS calls,
  SUM(cost_usd) AS usd_7d,
  SUM(CASE WHEN ts >= ?2 THEN cost_usd END) AS usd_24h,
  SUM(CASE WHEN ts >= ?3 THEN cost_usd END) AS usd_today,
  SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END) AS unpriced,
  SUM(CASE WHEN row_source = 'refused' AND COALESCE(note, '') NOT LIKE 'refused:call-guard%' THEN 1 ELSE 0 END) AS r_gate,
  SUM(CASE WHEN COALESCE(note, '') LIKE 'refused:call-guard%' THEN 1 ELSE 0 END) AS r_guard,
  SUM(CASE WHEN COALESCE(note, '') LIKE '%context-kill:%' OR COALESCE(note, '') LIKE '%cliff-avoided:%' THEN 1 ELSE 0 END) AS r_ctx
FROM cost_rows WHERE ts >= ?1
GROUP BY stage, lane_id, runner, billing_mode`;

const SETTINGS_SQL = "SELECT key, value, actor FROM settings WHERE key LIKE 'lane.%.llm_%' OR key LIKE 'lib.call-guard.%'";

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

export const routes = [
  ["GET", "/api/metrics/llm-sites", async ({ env, t }) => {
    await ensureColumns(env, "cost_rows");
    const now = Date.parse(t);
    const windows = { since_7d: iso(now - 7 * 864e5), since_24h: iso(now - 864e5), today: t.slice(0, 10) + "T00:00:00Z" };
    let agg;
    try {
      agg = (await env.DB.prepare(AGG_SQL).bind(windows.since_7d, windows.since_24h, windows.today).all()).results || [];
    } catch {
      return json(500, { error: "llm-sites aggregate failed" });
    }
    // A failed settings read nulls the knob fields and names itself in
    // `incomplete`; it never falls back to defaults or fails the page.
    let settings;
    try {
      settings = (await env.DB.prepare(SETTINGS_SQL).all()).results || [];
    } catch {
      settings = null;
    }
    const { sites, incomplete } = siteRows({ sites: LLM_SITES, agg, settings, registry: LANES_REGISTRY, budgets: BUDGETS });
    return json(200, { sites, windows, as_of: t, incomplete });
  }],
];
