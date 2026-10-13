# Fly machine registry (BH-1054 contract chunk + BH-1055 routes)

**What it is:** the schema, the worker routes and the client verbs for tracking
live Fly machines in the coordination DB. BH-1054 added the `machines` table,
the `fly_machines_rows` flag and five fail-open shell verbs; BH-1055 wired the
four route handlers that write the rows. Nothing enqueues them yet — the shell
writer that calls them on every pool tick is a later slice — so the registry
stays empty until an operator or that slice starts writing.

**How an operator reaches it:** there is no UI. The operator surfaces are the
schema file, the worker source, and the client script:

- `worker/jobs/schema.sql` — additive `machines` table plus `fly_machines_rows='off'` seed.
- `worker/jobs/src/lib/core.js` — `CREATED_TABLES.machines`, `MACHINE_STATES`, `MACHINE_TERMINAL`;
  `worker/jobs/src/routes/machines.js` — the four routes.
- `bin/jobs-client.sh` — `machines-rows-on`, `machine-put`, `machines-observe`, `machine-close`, `machines-list`.

**Key routes (wired in BH-1055, bearer-only like every other route here):**

- `PUT /api/machines` — register or upsert one machine. Upserts on `machine_id`;
  the FIRST register's `spawned_at` is the one that survives.
- `PUT /api/machines/observe` — bulk refresh from a Fly machines listing. Caps at
  200 entries (`capped:true` over it, and a capped call sweeps nothing); the
  unlisted go `gone` via `last_seen < t`, with a 30-minute grace for a machine
  that has never been listed (measured on `spawned_at`, or on the row's own
  `updated_at` when a PATCH close is all that ever registered it).
- `PATCH /api/machines/<id>` — close or correct a machine state. `ended_at` is
  stamped only for a TERMINAL state (`destroyed`/`gone`); `destroy_failed` is in
  the vocabulary and is NOT terminal — the machine is still there and the sweep
  retries the destroy. `detail` over 300 chars is a `400`.
- `GET /api/machines?project=<p>&app=<a>&key=<k>&live=1` — list tracked machines,
  `LIMIT 500`, each row carrying `age_s` and `seen_age_s`.

Wire shapes and the full validation rules are the `## API` table in
`worker/jobs/README.md`.

**Preconditions / seed needs:** the `fly_machines_rows` settings row defaults to
`off`. Flip it to `on` (or set `FLY_MACHINES_ROWS=on` on the caller) to enable
row writes.

**Verify it works:**

- `HARNESS_TEST_SANDBOX=1 node worker/jobs/test/machines-schema.bh-1054.test.js`
- `HARNESS_TEST_SANDBOX=1 bash tests/jobs-client-machines.bh-1054-test.sh`
- `cd worker/jobs && node --test test/machines.bh-1055.test.js` — the four routes
  driven through the worker's real `fetch` over a `node:sqlite` in-memory DB, so
  the SQL itself is under test (it skips when `node:sqlite` is unavailable).

**Manual-only / not automatable from a box:**

- After deploy, `bin/jobs-client.sh machines-list` returns rc 0 and prints nothing
  (the registry is empty, not missing). `bin/jobs-client.sh machines-rows-on` still
  returns rc 1, because the flag is `off` and the worker deliberately does not read
  it — the knob lives on the caller.
- The round trip, on the hub, once the deploy has landed:
  `bin/jobs-client.sh machine-put cromford harness-pool-test probe-1 pool`,
  then `bin/jobs-client.sh machines-list cromford live` prints the `probe-1`
  row; `bin/jobs-client.sh machine-close cromford harness-pool-test probe-1 destroyed`
  and the same `machines-list` prints nothing again.
