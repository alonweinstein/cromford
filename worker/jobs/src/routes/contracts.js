// contracts routes — phase outcome contracts (phase 7).
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.
// Since BH-2618, PUT /api/contracts also batches a config_changes audit row with
// its upsert (src/lib/config-changes.js).

import { json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { CONFIG_KINDS, configChangeStmts } from "../lib/config-changes.js";

export const routes = [
  // ── Phase 7: outcome contracts ─────────────────────────────────────────
  // Empty by default. Each row says a phase must record an artifact of a
  // given kind before it may close `done`; a phase with no row closes exactly
  // as it did in phase 6.
  [
    "GET", "/api/contracts",
    async ({ env, t }) => {
      const rows = await env.DB.prepare(
        "SELECT * FROM phase_contracts ORDER BY phase ASC LIMIT 500"
      ).all();
      return json(200, { contracts: rows.results || [], as_of: t });
    },
  ],

  [
    "PUT", "/api/contracts",
    async ({ env, t, body }) => {
      const phase = String(body.phase || "").trim().slice(0, 64);
      const kind = String(body.artifact_kind || "").trim().slice(0, 64);
      if (!phase || !kind) return json(400, { error: "phase and artifact_kind are required" });
      const pattern = body.pattern ? String(body.pattern).slice(0, 256) : null;
      const note = body.note ? String(body.note).slice(0, 512) : null;
      // BH-2513: the audit row rides the same batch as the upsert.
      await ensureTable(env, "config_changes");
      const was = await env.DB.prepare("SELECT * FROM phase_contracts WHERE phase=?1").bind(phase).first();
      const after = { artifact_kind: kind, pattern, note: note ?? was?.note ?? null };
      await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO phase_contracts (phase, artifact_kind, pattern, note, updated_at)
           VALUES (?1,?2,?3,?4,?5)
           ON CONFLICT(phase) DO UPDATE SET artifact_kind=?2, pattern=?3,
             note=COALESCE(?4, note), updated_at=?5`
        ).bind(phase, kind, pattern, note, t),
        ...configChangeStmts(env, CONFIG_KINDS.CONTRACT, phase, was, after,
          ["artifact_kind", "pattern", "note"], body.actor, body.reason, t),
      ]);
      const row = await env.DB.prepare("SELECT * FROM phase_contracts WHERE phase=?1").bind(phase).first();
      return json(200, { contract: row });
    },
  ],
];
