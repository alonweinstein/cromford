# Child context packs (hub side)

**What it is:** when a ticket splits, the parent's plan has already paid to
read the code. The parent publishes that reading once per split child, and the
child fetches it before it plans, so it starts warm instead of re-reading the
same files. This page covers the hub half (BH-3493): the `context_packs` D1
table, the `/api/context-packs` route, the `stage.plan.child` model route and
the two settings rows. The shell client is `bin/lib/context-pack.sh`
(`cp_put`, `cp_fetch`, `cp_preamble`, BH-3492). Everything on the shell side
fails open: a 404 or a missing setting means "plan in full, as before".

**How an operator reaches it.** No cron lane of its own. It is a worker route
the build pipeline calls:

| what | where |
|---|---|
| the table | `CREATE TABLE IF NOT EXISTS context_packs` in the `BH-3478.1 (BH-3493)` block at the end of `worker/jobs/schema.sql`, and the same DDL as `CREATED_TABLES.context_packs` in `worker/jobs/src/lib/core.js` |
| the route | `worker/jobs/src/routes/context-packs.js`, wired in `ROUTES` of `worker/jobs/src/index.js` directly after the preplans routes; bearer-only like every `ROUTES` entry |
| the model route | hub role `stage.plan.child`, seeded as a copy of the `plan` rung 0 (no model literal) |
| the knobs | settings `child_plan_tripwire_pct` (seed `50`) and `child_preplan_delta_tokens` (seed `150000`) |

**The wire contract:**

- `POST /api/context-packs` with `{project, ticket_key, parent_key, base_sha?, pack_md, box?}`
  answers `200 {context_pack}` (the row without `pack_md`) on upsert keyed by
  `(project, ticket_key)`. `400` when a key fails `[A-Za-z0-9._-]{1,64}`, when
  `parent_key` equals `ticket_key`, or when `pack_md` is empty, whitespace or not
  a string. `413 {error, bytes, max}` when `pack_md` is over 64000 UTF-8 bytes,
  and nothing is stored: an existing pack for the same key is left as it was.
  `base_sha` is lowercased and not validated. `created_at` survives an upsert,
  and so does `box` when the new POST omits it.
- `GET /api/context-packs?project=&key=` answers `200 {context_pack:{project,
  ticket_key, parent_key, base_sha, pack_md, bytes, box, created_at, updated_at},
  as_of}` or `404 {"error":"no such context pack"}`. `key` is required: there
  is no index read.

**Apply mechanism:** `bin/harness-sync.sh` applies `worker/jobs/schema.sql`
statement by statement before `wrangler deploy`. Both verbs also call
`ensureTable`, so a D1 the apply never reached answers an honest 404 on its
first read instead of a 500.

**How to drive it:**

| what | how |
|---|---|
| the whole contract, the seeds, the tombstone guard and the DDL parity | `cd worker/jobs && node --test test/context-packs.bh-3493.test.js` |
| the route's place in `ROUTES` | `cd worker/jobs && node --test test/route-table.test.js` |

**Live probes** (after the worker deploy, from the hub):

```bash
curl -s -H "Authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/context-packs?project=cromford&key=<child>" | jq .context_pack.parent_key
curl -s -H "Authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/model-routes/stage.plan.child" | jq .ladder
curl -s -H "Authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/settings/child_plan_tripwire_pct" | jq .setting.value
```

The first answers the parent's key for a child that has a pack, and a 404 for
one that has none. The second is one rung equal to
`/api/model-routes/plan` rung 0. The third answers `"50"` until an
operator changes it.

**What usually lies:**

- A 404 on the GET means no pack was published for that child, not an outage.
  The child plans in full, which is the pre-BH-3478 behaviour.
- `stage.plan.child` missing from the ladder after a deploy usually means a
  `model_route_changes` row exists for the role (an operator removed it), and
  the seed never overrules that. The resolver falls back to `plan` by design.
- A 200 on the POST proves the row landed, not that any child read it. The
  read side is the `cp_fetch` call in the child's plan stage.

**Manual-only / not automatable:** nothing here needs a browser. The live
probes need the hub's bearer and are read-only.
