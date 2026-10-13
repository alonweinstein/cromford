// cap-flags routes — explicit budget cap flags (phase 7).
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";

export const routes = [
  // ── Phase 7: explicit cap flags ────────────────────────────────────────
  // A DELIBERATELY SEPARATE ROUTE from PUT /api/catalog. That one is the
  // deploy-time sync of catalog/context-budgets.json and rewrites every lane
  // it carries; if this flag lived on that row, the next hot-deploy would
  // quietly un-explicit a cap a human set on purpose. Nothing but this route
  // ever writes budget_cap_flags.
  [
    "GET", "/api/cap-flags",
    async ({ env, t }) => {
      const rows = await env.DB.prepare(
        "SELECT * FROM budget_cap_flags ORDER BY lane ASC LIMIT 500"
      ).all();
      return json(200, { cap_flags: rows.results || [], as_of: t });
    },
  ],

  [
    "PUT", "/api/cap-flags",
    async ({ env, t, body }) => {
      const lane = String(body.lane || "").trim().slice(0, 256);
      if (!lane) return json(400, { error: "lane required" });
      // The EXACT budget_catalog key, never a ladder match: an explicit cap is a
      // statement about one row, and resolving it down the ladder would make
      // "this exact number, on purpose" bind on lanes nobody looked at.
      const explicit = (body.explicit === true || body.explicit === 1
        || body.explicit === "1" || body.explicit === "true") ? 1 : 0;
      const actor = body.actor ? String(body.actor).slice(0, 128) : null;
      const reason = body.reason ? String(body.reason).slice(0, 512) : null;
      await env.DB.prepare(
        `INSERT INTO budget_cap_flags (lane, explicit, actor, reason, updated_at)
         VALUES (?1,?2,?3,?4,?5)
         ON CONFLICT(lane) DO UPDATE SET explicit=?2, actor=COALESCE(?3, actor),
           reason=COALESCE(?4, reason), updated_at=?5`
      ).bind(lane, explicit, actor, reason, t).run();
      const row = await env.DB.prepare("SELECT * FROM budget_cap_flags WHERE lane=?1").bind(lane).first();
      return json(200, { cap_flag: row });
    },
  ],
];
