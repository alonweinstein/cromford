// retry-policies routes — how a dead claim is judged, per lane.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.
// Since BH-2618, PUT /api/retry-policies also batches a config_changes audit row with
// its upsert (src/lib/config-changes.js).

import { json } from "../lib/http.js";
import {
  resolveRetryPolicy, ensureTable,
} from "../lib/core.js";
import { CONFIG_KINDS, configChangeStmts } from "../lib/config-changes.js";

export const routes = [
  // ── Retry policy (phase 6) ─────────────────────────────────────────────
  // Empty by default: no row for a lane means today's behaviour, detection
  // with zero retries. Every row here is somebody deciding that THIS lane may
  // be re-attempted, how often, and how long the fleet waits in between.
  [
    "GET", "/api/retry-policies",
    async ({ env, t }) => {
      const rows = await env.DB.prepare("SELECT * FROM retry_policies ORDER BY lane ASC").all();
      return json(200, { policies: rows.results || [], as_of: t });
    },
  ],

  [
    "GET", { prefix: "/api/retry-policies/" },
    async ({ env, path, t }) => {
      const lane = decodeURIComponent(path.slice("/api/retry-policies/".length));
      if (!lane) return json(400, { error: "lane required" });
      const row = await resolveRetryPolicy(env, lane);
      // 200 with policy:null, not a 404: "this lane has no policy" is a real
      // answer the caller acts on, and the client's 404 branch means something
      // else entirely (a ledger miss).
      return json(200, { lane, policy: row || null, source: row ? "policy" : "none", as_of: t });
    },
  ],

  [
    "PUT", "/api/retry-policies",
    async ({ env, t, body }) => {
      const lane = String(body.lane || "").trim().slice(0, 256);
      if (!lane) return json(400, { error: "lane required" });
      const max = Number(body.max_attempts);
      if (!Number.isInteger(max) || max < 1) return json(400, { error: "max_attempts must be an integer >= 1" });
      const backoff = Number.isInteger(Number(body.backoff_seconds)) && Number(body.backoff_seconds) >= 0
        ? Number(body.backoff_seconds) : 300;
      const esc = (body.escalate_allowed === true || body.escalate_allowed === 1
        || body.escalate_allowed === "1" || body.escalate_allowed === "true") ? 1 : 0;
      const note = body.note ? String(body.note).slice(0, 512) : null;
      // BH-2513: the audit row rides the same batch as the upsert.
      await ensureTable(env, "config_changes");
      const was = await env.DB.prepare("SELECT * FROM retry_policies WHERE lane=?1").bind(lane).first();
      const after = { max_attempts: max, backoff_seconds: backoff, escalate_allowed: esc, note: note ?? was?.note ?? null };
      await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO retry_policies (lane, max_attempts, backoff_seconds, escalate_allowed, note, updated_at)
           VALUES (?1,?2,?3,?4,?5,?6)
           ON CONFLICT(lane) DO UPDATE SET max_attempts=?2, backoff_seconds=?3,
             escalate_allowed=?4, note=COALESCE(?5, note), updated_at=?6`
        ).bind(lane, max, backoff, esc, note, t),
        ...configChangeStmts(env, CONFIG_KINDS.RETRY_POLICY, lane, was, after,
          ["max_attempts", "backoff_seconds", "escalate_allowed", "note"], body.actor, body.reason, t),
      ]);
      const row = await env.DB.prepare("SELECT * FROM retry_policies WHERE lane=?1").bind(lane).first();
      return json(200, { policy: row });
    },
  ],
];
