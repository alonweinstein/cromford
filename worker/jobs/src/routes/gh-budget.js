// gh-budget routes — the GitHub API budget.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  intOrNull, strictInt, str, ensureTable, laneName, leaseWon, ghBudgetRow,
} from "../lib/core.js";

export const routes = [
  // ── SHARED FACTS: THE GITHUB BUDGET (BH-1043) ──────────────────────────
  // One row per TOKEN fingerprint, never per box. The upsert is MONOTONIC on
  // fetched_at: a slow box's older reading arriving late must not raise
  // `remaining` back up, or every lane reads a countdown that goes backwards
  // and the low-budget guard never fires.
  [
    "POST", "/api/gh-budget",
    async ({ env, t, body }) => {
      const fp = laneName(body.fingerprint);
      if (!fp) return json(400, { error: "fingerprint is required and must match [A-Za-z0-9._-]{1,64}" });
      const fetched = strictInt(body.fetched_at);
      if (fetched === null || fetched < 0) {
        return json(400, { error: "fetched_at must be a non-negative integer (epoch seconds)" });
      }
      const core = (body.core && typeof body.core === "object") ? body.core : {};
      const gql = (body.graphql && typeof body.graphql === "object") ? body.graphql : {};
      await ensureTable(env, "gh_budget");
      const r = await env.DB.prepare(
        "INSERT INTO gh_budget (fingerprint, core_remaining, core_limit, core_reset, "
        + "graphql_remaining, graphql_limit, graphql_reset, fetched_at, box, updated_at) "
        + "VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10) "
        + "ON CONFLICT(fingerprint) DO UPDATE SET core_remaining=excluded.core_remaining, "
        + "core_limit=excluded.core_limit, core_reset=excluded.core_reset, "
        + "graphql_remaining=excluded.graphql_remaining, graphql_limit=excluded.graphql_limit, "
        + "graphql_reset=excluded.graphql_reset, fetched_at=excluded.fetched_at, "
        + "box=excluded.box, updated_at=excluded.updated_at "
        + "WHERE excluded.fetched_at >= gh_budget.fetched_at"
      ).bind(
        fp, intOrNull(core.remaining), intOrNull(core.limit), intOrNull(core.reset),
        intOrNull(gql.remaining), intOrNull(gql.limit), intOrNull(gql.reset),
        fetched, str(body.box, 64), t
      ).run();
      return json(200, { wrote: leaseWon(r), row: await ghBudgetRow(env, fp), as_of: t });
    },
  ],

  [
    "GET", "/api/gh-budget",
    async ({ env, url, t }) => {
      const fp = laneName(url.searchParams.get("fingerprint"));
      if (!fp) return json(400, { error: "fingerprint is required and must match [A-Za-z0-9._-]{1,64}" });
      await ensureTable(env, "gh_budget");
      // ALWAYS 200 with `row: null` when nothing is stored: the client treats a
      // 404 as an outage, and "no reading yet" is not an outage — it is the
      // normal state of the first box to ask after a deploy.
      return json(200, { row: await ghBudgetRow(env, fp), as_of: t });
    },
  ],
];
