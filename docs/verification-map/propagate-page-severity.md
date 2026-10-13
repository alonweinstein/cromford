# fleet-propagate page severity and bake push grace (BH-3680)

**What it is:** two changes to `bin/fleet-propagate.sh` (the hub's `*/5` lane
that lands a merge on the whole fleet).

1. **A failed pool bake whose retry is queued no longer pages.** BH-3463 gave a
   failed bake a capped retry on the next due tick, but the run still paged
   `--critical` on the first failure. Now that run is one `--severity warn`
   digest line naming the pool under `retrying:`. The page comes on the run
   whose failure spends the retry cap, or at once when something else failed.
2. **A bake already pushing gets a margin.** `POOL_BAKE_TIMEOUT_S` used to kill
   a bake wherever it was. A bake still building at that limit is killed as
   before; one that has reached the image push (or the pointer record after
   it) gets `POOL_BAKE_PUSH_GRACE_S` more before the hard timeout.

**How an operator reaches it:** `cron/hub.cron`, `*/5 * * * *
/root/harness/bin/fleet-propagate.sh`. There is no console screen for the lane;
the knobs show in the settings view under the `fleet-propagate` lane.

**Severity, one alert per run:**

| the run | alert |
|---|---|
| hub failed, a box failed or did not report, or the crontab render/install failed | `--critical` |
| a pool bake failed with `retry cap reached` or `no retry (POOL_BAKE_RETRY_MAX=0)` | `--critical` |
| a failed pool with no retry verdict at all (should be impossible) | `--critical` (fail open) |
| any failed pool while `PROPAGATE_PAGE_ON_FIRST_FAIL=1` | `--critical` (the behaviour before BH-3680) |
| the only failures are pools with `retry queued (k/MAX)` | `--severity warn`, `propagated <sha7> with pool bakes retrying: …` (or `drained … at <sha7> with pool bakes retrying: …` on a drain tick) |
| clean, but a pool shipped with a timed-out warm build | `--severity warn` (unchanged) |
| clean | `--log-only` (unchanged) |

The page keeps its prefix `propagating <sha7> to the fleet FAILED in part`,
which the `fleet-propagate-partial` alert-verify row matches; the warn line
never carries it. In the page, `failed:` after the pool count names only the
paging pools, `retrying:` names the queued ones, and the text ends
`Still running the OLD harness: <hub> <failed boxes> <paging pools>.` A
retrying pool and a cold-warm pool are never in that list; a cold-warm pool has
its own clause, `shipped the new harness, warm layer cold (warm build timed
out): <p> (<capture>)`.

A retry that bakes ok logs `pool <p>: ok on retry n/N` and appends
`; <p> ok on retry n/N` to that run's success line. The severity of the success
line does not change.

**Knobs** (`catalog/lanes.d/fleet-propagate.json`, settable, env fallback):

| knob | settings row | default | notes |
|---|---|---|---|
| `PROPAGATE_PAGE_ON_FIRST_FAIL` | `lane.fleet-propagate.propagate_page_on_first_fail` | 0 | `1` pages on the first failed bake. Anything but 0/1 logs `PROPAGATE_PAGE_ON_FIRST_FAIL=<v> is not 0 or 1 — using 0` |
| `POOL_BAKE_PUSH_GRACE_S` | `lane.fleet-propagate.pool_bake_push_grace_s` | 300 | `0` = off, one timeout for the whole bake. Not a number logs `… is not a number of seconds — using 300` |

The phase is read from the bake's output: `record` once the
`image: registry.fly.io/…` line fly-image-build.sh parses is printed, `push` on
a BuildKit `pushing layer(s)|manifest` or `exporting to image|layers` line,
`build` otherwise.

**How to drive it:**

| what | how |
|---|---|
| every severity case, the ok-on-retry label and the push grace, on a scratch harness | `HARNESS_TEST_SANDBOX=1 bash tests/fleet-propagate.bh-3680-test.sh` |
| what happened on the hub | `tail /root/harness/logs/fleet-propagate.log`: `pool <p>: ok on retry n/N`, `pool <p>: outer timeout hit in the <build\|push\|record> phase (<T>s build limit, +<G>s push grace)`, `pool <p>: bake ran <s>s, past the <T>s build limit, finished in its push grace` |
| the alert that went out | `grep fleet-propagate /root/harness/logs/ALERTS.log \| tail -3` |
| the capture of a timed-out bake | `logs/fly-image-build/<p>-<sha7>.log`, header `… reason=timeout phase=<phase> bake elapsed=…` |

**What usually lies:**

- A warn with `retrying:` is not a success. That pool is still on its previous
  image until the retry lands.
- `ok on retry` is missing when the retry landed after 00:00Z. The retry
  counter is per UTC day, and the label follows the same rule. The page is
  never affected.
- A bake that finished in its push grace ran longer than `POOL_BAKE_TIMEOUT_S`.
  Its `ok` is real (the pointer was written), but the elapsed time is past the
  limit on purpose.
- The run log's summary line still lists every failed pool in `failed=`,
  retrying ones included. That line is the record; the alert is the page.
