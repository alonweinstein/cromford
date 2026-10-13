# The alerts table (the fleet's incident rows in the coordination DB)

**What it is:** the `alerts` table in the harness-jobs D1 database, and the
client and worker halves that read and write it (BH-1068, the first slice of
BH-1030). Until now an incident lived only in a JSON file on the box that
noticed it, so two boxes seeing one outage produced two unrelated states and
nothing fleet-wide could count, claim or close them. A row is one incident: `id`
is the alert-state identity (the explicit `--id` or `row_key(line)`), `family`
is the grouping key `bin/alert_family.py` derives from the line, and
`first_seen`/`last_seen`/`count`/`state`/`claimed_by`/`notified_at` carry the
fire / remind / suppress rule `bin/lib/alert-state.sh` has always run on files.

Every write is a compare-and-swap whose `WHERE` carries the state the decision
was made on, because two boxes noticing the same outage in the same second is
the NORMAL case here, not the edge. Nothing waits, sleeps or polls: a row that
loses its race is re-read and re-decided, and three losses answer 409.

**Wire contract:** `worker/jobs/README.md`, section `## Alerts table
(2026-09-19)` — the routes, their bodies and their status codes.

**How a user reaches it:** nothing on any box calls it until the `alerts-db`
flag is set (`bin/lib/alert-state.sh` `alerts_db_on`, with the
`ALERTS_DB_ENABLED` kill switch in `flags/alerts.conf`, template
`env-templates/alerts.conf.example`). With the flag off every caller keeps
today's file behaviour byte for byte. By hand: `bin/jobs-client.sh alerts`,
`alert-note`, `alert-state`, `alert-resolve`, `alert-claim`, `alert-flush`,
`alert-families`.

**Key routes/screens:**
- `worker/jobs/schema.sql` — the table, its two indexes and the two operator
  knobs (`alert_flush_ttl_s`, `alert_claim_lease_s`), seeded 2700/900
- `worker/jobs/src/routes/alerts.js` — `POST /api/alerts/note`,
  `PATCH /api/alerts/state`, `POST /api/alerts/resolve`,
  `POST /api/alerts/claim`, `POST /api/alerts/flush`, and
  `GET /api/alerts` / `GET /api/alerts/families`; registered in the route table
  in `worker/jobs/src/index.js`
- `worker/jobs/src/lib/core.js` `CREATED_TABLES.alerts` — the self-create
  mirror, so a deploy needs no `d1 execute`
- `bin/lib/jobs/alerts.sh` — the seven client wrappers, sourced by
  `bin/jobs-client.sh` as one of its `JC_MODULES`
- `bin/lib/alert-state.sh` `alerts_db_on` — the gate every sibling tests first

**Selectors:** none (no UI in this slice; the console's read-only view is
BH-1072). The table is addressed by `grep -n 'CREATE TABLE IF NOT EXISTS alerts'
worker/jobs/schema.sql` and the client half by
`grep -n '^JC_MODULES=' bin/jobs-client.sh`.

**Preconditions / seed needs:** `HARNESS_SECRET` and `JOBS_URL` in the box env
(every route is behind the same bearer as the rest of the coordination API);
`jq` on the box for the client wrappers. No flag is needed to TEST the routes —
the gate only decides whether the fleet's own callers use them.

**Verify it works:**
`HARNESS_TEST_SANDBOX=1 bash tests/alerts-client.bh-1068-test.sh` — the seven
wrappers and the CLI dispatch driven against a recording `curl` stub: the body
each one sends, the TSV it renders (line LAST, so an embedded tab cannot shift a
column), `#truncated`, the rc map (0 body, 2 no row, 1 outage), a 200 that is
not JSON being an outage rather than "no alerts", the claimant riding as
`<lane>@<box>`, positional options never becoming ids, and the `alerts_db_on`
gate including the kill switch uncommented verbatim from the template.

`cd worker/jobs && npm test` (node 22+, for `node:sqlite`) — the routes driven
against the REAL schema through `test/lib/d1-sqlite.bh-1030.js`: the note's
fire/remind/suppress boundaries, a row that moves between the read and the write
being re-read rather than blind-written, the state edges, claim exclusivity and
the lease, the flush TTL and its settings override, every documented list filter
and an honest `truncated`, and `CREATED_TABLES.alerts` producing the same
columns as `schema.sql`. The routes are also pinned in the route table fixture
(`worker/jobs/test/route-table.test.js`), so one cannot be dropped or reordered.

**Manual-only / not automatable:** the flag flip itself. Turning `alerts-db` on
for a live box is an operator step whose blast radius is the fleet's alerting,
so it happens once the sibling slices have landed and is watched by hand;
nothing in this slice turns it on.
