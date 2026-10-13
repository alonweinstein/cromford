# Pool warm-build timeout, bake capture and capped retry (BH-3463)

**What it is:** four changes to how a pool image bake behaves when it goes
wrong.

1. **The warm build has its own timeout.** The warm stage of `fly/Dockerfile`
   runs the project's production build through `fly/warm-build.sh` under
   `timeout WARM_BUILD_TIMEOUT_S`. A hung `next build` is killed, the image
   still ships with checkout + `node_modules`, and the script always exits 0.
   Before this, a hang held the whole remote build until
   `bin/fleet-propagate.sh`'s outer 1800 s timeout killed it with no image
   pushed.
2. **A timed-out bake leaves evidence.** A warm-build timeout, or the outer
   timeout (rc 124), writes `logs/fly-image-build/<pool>-<sha7>.log`.
3. **A catalog-only diff rebakes no pool.** `catalog/` reaches a pool machine
   in the spawn tarball (`bin/fly-pool.sh` `harness_tarball`), not through the
   image. `docs/` was never a fleet path.
4. **A failed bake is retried** on the next due tick, capped per pool per UTC
   day.

**How an operator reaches it:** `cron/hub.cron`, `*/5 * * * *
/root/harness/bin/fleet-propagate.sh`. The warm timeout also applies to every
other caller of `bin/fly-image-build.sh` (the 05:40Z `fly-image-refresh.sh` and
`fly-pool-rollout.sh`); those do not write captures or read the retry count.

**Knobs:**

| knob | where | default | notes |
|---|---|---|---|
| `pool.warm_build_timeout_s` | settings row, read by `bin/fly-image-build.sh` | — | wins over env |
| `WARM_BUILD_TIMEOUT_S` | env of whoever runs `fly-image-build.sh` | 600 | used when there is no usable row; a value that is not a positive number is named in a `WARN:` line and skipped |
| `POOL_BAKE_RETRY_MAX` | `catalog/lanes.d/fleet-propagate.json` (row or `env/global.env`) | 2 | retries per pool per UTC day; `0` = one attempt, the old behaviour |
| `PROPAGATE_PAGE_ON_FIRST_FAIL` | same file, row `lane.fleet-propagate.propagate_page_on_first_fail` | 0 | BH-3680: `1` pages `--critical` on the first failed bake even with a retry queued; see [propagate-page-severity.md](propagate-page-severity.md) |
| `POOL_BAKE_PUSH_GRACE_S` | same file, row `lane.fleet-propagate.pool_bake_push_grace_s` | 300 | BH-3680: extra seconds past `POOL_BAKE_TIMEOUT_S` for a bake already pushing; `0` = off |

The build log shows which timeout was used: `== warm build timeout: 600s
(default) ==` (or `(env WARM_BUILD_TIMEOUT_S)` / `(settings row
pool.warm_build_timeout_s)`).

**The record** (`state/fleet-propagate.json`, `.pools[<p>]`) gains two keys
next to `status`, `reason` and `warm_sha`:

- `warm`: `cold` when the warm build timed out or failed inside the bake,
  `warm` when it printed `warm build OK`, empty when the layer was reused or
  the image baked with no warm args. A `cold` pool with `status: ok` shipped a
  new image; only its build caches are missing.
- `capture`: the capture path, or empty.

**Reading a capture** (`logs/fly-image-build/<pool>-<sha7>.log`, pruned after
14 days):

```
# fleet-propagate bake capture (BH-3463)
pool=project-4 sha=<40 hex> rc=0 reason=none bake elapsed=742s written=...
## step timings
#14 [warm 5/5] RUN set -eux; ...
#14 3.1 warm-build: step build start timeout=600s
#14 603.2 warm-build: TIMED OUT after 600s — baking checkout+node_modules only (warm=cold)
#14 603.3 warm-build: step build elapsed=600s rc=124
#14 DONE 604.0s
## last 200 lines
...
```

`rc=0` with a `TIMED OUT` line is a shipped image with a cold warm layer.
`rc=124` is the outer timeout. Since BH-3680 the header also carries
`phase=build|push|record`: `build` means nothing was pushed and the last step
line before `## last 200 lines` is the one that hung; `push` or `record` means
the bake used its push grace too and still did not return, so a tag may be in
the registry that no pointer names.

**How to drive it:**

| what | how |
|---|---|
| the warm script, the Dockerfile wiring and the timeout argv | `HARNESS_TEST_SANDBOX=1 bash tests/fly-warm-build.bh-3463-test.sh` |
| catalog skip, capture, warn alert, retry and cap on a scratch harness | `HARNESS_TEST_SANDBOX=1 bash tests/fleet-propagate.bh-3463-test.sh` |
| what the next tick would do, spending nothing | `/root/harness/bin/fleet-propagate.sh --check` — a catalog-only range prints `pools:   none (no image input changed)` |
| what happened | `tail /root/harness/logs/fleet-propagate.log` — `pool <p>: warm build timed out — image shipped cold, see <capture>`, `pool <p>: retry k/MAX queued for the next tick (bake failed)`, `pool <p>: retry cap MAX reached today (bake failed), ...`, `pools: no image input changed (...)` |
| the record | `jq '.pools' /root/harness/state/fleet-propagate.json` |
| retries used today | `cat /root/harness/state/fly/<p>.bake-retries` — `<UTC-date> <n>`; absent after an ok bake |

**Alerts** (still exactly one per run):

- A clean run with a warm timeout: `--severity warn` (the digest), text ends
  `shipped the new harness, warm layer cold (warm build timed out): <p> (logs/fly-image-build/<p>-<sha7>.log)`.
- A run with a failed pool: per failed pool `<p>: retry queued (k/MAX)` or
  `retry cap reached`, and `see <capture>` when it has one. Since BH-3680 it is
  `--critical` only when a pool is out of retries (or the hub, a box or the
  crontab failed); a pool whose retry is queued is a `--severity warn` line.
  See [propagate-page-severity.md](propagate-page-severity.md).
- A catalog-only run: `--log-only`, `0/0 pool images rebaked (no image input changed)`.

**What must never regress:**

- **The warm layer never fails the image.** `fly/warm-build.sh` exits 0 on
  every path, and a pushed image is `ok` whatever its warm layer did.
- **A cold image never reads as warm.** `warm: cold` plus the warn line say so.
- **The retry is bounded.** At most `POOL_BAKE_RETRY_MAX` retries per pool per
  UTC day, each through the debounce window, then the marker is cleared and the
  log says when the next attempt comes.
- **Only a timeout sentinel counts.** `next build exceeded the configured
  timeout`, `Terminated`, and `TIMED OUT` inside an unrelated line never mark a
  pool cold or write a capture.
