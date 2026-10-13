// hub-standby routes — BH-2639 (BH-2519.1) on the BH-2519 contract.
//
// The standby box's stream run reports its heartbeat here, and GET
// /api/hub/recovery reads it back as role.standby and `standbys`. The one store
// is standby_status (schema.sql), one row per standby box.
//
// POST /api/hub/standby/heartbeat   body {box, of, snapshot, ok}
//   - box not [A-Za-z0-9._-]{1,64} → 400; of not [a-z0-9-]{1,64} → 400;
//     ok not the JSON literal true or false → 400 ("true", 0, 1 and a missing
//     ok are all refused). None of these writes a row.
//   - snapshot is kept when it is a YYYYMMDDTHHMMSSZ stamp and stored as null
//     otherwise: a heartbeat is never refused for its snapshot.
//   - box without a box_status row → 409 {error:"unknown_box"}, so a typo
//     cannot create a ghost standby.
//   - otherwise upsert on box (reported_at = now) → 200 {ok:true, standby:<row>}.

import { json, d1Guarded } from "../lib/http.js";
import { laneName } from "../lib/core.js";
import { knownBox } from "../lib/hub-recovery.js";

const STAMP_RE = /^\d{8}T\d{6}Z$/;
const HUB_RE = /^[a-z0-9-]{1,64}$/;

export const routes = [
  ["POST", "/api/hub/standby/heartbeat", ({ env, t, body }) => d1Guarded("standby_status", async () => {
    const box = typeof body.box === "string" ? laneName(body.box) : "";
    if (!box) return json(400, { error: "box is required and must match [A-Za-z0-9._-]{1,64}" });
    if (typeof body.of !== "string" || !HUB_RE.test(body.of)) return json(400, { error: "of must match [a-z0-9-]{1,64}" });
    if (body.ok !== true && body.ok !== false) return json(400, { error: "ok must be true or false" });
    const snapshot = typeof body.snapshot === "string" && STAMP_RE.test(body.snapshot) ? body.snapshot : null;
    if (!(await knownBox(env, box))) return json(409, { error: "unknown_box" });
    await env.DB.prepare(
      "INSERT INTO standby_status (box,of_hub,snapshot,ok,reported_at) VALUES (?1,?2,?3,?4,?5) "
      + "ON CONFLICT(box) DO UPDATE SET of_hub=excluded.of_hub, snapshot=excluded.snapshot, ok=excluded.ok, reported_at=excluded.reported_at",
    ).bind(box, body.of, snapshot, body.ok ? 1 : 0, t).run();
    const standby = await env.DB.prepare("SELECT * FROM standby_status WHERE box=?1").bind(box).first();
    return json(200, { ok: true, standby });
  })],
];
