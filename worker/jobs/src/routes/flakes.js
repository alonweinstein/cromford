// flakes routes — flaky-test accounting.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.
// The three quarantine routes at the end were added later by BH-2632 and are
// not part of that move.

import { json, d1Guarded } from "../lib/http.js";
import {
  str,
} from "../lib/core.js";

export const routes = [
  // ── Flaky CI (2026-09-12) ──────────────────────────────────────────────
  // One row per (repo, workflow, test, head): a red classified against the
  // run history of the head sha it ran on. PUT, not POST, because the write
  // is an idempotent upsert of a known key — bin/flaky-detect.sh re-scans an
  // overlapping window every day and must land on the same rows.
  //
  // created_at is NOT touched on conflict, for the same reason outcome_metrics
  // does not touch it: the first time we saw this test flake on this head is
  // the fact, and tomorrow's re-scan of the same window must not make it look
  // like it happened again.
  [
    "PUT", "/api/metrics/flakes",
    async ({ env, t, body }) => {
      const rows = Array.isArray(body.rows) ? body.rows : (body.repo ? [body] : []);
      if (!rows.length) return json(400, { error: "rows[] or a single flake row required" });
      if (rows.length > 2000) return json(400, { error: "at most 2000 rows per request" });
      const stmts = [];
      for (const r of rows) {
        const repo = str(r.repo, 256);
        const workflow = str(r.workflow, 512);
        const test = str(r.test, 512);
        const head = str(r.head, 64);
        if (!repo || !workflow || !test || !head) continue;
        // An unknown kind is stored as "red". The rate's numerator is the claim
        // that needs evidence; its denominator is the safe default, so a client
        // that sends nonsense makes the fleet look flakier than it is rather
        // than less flaky, which is the direction a bad write must fall.
        const kind = r.kind === "flake" ? "flake" : "red";
        stmts.push(env.DB.prepare(
          `INSERT INTO ci_flakes (repo, workflow, test, head, kind, day, created_at)
           VALUES (?1,?2,?3,?4,?5,?6,?7)
           ON CONFLICT(repo, workflow, test, head) DO UPDATE SET
             kind=?5, day=COALESCE(?6, day)`
        ).bind(repo, workflow, test, head, kind, str(r.day, 10), t));
      }
      if (!stmts.length) return json(400, { error: "no row carried repo, workflow, test and head" });
      await env.DB.batch(stmts);
      return json(200, { upserted: stmts.length, as_of: t });
    },
  ],

  [
    "GET", "/api/metrics/flakes",
    async ({ env, url, t }) => {
      const lim = Math.min(Math.max(Number(url.searchParams.get("limit")) || 200, 1), 2000);
      const repo = str(url.searchParams.get("repo"), 256);
      const since = str(url.searchParams.get("since"), 10);
      const where = [];
      const binds = [];
      if (repo)  { binds.push(repo);  where.push(`repo=?${binds.length}`); }
      if (since) { binds.push(since); where.push(`day>=?${binds.length}`); }
      const sql = `SELECT * FROM ci_flakes${where.length ? ` WHERE ${where.join(" AND ")}` : ""}`
                + ` ORDER BY day DESC, created_at DESC LIMIT ${lim}`;
      const q = env.DB.prepare(sql);
      const rows = binds.length ? await q.bind(...binds).all() : await q.all();
      return json(200, { flakes: rows.results || [], as_of: t });
    },
  ],

  // ── Flake quarantine (BH-2632, BH-2517.1) ──────────────────────────────
  // An operator's audited switch: "this test is a known flake, forgive its
  // red". bin/lib/flaky.sh flaky_gate_set folds the active rows into the merge
  // conductor's red gate, which still takes one rerun per head first, so a
  // quarantine buys a retry and never an ignore.
  //
  // Validation refuses rather than trims to fit (D11): an over-long reason is
  // a 400, never a slice, and active is exactly 0/1/true/false. A job:* or
  // workflow:* name is refused because quarantining one would forgive a whole
  // job, not a test. The test name is trimmed at write because
  // flaky_parse_tests trims what it reads, and case is kept as sent.
  //
  // The before-read, the audit row and the upsert ride ONE batch, which D1
  // runs as one transaction: there is never a flip without its audit row. A
  // toggle to the state already held still writes the audit row (every call is
  // an operator action) and answers changed:false.
  [
    "PUT", "/api/metrics/flakes/quarantine",
    async ({ env, t, body }) => {
      const repo = reqText(body.repo, 256);
      const test = reqText(body.test, 512);
      const reason = reqText(body.reason, 512);
      const actor = reqText(body.actor, 128);
      if (!repo) return json(400, { error: "repo required, 1-256 chars" });
      if (!test) return json(400, { error: "test required, 1-512 chars" });
      if (/^(job|workflow):/.test(test)) return json(400, { error: "test must name a test, not a job: or workflow:" });
      if (!reason) return json(400, { error: "reason required, 1-512 chars" });
      if (!actor) return json(400, { error: "actor required, 1-128 chars" });
      const active = { 0: 0, 1: 1, true: 1, false: 0 }[
        typeof body.active === "number" || typeof body.active === "boolean" ? String(body.active) : ""];
      if (active === undefined) return json(400, { error: "active must be 0, 1, true or false" });
      return d1Guarded("flaky_quarantine", async () => {
        const [before, , , after] = await env.DB.batch([
          env.DB.prepare("SELECT active FROM flaky_quarantine WHERE repo=?1 AND test=?2").bind(repo, test),
          env.DB.prepare(
            `INSERT INTO flaky_quarantine_changes (repo, test, before_active, after_active, actor, reason, at)
             SELECT ?1, ?2, (SELECT active FROM flaky_quarantine WHERE repo=?1 AND test=?2), ?3, ?4, ?5, ?6`
          ).bind(repo, test, active, actor, reason, t),
          env.DB.prepare(
            `INSERT INTO flaky_quarantine (repo, test, active, actor, reason, updated_at)
             VALUES (?1,?2,?3,?4,?5,?6)
             ON CONFLICT(repo, test) DO UPDATE SET
               active=excluded.active, actor=excluded.actor, reason=excluded.reason, updated_at=excluded.updated_at`
          ).bind(repo, test, active, actor, reason, t),
          env.DB.prepare("SELECT * FROM flaky_quarantine WHERE repo=?1 AND test=?2").bind(repo, test),
        ]);
        const prev = (before.results || [])[0];
        const row = (after.results || [])[0] || null;
        return json(200, { ok: true, row, changed: prev === undefined ? true : prev.active !== active });
      });
    },
  ],

  // Current rows, newest first. One past the cap is read so truncated is a
  // measurement, not a guess (D12).
  [
    "GET", "/api/metrics/flakes/quarantine",
    async ({ env, url, t }) => {
      const repoRaw = url.searchParams.get("repo");
      const repo = repoRaw === null || repoRaw === "" ? null : reqText(repoRaw, 256);
      if (repoRaw && !repo) return json(400, { error: "repo must be 1-256 chars" });
      const activeRaw = url.searchParams.get("active");
      if (activeRaw !== null && activeRaw !== "0" && activeRaw !== "1") {
        return json(400, { error: "active must be 0 or 1" });
      }
      return d1Guarded("flaky_quarantine", async () => {
        const where = [];
        const binds = [];
        if (repo) { binds.push(repo); where.push(`repo=?${binds.length}`); }
        if (activeRaw !== null) { binds.push(Number(activeRaw)); where.push(`active=?${binds.length}`); }
        const sql = `SELECT * FROM flaky_quarantine${where.length ? ` WHERE ${where.join(" AND ")}` : ""}`
                  + ` ORDER BY updated_at DESC, repo, test LIMIT ${QUARANTINE_CAP + 1}`;
        const q = env.DB.prepare(sql);
        const res = binds.length ? await q.bind(...binds).all() : await q.all();
        const rows = res.results || [];
        return json(200, { rows: rows.slice(0, QUARANTINE_CAP), truncated: rows.length > QUARANTINE_CAP, as_of: t });
      });
    },
  ],

  // The audit trail, newest first. id breaks ties between writes in the same
  // second. limit is 1-200, default 50; anything else is a 400, never clamped.
  [
    "GET", "/api/metrics/flakes/quarantine/changes",
    async ({ env, url, t }) => {
      const limRaw = url.searchParams.get("limit");
      const lim = limRaw === null ? 50 : (/^[0-9]+$/.test(limRaw) ? Number(limRaw) : NaN);
      if (!(lim >= 1 && lim <= 200)) return json(400, { error: "limit must be an integer 1-200" });
      const where = [];
      const binds = [];
      for (const k of ["repo", "test"]) {
        const v = url.searchParams.get(k);
        if (v !== null && v !== "") { binds.push(v); where.push(`${k}=?${binds.length}`); }
      }
      return d1Guarded("flaky_quarantine_changes", async () => {
        const sql = `SELECT * FROM flaky_quarantine_changes${where.length ? ` WHERE ${where.join(" AND ")}` : ""}`
                  + ` ORDER BY id DESC LIMIT ${lim}`;
        const q = env.DB.prepare(sql);
        const res = binds.length ? await q.bind(...binds).all() : await q.all();
        return json(200, { changes: res.results || [], as_of: t });
      });
    },
  ],
];

const QUARANTINE_CAP = 2000;

// A required text field: trimmed, and null when absent, blank, not a string,
// or longer than max. Never sliced to fit (str() in core.js slices).
function reqText(v, max) {
  if (typeof v !== "string") return null;
  const s = v.trim();
  return s && s.length <= max ? s : null;
}
