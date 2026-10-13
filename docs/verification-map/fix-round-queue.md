# Fix-round queue: the box claimer lane

**What it is:** the owning box's half of the fix-round queue (BH-2530). The hub's
blocked-resolver used to run a fix round by ssh-ing to the box that owns the
project (`br_fix_remote`). The queue replaces that hop with a pull: the hub
enqueues a `fix_round_jobs` row addressed to a box, and `bin/fix-round-claim.sh`
on that box claims it, runs `bin/blocked-resolver.sh --fix-here` on it, and
posts the answer back as the row's finish.

**The hub half (BH-2674).** `bin/blocked-resolver.sh` on the hub no longer
hops. `br_fix_remote` enqueues the row. `br_one`'s in-flight gate then holds
the park while the row is queued or claimed, and hands a done row to
`br_fix_adopt`, which saves the box's record, wins the adopt CAS and only then
takes the rung. The hub log shows `EVENT resolver_rung <p>/<ck> [...] rung 2
fix-round queued for <box>` and then `fix round in flight on <box> (<status>
since <updated_at>)`. A row still queued after `BR_FIX_LANE_TIMEOUT` pages once as
`fix-round-unclaimed-<p>-<ck>`; a row still claimed after `BR_FIX_LANE_TIMEOUT +
BR_FIX_HOP_MARGIN` pages once as `fix-round-stale-claim-<p>-<ck>`, and a hub
without `bin/lib/fix-round-queue.sh` pages once as
`fix-round-queue-missing-<p>`. Until the worker routes (`/api/fix-rounds/*`,
BH-2670) answer in production, the enqueue fails and the hub logs `fix round
NOT queued — jobs DB unreachable`. The gate's read answers 404, which reads as
"no row" and holds nothing. Pinned by
`tests/fix-round-hub-restart.bh-2530-test.sh`.

**How to reach it:** there is no screen. It is a cron lane:

- `cron/lanes/718-fix-round-claim.cron`:
  `*/2 * * * * /root/harness/bin/fix-round-claim.sh >>/root/harness/logs/fix-round-claim.log 2>&1`,
  rendered into the crontab of the eight project boxes listed in
  `catalog/lanes.d/fix-round-claim.json`. It is not a hub lane and has no
  hub-lease gate. On the hub the script exits before any request.
- Off/on: `bin/harness-ctl.sh off fix-round-claim "<reason>"` (writes
  `flags/lane-off-fix-round-claim`), or the knob `FIX_ROUND_CLAIM=0`.
- Knobs (console lane page, rendered from the registry):
  `FIX_ROUND_CLAIM` (default 1), `FIX_ROUND_CLAIM_MAX` (claims per tick,
  default 2). The stale cutoff sent with each claim is
  `ceil((BR_FIX_LANE_TIMEOUT + BR_FIX_HOP_MARGIN) / 60)` minutes, 95 by
  default, read from the `blocked-resolver` lane's knobs.

**What shows it working on a live box:**

- `logs/fix-round-claim.log`. A tick that claimed logs
  `tick on <box>: claimed N, lost N race(s), stale_min 95`. Each runner logs
  `row <id> <p>/<ck> attempt <n>: fix round starting` and then
  `row <id> finished: <done|terminal|rebuild-fresh|setup-blocked|box-paused> (...)`.
  A tick with nothing to claim writes nothing.
- `locks/fix-round-<project>-<cap_key>.lock`, held (`flock -n`) for as long as
  that round runs.
- A re-offered row whose round already ran on this box logs
  `re-offered row <id>: the round already ran here (attempts n0→n1) ...` and is
  finished `done` from `state/blocked-resolver/<p>/<ck>.json` without a
  second round.

**Failure semantics:** no `FIX_RESULT` from the round (killed, timed out, a bin/
without `--fix-here`) finishes `setup-blocked <base64 reason>`, never `done`. A
malformed row (project or cap_key outside `[A-Za-z0-9._-]`, args not six
strings) finishes `setup-blocked` without running. A finish that fails leaves
the row `claimed`; the stale re-offer plus the re-offer guard recover it. A 409
on finish is logged once and not retried.

**Drive suite:** `HARNESS_TEST_SANDBOX=1 bash tests/fix-round-claim.bh-2530-test.sh`
runs the real script in a scratch box harness against a curl shim that plays
the worker and a stub `--fix-here`. The queue client itself is pinned by
`tests/fix-round-queue.bh-2668-test.sh`.
