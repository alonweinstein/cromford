# Queues are rows (the three flags, and the one active-key read)

**What it is:** the contract slice of #1026. Three of the fleet's queues still
live as directories of files on ONE box — the build queue's active job
(`state/fly/<p>-active.json`), the merge queue (`state/merge-queue/<p>/<pr>`)
and the deploy queue (`state/deploy-queue/<p>/<epoch>-<sha8>`) — which is why a
lane that cannot ssh into the owning box cannot see the work. This slice ships
the ROW side of all three: the `deploy_queue` table, `build_queue.machine`, three
`settings` knobs, and one shared helper that answers "is anything already
building for this project, and where". **It lands dark.** All three knobs seed
`'0'`, and at `'0'` every lane behaves byte for byte as it does today.

**How a user reaches it:** there is **no UI route** — cromford has no app.
The operator surfaces are the client and the worker, both bearer-gated:

- on a box: `. /root/harness/bin/jobs-client.sh` then
  `build_queue_rows_only_on; echo $?` (1 = off, the seeded state) and
  `build_queue_active_key <project> [key]`
- the knobs: `bin/jobs-client.sh setting-get build_queue_rows_only`,
  `bin/jobs-client.sh setting-set build_queue_rows_only 1 "<why>"`
- the worker: `GET /api/queue?project=<p>&status=claimed&limit=1` and
  `POST /api/queue/claim`

**Key routes/screens:**
- `POST /api/queue/claim` — takes ONE queued row by compare-and-swap. Accepts an
  optional `machine`; with one it runs `ensureColumns(env, "build_queue")` before
  the CAS and records the machine on the row it changed. With none it is today's
  SQL and today's query order. The RESPONSE gains one key once the column
  exists: `queued` is the row and the row is `SELECT *`, so a claim that sent no
  machine answers `machine: null`. Every caller reads named fields, so that is
  additive — but it is a change, and it is stated rather than glossed.
  `machine` must be an id-shaped string (`[A-Za-z0-9._:-]{1,64}`); anything else
  — an object, a number, an over-long value — records NOTHING and still claims.
  The guarantee is "a claimed row never names the WRONG machine", not "always
  names one", and the response echoes what was recorded, never what was sent.
- `GET /api/queue?project=<p>&status=claimed[&key=<k>]` — `SELECT *`, so
  `machine` appears the moment the column exists. No column list to drift.
- `PATCH /api/queue` with `status=queued` (the release) and `POST /api/queue`
  (the re-queue) both CLEAR `machine`: it belongs to the claim, not to the
  ticket. A terminal row keeps it as ledger; the re-queue is what clears that
  one. Without this a dead machine's id survives into the next claim — every
  local claim sends no machine — and the row would read `claimed` while naming
  a machine that is gone or recycled to another build.

**Selectors:** none (no UI). The observable surfaces are the TSV a helper prints
and the JSON a route answers.

**Preconditions / seed needs:**
- `worker/jobs/schema.sql` applied — which happens on its own: `bin/harness-sync.sh`
  applies each statement before `wrangler deploy` and skips the deploy if one
  fails. There is no hand step.
- a LIVE database whose `build_queue` predates `machine` is widened by
  `ADDED_COLUMNS.build_queue` in `worker/jobs/src/lib/core.js`, on the first
  claim that names a machine — the CREATE reaches only a fresh database.
- `HARNESS_SECRET` and `JOBS_URL` (the client reads both from
  `env/global.env` when the caller has not exported them).

**The three knobs, and what each one moves:**

| settings key | env fallback | what it moves | who reads it |
|---|---|---|---|
| `build_queue_rows_only` | `BUILD_QUEUE_ROWS_ONLY` | the build queue and the ACTIVE job: rows first, `state/build-queue/<p>/<KEY>.json` + `state/fly/<p>-active.json` second | `build_queue_active_key` (this slice); the build-queue sibling |
| `merge_queue_rows_only` | `MERGE_QUEUE_ROWS_ONLY` | the merge queue: rows first, `state/merge-queue/<p>/<pr>` second | the merge-queue sibling |
| `deploy_queue_rows` | `DEPLOY_QUEUE_ROWS` | the deploy queue: `deploy_queue` rows first, `state/deploy-queue/<p>/<epoch>-<sha8>` second | the deploy-queue sibling |

Three rows and not one, because the siblings land as separate PRs and a shared
knob would arm a lane whose PR had not merged yet. Resolution order is the
client's usual one (`_flag_on_row`): the settings ROW, then the documented env
value, then `0`. A real answer is memoised per process; **an outage is never
memoised**, so a worker that blinks cannot pin one answer for the rest of a run.

**What is still file-first after this slice:** everything. No lane changes its
source of truth here. `build_queue_active_key` is ROW-FIRST-THEN-FILE, never
row-authoritative: with the flag on and no `claimed` row — or with the worker
unreachable — it reads `state/fly/<p>-active.json` exactly as both call sites
did. That is deliberate. Nothing writes a `claimed` row for the fly lane until a
sibling slice lands, so an empty answer from a reachable worker is not evidence
that nothing is building, and both call sites are DEDUPE guards: an answer they
read as "nothing active" spawns a second machine for a key already in flight.

**PASS THE KEY.** Both call sites ask "is THIS key already building", so the
helper's row read is `&key=<key>` and its answer is about that key or it is rc 1.
A project-wide row read cannot stand in for the file: the file holds the ONE
non-pool fly job (`bin/fly-dispatch.sh` owns it), while `claimed` rows are
written for every local build (`bin/run-build.sh`, `bin/lib/rb/gates.sh`, empty
target) and for every pool machine (`bin/fly-pool.sh`). `GET /api/queue` ends
`ORDER BY enqueued_at ASC LIMIT 1`, and among claimed rows the oldest is the
likeliest to be STALE — a claim whose build died, which `bin/jobs-watchdog.sh`
only sweeps after `JOBS_QUEUE_CLAIM_MIN` (6h). Answering the guard with that row
would name a key that is not building, miss the key that is, and open the guard
on exactly the case it exists to close. Called with no key, the helper answers
the project-level question as a UNION — one TSV line per active key, rows and
file — so a row answer can only ever ADD an active key and never hide one.

**The `deploy_queue` key is a deliberate change of identity.**
`state/deploy-queue/<p>/<epoch>-<sha8>` is one file per REQUEST, holding
`<merge-sha> <build-dir>`; the same sha asked for twice is two files and the
train departs on both. `(project, sha)` collapses that to one row, because
"deploy this commit" is a desired end state and departing twice on one sha is a
double-move. The cost is that a repeat request is not a new row, so **the writer
contract is RE-OPEN, never `INSERT OR IGNORE`**: a request for a sha whose row is
terminal sets `status` back to `queued` and clears `departed_at`/`reason`. The
case that forces it is `bin/deploy-train.sh`'s self-sourced departure, which
fires exactly when a sha has already departed `done` and production is still not
serving it — an `INSERT OR IGNORE` there drops the retry and leaves production
stale with no alert.

**Verify it works:**
- flag off (the shipped state): `build_queue_active_key <p>` prints the same key
  `jq -r '.key // ""' state/fly/<p>-active.json` prints, with `-` for the
  machine, and makes no `/api/queue` request at all.
- flag on with a `claimed` row: it prints `<ticket_key><TAB><machine>` even with
  the file deleted.
- flag on with a STALE claim for another key in front of the live one:
  `build_queue_active_key <p> <key>` still answers `<key>`, and answers rc 1 for
  a key nothing holds.
- a claim that carries a machine: `GET /api/queue?project=<p>&status=claimed`
  shows it on the row; a claim without one leaves the column NULL. Release the
  row (`PATCH … status=queued`) and the column is NULL again.
- re-applying `schema.sql` never resets a knob an operator flipped to `'1'`
  (`INSERT OR IGNORE`), and never loses a `deploy_queue` row (`IF NOT EXISTS`).

**Manual-only / not automatable:** flipping a knob on the LIVE fleet. Each one
changes which store a lane believes, so it is an operator decision with a
rollback (set the row back to `'0'`), not something a test drives. The suites
below drive every path against a stubbed worker and a real SQLite instead.

Driven by `tests/queue-rows-flags.bh-1026-test.sh` (the readers, the helper, both
call sites extracted from their real scripts, and `queue_claim`'s body) and
`worker/jobs/test/schema-deploy-queue.bh-1026.test.js` (the shipped SQL, the
column migration, and the claim route through `worker.fetch`).
