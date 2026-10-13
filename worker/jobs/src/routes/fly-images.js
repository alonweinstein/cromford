// fly-images routes — BH-2523: the Fly builder image each project's pool
// dispatches from, as a row every hub can read.
//
// The pointer (state/fly/<p>.image), the bake manifest (.bake) and the bake time
// (.baked-at) used to exist only as files on the hub that baked, so a fresh hub
// read "never baked" and bought a remote bake the fleet already had. The writers
// are bin/fly-image-build.sh and bin/fly-pool-rollout.sh; the readers go through
// bin/lib/fly-image-row.sh. baked_at is epoch seconds, like the files.

import { json } from "../lib/http.js";
import { strictInt, str, ensureTable, ensureColumns, laneName } from "../lib/core.js";

// The ref fly deploy --build-only --push prints, and nothing else: a garbage
// row must never be served to the pool as the image to spawn.
const DIGEST_RE = /^registry\.fly\.io\/[A-Za-z0-9._-]+:[A-Za-z0-9._-]+$/;
// A box clock a little ahead of the worker's is not a future bake. Past this it
// is refused, never clamped: a stored future baked_at would suppress rebakes.
const SKEW_S = 120;
const MANIFEST_MAX = 4096;
// BH-2743: the states a client may set. `baked` is a candidate the rollout has
// not smoke-tested yet, `smoke_failed` one whose smoke did not pass. `active`
// and `demoted` are the server's, set only by an activating PUT.
const CLIENT_STATES = new Set(["baked", "smoke_failed"]);
const epoch = (t) => Math.floor(Date.parse(t) / 1000);
const rowOut = (r) => ({
  project: r.project, app: r.app, digest: r.digest, bake: r.bake, cli: r.cli,
  baked_at: r.baked_at === null ? null : Number(r.baked_at),
  active: Number(r.active), box: r.box, set_at: r.set_at, state: r.state ?? null,
});

// Upsert on (project, digest). A resend without bake, cli or baked_at keeps the
// stored values: the rollout activates a ref the build already described. A
// candidate state never relabels the active row, and a resend without a state
// keeps the stored one.
const UPSERT_SQL =
  "INSERT INTO fly_images (project, digest, app, bake, cli, baked_at, active, box, set_at, state) "
  + "VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, ?7, ?8, ?9) "
  + "ON CONFLICT(project, digest) DO UPDATE SET app = excluded.app, "
  + "bake = COALESCE(excluded.bake, fly_images.bake), "
  + "cli = COALESCE(excluded.cli, fly_images.cli), "
  + "baked_at = COALESCE(excluded.baked_at, fly_images.baked_at), "
  + "box = COALESCE(excluded.box, fly_images.box), set_at = excluded.set_at, "
  + "state = CASE WHEN fly_images.active = 1 THEN fly_images.state "
  + "ELSE COALESCE(excluded.state, fly_images.state) END";

export const routes = [
  [
    "PUT", "/api/fly-images",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      if (!project) return json(400, { error: "project must match [A-Za-z0-9._-]{1,64}" });
      const app = laneName(body.app);
      if (!app) return json(400, { error: "app must match [A-Za-z0-9._-]{1,64}" });
      const digest = typeof body.digest === "string" && DIGEST_RE.test(body.digest) ? body.digest : "";
      if (!digest) return json(400, { error: "digest must be a registry.fly.io/<app>:<tag> ref" });
      // Bound to its own app: a ref another project's file carried (TK-1175)
      // must never become the image this project's pool spawns, fleet-wide.
      if (!digest.startsWith(`registry.fly.io/${app}:`)) {
        return json(400, { error: `digest must be under registry.fly.io/${app}:` });
      }
      let bakedAt = null;
      if (body.baked_at !== undefined && body.baked_at !== null && body.baked_at !== "") {
        bakedAt = strictInt(body.baked_at);
        if (bakedAt === null || bakedAt < 0) return json(400, { error: "baked_at must be a non-negative epoch integer" });
        if (bakedAt > epoch(t) + SKEW_S) return json(400, { error: "baked_at is in the future" });
      }
      const active = body.active === 1 || body.active === "1" || body.active === true;
      let state = null;
      if (body.state !== undefined && body.state !== null && body.state !== "") {
        if (!CLIENT_STATES.has(body.state)) return json(400, { error: "state must be baked or smoke_failed" });
        if (active) return json(400, { error: "state and active are exclusive: the server sets state on activation" });
        state = body.state;
      }
      await ensureTable(env, "fly_images");
      await ensureColumns(env, "fly_images");
      const upsert = env.DB.prepare(UPSERT_SQL).bind(
        project, digest, app, str(body.bake, MANIFEST_MAX), str(body.cli, MANIFEST_MAX),
        bakedAt, laneName(body.box) || null, t, state
      );
      if (active) {
        // One batch: every other row of the project off and demoted, this one
        // on. At most one active row per project holds by construction.
        await env.DB.batch([
          upsert,
          env.DB.prepare("UPDATE fly_images SET active = 0, state = 'demoted' WHERE project = ?1 AND digest != ?2 AND active != 0").bind(project, digest),
          env.DB.prepare("UPDATE fly_images SET active = 1, state = 'active' WHERE project = ?1 AND digest = ?2").bind(project, digest),
        ]);
      } else {
        await upsert.run();
      }
      const row = await env.DB.prepare(
        "SELECT * FROM fly_images WHERE project = ?1 AND digest = ?2"
      ).bind(project, digest).first();
      if (!row) return json(500, { error: "fly_images row not found after upsert" });
      return json(200, { ok: true, row: rowOut(row) });
    },
  ],

  // The active row only. No row is an answer (row:null, 200), never an error:
  // the reader falls back to its file on an unknown, and "none" is not unknown.
  [
    "GET", "/api/fly-images",
    async ({ env, url, t }) => {
      const project = laneName(url.searchParams.get("project"));
      if (!project) return json(400, { error: "project must match [A-Za-z0-9._-]{1,64}" });
      await ensureTable(env, "fly_images");
      const row = await env.DB.prepare(
        "SELECT * FROM fly_images WHERE project = ?1 AND active = 1 LIMIT 1"
      ).bind(project).first();
      return json(200, { row: row ? rowOut(row) : null, as_of: t });
    },
  ],
];
