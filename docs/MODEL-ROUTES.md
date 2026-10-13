# Model routes (BH-1510)

How a lane learns which model, and which runner, to call — as a database row,
not a `${VAR:-claude-fable-5-1}` shell default.

## The directive

> "We shouldn't have hardcodes anywhere; all of that should be DB values."
> — the operator, 2026-09-22

136 model-id literals were measured on main (b4912c5c) across ~40 files, every
one a shell-default fallback or a bare argv literal: `bin/agent-call.sh`
(29 — failover candidates, codex/grok defaults), `bin/update-model-prices.sh`
(28 — the price MAP), `catalog/lanes.d/*.json` knob defaults, and every plan/
execute/review/qa/triage/decompose/orchestrate call site in between. There was
no table and no resolver — an operator who wanted to move one lane to a
different model had to find every call site that carried it and ship a deploy.

## The shape

**`model_routes`** (Cloudflare D1, `worker/jobs/schema.sql`): one row per
*rung* of a role's failover ladder.

| column | meaning |
|---|---|
| `scope` | `'hub'` or `'project'` — decorative; `project IS NULL` is the real switch |
| `project` | `NULL` = hub default; a `fleet.conf` project name otherwise |
| `role` | the job this rung serves — `build.execute`, `triage`, `codex.default`, … |
| `position` | 0 = primary, 1.. = failover order within this role+scope |
| `model` | must carry a `model_prices` row at write time |
| `runner` | one of `claude \| codex \| openrouter \| grok \| fireworks` |
| `updated_by`, `updated_at` | audit metadata on the CURRENT row |

Uniqueness is on `(coalesce(project,''), role, position)`, not a plain
composite primary key — SQLite never equates two `NULL`s in a uniqueness
check, so a bare `PRIMARY KEY (project, role, position)` would let an
unlimited number of hub rows collide at the same rung instead of refusing the
second one.

**`model_route_changes`** is append-only: one row per WRITE (not per rung), so
a role's history reads as a sequence of decisions. `before_*` is `NULL` when a
write ADDED a rung; `after_*` is `NULL` when a write REMOVED one (a shorter
ladder than before).

**Precedence is per ROLE, not per rung.** A project either owns its whole
ladder for a role, or it owns none of it — `resolveModelLadder` (worker) and
`model_ladder` (bash) never merge one operator's hub rung 1 with a different
operator's project rung 0. A project ladder is a complete replacement, always
written and read as a whole array.

## No RLS step

This is Cloudflare D1, reached only through the bearer-authed worker
(`HARNESS_SECRET`) — the same access boundary every other table in
`worker/jobs/schema.sql` uses (see `docs/DB-COORDINATION-SPEC.md`). The
Supabase RLS doctrine (`~/.claude/rules/supabase-rls.md`) does not apply to a
D1 binding.

## The routes

- `GET /api/model-routes/<role>?project=<p>` — the resolved ladder for one
  role: `{role, project, ladder:[{position,model,runner}], source}`, where
  `source` is `project` / `hub` / `none`. 200 with an empty ladder for an
  unknown role — a real answer, not a 404.
- `GET /api/model-routes?project=<p>` — every role with a hub row (or, with
  `?project=`, every role either scope has one for), resolved. The console
  Models screen (#1510.3) reads this.
- `PUT /api/model-routes` — `{role, project?, ladder:[{model,runner}], actor?,
  reason?}`. Replaces the WHOLE ladder for `(scope, role)` in one call, writes
  one `model_route_changes` row per rung that actually changed (a re-PUT of an
  identical ladder writes no new audit rows), and DELETEs any trailing rung the
  new ladder dropped (also audited, `after_*` NULL). Refuses an unknown
  `runner`, an unpriced `model` (not in `model_prices`), or a malformed
  `role`/`project` — 400, nothing written.
- **Every write replaces the WHOLE scope in one D1 batch (#1510.3 fix round 1).**
  The PUT deletes every row of `(project, role)` and inserts the new ladder in
  the same transaction; an unchanged rung keeps its own `updated_by` /
  `updated_at`. The earlier upsert-plus-delete-the-positions-it-read shape let
  two concurrent writes leave a ladder nobody wrote (`[b0, a2]`, or a project
  override holding only rung 2), which a first-row reader would promote.
- **Optimistic concurrency.** The one-role read returns `scope_version` (the
  highest row id in the scope it names, 0 when empty; every write moves it) and
  `hub_scope_version` (the same number for the HUB scope; equal to
  `scope_version` on a hub read). A PUT or reset carrying `expected_version`
  that no longer matches answers **409** and writes nothing — checked at read
  time AND as a statement of the batch, so a write that lands between the two is
  still caught. The console always sends it and reloads on a 409.
- **The hub-drift guard (#1563).** A project's `scope_version` is 0 while it has
  no override, so `expected_version` alone cannot notice the HUB ladder moving
  under a save that is *creating* an override from it. A project PUT may carry
  `expected_hub_version` as well; it is guarded the same way (read time, plus a
  second in-batch guard on the hub scope). It belongs to the project PUT and
  nowhere else — on a hub write, or on a reset (which deletes the project's own
  rows), it is a **400**, never a silently ignored field that would read as
  protection; a non-integer is a 400 too. The
  409 body carries `scope_version`, `hub_scope_version` and `stale`, which is
  `project`, `hub` or `both`. The console sends the field exactly when the edit
  is based on an inherited hub ladder — a project that owns its override does
  not, because a hub edit cannot affect it — and words its message from `stale`.
- **`confirm: true`** on a PUT of an unchanged ladder re-stamps every rung with
  the actor and audits each with before = after. It is how a `'seed'` rung is
  recorded as reviewed without changing its model (the console's KEEP SEEDED
  VALUE). Without it an unchanged PUT writes nothing.
- **No rung 0 = no scope.** `resolveModelLadder` (worker) and `model_ladder`
  (bash) treat a scope whose rows do not start at position 0 as absent: a
  project scope falls back to the hub (the bash side alerts once a day), a
  hub scope is no route (rc 75). A gapped ladder is never cached.
- **…and the gapped scopes that rule hides are listed (#1563).** Because the
  resolver ignores them, nothing used to say they existed. `GET
  /api/model-routes` carries `gaps` — every scope fleet-wide with
  `min(position) > 0`, as `{project, role, positions}`, on EVERY tab — plus
  `gapped: true` on a role whose own scope for that read is one of them. The
  one-role read carries `gapped: {rows}` (the orphan rows) for the scope it
  names, or `null`. A hole PAST rung 0 (a `0,2` ladder) is not a gap: position
  is a failover order, not an index, and the resolver serves it correctly. The
  console banners them with a link each and tags the row `GAPPED`; the role page
  lists the orphan rungs and offers RESET TO HUB (a project scope) or SAVE
  LADDER (either), both of which replace the whole scope under the existing
  version guard. `bin/model-route-gap-check.sh` (hub, daily 04:35Z) writes one
  `ALERTS.log` line per gapped scope per UTC day through the same reservoir flag
  `bin/lib/model-route.sh` uses (`alerted-model-route-<role>-norung0…`), so the
  two paths together page once per scope-day.
- An empty-string `project` on a PUT body is refused (400), not read as the hub.
- `POST /api/model-routes/reset` — `{role, project, actor?, reason?, expected_version?}` (#1510.3).
  Deletes that PROJECT's whole override for the role, one audit row per removed
  rung (`after_*` NULL), and answers the role's newly resolved ladder (the hub
  default). The audit rows are read inside the batch that deletes the rungs
  (BH-1928), so they name what was actually deleted, and `removed` is the
  DELETE's own count. Project-only: 400 without one. A project with no override is a
  no-op (`removed: 0`), not an error. Its own route because the PUT refuses an
  empty ladder on purpose.
- `POST /api/model-routes/remove` — `{role, actor?, reason?, expected_version?}` (BH-1572).
  Takes a HUB role away, durably: every hub rung is deleted in one batch, each
  with its own audit row (`after_*` NULL), and the role then resolves to no
  route, so each caller does what it does for no route (a floor rung is skipped,
  which is how a floor is switched off; a build lane defers). Hub-only: a
  `project` is refused (400; drop an override with reset). The audit rows are
  read inside the same batch as the DELETE (BH-1928), so a write that lands
  while the request is in flight is audited with the value actually deleted,
  and `removed` is the DELETE's own count. A role with no hub rows writes one
  **tombstone** audit row (position 0, every `before_*`/`after_*` NULL) and
  answers `{removed: 0, tombstone: true}`; the MODELS history labels it
  "removed". Put a role back with a PUT.
  **The audit rows are the tombstone.** Every `model_routes` seed in
  `worker/jobs/schema.sql` skips a role with ANY hub audit history, so a role an
  operator has decided (removed, or PUT, including a PUT that cut rungs) is never
  re-seeded by the next deploy. Before BH-1572 the #1510.0 and #1510.2 VALUES
  seeds were per rung, and put back any rung a PUT had cut on every deploy. A raw
  `DELETE` leaves no audit row, so the seed still restores that role, until a
  remove on it writes its tombstone.
  **A seed change to an existing role is inert on live.** For the same reason,
  changing a role's rungs in `schema.sql` reaches a fresh database only: the
  deploy skips every role with hub history. `bin/model-route-seed-lint.sh` (CI,
  lint job, BH-1928) fails a PR whose seed changes for a role already in the
  base seed unless it also ships the audited PUT that moves live (a changed
  `bin/` or `scripts/` file whose code makes a PUT call to `/api/model-routes`,
  `_jobs_req PUT` or `curl -X PUT`, and names the role; a file that only reads
  the API or mentions a PUT in a message does not count)
  or says `seed-only: fresh-db` in the PR body or on an added schema.sql line.
  A brand-new role passes: it has no history, so its seed lands.
- `GET /api/model-route-changes?role=<r>[&project=<p>][&limit=<n>]` — the audit
  trail, newest first (#1510.3). With `project`, that project's changes AND the
  hub's (a project on the hub default runs whatever the hub was last set to);
  without it, every scope. `limit` defaults to 100, caps at 500, and
  `truncated: true` says when it bit.

The list read (`GET /api/model-routes`) also carries `runners` (the closed
runner set) and, per rung, `updated_by` / `updated_at` — so the console can tag
rungs still holding their `'seed'` value. The one-role read keeps its
`{position, model, runner}` rung shape, which `bin/lib/model-route.sh` parses,
and carries `scope_version`, `runners` and a `provenance` list beside it.

## The console: MODELS (#1510.3)

`/models` (hub tab, plus one tab per fleet project) is one sortable row per
role: role, primary model, failover ladder, runner, $/1M in and out (from
`model_prices`, stored per token), the last 7 days' calls and spend, and
whether the row is the hub default or a project override. `/models/<role>` is
the ladder, the editor (model choices = priced models only, runner choices =
the worker's `runners`, a reason field, an in-app confirm modal showing every
rung before → after), RESET TO HUB on a project override, and the role's
history with each change its own `#change-<id>` anchor.

**WHO is always `console`.** The console has no operator identity: login is
`/login/<DASH_SECRET>`, one shared secret that mints an anonymous `dash`
cookie, and no username, email or session subject exists anywhere in
`console-ui/` or the worker. So every console write records `actor: 'console'`
(`ACTOR` in `console-ui/src/lib/models.js`). The worker already stores whatever
`actor` a body carries, sliced to 128 chars, so the day a session carries an
identity, that constant is the one place to pass it through — until then no
placeholder is invented.

**Spend per role is an attribution, not a column.** `cost_rows` records the
stage a call ran under (`bin/agent-call.sh`'s first argument), its runner and
its project — never the role. `console-ui/src/lib/models.js`
`ROLE_ATTRIBUTION` maps each role onto those labels and grades it: `exact`,
`shared` (the figure is the whole stage, and the roles sharing it are named),
`partial`, or `none` (a dash, never $0). As of #1510.3: `auth.fallback` has no
attribution (it is a failover for any stage, and its calls carry that stage's
label); `greenfield` and `product` are partial; the triage family, the
build.execute pair, the review pair and the fireworks pair are shared stages. A
role added later with no entry reads as `none` until one is written.

**The #1507 carry-over.** The seed rows still holding claude-opus-5 /
claude-fable-5-1 (see the issue comment on #1510) are tagged SEED on the
screen, with a banner counting the roles that carry one. The screen does not
change them on its own: an operator either changes the model and saves, or
presses KEEP SEEDED VALUE (a `confirm: true` PUT) to record the seed as
reviewed. Moving the #1507 rows is that operator edit, or the first reader
slice's data write.

## The resolver: `bin/lib/model-route.sh`

`model_for <role> [project]` (primary model) and `model_ladder <role>
[project]` (every rung, `position\tmodel\trunner` per line). **Zero model-id
literals live in this file** — `tests/model-literal-lint.sh` checks that.

DB-first, with a box-local cache of the last good answer per `(role,project)`
under `state/model-routes/`, used ONLY when the worker is unreachable (logged
once). A worker that is reachable and says "no route for this role" is
authoritative and is never overridden by a stale cache — those are two
different branches on purpose (see the file's own header for why). That answer
also deletes the cache for the scope it was read for (the hub's `<role>.tsv`
on a hub read, the project's cache and `.hub` marker on a project read), so a
later outage fails closed instead of replaying it.

**Fail CLOSED, unlike the rest of `bin/lib/jobs/*.sh`.** Every other
DB-backed helper in this fleet is fail-OPEN: an unreachable worker leaves a
box behaving exactly as it did before the coordination DB existed. That
doctrine does not apply here, because "before this table existed" WAS a
hardcoded model literal — the exact thing this ticket removes. So a role with
nothing in the DB and nothing cached returns **rc 75** (the same vocabulary
`bin/lib/gh-rest.sh` uses for "unverifiable, do not guess") and writes one
`ALERTS.log` line per `(role, day)` naming the role. It never falls through to
a literal of its own.

## #1510.1: the build lanes read the table

Every model a BUILD lane runs now comes from a row: `bin/agent-call.sh`'s own
ladders, `bin/run-build.sh` (and its `bin/lib/rb/gates.sh` copy), the fly
builder, `bin/blocked-resolver.sh`, `bin/review-prs.sh`,
`bin/review-autopilot.sh`, `bin/review-rescue.sh`, `bin/postmerge-qa.sh`
and `bin/lib/review-model.sh`. Their literal defaults are
deleted. An env value (`EXECUTE_MODEL`, `REVIEW_MODEL`, `CODEX_MODEL`, …) still
wins, as it did; #1510.4 folds those knobs into rows.

- **The lane's model**: `model_env_or_route <VAR> <role> [project]` (or
  `model_for` / `review_model`), per project. No route = the lane buys nothing:
  run-build defers (`BUILD_DEFERRED`, exit 3), a review lane skips the head
  without charging it, postmerge-qa exits 75.
- **The claude lane's failover** (`bin/agent-call.sh` `claude_ladder`) is the
  role's ladder — `build.<stage>` for plan/execute/review/fix/qa,
  `AGENT_CALL_ROLE` when a caller names one (`rescue.review`, `postmerge.qa`,
  `build.execute.fallback`), else `claude.ladder` from the argv model's rung on.
  A role that names only its primary inherits `claude.ladder`'s rungs from that
  model on. It is resolved on the FIRST FAILURE only: a call that succeeds on
  its argv model never reads the table. #1523's two rules are unchanged: a CLI
  refusal (an API 400 envelope saying the CLI does not support the model)
  advances to the next rung with one ALERTS line per box per model per day; an
  ordinary failure advances only across a model FAMILY (Fable ↔ Opus), never to
  an older release of the same one.
- **The non-claude rungs**: `codex.default`, `grok.default`,
  `fireworks.default`, with `fireworks.floor` and `openrouter.floor` as the
  survival lanes' last rungs. A rung with no route is not run: rc 75, the
  marker `AGENT_CALL_NO_MODEL_ROUTE <role>`, nothing billed, and the ladder
  descends.
- **The fly builder resolves its own ladders**: a pool machine reaches the
  worker (it pushes cost rows and pulls prices there), so `model_routes_warm`
  reads every build role (`MODEL_ROUTE_BUILD_ROLES`) at each job start into the
  box cache, which then serves the build if the worker goes away.
- **The dispatcher's answers ride the job bundle (BH-1572)**, so a worker blip
  at a fresh builder's job start does not defer its build. `bin/fly-pool.sh`
  (once per tick, before the first spawn) and `bin/fly-dispatch.sh` run
  `model_routes_bundle <project> <file>`: every build role plus the stage.*
  runner roles, one line per rung, `<role> <resolved-at> <position> <model>
  <runner>`, stamped now for a worker answer and with the cache file's mtime for
  a cached one. It asks one short try per role and reads only the cache after
  the first failed ask. The whole build has one total deadline too (BH-1928),
  `MODEL_ROUTES_BUNDLE_DEADLINE_S` (lib knob `model-route`, settings row
  `lib.model-route.model_routes_bundle_deadline_s`, default 15 s): each ask gets
  the smaller of the 4 s per-ask cap and what is left, and once it is spent the
  remaining roles come from the cache, with one `model-route.log` line saying
  so. The file is pushed to `/run/harness-env/model-routes.tsv`
  before `job.json`. `model_routes_warm` installs it
  (`model_routes_bundle_install`) BEFORE the warm, only where the box holds
  nothing newer, drops the role's `.hub` marker, and deletes the file; the warm
  then replaces every ladder the worker answers, so a live answer still wins. A
  builder with no bundle and no worker still defers rather than guess. A reused
  pool machine gets no new bundle: it keeps the cache its first job warmed.

## The non-build lanes (#1510.2): `bin/lib/lane-model.sh`

Every non-build lane (triage and its shards, pre-plan, decompose, the
orchestrator and box chat, product/greenfield/draft-proposal, alert-triage,
alerts-medic, the responder, remediate, rule-miner, lander, lane-probe,
runner-bench, prompt-eval, claude-auth-check) resolves its model through one
of three calls, each inside a `# >>> model-route` block that
`tests/model-route-other-lanes.bh-1510-2-test.sh` cuts out and drives:

- `lane_model <ENV> <role> [project]`: the env var when it is set (process
  env, env files, or a settings row `lane_env_apply` exported), else
  `model_for`. The env still wins because a box already running on an override
  must not silently lose it the day its lane is converted (#1515 review, F7).
- `lane_role_model <role> [project]`: no env override, for call sites that
  never had one (a bare literal before).
- `lane_housekeeping_floor`: the `housekeeping.floor` ladder, where rung 0 is
  the floor model and its runner and rung 1 is the claude fallback.

No route means rc 75 before anything is claimed or bought, with one ALERTS
line per role per day. `housekeeping.floor` may be ONE rung (an operator
edit): the floor then runs on that rung alone, with `AGENT_CALL_RUNNERS`
pinned to its runner so no other vendor is reached; no rung at all stops both
housekeeping lanes loudly. The two lanes that
answer a person in real time are the exceptions. When the orchestrator's
Telegram turn or the box chat pane has no route, the model stays empty and the
turn goes straight to its survival lanes and deterministic floor, so it is
never silent. The model knobs these lanes registered in `catalog/lanes.d` now
default to `""`, and each note names the role that owns the value.

Roles added by #1510.2's seed (today's values, INSERT OR IGNORE):
`product.{map,signals,ideate,synth,prd,mockup,revise}`,
`greenfield.{signals,ideate,synth,mockup,deck}`, `responder`, `remediate`,
`rule.miner`, `lander`, `openrouter.default`, and `housekeeping.floor` rung 1.

### Resolver additions (#1510.2)

- A 2xx without a `ladder` array is an unusable answer, served from cache like
  an unreachable worker, never an authoritative "no route".
- The client loads first (it reads `HARNESS_SECRET`); with no secret after
  that, the worker is not asked and the cache answers.
- **Hub cache for a project, only on evidence.** Each successful project read
  records which scope answered (`state/model-routes/<role>@<project>.tsv.hub`
  when `source` was `hub`, removed when a project override answered). In an
  outage, a project with that marker is served the hub's cached ladder; a
  project without it gets only its own cache, else rc 75. A project whose
  worker answer is "no route" (`source: none`) loses both the marker and its
  own cached ladder on that answer, so the next outage fails closed. A project
  with a usable override is never served the hub rungs. A **gapped** override
  (no rung 0) is not usable: the worker ignores it and answers the hub ladder
  with `source: hub` (the gapped rows ride beside it), so such a project runs
  the hub ladder online and, through the marker, in an outage too.

## What #1510.0 did NOT do

`#1510.0` was the contract only: the table, the routes, the resolver, the seed
of today's effective model per role, and `tests/model-literal-lint.sh` in WARN
mode. No lane was converted. `#1510.1` (build lanes, above) and `#1510.2`
(every other lane) point real callers at the resolver and delete the literals
the lint counts; `#1510.3` adds the console Models screen; `#1510.4` flips the
lint to `--strict` once the count reaches 0.
