// merge-queue routes — the merge train.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.
// BH-3156: PATCH writes a `merge_queue` config_changes row in the same batch as
// its UPDATE when status or reason actually changes; its response is unchanged.

import { json } from "../lib/http.js";
import {
  MERGE_TRANSITIONS, checkTransition, ensureTable, intOrNull, str, laneName,
} from "../lib/core.js";
import { CONFIG_KINDS, configChangeStmts } from "../lib/config-changes.js";

export const routes = [
  // ── THE MERGE QUEUE (2026-09-10) ───────────────────────────────────────
  // state/merge-queue/<project>/<pr> as rows. See the `merge_queue` comment
  // in schema.sql for what a filename could not carry and for why `blocked`
  // is re-queueable. THIS IS NOT A DONE-LIST: whether a PR has already been
  // merged stays the `ledgers` row (kind=merge) and nothing else.
  [
    "POST", "/api/merge-queue",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      const pr = intOrNull(body.pr);
      if (!project) return json(400, { error: "project is required and must match [A-Za-z0-9._-]{1,64}" });
      if (pr === null || pr <= 0) return json(400, { error: "pr must be a positive integer" });
      const existing = await env.DB.prepare(
        "SELECT * FROM merge_queue WHERE project=?1 AND pr=?2").bind(project, pr).first();
      // Only `queued` is a duplicate. A `blocked` row is re-queueable because
      // that is exactly what bin/tier2-merge-sweep.sh does with the file today
      // (it tests `<num>`, never `<num>.blocked`), and this table describes the
      // existing policy rather than inventing one.
      if (existing && existing.status === "queued") {
        return json(200, { merge: existing, duplicate: true,
          reason: `${project}#${pr} is already queued` });
      }
      // The upsert below sets status='queued' unconditionally, so this route
      // could walk a row into `queued` from a state the graph forbids. Every
      // move it makes today happens to be legal — but the GRAPH has to be the
      // one definition of that, or the next status added here disagrees with
      // PATCH silently.
      if (existing) {
        const bad = checkTransition(MERGE_TRANSITIONS, String(existing.status), "queued", "merge queue entry");
        if (bad) return json(409, { ...bad, project, pr, refused: true });
      }
      await env.DB.prepare(
        `INSERT INTO merge_queue (project, pr, status, repo, reason, enqueued_by, enqueued_at, updated_at)
         VALUES (?1,?2,'queued',?3,?4,?5,?6,?6)
         ON CONFLICT(project, pr) DO UPDATE SET
           status='queued', repo=COALESCE(?3, merge_queue.repo), reason=?4,
           enqueued_by=COALESCE(?5, merge_queue.enqueued_by), enqueued_at=?6, updated_at=?6`
      ).bind(project, pr, str(body.repo, 128), str(body.reason, 500),
             str(body.enqueued_by, 64), t).run();
      return json(201, {
        merge: {
          project, pr, status: "queued",
          repo: str(body.repo, 128) || (existing ? existing.repo : null),
          reason: str(body.reason, 500),
          enqueued_by: str(body.enqueued_by, 64) || (existing ? existing.enqueued_by : null),
          enqueued_at: t, updated_at: t,
        },
        duplicate: false, as_of: t,
      });
    },
  ],

  [
    "GET", "/api/merge-queue",
    async ({ env, url, t }) => {
      const where = [], binds = [];
      for (const col of ["project", "status"]) {
        const v = url.searchParams.get(col);
        if (v) { binds.push(v); where.push(`${col}=?${binds.length}`); }
      }
      const sql = "SELECT * FROM merge_queue"
        + (where.length ? ` WHERE ${where.join(" AND ")}` : "")
        // FIFO by enqueued_at, which is what `ls -tr` gave the directory — with
        // `pr` as the tiebreak, because two PRs enqueued in the SAME SECOND
        // otherwise come back in whatever order the scan produced, and
        // bin/merge-queue.sh materialises them by touching files whose mtimes
        // would then tie as well. A queue that reorders landings is a different
        // queue. Math.max(1, …) because SQLite reads LIMIT -1 as unbounded.
        + ` ORDER BY enqueued_at ASC, pr ASC LIMIT ${Math.min(Math.max(1, Number(url.searchParams.get("limit")) || 200), 500)}`;
      const rows = await env.DB.prepare(sql).bind(...binds).all();
      return json(200, { merge_queue: rows.results || [], as_of: t });
    },
  ],

  [
    "PATCH", "/api/merge-queue",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      const pr = intOrNull(body.pr);
      if (!project || pr === null) return json(400, { error: "project and pr are required" });
      const status = String(body.status || "").slice(0, 32);
      const cur = await env.DB.prepare(
        "SELECT * FROM merge_queue WHERE project=?1 AND pr=?2").bind(project, pr).first();
      if (!cur) return json(404, { error: `${project}#${pr} is not on the merge queue` });
      const bad = checkTransition(MERGE_TRANSITIONS, String(cur.status), status, "merge queue entry");
      if (bad) return json(409, { ...bad, project, pr });
      const reason = str(body.reason, 500);
      // After the 404/409 returns, so a refused write creates nothing.
      await ensureTable(env, "config_changes");
      await env.DB.batch([
        env.DB.prepare(
          "UPDATE merge_queue SET status=?3, reason=?4, updated_at=?5 WHERE project=?1 AND pr=?2"
        ).bind(project, pr, status, reason, t),
        ...configChangeStmts(env, CONFIG_KINDS.MERGE_QUEUE, `${project}#${pr}`, cur,
          { ...cur, status, reason }, ["status", "reason"], body.actor, body.reason, t),
      ]);
      return json(200, {
        merge: { ...cur, status, reason, updated_at: t },
        as_of: t,
      });
    },
  ],
];
