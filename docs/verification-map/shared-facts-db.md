# Shared facts (account leases, the gh budget, box identity)

**What it is:** three facts the fleet used to keep a per-BOX copy of, all three
of which are only true fleet-wide. The 2026-09-19 spend/state audit (§2.4) found
them together because they fail the same way: nothing errors, nothing alerts,
and the answer is quietly wrong on every box at once.

- **an account's lease count.** `bin/lib/pool-account.sh` counted live leases as
  FILES under `state/quota/leases/<account>/<machine-id>`. That directory is per
  box, so the hub at cap 4 and a second box at cap 4 both counted zero used and
  both filled the same account — eight heavy sessions on an account
  `fly/account-capacity.conf` rates at ~4. The account then starts refusing, and
  the refusals read like the account's problem.
- **a token's GitHub rate budget.** `bin/lib/gh-budget.sh` cached
  `gh api rate_limit` at `state/gh-budget/<token-fingerprint>.json`, per box. The
  bucket belongs to the TOKEN and the fleet shares one identity, so nine boxes
  each read "4,800 remaining" and each believed it had 4,800 to spend — and each
  burned one rate_limit call per TTL to learn the same number.
- **the box's own name.** `box` is half the primary key of every row the fleet
  writes, and `bin/cost-rows-push.sh` fell through to `hostname`. Every Orgo box
  answers the image default `orgo-desktop`, so a box whose `state/box-id` had not
  landed filed its rows under a PHANTOM that merges however many machines were in
  that state — while reporting success.

The first two become ROWS in the harness-jobs worker (`account_leases`,
`gh_budget`), with the cap enforced by a compare-and-swap and the TTL judged on
the server's clock. The third becomes an ASSERTION at lane start
(`bin/lib/box-id.sh`): no identity, no rows, one alert a day.

**How an operator reaches it:** no UI route. Three ways in, all bearer-gated:

```bash
curl -s -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/account-leases"
curl -s -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/account-leases?account=max1"
curl -s -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/gh-budget?fingerprint=<12 hex>"
```

From a box, the clients are `account_lease_claim` / `account_lease_release` /
`account_lease_count` / `account_lease_counts` and `gh_budget_row_get` /
`gh_budget_row_put` in `bin/jobs-client.sh`, and `box_id_get` /
`box_id_require` in `bin/lib/box-id.sh`. A pick uses the BATCHED
`account_lease_counts`: the rank reads a count for every account in the
registry and `bin/fly-pool.sh` spawns up to ten machines a tick, so a
per-account GET would be seventy round trips every two minutes, each one in
front of a machine waiting to launch.

**The primary lanes:**

- `bin/fly-pool.sh` (`cron/hub.cron`, `*/10` via `fly-pool-tick.sh`) → sources
  `bin/lib/pool-account.sh` → claims a lease per machine it spawns, releases on
  reap and on every failed env push.
- every lane that sources `bin/lib/gh-budget.sh` — `bin/merge-conductor.sh`,
  `bin/review-autopilot.sh`, `bin/wake-loop.sh`, `bin/pipeline-health.sh`,
  `bin/pr-owner-sweep.sh`, `bin/orphan-reconcile.sh`,
  `bin/watchdog-responder.sh`.
- `bin/cost-rows-push.sh` (every `cron/<box>.cron`, `*/10`) plus the pool
  machine's own push from `fly/builder-runner.sh`.

**Key routes:**

- `POST /api/account-leases/claim` — `{account, machine_id, box?, project?,
  ticket_key?, cap?, ttl_s?}`. `account` and `machine_id` must match
  `[A-Za-z0-9._-]{1,64}`, else `400`. `cap` clamps to `[0, 64]` and defaults to
  4; `0` means no cap. `ttl_s` clamps to `[60, 86400]` and defaults to 10800
  (the box's `ACCOUNT_LEASE_TTL_SECS`). Expired rows are swept, then ONE
  statement decides:

  ```sql
  INSERT INTO account_leases (account, machine_id, box, project, ticket_key, expires_at, created_at, updated_at)
  SELECT ?1,?2,?3,?4,?5,?6,?7,?7 WHERE
  (SELECT COUNT(*) FROM account_leases WHERE account=?1 AND machine_id<>?2 AND expires_at>?7) < ?8
  ON CONFLICT(account, machine_id) DO UPDATE SET box=excluded.box, project=excluded.project,
  ticket_key=excluded.ticket_key, expires_at=excluded.expires_at, updated_at=excluded.updated_at
  ```

  judged by `meta.changes` → `200 {claimed:true, live, cap, expires_at}` or
  `409 {claimed:false, reason:"cap", live, cap}`. The count excludes the
  claimant's own row, so a machine renewing its lease is never refused by
  itself; a read-then-write would let two boxes both win the last slot, which is
  the original bug rebuilt inside the fix.
- `POST /api/account-leases/release` — `{machine_id, account?}` →
  `200 {released:<n>}`. A machine that holds nothing is `released:0`, not an
  error.
- `GET /api/account-leases` — with `account`, `{account, live, rows}`; without,
  `{counts:{<account>:n}, live}` for the whole fleet in one call.
- `POST /api/account-leases/token-health` — stub (BH-2516.0); the BH-2516
  routes child fills it. Answers `202 {ok:true, stub:true}` and writes nothing.
- `GET /api/account-leases/health` — stub (BH-2516.0); the BH-2516 routes child
  fills it. Answers `{accounts:[], warn_h:24, warn_h_source:'default', as_of,
  truncated:{leases:false, tokens:false}}` and reads nothing.
- `POST /api/gh-budget` — `{fingerprint, fetched_at, core:{}, graphql:{}, box?}`.
  The upsert is MONOTONIC (`WHERE excluded.fetched_at >= gh_budget.fetched_at`),
  so a slow box's older reading can never raise `remaining` back up. A bucket the
  vendor did not report lands NULL, never 0 — a zero remaining means EXHAUSTED
  and would stop every non-essential read in the fleet.
- `GET /api/gh-budget?fingerprint=` — `200 {row|null}`. Never a `404` for "no
  reading yet": the client treats `404` as an outage, and the first box to ask
  after a deploy is not an outage.

**Selectors:** not applicable — no rendered screen. The observable surfaces are
the HTTP status and `claimed` / `reason:"cap"` / `released` / `wrote` / `row`.

**Fail-open, in every direction but one.** `bin/lib/pool-account.sh` treats an
unreachable worker as "take this candidate" and only a `409` as "try the next
one": a launch that does not happen is worse than a launch on a busy account,
and collapsing the two would put the whole pool back on the single capped
project-6 token. `bin/lib/gh-budget.sh` falls through to its own `rate_limit`
read on any failure. The ONE fail-CLOSED path is `box_id_require`: the "work"
it would be protecting is writing a row under a name that is not a box, and not
doing that is the correct outcome — `logs/cost.csv` is untouched and the first
tick after `state/box-id` lands sends everything that was held.

**Preconditions / seed needs:** none by hand. Both tables are in
`CREATED_TABLES` in `worker/jobs/src/lib/core.js`, so they self-create before the
first statement that needs them — `bin/harness-sync.sh` runs `wrangler deploy`
and nothing else, and a table that waits for a hand-run `d1 execute` ships dead
(the TK-64 shape; `hub_lease` shipped with exactly it). `schema.sql` carries the
same CREATEs as the readable definition and for a fresh database. No new env
var: `HARNESS_SECRET` and `JOBS_URL` are the ones every box already holds.

**Knobs:**

| knob | default | what it does |
|---|---|---|
| `POOL_ACCOUNT_DB_LEASES` | 1 | 0 = the pool ranks and claims from per-box files only, exactly as before this change |
| `ACCOUNT_POOL_MAX_LEASES` | `fly/account-capacity.conf` claude row (4) | the per-account cap sent with every claim; 0 = no cap |
| `ACCOUNT_LEASE_TTL_SECS` | 10800 | the ttl sent with every claim (clamped server-side to [60, 86400]) |
| `GH_BUDGET_DB` | 1 | 0 = every box reads and caches its own `rate_limit`, as before |
| `GH_BUDGET_TTL_S` | 60 | how long a shared reading counts as current |
| `BOX_ID` | — | a lane declaring its own identity (the pool's `pool-<project>-<machine-id>`) |

**Verify it works:**

```bash
bash tests/account-lease-cas-test.sh    # two boxes, one shared table, one winner
bash tests/gh-budget-shared-test.sh     # one token, one remaining figure, one API call
bash tests/box-id-required-test.sh      # no identity -> no row, one alert
cd worker/jobs && node --test test/shared-facts.test.js
```

The three shell suites drive the REAL `bin/lib/pool-account.sh`,
`bin/lib/gh-budget.sh` and `bin/cost-rows-push.sh` on two scratch boxes with
separate `$HARNESS` trees and one shared table file, so "box 2 could not lease
what box 1 filled" is measured on the wire rather than asserted about source
text. `test/shared-facts.test.js` PARSES the claim statement and evaluates it
against fixture rows — a stub answering `changes:1` would pass a worker that
never checks the cap, which is the bug.

On a live box, after the worker deploys:

```bash
curl -s -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/account-leases" | jq .counts
grep 'gets account' /root/harness/logs/fly-pool.log | tail -5   # which account each machine got
grep 'all_leased'   /root/harness/logs/fly-pool.log | tail -5   # the fleet-wide cap biting
cat /root/harness/state/gh-budget/*.json | jq '{fetched_at, _shared, core}'
```

`_shared: true` in a box's gh-budget cache is the evidence it took the fleet's
reading instead of spending its own `rate_limit` call.

**What must never regress:** a worker outage must never refuse a pool launch or
turn a healthy GitHub bucket into a skipped tick; a `409` must never be
confused with an outage; an older `rate_limit` reading must never raise
`remaining`; and no lane may ever write a row under a guessed box name.

**Manual-only / not automatable:** the fleet-wide race itself. Two real boxes
spawning into the same account in the same second is what the CAS exists for,
and it cannot be staged in CI — what IS automated is that the decision is one
statement with the cap inside it, which is the property the race depends on.

**Sibling slices:** the audit's other §2.4 item, the pool machine spawned before
its `auth-accounts.local.json` overlay, was already closed in `bin/fly-pool.sh`
(the overlay is pushed before `job.json`); `tests/box-id-required-test.sh`
section G pins that ordering so it cannot silently invert.
