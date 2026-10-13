# Land-triggered rebase (`MC_LAND_REBASE`)

**What it is:** the conductor arm that treats a merge landing on a project's
base branch as an event. When `git ls-remote` says the base has a sha this lane
has not handled, every open base-based PR of that repo is offered ONE mechanical
rebase in the same tick — instead of waiting for GitHub to call each of them
DIRTY, which is the expensive way to learn main moved.

It is not a new lane and not a new cron line. It is `land_rebase_arm` in
`bin/merge-conductor.sh`, called once per PR inside `pr_worker`, plus the base
sha read in `tick_project`.

**How an operator reaches it:**

- `cron/hub.cron`, `*/5`, `bin/merge-conductor.sh`. Nothing else invokes it.
- Everything it does is in `logs/merge-conductor.log` under one word:
  `grep ' LAND' /root/harness/logs/merge-conductor.log | tail -40`.
- Kill switch: `MC_LAND_REBASE=0` in `env/global.env` restores the pre-BH-870
  conductor byte for byte — no base-sha read, no state file, no LAND line.
- Ceiling: `MC_LAND_REBASE_PARALLEL` (default 4, `0` = unlimited) bounds how
  many hub rebases this arm may have running. It is passed to
  `mc_rebase_spawn` as its seventh argument and is counted against
  `mc_rb_running`, which counts ALL rebases — so the land lane yields to
  ordinary ones and can never push the box above its own number alone.

**The lines, in the order a landing produces them:**

| line | means |
|---|---|
| `<slug> LAND baseline <base> <sha8> recorded` | first tick after rollout for this project; nothing fans out |
| `<slug> LAND <base> moved <old8> -> <new8>` | the trigger; every open base-based PR is offered a rebase this tick |
| `<slug> LAND: <base> sha unreadable this tick` | ls-remote could not answer; nothing fires, the recorded sha stands |
| `<key> LAND_REBASE_SPAWNED main <sha8>` | a detached hub rebase was spawned and the row is REBASING |
| `<key> LAND_REBASE_QUEUED main <sha8>` | `REBASE_ON_POOL` is on; a pool queue row was written, nothing cloned here |
| `<key> LAND_SKIP parked BLOCKED_AGENT/RED_TWICE` | `bin/blocked-resolver.sh` owns that PR |
| `<key> LAND_SKIP Mergify dequeued label` | Mergify's terminal label; this lane does not rebase it |
| `<key> LAND_CONFLICT` | the head conflicts; left to the existing `NEEDS_REBASE` path and the resolver ladder |
| `<key> LAND_DEFER …` | not reached this tick (cap, PR lock, re-review in flight, merge test unavailable); re-offered next tick |
| `<key> would land-rebase …` | observe mode (`flags/merge-conductor-actions` absent) |
| `<slug> LAND <base> <sha8> handled: spawned=N current=N conflict=N skipped=N` | the fan-out reached every PR; the sha is now recorded |
| `<slug> LAND <base> <sha8> PARTIAL: spawned=N deferred=N` | it did NOT reach them all; the sha is NOT recorded, so the next tick re-offers the deferred PRs |

**What to read on a live hub:**

| what | where |
|---|---|
| the last base sha whose fan-out completed | `cat /root/harness/state/merge-conductor/land/<project>` — after a completed fan-out it equals `git ls-remote origin refs/heads/main` on that repo |
| which PRs already had their answer for a sha | `grep '^landrebase ' /root/harness/state/merge-conductor/attempts.txt` — one `landrebase <slug>#<num> <40-hex>` per (PR, base sha) |
| how many land rebases are in flight | `ls /root/harness/state/merge-conductor/rebase/*.json` — land jobs are ordinary rebase jobs; with the pool off, the running count stays at or below `MC_LAND_REBASE_PARALLEL` |

**How to drive it:**

| what | how |
|---|---|
| the whole arm end to end: baseline, landing, idempotence, every skip, the conflict, the cap, the pool, both kill paths | `HARNESS_TEST_SANDBOX=1 bash tests/land-rebase.bh-870-test.sh` |
| the detached-lane fd hygiene the spawn relies on (and that `mc_rebase_spawn`'s six-argument callers are unchanged) | `HARNESS_TEST_SANDBOX=1 bash tests/conductor-detached-lanes-test.sh` |
| the result path a land job's answer takes | `HARNESS_TEST_SANDBOX=1 bash tests/mc-rebase-consume-test.sh` |
| the pool branch the arm reuses | `HARNESS_TEST_SANDBOX=1 bash tests/rebase-on-pool-test.sh` |

**What must never regress:**

- **A deferral must not record the sha.** Every path that does not deliver a
  rebase increments `landdeferred`, and `tick_project` records the handled sha
  only when that count is zero and actions are on. Recording over a deferral
  drops that PR's rebase for good — the cap would become a silent loss instead
  of a delay.
- **The marker is written AFTER the spawn.** `landrebase <key> <sha>` means
  "this PR has had its answer for this sha". A marker written before a spawn
  that then failed is a PR this lane will never come back to.
- **`READY` is never land-rebased.** It is one merge away; moving its head
  costs that merge a whole CI cycle and buys nothing.
- **No new rebase machinery.** The arm calls `mc_rebase` / `mc_rebase_spawn`
  and lets the existing `rebase_consume` read the result, so the approval
  rebind (patch-id, and `mc_rebase`'s own) keeps working. A separate rebase
  path here would be a second place approvals could be lost.

**Measurement owed (operator, not code).** The ticket asks for median open-PR
age before and after. Run this on the hub before the rollout and about 48h
after:

```
gh pr list -R example-org/cromford --state open --json createdAt \
  -q '[.[] | (now - (.createdAt|fromdateiso8601))/3600] | sort | .[length/2|floor]'
```
