// queue-actions routes — BH-3151 (BH-2510.1): the Project page's QUEUES panel
// acting on one build_queue row. The console reaches this through the coord
// proxy's `queue/action` row, which requires a reason and stamps the actor.
//
//   release: claimed -> queued. For a claim whose build is dead: the row goes
//            back to the claim path (queue.js POST /api/queue/claim), attempt
//            kept. A build that is in fact alive keeps running.
//   drop:    ready|queued -> failed, with a FIXED reason. `failed` and not
//            `dropped`, because bin/lib/jobs/queue.sh treats `dropped` as not
//            in custody and the fly-dispatch drain would build a leftover box
//            file. The reason is fixed because the operator's text must never
//            match `?reason_deferred=1` (`%REFUSED%`, `BUILD_DEFERRED%`, which
//            bin/jobs-watchdog.sh re-queues) or `died N times` (which
//            bin/blocked-resolver.sh intakes). That text goes only into the
//            stage_events detail.
//
// Each landed action writes one stage_events row, job_id `queue:<p>/<k>`, stage
// `queue`. The row write is a compare-and-set on the status AND updated_at read
// here, and the event is guarded on that write having landed, in ONE batch
// (the job-abandon.js pattern): a lost CAS writes nothing at all.

import { json } from "../lib/http.js";
import { ensureColumns, laneName, str } from "../lib/core.js";

const RELEASED = "RELEASED by operator";
const DROPPED = "DROPPED by operator (queue-action)";

export const routes = [
  [
    "POST", "/api/queue/action",
    async ({ env, t, body }) => {
      // Everything is validated before the first statement (D14).
      const action = body.action;
      if (action !== "release" && action !== "drop") {
        return json(400, { error: "action must be release or drop" });
      }
      const project = laneName(body.project);
      const key = laneName(body.key);
      if (!project || !key) {
        return json(400, { error: "project and key are required and must match [A-Za-z0-9._-]{1,64}" });
      }
      const reason = (str(body.reason, 512) || "").trim();
      if (!reason) return json(400, { error: "reason required" });
      const actor = (str(body.actor, 128) || "").trim();
      if (!actor) return json(400, { error: "actor required" });

      const row = await env.DB.prepare(
        "SELECT * FROM build_queue WHERE project=?1 AND ticket_key=?2").bind(project, key).first();
      if (!row) return json(404, { error: `nothing queued for ${project}/${key}` });
      const prev = String(row.status);
      const refuse = (error) => json(409, { error, refused: true, project, key, action, status: prev });

      let to, fixed, update;
      if (action === "release") {
        if (prev !== "claimed") return refuse(`only a claimed row can be released; this one is ${prev}`);
        to = "queued";
        fixed = RELEASED;
        // The statement names `machine`, so a table that predates it is widened first.
        await ensureColumns(env, "build_queue");
        update = env.DB.prepare(
          `UPDATE build_queue SET status='queued', claimed_by=NULL, claimed_at=NULL, machine=NULL, reason=?1, updated_at=?2
           WHERE project=?3 AND ticket_key=?4 AND status='claimed' AND updated_at=?5`
        ).bind(fixed, t, project, key, row.updated_at);
      } else {
        if (prev === "claimed") return refuse("a live build owns this row; ABANDON the job instead");
        if (prev === "failed" && row.reason === DROPPED) {
          return json(200, { project, key, action, decision: "already", previous_status: prev, status: prev, reason, actor, as_of: t });
        }
        if (prev !== "ready" && prev !== "queued") return refuse(`only a ready or queued row can be dropped; this one is ${prev}`);
        to = "failed";
        fixed = DROPPED;
        update = env.DB.prepare(
          `UPDATE build_queue SET status='failed', finished_at=?1, reason=?2, updated_at=?1
           WHERE project=?3 AND ticket_key=?4 AND status=?5 AND updated_at=?6`
        ).bind(t, fixed, project, key, prev, row.updated_at);
      }

      const verdict = action === "release" ? "RELEASED" : "DROPPED";
      const detail = JSON.stringify({ reason, from: prev, to });
      const res = await env.DB.batch([
        update,
        env.DB.prepare(
          `INSERT INTO stage_events (job_id, stage, verdict, actor, detail, created_at)
           SELECT ?1, 'queue', ?2, ?3, ?4, ?5
           WHERE EXISTS (SELECT 1 FROM build_queue WHERE project=?6 AND ticket_key=?7 AND status=?8 AND reason=?9 AND updated_at=?5)`
        ).bind(`queue:${project}/${key}`, verdict, actor, detail, t, project, key, to, fixed),
      ]);
      if (!res[0] || !res[0].meta || res[0].meta.changes === 0) {
        return json(409, { error: "row moved, reload", refused: true, project, key, action });
      }
      return json(200, {
        project, key, action, decision: action === "release" ? "released" : "dropped",
        previous_status: prev, status: to, reason, actor, as_of: t,
      });
    },
  ],
];
