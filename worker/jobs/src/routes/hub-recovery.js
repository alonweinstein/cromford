// hub-recovery routes — BH-1943 (BH-1909.1), built on the BH-1942 contract.
//
// GET /api/hub/recovery
//   → 200 { lease: readLease(...) + {live:boolean} | null,
//           role: {active: string|null, active_expired_holder: string|null,
//                  standby: string[] (standby_status boxes), standby_note: string|null},
//           stale_min, stale_min_source: 'setting'|'fallback',
//           backups: [{box, backup_ts, backup_off, backup_unconfigured,
//                      backup_reported_at, state, age_min}],
//           standbys: [standby_status rows, by box],
//           recent_changes: [hub_lease_changes rows, newest first, at most 20],
//           truncated, as_of }
//   Read from hub_lease, box_status, standby_status, settings and hub_lease_changes only, never
//   over SSH. Always 200: an empty lease table is `lease:null`, and a missing
//   table is d1Guarded's 503, never a 404. `standby` comes from standby_status
//   (fed by POST /api/hub/standby/heartbeat) and is never inferred from hostnames.
//   Restore-lab history is NOT here: it is GET /api/hub/restore-lab.
//
// POST /api/hub/promote   body {target, expected_epoch, actor, reason, confirm, ttl_s,
//                               override_live_lease}
//   `holder` and `expect_epoch` (the issue #1943 spelling) are accepted as
//   aliases; the contract spelling wins when both are sent. Checked in order:
//   - actor empty              → 400 {error:"actor_required"}, NO audit row
//                                (hub_lease_changes.actor is NOT NULL, and
//                                auditStmt never invents one)
//   - settings.hub.promote_enabled
//     not on (seeded '0'; a
//     missing row is off too)  → 403 {error:"promote-disabled"}, outcome refused:promote-disabled
//   - confirmed(body) false    → 400 {error:"confirm_required"}, outcome refused:confirm
//   - target not a lane name,
//     or no box_status row     → 400 {error:"unknown_box"}, outcome refused:unknown_box
//   - expected_epoch not a JS
//     integer ≥ 0 ("4" is not) → 400 {error:"expected_epoch_invalid"}, refused:expected_epoch
//   - no lease row             → 409 {error:"no_lease", lease:null}, refused:no_lease
//   - expected ≠ live epoch,
//     or the epoch moved before
//     the write landed         → 409 {error:"stale_epoch", lease}, refused:stale_epoch
//   - the lease is still live
//     (expires_at > now) and
//     override_live_lease is not
//     the JSON literal true, or
//     the holder renewed before
//     the write landed         → 409 {error:"lease_live", lease, hint}, and NOTHING is
//                                written: not hub_lease, not an audit row
//   - success                  → 200 {ok:true, before:{holder,epoch}, after:{holder,epoch},
//                                     lease, promoted:true, audit_id, as_of,
//                                     override_live_lease, stop_old_hub}
//   Every refusal after the actor check, except lease_live, writes exactly one
//   promote_refused row and nothing to hub_lease. On success the epoch-fenced
//   UPDATE and the `promote` audit row go in ONE env.DB.batch; the audit INSERT
//   is conditional on the row now holding exactly what the UPDATE wrote, so a
//   lost CAS leaves no `ok` row behind. An overridden promote's row says
//   outcome `ok:override_live_lease`, a plain one `ok`. This is a different
//   route from POST /api/hub/lease/promote (src/routes/hub-lease.js), which
//   is retired: since BH-2272 it answers 410 {error:"gone",
//   use:"/api/hub/promote"} before any D1 statement.
//
// STOP THE OLD HUB FIRST (BH-2198). The epoch bump fences the old holder only
// when it can hear the worker. bin/hub-lease.sh FAILS OPEN on the configured
// hub while the worker is unreachable (BH-1000), so an old hub that is alive
// but cut off keeps running its lanes after this route answers 200: two hubs.
// The human step is to stop the old hub (stop its cron, or power it off) or cut
// its lane gate BEFORE promoting. That is why a live lease is refused, why the
// override exists only for "I have already stopped it", why the route is off
// until hub.promote_enabled is flipped, and why every 200 repeats the step in
// `stop_old_hub`: an expired lease can be exactly that isolated, still-running
// hub.

import { d1Guarded, json } from "../lib/http.js";
import {
  boolInt, ensureColumns, isoPlusSeconds, laneName, leaseTtl, leaseWon, readLease, str,
} from "../lib/core.js";
import { auditStmt, confirmed, knownBox } from "../lib/hub-recovery.js";

// The code fallback for settings.backup_stale_min, the same 30 as
// bin/lib/backup-freshness.sh's BF_DEFAULT_STALE_MIN.
const DEFAULT_STALE_MIN = 30;
const RECENT_CHANGES = 20;
const STANDBY_NOTE = "no standby has reported a heartbeat yet";

const LEASE_LIVE_HINT = "the current hub's lease is live: stop the old hub (stop its cron or power it off) or cut its lane gate, wait for the lease to expire, then promote; send override_live_lease:true only once it is stopped";
const stopOldHub = (holder) => `stop the old hub now: on ${holder}, run \`systemctl stop cron\` (or power it off) — bin/hub-lease.sh fails open while the worker is unreachable (BH-1000), so the epoch bump alone does not stop it`;

const withLive = (lease) => (lease ? { ...lease, live: !lease.expired } : null);

// One box_status row → {state, age_min}, in bf_state_age's order
// (bin/lib/backup-freshness.sh). An unparseable stamp is `unknown`, never
// `missing`: `missing` pages. age_min is null for every state without a real
// stamp; the only 0 is a stamp in the future (clock skew).
export function backupState(row, nowMs, staleMin) {
  if (row.backup_off) return { state: "off", age_min: null };
  if (row.backup_ts) {
    const ms = Date.parse(row.backup_ts);
    if (!Number.isFinite(ms)) return { state: "unknown", age_min: null };
    const age = Math.max(0, Math.floor((nowMs - ms) / 60000));
    return { state: age > staleMin ? "stale" : "ok", age_min: age };
  }
  if (row.backup_unconfigured) return { state: "unconfigured", age_min: null };
  return { state: "missing", age_min: null };
}

async function staleMin(env) {
  const v = await env.DB.prepare("SELECT value FROM settings WHERE key='backup_stale_min'").first("value");
  return typeof v === "string" && /^\d+$/.test(v)
    ? { stale_min: Number(v), stale_min_source: "setting" }
    : { stale_min: DEFAULT_STALE_MIN, stale_min_source: "fallback" };
}

// Off unless the row says so: a missing row, '0' or anything boolInt does not
// read as on keeps the route shut (BH-2198).
async function promoteEnabled(env) {
  const v = await env.DB.prepare("SELECT value FROM settings WHERE key='hub.promote_enabled'").first("value");
  return boolInt(v) === 1;
}

async function recovery({ env, t }) {
  return d1Guarded("hub_lease", async () => {
    await ensureColumns(env, "box_status");
    const lease = withLive(await readLease(env, t));
    const knob = await staleMin(env);
    const nowMs = Date.parse(t);
    const boxes = (await env.DB.prepare(
      "SELECT box, backup_ts, backup_off, backup_unconfigured, backup_reported_at FROM box_status ORDER BY box",
    ).all()).results || [];
    const changes = (await env.DB.prepare(
      "SELECT * FROM hub_lease_changes ORDER BY id DESC LIMIT ?1",
    ).bind(RECENT_CHANGES + 1).all()).results || [];
    const standbys = (await env.DB.prepare("SELECT * FROM standby_status ORDER BY box").all()).results || [];
    return json(200, {
      lease,
      role: {
        active: lease && lease.live ? lease.holder : null,
        active_expired_holder: lease && !lease.live ? lease.holder : null,
        standby: standbys.map((s) => s.box),
        standby_note: standbys.length ? null : STANDBY_NOTE,
      },
      standbys,
      ...knob,
      backups: boxes.map((b) => ({ ...b, ...backupState(b, nowMs, knob.stale_min) })),
      recent_changes: changes.slice(0, RECENT_CHANGES),
      truncated: changes.length > RECENT_CHANGES,
      as_of: t,
    });
  });
}

async function promote({ env, t, body }) {
  return d1Guarded("hub_lease", async () => {
    const rawTarget = body.target ?? body.holder;
    const expected = body.expected_epoch ?? body.expect_epoch;
    const actor = (str(body.actor, 64) || "").trim();
    const reason = str(body.reason, 500);
    if (!actor) return json(400, { error: "actor_required" });

    const refuse = async (status, error, why, extra = {}, before = null) => {
      await auditStmt(env, {
        action: "promote_refused", target: str(rawTarget, 64), actor, reason,
        outcome: `refused:${why}`, before_holder: before?.holder, before_epoch: before?.epoch,
      }, t).run();
      return json(status, { error, ...extra });
    };

    if (!(await promoteEnabled(env))) return refuse(403, "promote-disabled", "promote-disabled");
    if (!confirmed(body)) return refuse(400, "confirm_required", "confirm");
    const target = laneName(rawTarget);
    if (!target || !(await knownBox(env, target))) return refuse(400, "unknown_box", "unknown_box");
    if (!(Number.isInteger(expected) && expected >= 0)) {
      return refuse(400, "expected_epoch_invalid", "expected_epoch");
    }
    const before = await readLease(env, t);
    if (!before) return refuse(409, "no_lease", "no_lease", { lease: null });
    if (before.epoch !== expected) {
      return refuse(409, "stale_epoch", "stale_epoch", { lease: withLive(before) }, before);
    }

    // Refused with no write at all: nothing happened, and the operator's next
    // move is to stop the old hub, not to read an audit row.
    const override = body.override_live_lease === true;
    const refuseLive = (lease) => json(409, { error: "lease_live", lease: withLive(lease), hint: LEASE_LIVE_HINT });
    if (!before.expired && !override) return refuseLive(before);

    const after = expected + 1;
    const exp = isoPlusSeconds(t, leaseTtl(body.ttl_s));
    const res = await env.DB.batch([
      // Fenced on the epoch AND, unless overridden, on the lease still being
      // expired: an old holder that renews between the read and this write
      // keeps its lease.
      env.DB.prepare(
        "UPDATE hub_lease SET holder=?1, epoch=epoch+1, expires_at=?2, updated_at=?3 WHERE id=1 AND epoch=?4 AND (?5=1 OR expires_at<=?3)",
      ).bind(target, exp, t, expected, override ? 1 : 0),
      // Inserts only when the row holds exactly what the UPDATE above wrote, so
      // an `ok` row can never outlive a CAS that changed nothing.
      env.DB.prepare(
        "INSERT INTO hub_lease_changes (action,before_holder,before_epoch,after_holder,after_epoch,target,actor,reason,outcome,at) "
        + "SELECT 'promote',?1,?2,?3,?4,?3,?5,?6,?8,?7 FROM hub_lease WHERE id=1 AND holder=?3 AND epoch=?4 AND updated_at=?7",
      ).bind(before.holder, before.epoch, target, after, actor, reason, t, override ? "ok:override_live_lease" : "ok"),
    ]);
    if (!leaseWon(res[0])) {
      const now = await readLease(env, t);
      if (now && now.epoch === expected && !now.expired && !override) return refuseLive(now);
      return refuse(409, "stale_epoch", "stale_epoch", { lease: withLive(now) }, before);
    }
    return json(200, {
      ok: true,
      before: { holder: before.holder, epoch: before.epoch },
      after: { holder: target, epoch: after },
      lease: withLive(await readLease(env, t)),
      promoted: true,
      audit_id: res[1].meta.last_row_id,
      as_of: t,
      override_live_lease: override,
      stop_old_hub: stopOldHub(before.holder),
    });
  });
}

export const routes = [
  ["GET", "/api/hub/recovery", recovery],
  ["POST", "/api/hub/promote", promote],
];
