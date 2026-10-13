// job-events routes — stage events appended to a job.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";

export const routes = [
  // ── Stage events ───────────────────────────────────────────────────────
  [
    "POST", /^\/api\/jobs\/([^/]+)\/events$/,
    async ({ env, t, body, m: evMatch }) => {
      const id = decodeURIComponent(evMatch[1]);
      const job = await env.DB.prepare("SELECT id, stage FROM jobs WHERE id=?1").bind(id).first();
      if (!job) return json(404, { error: "no such job" });
      const actor = String(body.actor || "").slice(0, 128);
      if (!actor) return json(400, { error: "actor required" });
      const r = await env.DB.prepare(
        `INSERT INTO stage_events (job_id, stage, verdict, actor, detail, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)`
      ).bind(
        id,
        String(body.stage || job.stage).slice(0, 64),
        body.verdict ? String(body.verdict).slice(0, 64) : null,
        actor,
        body.detail ? String(body.detail).slice(0, 4000) : null,
        t
      ).run();
      return json(201, { event_id: r.meta.last_row_id, job_id: id, created_at: t });
    },
  ],
];
