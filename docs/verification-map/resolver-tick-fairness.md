# Resolver tick fairness (least-recently-visited project order, the `tick:` line, the `STARVED` alert)

**What it is:** `bin/blocked-resolver.sh` spends one fleet budget per tick
(`BR_PER_TICK`, default 4). Since BH-980 it spends it on the projects it looked
at LONGEST AGO, remembers that in a small ledger across ticks, writes one line
per tick saying which projects it visited and why it stopped, and pages once for
a project that has parked candidates and has not been looked at for more than an
hour.

Before BH-980 the project order was first appearance in the candidate stream,
which is deterministic, so every tick offered the same first `BR_PER_TICK`
projects and the ones behind them were never reached. On the hub that was
project-5: 14 hand-offs, seven hours, zero resolver lines, no alert.

**How an operator reaches it:** no UI. `cron/hub.cron` runs the lane at
`4,14,24,34,44,54`. The three surfaces are:

- `logs/blocked-resolver.log` — the `tick:` line, one per non-idle tick.
- `logs/ALERTS.log` and the `fleet_alert` beat — the `STARVED` line.
- `state/blocked-resolver/.last-visited.tsv` — the visit ledger itself.

**Primary lane / scripts:**
- `bin/blocked-resolver.sh` — `br_round_robin` (the ledger-ordered interleave and
  its single-emission fail-open), `br_visited_row` / `br_visited_put` (the
  ledger), `br_starved_alert`, and the drain loop that reads the candidate array,
  stamps a project before its rung, and writes the tick line.
- `bin/lane-alert.sh blocked-resolver` — how the `STARVED` line leaves the box,
  with the direct `ALERTS.log` + `bin/beat.sh` fallback when it is absent.

**State and knobs:**
- ledger: `state/blocked-resolver/.last-visited.tsv`, one row per project,
  `<project>\t<last_visited>\t<first_seen>\t<last_alerted>` (unix epochs, `0` =
  never). A dotfile so `br_from_rebuilds`' `*/*.json` glob and the per-project
  state directories never see it. Bounded by `fleet.conf`.
- lock: `locks/blocked-resolver-visited.lock`, `flock -w 5`, held for one
  read-modify-write and never across a rung.
- `BR_STARVE_ALERT_SECS` — seconds a project may go unlooked-at before the one
  alert, default 3600. A non-numeric value falls back to 3600.
- `BR_PER_TICK`, `BR_PER_TICK_<PROJECT>` — unchanged by this feature; the tick
  line reports the spend against them.

**Preconditions / seed needs:** none. A box with no ledger file behaves exactly as
it did before BH-980 and creates the file on its first tick that spends a rung.

**How to drive it:**
- `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver.bh-980-test.sh` — six
  projects with one park each: §0 drives `br_round_robin` extracted verbatim
  (ledger order, no-ledger order, a broken awk, an awk that dies after a partial
  write), §1 is the ticket's test (`BR_PER_TICK=2`, all six visited within three
  ticks), §2 the tick line (`budget`, `drained`, silent idle tick), §3 no
  `Broken pipe` in the whole run, §4 the alert and its negatives, §5 BH-870's
  fixture unchanged.
- `HARNESS_TEST_SANDBOX=1 bash tests/resolver-per-project-budget.bh-870-test.sh` —
  the BH-870 contract this sits on top of (interleave, per-project share, a HELD
  candidate spending nothing).
- On a live box: `grep 'tick:' logs/blocked-resolver.log | tail -5` shows the last
  five ticks; `cat state/blocked-resolver/.last-visited.tsv` shows when each
  project was last looked at.

**Verify it works:** `tests/blocked-resolver.bh-980-test.sh` reports
`PASS 58 FAIL 0`. On the hub, every project holding parked candidates appears in
a `visited=[...]` within `ceil(projects / BR_PER_TICK)` consecutive `tick:` lines,
and no `Broken pipe` appears in the lane's output.

**What must never regress:**
- No ledger file = BH-870's order, byte for byte. A box that has never run this
  code must not behave differently on its first tick.
- An idle tick (empty candidate stream) writes nothing at all.
- One `STARVED` line per episode, re-armed only by an actual visit. A project with
  no candidates this tick is never starved, however old its row.
- `reason=` is decided by the loop's own exit — `budget` only when the break ran,
  `drained` when every candidate was offered.
- The ordering never drops or duplicates a candidate, on the awk path or the
  fail-open path.

**Manual-only / not automatable:** watching the hub's real seven-project tick
rotate over an hour (the fixture pins the same behaviour in three ticks).
