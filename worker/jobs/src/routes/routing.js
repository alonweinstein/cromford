// routing routes — BH-1369 (BH-1027.0): builder routing as rows.
//
// One row per project: builder (local | fly1 | pool), pool_app, halted. The
// flags/ files stay what every box reader tests; bin/lib/jobs/routing.sh
// derives them from these rows once the `routing_rows` setting is on.
// Same shape as flags.js: list, exact per-project read (404 = no row), upsert.

import { json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";

// `.` and `..` pass the character class but name flags/ itself or its parent,
// so they are refused here exactly as the client's _routing_name_ok refuses
// them (a row the client cannot apply would fail routing_sync_all every tick).
const NAME_RE = /^(?!\.{1,2}$)[A-Za-z0-9._-]{1,64}$/;
const BUILDERS = new Set(["local", "fly1", "pool"]);

const MAX_CHANGES = 500;

export const routes = [
  // GET /api/routing-changes[?project=<p>][&limit=<n>] — the audit trail
  // (BH-2010), newest first; `truncated` says when the limit bit.
  [
    "GET", "/api/routing-changes",
    async ({ env, url, t }) => {
      await ensureTable(env, "routing_changes");
      const project = url.searchParams.get("project");
      if (project !== null && !NAME_RE.test(project)) return json(400, { error: "project must be a valid name" });
      const limit = Math.min(Math.max(Number(url.searchParams.get("limit")) || 100, 1), MAX_CHANGES);
      // One constant statement: no project binds NULL and the filter is true.
      const rows = await env.DB.prepare(
        "SELECT * FROM routing_changes WHERE (?2 IS NULL OR project=?2) ORDER BY id DESC LIMIT ?1"
      ).bind(limit + 1, project).all();
      const list = rows.results || [];
      return json(200, { changes: list.slice(0, limit), truncated: list.length > limit, as_of: t });
    },
  ],

  [
    "GET", "/api/routing",
    async ({ env, t }) => {
      const rows = await env.DB.prepare(
        "SELECT * FROM routing ORDER BY project ASC LIMIT 500"
      ).all();
      return json(200, { routing: rows.results || [], as_of: t });
    },
  ],

  [
    "GET", { prefix: "/api/routing/" },
    async ({ env, path, t }) => {
      // decodeURIComponent throws on a torn escape (`%E0%A4%A`); a caller's
      // malformed URL is a 400, never a 500 that reads as "worker down" (as
      // settings.js does).
      let project;
      try { project = decodeURIComponent(path.slice("/api/routing/".length)); } catch { project = null; }
      if (!project) return json(400, { error: "project required" });
      // Exact match: a row for `project-3` never answers `project-3`.
      const row = await env.DB.prepare("SELECT * FROM routing WHERE project=?1").bind(project).first();
      if (!row) return json(404, { error: "not found" });
      return json(200, { routing: row, as_of: t });
    },
  ],

  [
    "PUT", "/api/routing",
    async ({ env, t, body }) => {
      // Project and pool_app become parts of flags/ filenames on every box, so
      // the legal set is the one that cannot escape that directory.
      const project = String(body.project ?? "");
      if (!NAME_RE.test(project)) return json(400, { error: "valid project required" });
      const builder = String(body.builder ?? "");
      if (!BUILDERS.has(builder)) return json(400, { error: "builder must be local, fly1 or pool" });
      let poolApp = null;
      if (body.pool_app !== undefined && body.pool_app !== null && body.pool_app !== "") {
        poolApp = String(body.pool_app);
        if (!NAME_RE.test(poolApp)) return json(400, { error: "valid pool_app required" });
      }
      // Only a pool row has an app; local and fly1 store NULL whatever was sent.
      if (builder !== "pool") poolApp = null;
      const halted = (body.halted === true || body.halted === 1 || body.halted === "1" || body.halted === "true") ? 1 : 0;
      // COMPARE-AND-SWAP (BH-2459): `expected_updated_at` is the row's
      // updated_at as the caller read it, an opaque token compared exactly.
      // Absent (undefined or null) is the unguarded upsert below. A guard the
      // worker cannot honour is a 400, never dropped: the caller would believe
      // it was protected. updated_at is stamped to the second, so a change in
      // the same second as the write the caller read is not detected.
      const expected = body.expected_updated_at ?? null;
      if (expected !== null && (typeof expected !== "string" || expected === "" || expected.length > 64)) {
        return json(400, { error: "expected_updated_at must be the updated_at string you read" });
      }
      // THE AUDIT TRAIL (BH-2010), as model_routes keeps one: who changed the
      // row and why, before -> after, in the SAME batch as the upsert so a
      // routing change without its audit row cannot exist. An unchanged row is
      // not a decision and writes none.
      const actor = body.actor ? String(body.actor).slice(0, 128) : "api";
      const reason = body.reason ? String(body.reason).slice(0, 512) : null;
      await ensureTable(env, "routing_changes");
      const was = await env.DB.prepare("SELECT * FROM routing WHERE project=?1").bind(project).first();
      const changed = !was || was.builder !== builder || (was.pool_app ?? null) !== poolApp || Number(was.halted) !== halted;
      if (expected !== null) {
        // A guarded write never creates a row, and a row that moved since the
        // read is answered with what it is now, so the caller can re-render.
        if (!was || was.updated_at !== expected) return json(409, { error: "routing changed underneath you", routing: was || null });
        const guarded = [];
        // The audit INSERT and the UPDATE carry the same updated_at predicate
        // in one D1 batch (one transaction), so a write landing after the read
        // above leaves neither behind.
        if (changed) {
          guarded.push(env.DB.prepare(
            `INSERT INTO routing_changes
               (project, before_builder, before_pool_app, before_halted, after_builder, after_pool_app, after_halted, actor, reason, at)
             SELECT ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10 WHERE EXISTS (SELECT 1 FROM routing WHERE project=?1 AND updated_at=?11)`
          ).bind(project, was.builder, was.pool_app ?? null, Number(was.halted), builder, poolApp, halted, actor, reason, t, expected));
        }
        guarded.push(env.DB.prepare(
          "UPDATE routing SET builder=?2, pool_app=?3, halted=?4, updated_at=?5 WHERE project=?1 AND updated_at=?6"
        ).bind(project, builder, poolApp, halted, t, expected));
        const res = await env.DB.batch(guarded);
        const now = await env.DB.prepare("SELECT * FROM routing WHERE project=?1").bind(project).first();
        if (Number(res.at(-1)?.meta?.changes) !== 1) return json(409, { error: "routing changed underneath you", routing: now || null });
        return json(200, { routing: now });
      }
      const stmts = [env.DB.prepare(
        `INSERT INTO routing (project, builder, pool_app, halted, updated_at) VALUES (?1,?2,?3,?4,?5)
         ON CONFLICT(project) DO UPDATE SET builder=?2, pool_app=?3, halted=?4, updated_at=?5`
      ).bind(project, builder, poolApp, halted, t)];
      if (changed) {
        stmts.push(env.DB.prepare(
          `INSERT INTO routing_changes
             (project, before_builder, before_pool_app, before_halted, after_builder, after_pool_app, after_halted, actor, reason, at)
           VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)`
        ).bind(project, was ? was.builder : null, was ? (was.pool_app ?? null) : null,
               was ? Number(was.halted) : null, builder, poolApp, halted, actor, reason, t));
      }
      await env.DB.batch(stmts);
      const row = await env.DB.prepare("SELECT * FROM routing WHERE project=?1").bind(project).first();
      return json(200, { routing: row });
    },
  ],
];
