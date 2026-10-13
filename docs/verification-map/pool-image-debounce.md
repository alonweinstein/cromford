# Pool image bake debounce

**What it is:** `bin/fleet-propagate.sh` rebakes the pool builder images when a
merge touches a fleet path. Every bake is a remote Fly build, and the lane runs
every five minutes, so a burst of merges (cromford landed 11 PRs in eight
minutes on 2026-09-18) used to mean ten remote builds per tick. A pool whose
image was baked less than `POOL_IMAGE_MIN_AGE_MIN` minutes ago is now skipped:
it is recorded `debounced` — a tolerated skip, never a `--critical` — and marked
dirty in state. The next tick whose window has expired bakes it, **even when
nothing new has merged**, so a skip never leaves a pool on a stale image.

`--force` and the nightly `bin/fly-image-refresh.sh` are unchanged: they always
bake.

**How an operator reaches it:** `cron/hub.cron` line 138, `*/5 * * * *
/root/harness/bin/fleet-propagate.sh`. The nightly refresh is line 37 (05:40Z)
and does not read or write the debounce state.

**How to drive it:**

| what | how |
|---|---|
| the whole decision, both entry paths, on a scratch harness | `HARNESS_TEST_SANDBOX=1 bash tests/fleet-propagate.bh-821-test.sh` |
| the per-merge mode this replaced (knob `0`) is still proven | `HARNESS_TEST_SANDBOX=1 bash tests/fleet-propagate-test.sh`, `HARNESS_TEST_SANDBOX=1 bash tests/warm-bake-guard-test.sh` — both pin `POOL_IMAGE_MIN_AGE_MIN=0` |
| what the next tick would do, on the hub, spending nothing | `POOL_IMAGE_MIN_AGE_MIN=30 /root/harness/bin/fleet-propagate.sh --check` — one `bake` / `debounced (Nm old, under 30m)` line per pool, and in drain mode the pools it would drain |
| the knob and the state files, from the header | `/root/harness/bin/fleet-propagate.sh --help` |
| what actually happened | `tail /root/harness/logs/fleet-propagate.log` — `images=0/10 (10 debounced)`, plus one `debounced, marked dirty at <sha7>` line per skipped pool |
| the run record | `jq '.drain, .pools' /root/harness/state/fleet-propagate.json` — `drain:true` on a tick that only drained; `.pools[p].status` reads `ok`, `fail` or `debounced` (BH-1115 added `.reason` and `.warm_sha` beside it, see [pool-bake-fanout.md](pool-bake-fanout.md)) |

**Files it owns on a live hub:**

- `state/fly/<project>.baked-at` — epoch seconds of the last bake that returned
  `ok`, written from the bake's result, never on a failure.
- `state/fly/<project>.image-dirty` — the sha a debounce skipped. Removed when a
  later bake of that project returns `ok`, when a failed bake has used up its
  retries (BH-3463, [pool-warm-timeout.md](pool-warm-timeout.md)), or when the
  project loses its `flags/fly-pool-app-<project>`. The nightly `fly-image-refresh.sh`
  does not read or write either file, so a marker written before 05:40Z outlives
  the nightly bake and the next eligible tick drains a pool the nightly just
  baked — at most one extra bake per dirty pool per day, and the same one extra
  bake the untouched nightly already costs the first merge after it.
- `env/global.env` — `POOL_IMAGE_MIN_AGE_MIN` (documented in
  `env-templates/global.env.example`; default 30 with the file absent).

**What must never regress:**

- **A skip is not a failure.** A debounced pool is `debounced` in the record and
  in the alert, and never appears in `failed:`. A run whose only "problem" is a
  debounce is not `--critical`. A pool that really failed still is.
- **A debounce always terminates, and the drain is bounded.** The dirty marker
  survives every tick until the pool is baked. An `ok` stamps and clears it. A
  failure does not stamp; since BH-3463 it keeps the marker for at most
  `POOL_BAKE_RETRY_MAX` (default 2) retries per pool per UTC day, then clears
  it (`0` = clear at once, the behaviour before BH-3463, still pinned by
  `tests/fleet-propagate.bh-821-test.sh` §H2). It must never buy a retry every
  five minutes without a cap — a permanently broken pool (deleted Fly app,
  broken Dockerfile) would then cost 288 remote build attempts a day, which is
  the spend this whole entry exists to stop. Past the cap the bake returns on
  the next merge or the 05:40Z nightly.
- **Absent is not fresh.** No stamp, an unparseable stamp, or a stamp in the
  future all bake. A future stamp must not suppress bakes until the clock
  catches up.
- **A drain bakes, it does not re-propagate.** A tick with nothing new merged
  runs the hub step and the dirty pools only — it does not ssh the boxes (they
  already hold that sha) and does not move `last_sha` or re-render the crontab.
- **`--check` spends nothing.** It reads the same knob and the same state and
  writes neither, so what it prints is what the next real tick would do.
- **The knob is config.** A hardcoded 30 in the branch would be the bug this
  entry exists to prevent; an unparseable value logs one line and uses 30, never
  silently falls back to baking on every merge.
