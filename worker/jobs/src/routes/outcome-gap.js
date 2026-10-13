// outcome-gap route — BH-4017 (BH-3987.3): per project, the tickets with
// priced build-stage spend over min_usd and no merged harness PR as of the
// day's end. Read by bin/daily-digest.sh into the digest's Outcome gap block.
// Read-only: it never writes and never calls ensureColumns (every column it
// reads is in the base schema.sql). A thrown read is not caught into a 200.
//
// The definition, params and SQL are in lib/outcome-gap.js.

import { json } from "../lib/http.js";
import { parseGapParams, gapSql, unpricedSql, foldGap, GROUP_MAX } from "../lib/outcome-gap.js";

export const routes = [
  [
    "GET", "/api/metrics/outcome-gap",
    async ({ env, url, t }) => {
      const p = parseGapParams(url.searchParams, t);
      if (p.error) return json(400, { error: p.error });
      const { win, stages } = p;

      const r = await env.DB.prepare(gapSql(stages.length))
        .bind(p.from, win.to, p.minUsd, p.grace, ...stages, GROUP_MAX + 1).all();
      const up = await env.DB.prepare(unpricedSql(stages.length)).bind(p.from, win.to, ...stages).first();
      if (typeof up?.n !== "number") throw new Error("outcome-gap: the unpriced count read returned no number");

      const fold = foldGap(r.results || [], { limit: p.limit, groupMax: GROUP_MAX });
      return json(200, {
        ok: true,
        day: win.day,
        from: p.from,
        to: win.to,
        min_usd: p.minUsd,
        days: p.days,
        lookback: p.lookback,
        stages,
        total_usd: fold.total_usd,
        tickets_n: fold.tickets_n,
        unpriced_calls: up.n,
        projects: fold.projects,
        truncated: fold.truncated,
      });
    },
  ],
];
