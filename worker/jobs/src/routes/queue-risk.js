// queue-risk routes — BH-5430: the record of the merge-queue break-risk score,
// one row per scored PR head (schema.sql's queue_risk_scores block, and the
// self-create copy in CREATED_TABLES).
//
// The writer is bin/lib/queue-risk.sh (qr_enqueue_step, from mc_enqueue_mergify):
// every enqueue in a mode other than off scores the PR's diff and records the
// score, the route (solo | batch) and the reasons here. The reader is Mission
// Control's MERGE QUEUE BREAK RISK badge, through the coord proxy.
//
// This row is a RECORD, not a credential: the routing itself is the queue-solo
// label the shell writes. Nothing reads this table to decide a merge, so the
// bearer alone writes it.
//
// UNLIKE risk_tiers, the same head is UPDATED, not kept. A head's diff never
// changes, but the queue_risk.* rows that score it do, and a re-enqueue under
// changed rows must show the new routing. 201 means this POST created the row,
// 200 means it updated an existing one. That is measured, not guessed: the
// INSERT ... DO NOTHING reports exactly one change only when it inserted, and
// the UPDATE runs only when it did not. (One upsert statement reports one
// change either way, and telling the two apart by comparing created_at to this
// request's whole-second stamp would call a same-second re-score a create.)
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { REPO_RE, optStr, prOf, shaOf } from "./verdicts.js";

export const QR_ROUTES = ["solo", "batch"];
export const QR_MODES = ["off", "shadow", "enforce"];
const PROJECT_RE = /^[A-Za-z0-9_.-]{1,100}$/;
const SCORE_MAX = 10000;
const LIST_DEFAULT = 50;
const LIST_MAX = 200;

const guarded = (fn) => (ctx) =>
  d1Guarded("queue_risk_scores", async () => {
    await ensureTable(ctx.env, "queue_risk_scores");
    return fn(ctx);
  });

const isInt = (v, lo, hi) => Number.isInteger(v) && v >= lo && v <= hi;

export const routes = [
  [
    "POST", "/api/queue-risk",
    guarded(async ({ env, t, body }) => {
      const b = body || {};
      const repo = typeof b.repo === "string" ? b.repo.trim() : "";
      if (!REPO_RE.test(repo)) return json(400, { error: "repo must be owner/name" });
      const pr = prOf(b.pr);
      if (pr === null) return json(400, { error: "pr must be a positive integer" });
      const head_sha = shaOf(b.head_sha);
      if (!head_sha) return json(400, { error: "head_sha must be a full 40-hex commit sha" });
      if (!QR_ROUTES.includes(b.route)) return json(400, { error: `route must be one of ${QR_ROUTES.join(", ")}` });
      if (!QR_MODES.includes(b.mode)) return json(400, { error: `mode must be one of ${QR_MODES.join(", ")}` });
      // null = the PR's files were unreadable; anything else is a whole number.
      const score = b.score === undefined || b.score === null ? null : b.score;
      if (score !== null && !isInt(score, 0, SCORE_MAX)) {
        return json(400, { error: `score must be an integer 0..${SCORE_MAX}, or null` });
      }
      if (!isInt(b.threshold, 0, SCORE_MAX)) return json(400, { error: `threshold must be an integer 0..${SCORE_MAX}` });
      const project = b.project === undefined || b.project === null || b.project === "" ? null : b.project;
      if (project !== null && (typeof project !== "string" || !PROJECT_RE.test(project))) {
        return json(400, { error: "project must be a project name, [A-Za-z0-9_.-], <= 100 chars" });
      }
      const reasons = optStr(b, "reasons", 1000);
      if (!reasons.ok) return json(400, { error: reasons.err });

      const ins = await env.DB.prepare(
        `INSERT INTO queue_risk_scores (repo, pr, head_sha, project, score, threshold, route, mode, reasons, created_at, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?10)
         ON CONFLICT(repo, pr, head_sha) DO NOTHING`
      ).bind(repo, pr, head_sha, project, score, b.threshold, b.route, b.mode, reasons.v, t).run();
      if (ins.meta.changes === 1) return json(201, { ok: true, id: ins.meta.last_row_id });
      await env.DB.prepare(
        `UPDATE queue_risk_scores SET score = ?4, threshold = ?5, route = ?6, mode = ?7, reasons = ?8, updated_at = ?9
         WHERE repo = ?1 AND pr = ?2 AND head_sha = ?3`
      ).bind(repo, pr, head_sha, score, b.threshold, b.route, b.mode, reasons.v, t).run();
      return json(200, { ok: true, updated: true });
    }),
  ],

  // ?repo=&pr=&route=&limit= — newest updated_at first (id DESC on a tie), so a
  // re-scored head moves to the top. The limit is refused outside 1..200, never
  // clamped, and `truncated` is measured by reading one row past it. One
  // constant statement: an absent filter binds NULL and its clause is true.
  [
    "GET", "/api/queue-risk",
    guarded(async ({ env, url, t }) => {
      const repo = (url.searchParams.get("repo") || "").trim();
      if (repo && !REPO_RE.test(repo)) return json(400, { error: "repo must be owner/name" });
      const rawPr = url.searchParams.get("pr");
      const pr = rawPr === null || rawPr === "" ? null : prOf(rawPr);
      if (rawPr && pr === null) return json(400, { error: "pr must be a positive integer" });
      const route = url.searchParams.get("route") || null;
      if (route !== null && !QR_ROUTES.includes(route)) return json(400, { error: `route must be one of ${QR_ROUTES.join(", ")}` });
      const rawLimit = url.searchParams.get("limit");
      let limit = LIST_DEFAULT;
      if (rawLimit !== null) {
        limit = /^\d+$/.test(rawLimit) ? Number(rawLimit) : NaN;
        if (!(limit >= 1 && limit <= LIST_MAX)) return json(400, { error: `limit must be an integer 1..${LIST_MAX}` });
      }
      const rows = (await env.DB.prepare(
        "SELECT * FROM queue_risk_scores" +
        " WHERE (?1 IS NULL OR repo = ?1)" +
        " AND (?2 IS NULL OR pr = ?2)" +
        " AND (?3 IS NULL OR route = ?3)" +
        " ORDER BY updated_at DESC, id DESC LIMIT ?4"
      ).bind(repo || null, pr, route, limit + 1).all()).results || [];
      return json(200, { rows: rows.slice(0, limit), truncated: rows.length > limit, as_of: t });
    }),
  ],
];
