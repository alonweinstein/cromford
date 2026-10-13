# Daily OpenRouter reconcile

**What it is:** the `# >>> openrouter reconcile (BH-3983)` block in
`bin/cost-reconcile.sh`. On the daily run it calls `or_ledger_compare`
(`bin/lib/openrouter-ledger.sh`, BH-3998), compares what OpenRouter billed
(the `vendor_spend.cumulative_usd` delta, or the named keys' `raw.keys[].usage`
delta) with the sum of our priced `runner=openrouter` cost rows over the
vendor's own span, writes one log line, pushes one `account:"openrouter"` row
to `POST /api/metrics/reconcile`, and alerts once a UTC day when the gap is
over 15% AND over $20 (both strict). Full contract: [COST.md](../../COST.md),
section "OpenRouter reconciliation (BH-3983)".

**How an operator reaches it:**

| lane | where it runs | what it does here |
|---|---|---|
| `cost-reconcile` | `bin/cost-reconcile.sh --window 24h`, `cron/lanes/680-cost-reconcile.cron` (`50 4 * * *`, hub) | runs the block: one `cost-reconcile openrouter 24h ...` line, maybe one alert |
| `cost-reconcile` | `bin/cost-reconcile.sh --window 1h`, same file (`50 * * * *`) | does NOT run the block |
| by hand | `bin/cost-reconcile.sh --window day YYYY-MM-DD --dry-run` | runs it for a named day; logs ` would alert`, sends and pushes nothing |

**Knobs** (lane knobs in `catalog/lanes.d/cost-reconcile.json`):
`RECONCILE_OR` (1; 0 is off), `RECONCILE_OR_GAP_PCT` (15),
`RECONCILE_OR_MIN_USD` (20), `OPENROUTER_RECONCILE_KEYS` (empty = whole account).

**How it is driven:**

```
HARNESS_TEST_SANDBOX=1 bash tests/cost-reconcile-openrouter.bh-4000-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/openrouter-ledger.bh-3998-test.sh   # the lib it calls
```

The first runs the real `bin/cost-reconcile.sh` under `env -i` against a PATH
curl stub serving `vendor-spend`, `cost-rows` and the reconcile POST, with the
real lib copied beside it.

**What shows it working on a live box** (owed until the first 04:50Z run after
deploy):

```
grep 'cost-reconcile openrouter' /root/harness/logs/cost-reconcile.log | tail -1
```

**What usually lies:**

- `scope=account` includes product-app and personal keys, so a gap there is not
  necessarily ours. Set `OPENROUTER_RECONCILE_KEYS` to the harness key names.
- `state=unread` is a failed or capped read, never a quiet day. Only `state=ok`
  can alert.
- `state=no-lib` means the box has the script but not the lib: bin/ sync lag.
