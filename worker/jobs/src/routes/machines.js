// machines routes — the fly machine registry (BH-1055).
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  MACHINE_STATES, MACHINE_TERMINAL, ensureTable, laneName, decorateMachine,
  MACHINE_ROLES, OBSERVE_CAP, OBSERVE_GRACE_S, MACHINE_DETAIL_MAX, machineStr,
  isoPlusSeconds,
} from "../lib/core.js";

export const routes = [
  // ── Fly machine registry (BH-1055) ─────────────────────────────────────
  // WHAT THIS TABLE IS FOR: the hub spends real money on Fly machines and has
  // no memory of them between ticks. These four routes are that memory —
  // registered at spawn, refreshed from a listing, closed at destroy, read
  // back by the pool. Every one of them creates the table on its way in (the
  // preplans precedent: nothing in the fleet applies schema.sql, so a table
  // that waited for a hand step would 500 until someone noticed), and every
  // one of them stamps rows from `t`, the server clock, never from a time a
  // caller reported about itself.
  //
  // The `fly_machines_rows` flag is deliberately NOT read here: it is a
  // caller-side knob (`machines_rows_on` in bin/jobs-client.sh), so a hub
  // with it off writes nothing while a route that answers is still there to
  // be probed.

  // REGISTER ONE MACHINE, or correct what we know about it. The upsert is
  // keyed on `machine_id` (Fly's own id, globally unique), so a replayed
  // register is the same row, and `spawned_at` is COALESCEd — the first
  // register is the birth, later ones are only news about it.
  [
    "PUT", "/api/machines",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      const app = laneName(body.app);
      const machineId = laneName(body.machine_id);
      if (!project) return json(400, { error: "project is required and must match [A-Za-z0-9._-]{1,64}" });
      if (!app) return json(400, { error: "app is required and must match [A-Za-z0-9._-]{1,64}" });
      if (!machineId) return json(400, { error: "machine_id is required and must match [A-Za-z0-9._-]{1,64}" });
      const role = String(body.role === undefined || body.role === null ? "" : body.role).trim();
      if (!MACHINE_ROLES.has(role)) return json(400, { error: "role must be builder or pool" });
      const state = body.state === undefined || body.state === null || body.state === ""
        ? "spawned"
        : String(body.state).trim();
      if (!MACHINE_STATES.has(state)) return json(400, { error: "unknown machine state" });
      // `key` is a GET filter and half an index, so it is held to the same
      // character class as a lane name. Present but malformed is a 400, never
      // a silently dropped filter.
      let key = null;
      if (body.key !== undefined && body.key !== null && body.key !== "") {
        key = laneName(body.key);
        if (!key) return json(400, { error: "key must match [A-Za-z0-9._-]{1,64}" });
      }
      await ensureTable(env, "machines");
      await env.DB.prepare(
        `INSERT INTO machines
           (machine_id, project, app, role, key, ticket, auth_account, image, state, spawned_at, actor, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?10)
         ON CONFLICT(machine_id) DO UPDATE SET
           project=?2, app=?3, role=?4,
           key=COALESCE(?5, machines.key), ticket=COALESCE(?6, machines.ticket),
           auth_account=COALESCE(?7, machines.auth_account), image=COALESCE(?8, machines.image),
           state=?9, spawned_at=COALESCE(machines.spawned_at, ?10),
           ended_at=CASE WHEN ?12=1 THEN machines.ended_at ELSE NULL END,
           actor=?11, updated_at=?10`
      ).bind(
        machineId, project, app, role, key,
        machineStr(body.ticket, 128), machineStr(body.auth_account, 128), machineStr(body.image, 128),
        state, t, machineStr(body.actor, 64),
        MACHINE_TERMINAL.has(state) ? 1 : 0
      ).run();
      const row = await env.DB.prepare("SELECT * FROM machines WHERE machine_id=?1").bind(machineId).first();
      return json(200, { machine: decorateMachine(row, t) });
    },
  ],

  // BULK REFRESH FROM A FLY LISTING. The caller hands over what `fly machines
  // list` just showed it; this route makes the table agree with that.
  //
  // THE SWEEP IS THE POINT, AND IT IS A SET DIFFERENCE WITHOUT AN ID LIST.
  // Every listed row is stamped `last_seen = t` in the same transaction, so
  // `last_seen < t` IS "not in this listing" — no `NOT IN (<ids>)`, which
  // would blow past D1's 100-parameter limit at 100 machines and is exactly
  // the shape checks/sql-command-injection refuses to see interpolated.
  //
  // A row that has never been listed is judged on `spawned_at` instead, with
  // OBSERVE_GRACE_S of slack, because a machine created after the caller read
  // its listing is missing from that listing for an innocent reason. When
  // there is no `spawned_at` either — the row a PATCH close created for a
  // machine nobody registered — the fallback clock is the row's own
  // `updated_at`. Without it such a row is matched by NEITHER arm and sits at
  // `failed`/`destroy_failed`, `live=1`, for ever.
  [
    "PUT", "/api/machines/observe",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      const app = laneName(body.app);
      if (!project) return json(400, { error: "project is required and must match [A-Za-z0-9._-]{1,64}" });
      if (!app) return json(400, { error: "app is required and must match [A-Za-z0-9._-]{1,64}" });
      // An EMPTY array is a legal observation ("nothing is running"), which is
      // why absence of the field and an empty list are not the same answer.
      if (!Array.isArray(body.machines)) return json(400, { error: "machines must be an array" });
      const capped = body.machines.length > OBSERVE_CAP;
      const listed = [];
      // EVERY entry is validated before ANY write: a listing with one unknown
      // state is a caller that does not know what it is looking at, and half of
      // its observation applied is worse than none of it.
      for (const m of body.machines.slice(0, OBSERVE_CAP)) {
        const id = laneName(m && m.machine_id);
        if (!id) return json(400, { error: "every listed machine_id must match [A-Za-z0-9._-]{1,64}" });
        const st = String((m && m.state) === undefined || (m && m.state) === null ? "" : m.state).trim();
        if (!MACHINE_STATES.has(st)) return json(400, { error: "unknown machine state in listing" });
        listed.push({ id, state: st });
      }
      const actor = machineStr(body.actor, 64);
      await ensureTable(env, "machines");
      // `registered` is measured, not counted from the caller's list: the only
      // honest source for "how many of these we had never seen" is the row
      // count on either side of the upserts, inside the same transaction.
      const countStmt = env.DB.prepare(
        "SELECT COUNT(*) AS n FROM machines WHERE project=?1 AND app=?2"
      );
      // An id with no row is REGISTERED, not ignored: a machine we are paying
      // for and do not know about is the thing this table exists to surface.
      // `ended_at` is left NULL on that insert on purpose — Fly still lists the
      // machine, so this is a sighting, not a close; PATCH is the close.
      const upsert = env.DB.prepare(
        `INSERT INTO machines
           (machine_id, project, app, role, key, state, spawned_at, last_seen, actor, updated_at)
         VALUES (?1,?2,?3,'pool',NULL,?4,NULL,?5,?6,?5)
         ON CONFLICT(machine_id) DO UPDATE SET
           state=?4, last_seen=?5, actor=COALESCE(?6, machines.actor), updated_at=?5,
           ended_at=CASE WHEN ?7=1 THEN COALESCE(machines.ended_at, ?5) ELSE NULL END`
      );
      const stmts = [countStmt.bind(project, app)];
      for (const m of listed) {
        stmts.push(upsert.bind(m.id, project, app, m.state, t, actor, MACHINE_TERMINAL.has(m.state) ? 1 : 0));
      }
      stmts.push(countStmt.bind(project, app));
      // A CAPPED LISTING SWEEPS NOTHING. A partial view cannot prove absence,
      // and `gone` is the one mark here a client acts on. The answer says
      // `capped:true` so the caller knows the sweep is owed, not done.
      if (!capped) {
        stmts.push(env.DB.prepare(
          `UPDATE machines SET state='gone', ended_at=?3, updated_at=?3
            WHERE project=?1 AND app=?2 AND state NOT IN ('destroyed','gone')
              AND ((last_seen IS NOT NULL AND last_seen < ?3)
                OR (last_seen IS NULL AND COALESCE(spawned_at, updated_at) < ?4))`
        ).bind(project, app, t, isoPlusSeconds(t, -OBSERVE_GRACE_S)));
      }
      const res = await env.DB.batch(stmts);
      const countOf = (r) => {
        const rr = (r && r.results) || [];
        return rr.length ? Number(rr[0].n) || 0 : 0;
      };
      const registered = Math.max(0, countOf(res[listed.length + 1]) - countOf(res[0]));
      const sweep = capped ? null : res[listed.length + 2];
      const gone = sweep && sweep.meta ? (sweep.meta.changes || 0) : 0;
      return json(200, { seen: listed.length, registered, gone, capped, as_of: t });
    },
  ],

  // CLOSE OR CORRECT ONE MACHINE. An UPSERT rather than an UPDATE because the
  // close is the call most likely to arrive for a machine nobody registered
  // (a destroy of something the pool found running), and a close that writes
  // nothing is how a machine stays invisible forever.
  // `observe` is a ROUTE on this prefix, not a machine id: a client that
  // sends PATCH where it meant PUT must get a 404, not a registered machine
  // literally named `observe`.
  [
    "PATCH", { re: /^\/api\/machines\/([A-Za-z0-9._-]{1,64})$/, not: "observe" },
    async ({ env, t, body, m: machineMatch }) => {
      const machineId = machineMatch[1];
      const project = laneName(body.project);
      const app = laneName(body.app);
      if (!project) return json(400, { error: "project is required and must match [A-Za-z0-9._-]{1,64}" });
      if (!app) return json(400, { error: "app is required and must match [A-Za-z0-9._-]{1,64}" });
      const state = String(body.state === undefined || body.state === null ? "" : body.state).trim();
      if (!MACHINE_STATES.has(state)) return json(400, { error: "unknown machine state" });
      let detail = null;
      if (body.detail !== undefined && body.detail !== null && body.detail !== "") {
        if (typeof body.detail !== "string") return json(400, { error: "detail must be a string" });
        if (body.detail.length > MACHINE_DETAIL_MAX) {
          return json(400, { error: "detail must be 300 characters or fewer" });
        }
        detail = body.detail;
      }
      await ensureTable(env, "machines");
      // ended_at only moves on a TERMINAL state. A correction that says the
      // machine is `failed` or `stopped` leaves the end stamp exactly as it
      // was, because neither of those is an end.
      await env.DB.prepare(
        `INSERT INTO machines
           (machine_id, project, app, role, state, detail, ended_at, actor, updated_at)
         VALUES (?1,?2,?3,'pool',?4,?5,CASE WHEN ?7=1 THEN ?6 ELSE NULL END,?8,?6)
         ON CONFLICT(machine_id) DO UPDATE SET
           state=?4, detail=COALESCE(?5, machines.detail),
           ended_at=CASE WHEN ?7=1 THEN ?6 ELSE machines.ended_at END,
           actor=COALESCE(?8, machines.actor), updated_at=?6`
      ).bind(
        machineId, project, app, state, detail, t,
        MACHINE_TERMINAL.has(state) ? 1 : 0, machineStr(body.actor, 64)
      ).run();
      const row = await env.DB.prepare("SELECT * FROM machines WHERE machine_id=?1").bind(machineId).first();
      return json(200, { machine: decorateMachine(row, t) });
    },
  ],

  // READ THE REGISTRY. Every filter is optional and every filter that is
  // PRESENT must be well formed — a malformed `project=` answers 400 rather
  // than quietly listing the whole fleet to a caller that asked for one lane.
  [
    "GET", "/api/machines",
    async ({ env, url, t }) => {
      const where = [];
      const binds = [];
      for (const name of ["project", "app", "key"]) {
        const raw = url.searchParams.get(name);
        if (raw === null || raw === "") continue;
        const v = laneName(raw);
        if (!v) return json(400, { error: name + " must match [A-Za-z0-9._-]{1,64}" });
        binds.push(v);
        where.push(name + "=?" + binds.length);
      }
      // `live=1` is what the pool asks: everything Fly could still be billing
      // us for. A terminal row is history, not inventory.
      if (url.searchParams.get("live") === "1") where.push("state NOT IN ('destroyed','gone')");
      await ensureTable(env, "machines");
      // Assembled from a fixed clause list and bound parameters, never from
      // request text — see checks/sql-command-injection.
      const sql = "SELECT * FROM machines"
        + (where.length ? " WHERE " + where.join(" AND ") : "")
        + " ORDER BY updated_at DESC, machine_id ASC LIMIT 500";
      const stmt = env.DB.prepare(sql);
      const rows = await (binds.length ? stmt.bind(...binds) : stmt).all();
      return json(200, {
        machines: (rows.results || []).map((r) => decorateMachine(r, t)),
        as_of: t,
      });
    },
  ],
];
