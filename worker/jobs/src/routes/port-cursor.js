// port-cursor routes — the watermark bin/port-to-cromford.sh keeps per public
// target (BH-5227): the last upstream sha ported to owner/name, and the PR that
// carried it. The client is bin/lib/port-cursor.sh.
//
// The PUT is compare-and-set on the stored sha, never an upsert: two ports of
// the same target that both read the same cursor cannot both move it, and the
// loser is told what the row holds now. src/index.js puts these in ROUTES, so
// both verbs sit behind the bearer.

import { json } from "../lib/http.js";

const TARGET_RE = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;
const SHA_RE = /^[0-9a-f]{40}$/;

const isTarget = (v) => typeof v === "string" && v.length <= 200 && TARGET_RE.test(v);
const isSha = (v) => typeof v === "string" && SHA_RE.test(v);

const readRow = (env, target) =>
  env.DB.prepare(`SELECT upstream_sha, pr_url FROM port_cursor WHERE target=?1`).bind(target).first();

const shape = (target, row, t) => ({
  target,
  upstream_sha: row ? row.upstream_sha : null,
  pr_url: row ? row.pr_url ?? null : null,
  as_of: t,
});

export const routes = [
  // ── GET /api/port/cursor?target=owner/name — the watermark, or null ─────
  // An unknown target is `upstream_sha: null`: the client must be able to tell
  // "never ported" from a read that failed.
  [
    "GET", "/api/port/cursor",
    async ({ env, url, t }) => {
      const target = url.searchParams.get("target");
      if (!isTarget(target)) return json(400, { error: "target required (owner/name)" });
      return json(200, shape(target, await readRow(env, target), t));
    },
  ],

  // ── PUT /api/port/cursor {target, sha, prev, pr_url} — COMPARE-AND-SET ──
  // prev:null claims a target that has no row; any other prev moves the row
  // only while it still holds prev. changes === 1 is the win; anything else,
  // including a missing meta (same doctrine as leaseWon in core.js), is a 409
  // carrying the stored row. Every field is checked before any statement (D11).
  [
    "PUT", "/api/port/cursor",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      if (!isTarget(b.target)) return json(400, { error: "target required (owner/name)" });
      if (!isSha(b.sha)) return json(400, { error: "sha must be 40 lowercase hex" });
      if (b.prev !== null && !isSha(b.prev)) return json(400, { error: "prev must be null or 40 lowercase hex" });
      if (b.pr_url !== null && typeof b.pr_url !== "string") return json(400, { error: "pr_url must be a string or null" });
      const r = b.prev === null
        ? await env.DB.prepare(
          `INSERT INTO port_cursor(target, upstream_sha, pr_url, updated_at) VALUES (?1,?2,?3,?4)
           ON CONFLICT(target) DO NOTHING`
        ).bind(b.target, b.sha, b.pr_url, t).run()
        : await env.DB.prepare(
          `UPDATE port_cursor SET upstream_sha=?2, pr_url=?3, updated_at=?4 WHERE target=?1 AND upstream_sha=?5`
        ).bind(b.target, b.sha, b.pr_url, t, b.prev).run();
      const won = ((r && r.meta && Number(r.meta.changes)) || 0) === 1;
      const row = await readRow(env, b.target);
      if (won) return json(200, shape(b.target, row, t));
      return json(409, { error: "cursor moved", ...shape(b.target, row, t) });
    },
  ],
];
