# Model price table (daily refresh + reader order)

**What it is:** the per-token price table every cost figure in the fleet is
multiplied by. `bin/update-model-prices.sh` rebuilds it once a day from
OpenRouter's public `/api/v1/models` list, through the hand-maintained name map
in the script (cost.csv's `model` column -> the OpenRouter slug that prices it).

**Where the table lives, and why there are two of them:**

- `state/model-prices.json` — the LIVE table. Runtime state on the hub, written
  whole (temp + `mv`, so a reader mid-refresh keeps its inode). `bin/harness-sync.sh`
  neither inspects nor rsyncs `state/`, so this file never reaches a box and
  never makes a checkout dirty.
- `catalog/model-prices.json` — the COMMITTED FALLBACK. It is what boxes, fly
  builders and the pool archive price from, and it moves only when a human lands
  a PR. When the live table drifts from it the refresh says so once, as a warn
  under the lane-alert id `model-prices-catalog-behind`, naming how many model
  rates differ.
  Its AGE is watched separately (BH-3990): before the OpenRouter fetch the
  refresh reads the catalog's own `updated_at`, and when it is more than
  `MODEL_PRICES_CATALOG_MAX_AGE_DAYS` days old (settings row
  `lane.update-model-prices.model_prices_catalog_max_age_days`, default 14,
  0 = off) or unreadable it raises one warn under the lane-alert id
  `model-prices-catalog-stale`, resolved once the catalog is back within the
  threshold.

**Reader order**, identical in every consumer: `$MODEL_PRICES` (used as given,
never fallen back from) -> `$HARNESS/state/model-prices.json` ->
`/root/harness-checkout/catalog/model-prices.json` (or the script's own
`../catalog` where that is the checkout) -> `$HARNESS/catalog/model-prices.json`.
Consumers: `bin/transcript-cost.sh`, `bin/lib/cost-row.sh` (`cost_price_tokens`,
which prices every `agent-call.sh` row in the fleet, and `cost_model_cliff`,
which reads the same table to decide whether a runner has a price cliff at all —
see [runner-cliff.md](runner-cliff.md)), `bin/planned-files-cheap.sh`,
`bin/orchestrate.sh`, `bin/cost-rollup.sh` (`_prices_path()`, used for both
`row_cost` and `summary.prices_updated`).

**One key the refresh CARRIES rather than fetches:** `cliff_tokens` (BH-656).
OpenRouter publishes rates, not the per-request price cliff xAI bills on, so the
number is authored by hand in `catalog/model-prices.json` and copied onto the
matching model by the refresh. Without that carry the hub would lose the cliff at
04:30 every morning — readers prefer the live table — and the cliff warn, the
cliff route and the 2x row pricing would all silently stop on the one box that
runs the lane they exist for.

**Rows priced at the vendor's own rate:** a model whose `model_prices` row has
`price_source = vendor-direct` (BH-1613) is billed at the vendor's own rate, not
OpenRouter's. Its rates live on that same D1 row (`vendor_prompt`,
`vendor_completion`, `vendor_cache_read`, `vendor_cache_write`,
`vendor_cliff_tokens`, BH-1754), and `GET /api/model-prices` emits them as
`vendor_direct` on a marked row only. The refresh prices the model from those
D1 rates, taking a cache rate or cliff that D1 leaves unset from the catalog
row (a D1 price never drops the catalog cliff); when the row has no D1 prompt
and completion it copies the `catalog/model-prices.json` row verbatim (rates,
slug, cliff). Either way it is priced even when OpenRouter no
longer lists the slug. A catalog-priced row equals the fallback, so the
catalog-behind notice never counts it; a D1 price that differs from the catalog
row does count, because boxes that fall back to the catalog price at the older
rate. A marked model with neither keeps its OpenRouter price and gets one
`agent-rules.log` line. Apart from the cliff and these rows, nothing on a row
comes from the fallback, so the catalog-behind notice still reads "in step" on
a day rates did not move. Mark, price or clear a model with
`bin/jobs-client.sh model-price-source <model> <vendor-direct|openrouter>
[prompt completion [cache_read [cache_write [cliff_tokens]]]]`
(`PUT /api/model-prices/source`). Rates go with `vendor-direct` only; marking
with no rates keeps stored rates, and `openrouter` clears the mark and the rates.
`/models` in the console tags a marked model `DIRECT`.

**A failed read of the marks fails CLOSED (BH-1754):** when `model_prices_get`
fails, or answers without a `per_token` object (the read runs with
`MODEL_PRICES_MIN=0`, so a fresh or short table is a good read and the push
seeds it), the refresh raises one
`lane-alert.sh --id model-prices-price-source-unreadable` (a plain `ALERTS.log`
line where lane-alert is absent) and exits before writing anything:
`state/model-prices.json`, `state/openrouter-models.json` and the DB copy keep
yesterday's rates. The next good read resolves that id. A box with no
jobs-client has no marks to read and prices from OpenRouter as before.

**Price versions and the audit trail (BH-5652):** every `model_prices` row
carries `version` (starts at 1) and `effective_at`. A POST that changes a rate
(`prompt`, `completion`, `cache_read`, `cache_write` or `cliff_tokens`) bumps
the version, moves `effective_at`, and writes one `price_audit` row (kind
`model`, old and new rates) in the same D1 batch. The same rates posted again
bump nothing and write nothing. A `source=catalog` POST still only inserts, so
it writes a version-1 audit row for a new model and nothing for an existing
one. `GET /api/model-prices` carries `version` on each row, and `effective_at`
once a versioned write has filled it. Two more versioned tables mirror the
other committed price files: `price_fly` (one row per number in
`catalog/fly-prices.json`, keyed by its dotted path) and `model_slugs`
(`catalog/model-slugs.json`). Routes: `POST`/`GET /api/fly-prices`,
`POST`/`GET /api/model-slugs`, `GET /api/price-audit?kind=model|fly|slug&key=&limit=`
(newest first, limit default 50, max 200). The readers of the Fly prices and
the slug map still read the files.

**The seeder:** `bin/price-seed.sh` runs at the end of the 04:30Z refresh. It
POSTs the three committed files (model prices as `source=catalog`) and writes
the sha256 of the three files to `state/prices/seeded`. A matching marker
exits with no request, so each file content is seeded once. The marker is
written only when all three POSTs succeed. A failure raises one warn
`lane-alert.sh --id price-seed-failed` naming the POST and exits 1; the refresh
ignores that rc. A good seed resolves the id. `JOBS_URL` empty: no request, no
marker.

**Cost rows record the version:** `cost_row_price` writes `price_v:<n>` in the
row's `note` column when it priced the row from a table row that carries a
positive integer `version` (the box cache written by `bin/model-prices-sync.sh`).
A claude row is priced by `bin/transcript-cost.sh` from the same table, so its
dollars are table dollars too: `transcript-cost.sh --price-version` adds a 10th
field, the version of the row the top model was priced from, and
`cost_row_source`, the advisor row and `bin/claude-cost.sh` write it as
`price_v:<n>`. The hub writes its own table and has no sync line, so
`bin/update-model-prices.sh` reads the D1 versions back after a good push
(`model_prices_versions_merge`): a model gets its D1 version only when its four
rates equal the D1 row's. A table with no version (the committed catalog),
envelope and vendor dollars, no usage and an unknown model add no token.

`effective_at` on a row written before BH-5652 is the time the first POST after
deploy saw those rates, not the time they took effect: read it as "first
observed" for a version-1 row with no `price_audit` row.

**The cache fallback alerts:** when `bin/model-prices-sync.sh` cannot refresh
(API down, `{}`, HTTP 500) and the box has a cache, it keeps the cache bytes,
keeps its `agent-rules.log` line, and writes ONE `logs/ALERTS.log` line a day:
`model-prices-sync: the model_prices API did not answer with a usable table
(<http=500|curl_rc=7|...>); this box prices from its cached ... (updated_at ...)`.

**How an operator reaches it:** the hub cron line `30 4 * * *`
(`bin/update-model-prices.sh`, 04:30 hub-local). Its own output is silent on the
happy path; `logs/agent-rules.log` carries the catalog-behind notice and
`logs/ALERTS.log` carries the two fail-soft lines and, through `lane-alert.sh`,
the price-source-unreadable stop.

**How to drive it:**

| what | how |
|---|---|
| the whole refresh, against a scratch `$HARNESS` and a scratch git checkout | `bash tests/update-model-prices-test.sh` |
| the readers' precedence, by the number they price rather than the path they print | same test, section A5 |
| the vendor-direct price source: the refresh, the verb, the route and the `DIRECT` tag | `bash tests/update-model-prices.bh-1613-test.sh`, `cd worker/jobs && node --test test/model-price-source.bh-1613.test.js`, `cd console-ui && node --test tests/models-price-source.bh-1613.test.js` |
| the fail-closed marks read, the D1 vendor price and its verb and route (BH-1754) | `bash tests/update-model-prices.bh-1754-test.sh`, `cd worker/jobs && node --test test/model-price-vendor.bh-1754.test.js` |
| a newly priced model reaches the table and every box on its own deploy (BH-1566), including end to end through `bin/harness-sync.sh` | `bash tests/model-prices-deploy-sync.bh-1566-test.sh` |
| price versions, the audit rows, and the Fly and slug routes (BH-5652) | `cd worker/jobs && node --test test/price-versions.bh-5652.test.js` |
| the refresh creates no commit, and the seeder seeds once per file content (BH-5652) | `bash tests/price-refresh-no-commit.bh-5652-test.sh` |
| the cache fallback and its ALERTS line; the DB path prices like the catalog; `price_v:` on a cost row (BH-5652) | `bash tests/price-fallback.bh-5652-test.sh`, `bash tests/price-db-parity.bh-5652-test.sh`, `bash tests/cost-row-price-version.bh-5652-test.sh`, `bash tests/transcript-price-version.bh-5652-test.sh` |
| the consumers as suites | `bash tests/transcript-cost-test.sh`, `tests/claude-cost-test.sh`, `tests/pool-pricing-catalog-test.sh`, `tests/planned-files-cheap-test.sh`, `tests/unpriced-alert-test.sh` |

**Files on a live box:**

- `state/model-prices.json` — hub only, rewritten every day at 04:30 local.
  `jq '.per_token | length'` is the model count; `.updated_at` is the freshness.
- `catalog/model-prices.json` — everywhere, deployed by `harness-sync.sh`'s
  `catalog/` rsync, changed only by a merged PR.

**Knobs:** `HARNESS` and `HARNESS_CHECKOUT` override the two roots, for tests
only. No thresholds — the model map is the only judgement in the file, and it is
data in the script's `MAP`.
Per model, the `price_source` column in the `model_prices` table (BH-1613):
`vendor-direct` or NULL (= OpenRouter).

**What must never regress:**

- **The git checkout stays clean.** `git -C /root/harness-checkout status
  --porcelain` prints nothing after a refresh, on the rates-unchanged path and
  the rates-changed path alike. This lane used to rewrite `updated_at` into the
  tracked catalog file every morning with no commit; `harness-sync.sh` answers
  rc 30 on a dirty checkout, and the hub's live `bin/` froze behind a wall of
  green checks (BH-628). See [hub-sync-liveness.md](hub-sync-liveness.md) for
  the alert that now notices.
- **No `git commit` and no `git push` from this cron, ever.** The old
  hostname-gated push to `main` is gone; the iron guardrails forbid it and it was
  the second way the file ended up dirty.
- **A bad fetch or a thin parse keeps yesterday's table** and writes exactly one
  ALERTS line. Empty is not pass: fewer than 5 mapped models refuses the write.

**A newly priced model is priced on the deploy that brings it (BH-1566).**
Until this, a model added to `catalog/model-prices.json` (or the slug map) had
no `model_prices` row until the next 04:30Z refresh, and boxes pulled it at
05:05Z: for up to a day every box costed its calls from a
`state/model-prices.json` with no row for it (the reader chain takes the FIRST
readable table, so the catalog row never counted), and the `model_routes` PUT
refused it. Now `bin/harness-sync.sh`'s deploy path runs
`bin/model-prices-deploy-sync.sh` after its success stamp, keyed on the last
commit that touched `catalog/model-prices.json`, `catalog/model-slugs.json` or
`bin/update-model-prices.sh` (`state/model-prices-deploy-synced`; an unchanged
key exits with no network call). On the hub (the configured hub holding the
lease, `update-model-prices` lane not off) it runs the refresh once per key
(`state/model-prices-deploy-refreshed`), then POSTs every committed catalog
model the table still lacks, as `source=catalog`. It only ever adds a missing
model; a row the table already has is never overwritten by the catalog. A GET or
POST failure raises `lane-alert.sh --id model-prices-deploy-sync` and leaves the
key unstamped for the next deploy. Every box then pulls through
`bin/model-prices-sync.sh` when its `state/model-prices.json` lacks a catalog
model, and stamps the key only once the file covers the catalog; a box that
deploys before the hub pushed logs one `update-runners.log` line and retries on
each deploy.
