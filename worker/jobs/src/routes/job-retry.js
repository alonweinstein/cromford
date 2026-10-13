// job-retry routes — retry and requeue: the two ways a job gets another go.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  OPEN_STATUS, JOB_TRANSITIONS, checkTransition, resolveRetryPolicy, claimRow,
  putClaim, terminalMarker, str,
} from "../lib/core.js";

export const routes = [
  // ── Judge a dead claim under policy (phase 6) ──────────────────────────
  // ONE call, and the DB decides. bin/jobs-watchdog.sh used to write
  // `status=orphaned` itself; now it asks, and every failure lands in exactly
  // one terminal state:
  //   queued_for_retry — within policy, with next_attempt_at set to the
  //                      backoff. The LANE'S OWN NEXT TICK picks it up; the
  //                      watchdog never executes anything.
  //   parked           — the policy ran out of attempts. A human's problem now,
  //                      with the count that made it one.
  //   orphaned         — no policy for the lane (today's behaviour, unchanged),
  //                      or a KILL_STOP/BUDGET_STOP death, which is terminal
  //                      whatever the policy says because bin/agent-call.sh has
  //                      already served its own single same-lane retry.
  // Idempotent: judging a row that is no longer running returns the decision
  // already on it and writes nothing, so a repeated watchdog pass cannot
  // reset a backoff or double-count an attempt.
  [
    "POST", /^\/api\/jobs\/([^/]+)\/retry$/,
    async ({ env, t, body, m: retryMatch }) => {
      const id = decodeURIComponent(retryMatch[1]);
      const job = await env.DB.prepare("SELECT * FROM jobs WHERE id=?1").bind(id).first();
      if (!job) return json(404, { error: "no such job" });
      const claim = (await claimRow(env, id)) || {};
      const attempts = Number(claim.attempts) || 1;
      if (String(job.status) !== OPEN_STATUS) {
        return json(200, {
          job_id: id, decision: job.status, already: true, attempts,
          max_attempts: claim.max_attempts ?? null,
          next_attempt_at: claim.next_attempt_at || null,
          reason: claim.reason || "already judged", as_of: t,
        });
      }
      const detail = body.detail ? String(body.detail).slice(0, 512) : "no heartbeat";
      const lane = claim.lane || `${job.stage}/${job.project}/*`;
      const terminal = await terminalMarker(env, id, job);
      const policy = terminal ? null : await resolveRetryPolicy(env, lane);

      let decision, reason, nextAt = null, maxAttempts = policy ? Number(policy.max_attempts) : null;
      if (terminal) {
        decision = "orphaned";
        reason = `terminal: ${terminal} — agent-call.sh already served its own same-lane retry, so this one is not re-run`;
      } else if (!policy) {
        decision = "orphaned";
        reason = `no retry policy for lane ${lane} — detection only, as before phase 6 (${detail})`;
      } else if (attempts < maxAttempts) {
        decision = "queued_for_retry";
        const backoff = Number(policy.backoff_seconds) || 0;
        nextAt = new Date(Date.parse(t) + backoff * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
        reason = `attempt ${attempts} of ${maxAttempts} ended (${detail}); queued for the lane's next tick after ${nextAt}`;
      } else {
        decision = "parked";
        reason = `retries exhausted (${attempts} of ${maxAttempts}) after ${detail} — parked for a human`;
      }

      await env.DB.prepare("UPDATE jobs SET status=?2, updated_at=?3 WHERE id=?1")
        .bind(id, decision, t).run();
      await putClaim(env, id, {
        lane, attempts, max_attempts: maxAttempts, next_attempt_at: nextAt,
        escalate_allowed: policy ? Number(policy.escalate_allowed) || 0 : null,
        reason,
      }, t);
      await env.DB.prepare(
        `INSERT INTO stage_events (job_id, stage, verdict, actor, detail, created_at)
         VALUES (?1,?2,?3,?4,?5,?6)`
      ).bind(id, job.stage, decision.toUpperCase(),
        body.actor ? String(body.actor).slice(0, 128) : "jobs-watchdog", reason, t).run();

      return json(200, {
        job_id: id, decision, attempts, max_attempts: maxAttempts, next_attempt_at: nextAt,
        escalate_allowed: policy ? (Number(policy.escalate_allowed) || 0) : 0,
        policy_lane: policy ? policy.lane : null, lane, reason, as_of: t,
      });
    },
  ],

  // ── SILENT auto-requeue (ledger hygiene, 2026-09-15) ───────────────────
  // THE GAP THIS CLOSES. A triage tick claims a row, the session dies without
  // ever beating, and the watchdog's SILENT rule deliberately leaves the row
  // `running` — its age is a lower bound on inactivity, not proof of death.
  // Nothing then re-offers the ticket: the box only re-offers on its own tick
  // if the ticket is still VISIBLE on the board, and a claimed-then-abandoned
  // key usually is not. Ten such rows alerted in 24h on 2026-09-15 and every
  // one of them just sat there.
  //
  // ASK, DON'T DECIDE — the same shape as /retry above. The watchdog names
  // its cap and this route answers with exactly one of:
  //   queued_for_retry — requeued; the lane's own next tick takes it over
  //   parked           — the cap ran out; bin/blocked-resolver.sh owns it now
  //   held             — NOT requeued, and the reason says why. Two shapes:
  //                      a ticketless lane tick (run-triage opens a fresh row
  //                      every tick, so requeuing one is pure noise), and a
  //                      ticket that already has another LIVE row — requeuing
  //                      that is how one ticket gets built twice.
  //   already          — the row is no longer running; nothing written.
  //
  // THE COUNTER IS THE LEDGER'S OWN HISTORY, not a column and not a file on
  // the hub. It is the number of REQUEUED stage_events this job already
  // carries, so it survives a hub rebuild, is visible on the job page, and
  // needs no schema change (schema.sql is applied by hand and is never
  // touched from a build lane).
  [
    "POST", /^\/api\/jobs\/([^/]+)\/requeue$/,
    async ({ env, t, body, m: requeueMatch }) => {
      const id = decodeURIComponent(requeueMatch[1]);
      const job = await env.DB.prepare("SELECT * FROM jobs WHERE id=?1").bind(id).first();
      if (!job) return json(404, { error: "no such job" });
      const claim = (await claimRow(env, id)) || {};
      const lane = claim.lane || `${job.stage}/${job.project}/*`;
      const detail = str(body.detail, 512) || "no heartbeat and no live sibling";
      const actor = str(body.actor, 128) || "jobs-watchdog";
      const maxAttempts = Math.max(1, Math.min(Number(body.max_attempts) || 3, 20));

      const answer = (decision, reason, extra) => json(200, {
        job_id: id, decision, reason, lane,
        max_attempts: maxAttempts, as_of: t, ...(extra || {}),
      });

      // A row that already left `running` has been judged by something else —
      // the watchdog's own orphan pass, a late-reporting session, an operator.
      // Say so and write nothing, so a repeated sweep is free.
      if (String(job.status) !== OPEN_STATUS && String(job.status) !== "orphaned") {
        return answer("already", claim.reason || `job is ${job.status}`, { status: job.status });
      }

      // A ticketless row is a LANE TICK, not a piece of work. bin/run-triage.sh
      // opens a fresh one every ten minutes; handing this one back to the queue
      // would put a second claim on a lane that already has one.
      if (!job.ticket_id) {
        return answer("held", "ticketless lane tick — the lane's own next cron tick opens a fresh row, so there is nothing here to re-offer");
      }

      // THE DOUBLE-BUILD GUARD, applied to the requeue. job_open refuses a
      // second CONCURRENT claim on a ticket, which means a requeue can never
      // produce two running builds — but it CAN produce a pointless second
      // attempt on a ticket something else is already carrying, and the row we
      // would be reviving is the stale one. So: if anything else is live on
      // this project+ticket, leave it alone and say who owns it.
      const sibling = await env.DB.prepare(
        "SELECT id, kind, box, stage FROM jobs WHERE project=?1 AND ticket_id=?2 AND status=?3 AND id<>?4 ORDER BY created_at DESC"
      ).bind(job.project, job.ticket_id, OPEN_STATUS, id).first();
      if (sibling) {
        return answer("held",
          `${job.project}/${job.ticket_id} is already live as ${sibling.id} (${sibling.kind}/${sibling.stage} on ${sibling.box}) — requeuing this row would be a second attempt on work that has an owner`,
          { held_by: sibling.id });
      }

      const prior = await env.DB.prepare(
        "SELECT COUNT(*) AS n FROM stage_events WHERE job_id=?1 AND verdict=?2"
      ).bind(id, "REQUEUED").first();
      const attempts = (Number(prior && prior.n) || 0) + 1;

      const decision = attempts > maxAttempts ? "parked" : "queued_for_retry";
      const reason = decision === "parked"
        ? `auto-requeued ${attempts - 1} times already (cap ${maxAttempts}) after ${detail} — parked for bin/blocked-resolver.sh rather than requeued a ${attempts}th time`
        : `requeued after ${detail} (auto-requeue ${attempts} of ${maxAttempts}); the lane's own next tick picks it up`;

      const bad = checkTransition(JOB_TRANSITIONS, String(job.status), decision, "job");
      if (bad) return json(409, { ...bad, job_id: id, refused: true, decision });

      await env.DB.prepare("UPDATE jobs SET status=?2, updated_at=?3 WHERE id=?1")
        .bind(id, decision, t).run();
      await putClaim(env, id, { lane, next_attempt_at: null, reason }, t);
      await env.DB.prepare(
        `INSERT INTO stage_events (job_id, stage, verdict, actor, detail, created_at)
         VALUES (?1,?2,?3,?4,?5,?6)`
      ).bind(id, job.stage, decision === "parked" ? "REQUEUE_CAPPED" : "REQUEUED",
        actor, reason, t).run();

      return answer(decision, reason, { attempts, ticket_id: job.ticket_id });
    },
  ],
];
