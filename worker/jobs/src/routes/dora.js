// dora routes — the four DORA metrics, computed from job rows.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  ensureColumns, computeDora,
} from "../lib/core.js";

export const routes = [
  // ── DORA (2026-09-12, the operator: "the next bottleneck measured, not felt") ──
  //
  // Four DORA metrics plus the merge-lane split, per project, over a window.
  // Every number carries the TABLE it came from, and every number this fleet
  // cannot answer today says so instead of guessing — the whole value of this
  // endpoint is that a bottleneck it reports is a bottleneck that exists.
  //
  // WHAT IS REAL TODAY, AND WHAT IS NOT:
  //
  //   lead time    REAL, and it ends where DORA says it should — when the
  //                change is RUNNING in production — for every merge a
  //                bin/deploy-train.sh departure carried, because the train
  //                now writes that arrival as a `deploy` ledger row. A merge
  //                with no such row still ends at the MERGE, and says so:
  //                every row carries `lead_end`, and the project carries
  //                to_deploy_n / to_merge_n rather than one averaged column.
  //
  //   deploy freq  DEPARTURES per day once any are recorded for the project,
  //                MERGES per day otherwise, and `basis` + `deploy_verified`
  //                say which. A train carries a BATCH, so merges/day
  //                OVERCOUNTS departures — the moment there is a real
  //                departure count, reporting merges would be choosing the
  //                flattering number over the measured one.
  //
  //   change-fail  REAL. outcome_metrics over the merge ledger, DISTINCT PRs.
  //
  //   restore      REAL as an UPPER BOUND; `caveat` on the row says which.
  //
  //   merge lane   REAL, from the verdict artifact rather than pr_state —
  //                see computeDora's `gaps` for why pr_state cannot answer it.
  //
  // READ-ONLY: nothing in this branch writes a row.
  [
    "GET", "/api/metrics/dora",
    async ({ env, url, t }) => {
      await ensureColumns(env, "jobs");
      const days = Math.min(Math.max(Number(url.searchParams.get("days")) || 14, 1), 90);
      const wantProject = (url.searchParams.get("project") || "").trim() || null;
      const nowMs = Date.parse(t);
      const since = new Date(nowMs - days * 86400000).toISOString().replace(/\.\d{3}Z$/, "Z");
      // A PR merged today can belong to a job opened well before the window, so
      // the ATTRIBUTION read looks further back than the window does. Without
      // this, every long-running ticket loses its project and its lead time.
      const attrSince = new Date(nowMs - (days + 60) * 86400000)
        .toISOString().replace(/\.\d{3}Z$/, "Z");

      const [merges, artifacts, outcomes, states, queues, deployRows, launchRead] = await Promise.all([
        env.DB.prepare(
          `SELECT key, status, job_id, created_at, updated_at FROM ledgers
            WHERE kind='merge' AND status='merged' AND created_at>=?1
            ORDER BY created_at DESC LIMIT 3000`
        ).bind(since).all(),
        env.DB.prepare(
          `SELECT a.artifact_kind AS artifact_kind, a.artifact_ref AS artifact_ref,
                  a.job_id AS job_id, a.created_at AS created_at, a.updated_at AS updated_at,
                  j.project AS project, j.ticket_id AS ticket_id, j.created_at AS job_created_at,
                  j.kind AS job_kind
             FROM job_artifacts a JOIN jobs j ON j.id=a.job_id
            WHERE a.artifact_kind IN ('pr_url','verdict') AND a.updated_at>=?1
            ORDER BY a.updated_at DESC LIMIT 6000`
        ).bind(attrSince).all(),
        env.DB.prepare(
          `SELECT repo, pr, outcome, day, created_at FROM outcome_metrics
            WHERE created_at>=?1 ORDER BY created_at DESC LIMIT 2000`
        ).bind(since).all(),
        env.DB.prepare(
          `SELECT key, status, created_at, updated_at FROM ledgers
            WHERE kind='pr_state' ORDER BY updated_at DESC LIMIT 2000`
        ).all(),
        // The one place a repo slug is written down beside the project that
        // owns it. Without it, a repo whose PRs all predate the attribution
        // window carries outcomes nobody can file under a project.
        env.DB.prepare(
          `SELECT DISTINCT project, repo FROM merge_queue WHERE repo IS NOT NULL LIMIT 500`
        ).all(),
        // The verified-production record bin/deploy-train.sh writes. Same
        // window as the merges deliberately: a departure outside the window
        // belongs to a merge outside it, and reading it in would move a lead
        // time this window cannot show the other half of.
        env.DB.prepare(
          `SELECT key, status, detail, created_at, updated_at FROM ledgers
            WHERE kind='deploy' AND created_at>=?1
            ORDER BY created_at DESC LIMIT 2000`
        ).bind(since).all(),
        // BH-482.3: the launch half — the board's clock, grouped to one row per
        // ticket so a rebuild cannot count its wait twice. It carries its OWN
        // try/catch because it is the only read here touching columns a box's
        // D1 may have been ALTERed into moments ago: a panel that 500s takes
        // the six reads that DID work down with it, and a missing metric named
        // in `gaps` is worth more than an error page.
        (async () => {
          try {
            const r = await env.DB.prepare(
              `SELECT project, ticket_id, MIN(issue_created_at) AS issue_created_at,
                      MIN(first_spawn_at) AS first_spawn_at
                 FROM jobs
                WHERE kind='build' AND issue_created_at IS NOT NULL
                  AND first_spawn_at IS NOT NULL AND first_spawn_at>=?1
                GROUP BY project, ticket_id LIMIT 3000`
            ).bind(since).all();
            return { rows: r.results || [], error: null };
          } catch (e) {
            return { rows: null, error: String((e && e.message) || e) };
          }
        })(),
      ]);

      const payload = computeDora({
        days, since, now: nowMs, project: wantProject,
        merges: merges.results || [],
        artifacts: artifacts.results || [],
        outcomes: outcomes.results || [],
        prStates: states.results || [],
        repoMap: queues.results || [],
        deploys: deployRows.results || [],
        launches: launchRead.rows,
        launchesError: launchRead.error,
        launchesCapped: launchRead.rows !== null && launchRead.rows.length >= 3000,
      });
      return json(200, { ...payload, as_of: t });
    },
  ],
];
