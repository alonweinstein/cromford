// lane-runs-lease routes — the lease, the heartbeat and the attempt cap of the
// lane_runs queue (routes/lane-runs.js). Contract and knobs:
// docs/notes/2026-10-12-BH-6125-lane-run-lease.md.
//
// POST /api/lane-runs/:id/heartbeat {machine}: ONE statement extends
// lease_until to now + lane_run.lease_s and sets heartbeat_at, only while the
// row is `claimed` by that machine. Anything else is 409 `lost` with a reason
// (no_row, not_claimed, not_claimer) and writes nothing; the worker's loop
// (bin/lib/lane-run-heartbeat.sh) kills its run on it and sends no report.
//
// sweepDead(env, now): routes/lane-runs.js awaits it before every claim. ONE
// statement turns each `claimed` row whose lease ran out at attempts >=
// lane_run.max_attempts into `died`, rc 137. The claim never matches `died`
// and the live index excludes it, so the row is terminal.

import { d1Guarded, json } from "../lib/http.js";
import { isoPlusSeconds, laneName, leaseWon } from "../lib/core.js";

// The settings rows, their bounds and their documented code fallbacks.
const LEASE = { key: "lane_run.lease_s", def: 120, min: 30, max: 3600 };
const MAX_ATTEMPTS = { key: "lane_run.max_attempts", def: 3, min: 1, max: 20 };
const DIED_RC = 137;

// A settings integer in [min, max], else the fallback. Same rule as the claim's
// lease read in routes/lane-runs.js.
async function settingInt(env, { key, def, min, max }) {
  const r = await env.DB.prepare("SELECT value FROM settings WHERE key=?1").bind(key).first();
  const s = r ? String(r.value).trim() : "";
  const n = /^\d+$/.test(s) ? Number(s) : NaN;
  return n >= min && n <= max ? n : def;
}

export async function sweepDead(env, now) {
  const max = await settingInt(env, MAX_ATTEMPTS);
  const r = await env.DB.prepare(
    "UPDATE lane_runs SET status='died', rc=?3, finished_at=?1 WHERE status='claimed' AND lease_until < ?1 AND attempts >= ?2"
  ).bind(now, max, DIED_RC).run();
  return Number(r && r.meta && r.meta.changes) || 0;
}

export const routes = [
  [
    "POST", /^\/api\/lane-runs\/(\d+)\/heartbeat$/,
    ({ env, t, body, m }) => d1Guarded("lane_runs", async () => {
      const id = Number(m[1]);
      const machine = laneName(body.machine);
      if (!machine) return json(400, { error: "machine is required and must match [A-Za-z0-9._-]{1,64}" });
      const lease = isoPlusSeconds(t, await settingInt(env, LEASE));
      const r = await env.DB.prepare(
        "UPDATE lane_runs SET lease_until=?1, heartbeat_at=?2 WHERE id=?3 AND status='claimed' AND claimed_by=?4"
      ).bind(lease, t, id, machine).run();
      if (leaseWon(r)) return json(200, { id, status: "claimed", lease_until: lease, as_of: t });
      const row = await env.DB.prepare("SELECT status, claimed_by FROM lane_runs WHERE id=?1").bind(id).first();
      const reason = !row ? "no_row" : row.status !== "claimed" ? "not_claimed" : "not_claimer";
      return json(409, { error: "lost", reason, id, status: row ? row.status : null, as_of: t });
    }),
  ],
];
