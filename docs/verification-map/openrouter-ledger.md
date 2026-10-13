# OpenRouter gap tracer

**What it is:** one line that compares what OpenRouter's own meter moved over a
window with what our `cost_rows` say the `openrouter` runner spent over the same
span. `bin/openrouter-audit.sh` is the operator command; `or_ledger_compare` in
`bin/lib/openrouter-ledger.sh` is the function the BH-3983 siblings (the daily
reconcile, the bucketed audit) build on. Read-only: two GETs to the jobs worker.

**How an operator reaches it:** on a box whose `env/global.env` carries
`JOBS_URL` and `HARNESS_SECRET` (the hub):

```
bin/openrouter-audit.sh --since 2026-09-21T00:00:00Z --until 2026-10-03T23:59:59Z
```

No flags reads the last 7 days. `OPENROUTER_RECONCILE_KEYS=<name>[,<name>]`
(environment or `env/global.env`) narrows the vendor side to those keys' summed
usage (`scope=harness-keys`); unset, it is the whole account (`scope=account`).

**What it reads:**
- `GET /api/metrics/vendor-spend?vendor=openrouter&since=<since-6h>&limit=1000`
  — the hourly `vendor_spend` rows from `bin/vendor-spend-pull.sh`. `a` is the
  newest `ok` row at or before `since` (else the oldest in the window), `b` the
  newest at or before `until`; the delta is `b.cumulative_usd - a.cumulative_usd`,
  or per key from `raw.keys[].usage`.
- `GET /api/metrics/cost-rows?since=<a.ts>&until=<b.ts>` through
  `cost_rows_fetch` (`bin/lib/cost-rows-read.sh`), kept to `runner == openrouter`
  client-side. The route also accepts `?runner=` (BH-3998); this reader does not
  pass it, because `cost_rows_fetch` is shared and has no runner argument.

**Reading the line:** `openrouter scope= state= vendor_usd= rows_usd= rows_n=
unpriced_n= killed_n= span=<a.ts>..<b.ts>`.
- `state=ok` — both sides read. `no-meter` — fewer than two `ok` meter rows in
  the window. `meter-reset` — the cumulative went down; `vendor_usd` is empty.
  `unread` — a failed or capped read, or a named key missing from either
  snapshot; rc 1, and the CLI prints only `could not read: <what>` (stdout and
  stderr) with no table.
- A value that was not measured is EMPTY, never `0`. This line never prints a
  key name; the per-key table below it does (names only, never key values).
- `unpriced_n` counts rows with a blank `cost_usd`; `killed_n` counts rows whose
  `note` carries `killed:sig=` (no producer writes that yet).

**The bucketed audit (BH-4001, BH-3983.3):** after line 1 the CLI prints a
`| bucket | count | usd | attribution |` table, the per-key table, the per day x
model activity section and the per-request section. `--json` prints all of it as
one object; `--export <csv>` takes the dashboard's activity export.
- `other-keys`: usage deltas on keys not in `OPENROUTER_RECONCILE_KEYS`
  (`unread` while the knob is unset). `unpriced-rows`: openrouter rows with a
  blank `cost_usd`. `killed-no-row`: rc 143/137 openrouter lines in THIS box's
  `logs/failovers.log` plus reaped (`ABANDONED_TIMEOUT` + `REAPED`) build dirs
  with an `openrouter` `*.runner`. `residual`: vendor side minus priced rows.
- A key in only one snapshot is `unreadable` (no delta, in no bucket). The
  vendor pull reads only the first 100 keys of `/api/v1/keys`, so a key that
  falls off that page reads as unreadable.
- Activity runs only when the box's env files carry
  `OPENROUTER_PROVISIONING_KEY`; otherwise `activity: skipped (no management key
  on this box)` and no call is made. A refused answer is
  `activity: could not read (HTTP <code>)` and keeps rc 0.
- The markdown attribution cell names the five biggest groups; `--json` lists
  every group.

**How to drive it:**

| what | how |
|---|---|
| lib + CLI against a stubbed worker (L1-L10) | `HARNESS_TEST_SANDBOX=1 bash tests/openrouter-ledger.bh-3998-test.sh` |
| the bucketed audit (A1-A8) against a stubbed worker + OpenRouter | `HARNESS_TEST_SANDBOX=1 bash tests/openrouter-audit.bh-4001-test.sh` |
| the worker's `?runner=` filter | `cd worker/jobs && node --test test/cost-rows-runner-filter.bh-3998.test.js` |

**Preconditions:** `JOBS_URL` and `HARNESS_SECRET` in the environment or
`env/global.env`. No UI screen.
