# Cost rows at the source (and the rollup as a query)

**What it is:** every AI call's cost row reaches the harness-jobs `cost_rows`
table at the moment the call ends, and `bin/cost-rollup.sh` builds the fleet
file by READING that table instead of opening an ssh session to each box.
`logs/cost.csv` does not stop being written — it becomes the write-ahead log in
front of the table rather than the table's differencing baseline.

**How an operator reaches it:**

| lane | where |
|---|---|
| the write | `cost_row_emit` in `bin/lib/cost-row.sh`, called by `bin/agent-call.sh` once per attempt |
| the backstop | `bin/cost-rows-push.sh` (every `cron/*.cron`, \*/10) — unchanged, now a catch-up rather than the only path |
| the read | `cost_rows_fetch` in `bin/lib/cost-rows-read.sh`, called by `bin/cost-rollup.sh` section 1 (hub cron 04:45Z + hourly :50) |
| the price table | `bin/update-model-prices.sh` (hub 04:30Z) pushes `model_prices`; `bin/model-prices-sync.sh` pulls it into any box's `state/model-prices.json` |

**Verify it works:**

- A call just ran: `curl -s -H "Authorization: Bearer $HARNESS_SECRET"
  "$JOBS_URL/api/metrics/cost-rows?limit=5" | jq '.cost_rows[0] | {ts, cost_usd, ticket, raw}'`
  answers with a row whose `ts` is seconds old, not minutes. Before BH-1032 the
  freshest row was up to ten minutes behind, and `raw`/`note` did not exist.
- `bin/cost-rows-push.sh --verify <box>` prints `data_rows` > 0 on a box that has
  made calls. It printed `0` on every box until BH-1032 — its width ceiling was
  still 16 columns while rows had been 24 wide since the transcript wave, so the
  one check that notices a stuck cursor could not see a single modern row.
- `logs/agent-rules.log` carries exactly one `cost-rollup: collected N rows from
  cost_rows` line per run. The line `falling back to the per-box ssh collection`
  is the fallback firing and means the table could not be read.
- The two files agree: `state/cost/fleet-cost.csv` built from the table is
  byte-identical to the one built from the boxes' files on the same rows. That
  is what `tests/rollup-from-rows-test.sh` asserts, and it is why `raw` exists —
  reconstructing a row from `REAL` columns renders `4.00` as `4`.
- **No call is in `fleet-cost.csv` twice.** The rollup merges the table with
  files it still holds (`logs/cost.csv`, its own build ledgers, the mirrored
  remote ones), and `sort -u` can only collapse the two copies of a call when
  their TEXT matches — a row pushed before `raw` existed comes back
  reconstructed (`1.250000` -> `1.25`, `0.000010` -> `1e-05`) and both survive.
  So the rollup hashes every file line the way the push side hashes it and hands
  that set to the reader as `COST_ROWS_SKIP_HASHES`; the table's copy is dropped
  and the file's own text wins. Check it by hand:
  `awk 'NR>1' state/cost/fleet-cost.csv | sort | uniq -c | sort -rn | head` —
  and then `cut -d, -f1,2,17 state/cost/fleet-cost.csv | sort | uniq -d`, which
  is the same question asked of (ts, host, session_id) rather than of the whole
  line, so a pair that differs only in how a float rendered still shows up.
- **The table exists the minute the worker deploys.** `bin/harness-sync.sh`
  runs `npx wrangler deploy` and nothing else, so `model_prices` is in the
  worker's own `CREATED_TABLES` (BH-658) and both `/api/model-prices` handlers
  call `ensureTable` before their first statement. Without that the hub's 04:30
  push and every box's 05:05 pull answer 500 against a table no one created,
  and each box spends its daily ALERT naming `HARNESS_SECRET`/`JOBS_URL` for a
  missing table. `schema.sql` carries the same CREATE as the readable
  definition; the two are held equal by the worker test above.
- **Every box that should be pushing is.** `state/cost/cost-rows-boxes.tsv`
  (written by each DB-path run) is `box<TAB>rows<TAB>latest_ts` for the whole
  window. A box in `state/cost/overage/EXPECTED` with no line there gets one
  ALERT a day; one whose latest row is over 24h old gets a line in
  `logs/agent-rules.log`. `bin/cost-rows-push.sh --verify <box>` then says
  whether it is a stuck cursor, a missing `HARNESS_SECRET` or a quiet box.

**How to drive it:**

| what | how |
|---|---|
| the at-source write, its hash pairing with the mirror, the kill switches, fail-open | `bash tests/cost-row-at-source-test.sh` |
| the table read: byte parity with the file path, paging, fail-open, reconstruction | `bash tests/rollup-from-rows-test.sh` |
| the price table round trip, priced by the real `cost_price_tokens` | `bash tests/model-prices-table-test.sh` |
| `model_prices` creating itself on a database `wrangler deploy` never migrated | `cd worker/jobs && node --test test/model-prices-schema.bh-1032.test.js` |
| the mirror lane it backstops | `bash tests/cost-rows-db-test.sh`, `bash tests/pool-cost-rows-test.sh` |

**Knobs** (each one turns off a latency or a source, never a ledger entry):

- `COST_ROW_AT_SOURCE=0` / `flags/cost-row-at-source-off` — the row still lands
  in `cost.csv` and the \*/10 mirror still carries it.
- `COST_ROWS_FROM_DB=0` / `flags/cost-rows-from-db-off` — the rollup ssh's, as
  it did before.
- `COST_ROWS_READ_LIMIT`, `COST_ROWS_READ_PAGES`, `COST_ROLLUP_DB_DAYS` — the
  read window's shape. `COST_ROWS_READ_LIMIT` is clamped to 2000, the route's
  own ceiling: a larger number made a full page look short and stopped the walk
  after one.
- `COST_ROWS_SKIP_HASHES=<file>` — row hashes the caller already holds from a
  file; those rows are counted for presence and paging and not emitted. The
  rollup sets it; nothing else does yet.
- `MODEL_PRICES_SYNC=0` / `flags/model-prices-sync-off`, `MODEL_PRICES_MIN`.
- `JOBS_TIMEOUT` (default **8s**, `bin/jobs-client.sh`) now bounds an AGENT CALL
  too: `cost_row_emit` POSTs one row after each attempt, so a hung worker adds
  up to 8s (plus one retry, `JOBS_RETRIES`) per call rather than only per cron
  tick. `COST_ROW_AT_SOURCE=0` takes that back at the cost of the latency.
- A box with no `HARNESS_SECRET` logs one `HARNESS_SECRET unset` line into
  `logs/jobs-client.log` **per agent call** (the client's own fail-open line),
  where before this slice it was one per `*/10` tick. Set the secret or set
  `COST_ROW_AT_SOURCE=0`; the row itself is never at risk either way.
- `COST_ROWS_BOX` — the explicit box id, exported by `fly/entrypoint.sh` and now
  read FIRST by `cost_row_box_id`, so a pool machine's at-source rows and its
  `bin/cost-rows-push.sh` flush land under one PK instead of two.

**What must never regress:**

- **The CSV is written BEFORE the row is offered, and a failed offer never fails
  the caller.** `cost_row_emit` returns 0 on every path, including a missing
  `jobs-client.sh`. A build that failed because a metrics POST did would be a
  strictly worse lane than the cron it replaces.
- **One call is one row.** The at-source writer and `bin/cost-rows-push.sh`
  resolve the box id through the SAME `cost_row_box_id`, and hash the SAME
  verbatim line, so the mirror's later push is a dup the PK absorbs. Two
  resolvers or two hashes and every fleet total inflates silently.
- **An unreadable table is never an empty window.** `cost_rows_fetch` returns
  rc 1, writes no file, and logs one line; the caller falls back. A zero that
  came from an outage is indistinguishable from a quiet fleet on every cost view.
- **Empty is not pass on the price table.** `model_prices_get` refuses a body
  carrying fewer than `MODEL_PRICES_MIN` models and leaves the existing file
  alone; overwriting it would price every row in the fleet at nothing.

**What must never regress (continued):**

- **A merge of the table and the files never counts a call twice.** The skip set
  is keyed on `row_hash`, the table's own PK half — never on the rendered text,
  which is precisely what differs. A reader that stops sending `row_hash`, or a
  writer that hashes a line differently from `_metric_cost_rows_chunk`, turns
  this guard off silently and inflates every dollar figure downstream.
- **A box that is not pushing gets NAMED.** Reading the table moved the
  "unreachable box reads as a quiet box" failure to "stuck cursor reads as a
  quiet box"; section 1c is what closes it.

**Not moved yet (stated, not solved here — ticket #1032 stays open):**
`bin/cap-loss-detector.sh`, `bin/cache-hit-report.sh`, `bin/pipeline-health.sh`'s
cost breaker and `bin/cost-reconcile.sh` still scrape. Each pairs its cost file
with a file that is in no table yet (`failovers.log`, the health tail), and a
half-migrated pairing is the same silent zero in a new place — one lane per PR.
The ticket's other half (the four lanes as worker Cron Triggers, `vendor_spend`
as the billed-cost baseline, audit items #19/#20/#22) is untouched by this PR,
which is why it says **Part of #1032** rather than closing it.
