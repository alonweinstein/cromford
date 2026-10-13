// review-gate routes — the review gate and its thresholds.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.
// Since BH-2618, PUT /api/review-gate/thresholds also batches a config_changes audit row with
// its upsert (src/lib/config-changes.js).

import { json } from "../lib/http.js";
import {
  numOrNull, intOrNull, boolInt, str, ensureTable,
} from "../lib/core.js";
import { CONFIG_KINDS, configChangeStmts } from "../lib/config-changes.js";

export const routes = [
  // ── SDLC item 2: the review gate (2026-08-29) ──────────────────────────
  // Everything under /api/metrics MEASURES. This is the one place a
  // measurement is allowed to change what the fleet may do, and it may only
  // ever change it in the tighter direction — see schema.sql for why the
  // SWITCH is a pause_flags row and these rows are the detector's record.
  //
  // ONE GET carries both halves. A console that fetched gates and thresholds
  // separately could render a rate beside a threshold it was never judged
  // against, which is the one way this screen could lie.
  [
    "GET", "/api/review-gate",
    async ({ env, url, t }) => {
      const repo = url.searchParams.get("repo");
      const gates = repo
        ? await env.DB.prepare("SELECT * FROM review_gate WHERE repo=?1").bind(repo).all()
        : await env.DB.prepare("SELECT * FROM review_gate ORDER BY tightened DESC, rate DESC").all();
      const th = await env.DB.prepare("SELECT * FROM review_gate_thresholds ORDER BY scope").all();
      return json(200, { gates: gates.results || [], thresholds: th.results || [], as_of: t });
    },
  ],

  [
    "PUT", "/api/review-gate",
    async ({ env, t, body }) => {
      const repo = str(body.repo, 256);
      if (!repo) return json(400, { error: "repo required" });
      const tightened = boolInt(body.tightened);
      if (tightened === null) return json(400, { error: "tightened (0|1) required" });
      // tightened_at is the moment a repo CROSSED, so it survives the daily
      // re-measurements that keep it parked and is cleared only on release. A
      // detector that restamped it every run would make every parked repo look
      // like it had just failed.
      const tsAt = tightened === 1 ? t : null;
      await env.DB.prepare(
        `INSERT INTO review_gate (repo, tightened, rate, bad, merges, window_days,
                                  tighten_rate, clear_rate, min_merges, threshold_scope,
                                  decision, evidence, actor, tightened_at, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)
         ON CONFLICT(repo) DO UPDATE SET
           tightened=?2, rate=?3, bad=?4, merges=?5, window_days=?6,
           tighten_rate=?7, clear_rate=?8, min_merges=?9, threshold_scope=?10,
           decision=?11, evidence=?12, actor=COALESCE(?13, actor),
           tightened_at=CASE WHEN ?2 = 0 THEN NULL
                             WHEN review_gate.tightened = 1 THEN review_gate.tightened_at
                             ELSE ?14 END,
           updated_at=?15`
      ).bind(repo, tightened, numOrNull(body.rate), intOrNull(body.bad), intOrNull(body.merges),
             intOrNull(body.window_days), numOrNull(body.tighten_rate), numOrNull(body.clear_rate),
             intOrNull(body.min_merges), str(body.threshold_scope, 256), str(body.decision, 32),
             str(body.evidence, 2000), str(body.actor, 128), tsAt, t).run();
      const row = await env.DB.prepare("SELECT * FROM review_gate WHERE repo=?1").bind(repo).first();
      return json(200, { gate: row });
    },
  ],

  // The thresholds are VALIDATED HERE rather than trusted from the caller.
  // These four numbers decide whether a repo's PRs auto-merge; a clear_rate
  // above its tighten_rate would flap a repo in and out of the park on
  // alternate runs, and a rate outside 0..1 would either never fire or fire
  // on everything. Both are refusals, not clamps — a threshold silently
  // corrected is a threshold nobody knows the value of.
  [
    "PUT", "/api/review-gate/thresholds",
    async ({ env, t, body }) => {
      const scope = str(body.scope, 256);
      if (!scope) return json(400, { error: "scope ('*' or a repo slug) required" });
      const win = intOrNull(body.window_days);
      const minM = intOrNull(body.min_merges);
      const tRate = numOrNull(body.tighten_rate);
      const cRate = numOrNull(body.clear_rate);
      if (win === null || win < 1 || win > 365) return json(400, { error: "window_days must be 1..365" });
      if (minM === null || minM < 1) return json(400, { error: "min_merges must be >= 1" });
      if (tRate === null || tRate <= 0 || tRate > 1) return json(400, { error: "tighten_rate must be >0 and <=1" });
      if (cRate === null || cRate < 0 || cRate > 1) return json(400, { error: "clear_rate must be 0..1" });
      if (cRate > tRate) return json(400, { error: "clear_rate must be <= tighten_rate (an inverted pair flaps)" });
      const note = str(body.note, 500);
      // BH-2513: the audit row rides the same batch as the upsert. `after.note`
      // is what COALESCE(?6, note) stores, so a note-less re-PUT is no change.
      await ensureTable(env, "config_changes");
      const was = await env.DB.prepare(
        "SELECT * FROM review_gate_thresholds WHERE scope=?1").bind(scope).first();
      const after = { window_days: win, min_merges: minM, tighten_rate: tRate, clear_rate: cRate, note: note ?? was?.note ?? null };
      await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO review_gate_thresholds (scope, window_days, min_merges, tighten_rate,
                                               clear_rate, note, updated_at)
           VALUES (?1,?2,?3,?4,?5,?6,?7)
           ON CONFLICT(scope) DO UPDATE SET
             window_days=?2, min_merges=?3, tighten_rate=?4, clear_rate=?5,
             note=COALESCE(?6, note), updated_at=?7`
        ).bind(scope, win, minM, tRate, cRate, note, t),
        ...configChangeStmts(env, CONFIG_KINDS.REVIEW_GATE_THRESHOLD, scope, was, after,
          ["window_days", "min_merges", "tighten_rate", "clear_rate", "note"], body.actor, body.reason, t),
      ]);
      const row = await env.DB.prepare(
        "SELECT * FROM review_gate_thresholds WHERE scope=?1").bind(scope).first();
      return json(200, { threshold: row });
    },
  ],
];
