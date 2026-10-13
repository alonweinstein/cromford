// artifacts routes — the cross-job artifact search.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";

export const routes = [
  // ── THE ARTIFACT FEED (2026-09-10) ─────────────────────────────────────
  // Artifacts were readable one job at a time: given a job id, its rows.
  // That is the right shape for the console's drill-down and the wrong one
  // for the question a box's results sweep asks — "which builds of MY project
  // finished somewhere else and have a result I have not seen".
  //
  // Until now that answer arrived as a FILE, pushed to the owning box over
  // scp by bin/fly-pool.sh and bin/fly-results-ingest.sh. One join answers it
  // instead, and the BOX column is what makes it usable: a sweep must skip
  // its own builds, or it would stage a second copy of a close-out it has
  // already posted.
  [
    "GET", "/api/artifacts",
    async ({ env, url, t }) => {
      const where = [], binds = [];
      const add = (frag, v) => { binds.push(v); where.push(frag.replace("?", `?${binds.length}`)); };
      const project = url.searchParams.get("project");
      if (project) add("j.project=?", project);
      const kind = url.searchParams.get("kind");
      if (kind) add("a.artifact_kind=?", kind);
      const jobKind = url.searchParams.get("job_kind");
      if (jobKind) add("j.kind=?", jobKind);
      // `since` is the caller's own watermark. The CLOCK is the server's — the
      // only one every box agrees on — so a sweep asks for "newer than the last
      // updated_at I saw" rather than trusting its own wall clock.
      const since = url.searchParams.get("since");
      if (since) add("a.updated_at>?", since);
      const sql = `SELECT a.job_id, a.artifact_kind, a.artifact_ref, a.detail,
                          a.actor, a.updated_at,
                          j.project, j.ticket_id, j.kind AS job_kind, j.box, j.status
                     FROM job_artifacts a JOIN jobs j ON j.id = a.job_id`
        + (where.length ? ` WHERE ${where.join(" AND ")}` : "")
        + ` ORDER BY a.updated_at DESC LIMIT ${Math.min(Math.max(1, Number(url.searchParams.get("limit")) || 100), 500)}`;
      const rows = await env.DB.prepare(sql).bind(...binds).all();
      return json(200, { artifacts: rows.results || [], as_of: t });
    },
  ],
];
