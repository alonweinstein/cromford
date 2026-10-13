# Costs 24h window — what the console worker must map (2026-08-24)

the operator asked for a last-24-hours spend view on the Costs tab. The hub side and
the UI side are done in this repo; ONE mapping change remains in the console
worker (`harness-console`, the operator's local source), documented here.

## What already ships (this repo)

- `bin/cost-rollup.sh` writes two new per-project fields into
  `state/cost/summary.json` (and therefore into the watchdog KV
  `cost-snapshot`): **`cost_24h`** and **`unpriced_calls_24h`** — same
  semantics as the 7d/30d fields, window = 24h back from generation time.
  A project with no rows in the window reports a true `0`, unlike an
  unavailable project which is absent entirely.
- `cron/hub.cron` runs `WINDOWS_ONLY=1 cost-rollup.sh` hourly at :50 (hour 04
  skipped; the full 04:45 nightly covers it). Windows-only runs recompute the
  windows and re-push the snapshot but never stamp PR comments or send beats.
  So `generated_at` — and the dash's "rolled up N ago" — now moves hourly, and
  the 24h figure is at most ~1h stale.
- `console-ui` renders a `FLEET SPEND · 24H` stat tile and a `SPEND 24H`
  table column. Both degrade to `—` while the worker payload lacks the fields,
  so deploy order does not matter.

## What the console worker needs (`/api/dash/costs`)

1. Pass `cost_24h` and `unpriced_calls_24h` through on each `spend[]` row,
   exactly as `cost_7d` is passed (null when unavailable/absent — never 0).
2. Add a top-level **`fleet_cost_24h`** total, computed by the SAME rule as
   `fleet_cost_7d` (sum of priced projects; unpriced projects keep it a floor
   via `fleet_cost_incomplete`/`fleet_cost_missing`, which the UI already
   applies to the 24h tile).
3. Optional: `unpriced_calls_24h` fleet total, same rule as the 7d one. The UI
   does not read it yet.
4. Consider tightening `spend_stale` from 26h — the snapshot now refreshes
   hourly, so >3h old means the refresh lane is broken. Not required for the
   24h view to work.

Until 1–2 deploy, the tile and column show `—` (unknown), by design.
