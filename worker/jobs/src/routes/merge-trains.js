// merge-trains routes — BH-1269.
//
// One row per merge train bin/batch-resolve.sh builds: its members, the union
// sha CI ran once over, that run's id, and how it ended. See the `merge_trains`
// comment in schema.sql for what a per-box JSON file could not carry.
//
// THE TABLE SELF-CREATES (ensureTable), like preplans / machines / alerts: the
// deploy is `wrangler deploy` and nothing else, so a route that waits for a
// hand-run `d1 execute` answers 500 from the minute it ships — and the client
// fails open, so that 500 would be indistinguishable from a fleet running no
// trains at all.

import { json } from "../lib/http.js";
import { ensureTable, ensureColumns, intOrNull, str, laneName } from "../lib/core.js";

// The states a train can be in, and ONLY the ones bin/batch-resolve.sh actually
// writes. `creating` is the crash window between pushing the union branch and
// recording the PR; `abandoned` covers a train that was closed, aged out or
// pre-empted, each with its own `detail`. There is deliberately no `red`: a
// union that fails its verification contract BEFORE the push has no branch on
// the remote and no record, and one that goes red after it is `abandoned` —
// a word in this set that nothing ever writes is a column a reader would learn
// to expect and never see. An unknown word is REFUSED rather than stored,
// because a reader who has to guess what a state means will guess wrong about
// whether the work landed.
const TRAIN_OUTCOMES = new Set(["creating", "open", "landed", "abandoned"]);

export const routes = [
  [
    "PUT", "/api/merge-trains",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      const branch = str(body.branch, 200);
      const outcome = String(body.outcome || "").slice(0, 32);
      if (!project) return json(400, { error: "project is required and must match [A-Za-z0-9._-]{1,64}" });
      if (!branch) return json(400, { error: "branch is required" });
      if (!TRAIN_OUTCOMES.has(outcome)) {
        return json(400, { error: `outcome must be one of ${[...TRAIN_OUTCOMES].join(" | ")}` });
      }
      await ensureTable(env, "merge_trains");
      // BH-1270: merge_trains predates train_group, so a live database only gets
      // the column from here. Before the first write that carries one.
      await ensureColumns(env, "merge_trains");
      const members = str(body.members, 1000);
      // member_count is DERIVED when the caller did not send one, so a row can
      // never say "3 members" next to a list of two. The caller's own count
      // wins when it sends one, because a train that dropped a member mid-build
      // knows the truth before the list is rewritten.
      const count = intOrNull(body.member_count) ??
        (members ? members.split(",").filter((x) => x.trim() !== "").length : null);
      // COALESCE on every field a later PUT may omit: the lane writes this row
      // three times (creating, open, landed) and only the first call knows the
      // members, only the last knows the merge sha.
      await env.DB.prepare(
        `INSERT INTO merge_trains (project, branch, repo, train_pr, members, member_count,
                                   union_sha, run_id, outcome, merge_sha, detail,
                                   train_group, created_at, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?13,?12,?12)
         ON CONFLICT(project, branch) DO UPDATE SET
           repo=COALESCE(?3, merge_trains.repo),
           train_pr=COALESCE(?4, merge_trains.train_pr),
           members=COALESCE(?5, merge_trains.members),
           member_count=COALESCE(?6, merge_trains.member_count),
           union_sha=COALESCE(?7, merge_trains.union_sha),
           run_id=COALESCE(?8, merge_trains.run_id),
           outcome=?9,
           merge_sha=COALESCE(?10, merge_trains.merge_sha),
           detail=COALESCE(?11, merge_trains.detail),
           train_group=COALESCE(?13, merge_trains.train_group),
           updated_at=?12`
      ).bind(project, branch, str(body.repo, 128), intOrNull(body.train_pr),
             members || null, count, str(body.union_sha, 64), str(body.run_id, 32),
             outcome, str(body.merge_sha, 64), str(body.detail, 500), t,
             str(body.train_group, 16)).run();
      const row = await env.DB.prepare(
        "SELECT * FROM merge_trains WHERE project=?1 AND branch=?2").bind(project, branch).first();
      return json(200, { train: row, as_of: t });
    },
  ],

  [
    "GET", "/api/merge-trains",
    async ({ env, url, t }) => {
      await ensureTable(env, "merge_trains");
      await ensureColumns(env, "merge_trains");
      const where = [], binds = [];
      for (const col of ["project", "outcome", "branch"]) {
        const v = url.searchParams.get(col);
        if (v) { binds.push(v); where.push(`${col}=?${binds.length}`); }
      }
      // Newest first: a reader of this table is asking what is in flight now,
      // which is the opposite of the merge queue's FIFO. `branch` is the
      // tiebreak so two trains created in the same second do not come back in
      // whatever order the scan produced.
      const sql = "SELECT * FROM merge_trains"
        + (where.length ? ` WHERE ${where.join(" AND ")}` : "")
        + ` ORDER BY created_at DESC, branch DESC LIMIT ${Math.min(Math.max(1, Number(url.searchParams.get("limit")) || 50), 200)}`;
      const rows = await env.DB.prepare(sql).bind(...binds).all();
      return json(200, { merge_trains: rows.results || [], as_of: t });
    },
  ],
];
