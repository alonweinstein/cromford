// catalog routes — the budget catalog every lane resolves against.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  resolveLane, catalogEntries,
} from "../lib/core.js";

export const routes = [
  // ── Budget catalog ─────────────────────────────────────────────────────
  [
    "PUT", "/api/catalog",
    async ({ env, t, body }) => {
      const entries = catalogEntries(body || {});
      if (entries.size === 0) return json(400, { error: "no lanes/entries in body" });
      const stmt = env.DB.prepare(
        `INSERT INTO budget_catalog (lane, budget_usd, updated_at) VALUES (?1, ?2, ?3)
         ON CONFLICT(lane) DO UPDATE SET budget_usd=?2, updated_at=?3`
      );
      // Plain overwrite, NOT min(): the min lives in catalogEntries, within one
      // sync. Folding min() into the upsert would pin a lane to its lowest
      // value forever and make raising a ceiling in git a no-op on the fleet.
      await env.DB.batch([...entries].map(([lane, usd]) => stmt.bind(lane, usd, t)));
      return json(200, { upserted: entries.size, updated_at: t });
    },
  ],

  [
    "GET", { prefix: "/api/catalog/" },
    async ({ env, path }) => {
      // Lane keys contain slashes, so take the whole tail rather than one segment.
      const lane = decodeURIComponent(path.slice("/api/catalog/".length));
      if (!lane) return json(400, { error: "lane required" });
      const r = await resolveLane(env, lane);
      return json(200, { lane, ...r });
    },
  ],
];
