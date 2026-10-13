// hub-lease routes — which box is the hub, decided by compare-and-swap.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { d1Guarded, json } from "../lib/http.js";
import {
  strictInt, laneName, leaseTtl, isoPlusSeconds, leaseWon, readLease,
} from "../lib/core.js";

export const routes = [
  // ── THE HUB LEASE (BH-429) ─────────────────────────────────────────────
  // Hub-ness is a lease on one row, not a hostname in a conf file. Two facts
  // shape these three routes:
  //
  //   THE SERVER CLOCK IS THE ONLY CLOCK. Boxes were 66-464 s slow on
  //     2026-09-14, so "is this lease expired" is answered here, against `t`,
  //     and never by the box asking the question.
  //   NO READ-THEN-WRITE. Each rung is ONE statement whose WHERE is the
  //     compare-and-swap, judged by meta.changes — the same pattern the
  //     build_queue claim uses. Two boxes renewing the same expired lease in
  //     the same millisecond cannot both be told they won, because the second
  //     UPDATE sees an expires_at the first one already pushed into the
  //     future.
  //
  // The ladder self-bootstraps (rung 3), so rolling this out needs no human
  // promote: the first box to renew an empty table becomes the hub at epoch 1.
  //
  // Each route also answers on the spelling bin/hub-lease.sh already ships
  // (/api/hub-lease, /api/hub-lease/promote) — that client merged in #494 and
  // this slice may not touch bin/, so the aliases are what keep it from
  // reading a deployed worker as unreachable.
  [
    "GET", ["/api/hub/lease", "/api/hub-lease"],
    async ({ env, t }) => {
      // ALWAYS 200, even with no row: a 404 must uniquely mean "the worker is
      // not deployed yet", which the client treats as unreachable.
      return d1Guarded("hub_lease", async () =>
        json(200, { lease: await readLease(env, t), as_of: t }));
    },
  ],

  [
    "POST", ["/api/hub/lease/renew", "/api/hub-lease"],
    async ({ env, t, body }) => {
      // BH-1000: the ladder below is UNCHANGED — it is wrapped whole, at its
      // own indentation, so the diff is the wrap and nothing else. The two
      // validation 400s return before the first statement either way.
      return d1Guarded("hub_lease", async () => {
      const holder = laneName(body.holder);
      if (!holder) return json(400, { error: "holder is required and must match [A-Za-z0-9._-]{1,64}" });
      const epoch = strictInt(body.epoch);
      if (epoch === null || epoch < 0) return json(400, { error: "epoch must be a non-negative integer" });
      const exp = isoPlusSeconds(t, leaseTtl(body.ttl_s));

      // 1. Still ours and still live → extend it. The epoch is the fence: a box
      //    renewing with a cached epoch it has since lost matches nothing here.
      const held = await env.DB.prepare(
        "UPDATE hub_lease SET expires_at=?1, updated_at=?2 WHERE id=1 AND holder=?3 AND epoch=?4 AND expires_at > ?2"
      ).bind(exp, t, holder, epoch).run();
      if (leaseWon(held)) return json(200, { lease: await readLease(env, t), renewed: true, as_of: t });

      // 2. Expired → anyone may take it, and the epoch BUMPS even for the same
      //    holder, so no stale cached epoch anywhere in the fleet can ever equal
      //    the live one again.
      const taken = await env.DB.prepare(
        "UPDATE hub_lease SET holder=?1, epoch=epoch+1, expires_at=?2, updated_at=?3 WHERE id=1 AND expires_at <= ?3"
      ).bind(holder, exp, t).run();
      if (leaseWon(taken)) return json(200, { lease: await readLease(env, t), taken: true, as_of: t });

      // 3. No lease has ever existed → bootstrap. DO NOTHING is what makes this
      //    safe in a race: the loser changes no rows and falls to the 409.
      const first = await env.DB.prepare(
        "INSERT INTO hub_lease (id, holder, epoch, expires_at, updated_at) VALUES (1, ?1, 1, ?2, ?3) ON CONFLICT(id) DO NOTHING"
      ).bind(holder, exp, t).run();
      if (leaseWon(first)) return json(200, { lease: await readLease(env, t), taken: true, as_of: t });

      // 4. Somebody else holds a live lease. Nothing was written.
      return json(409, { error: "lease held", lease: await readLease(env, t), as_of: t });
      });
    },
  ],

  // RETIRED (BH-2272). This was a force-promote: one upsert, no setting, no
  // confirm, no epoch, no live-lease check and no audit, reachable by any box
  // holding HARNESS_SECRET. bin/hub-lease.sh `promote --holder X` sent it
  // `{"holder":"--holder"}`, and it promoted a hub by that name, so every real
  // hub's check failed closed. Moving the hub is POST /api/hub/promote now
  // (routes/hub-recovery.js): confirm-gated, epoch-fenced, audited, and a
  // target must be a box the fleet has heard from. Both spellings stay in the
  // table and answer 410 BEFORE any statement, never a 404, which this client
  // family reads as "worker not deployed".
  [
    "POST", ["/api/hub/lease/promote", "/api/hub-lease/promote"],
    async ({ t }) => json(410, {
      error: "gone",
      use: "/api/hub/promote",
      detail: "the legacy force-promote is retired (BH-2272); POST /api/hub/promote {target, expected_epoch, actor, reason, confirm:true}",
      as_of: t,
    }),
  ],
];
