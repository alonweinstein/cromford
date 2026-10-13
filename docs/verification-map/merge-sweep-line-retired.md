# The retired merge-sweep lane (the hub merges through the conductor only)

**What it is:** the absence of a cron line. `bin/merge-sweep.sh` ran on the hub
at `6,16,26,36,46,56 * * * *` from `cron/lanes/400-merge-sweep.cron`, behind the
`lane-off-merge-sweep` flag and the `automerge-disabled` alias. BH-1388 deletes
that lane file and `catalog/lanes.d/merge-sweep.json`, so the hub's only merger
is `bin/merge-conductor.sh` at `*/5`. **The SCRIPT stays**, and so do its
suites: `bin/batch-resolve.sh` and an operator still run it by hand. The box
side `tier2-merge-sweep` lane was a different lane; BH-1366 retired it on main
separately, and this ticket does not touch it.

The second half is a consequence of the first. `state/merge-sweep-done.txt` is
written by the sweep, so once the lane stops it stops growing — and
`bin/pipeline-health.sh`'s "sweep should have landed" detector used that file as
its only "this PR was handled" answer. It now also asks the merge ledger
(`merge_ledger_has`, kinds `merge` and `pr_merged`), which is what
`mc_settle_merged` writes on every conductor landing.

## How you reach it

There is no UI and no CLI verb; the artifact is the crontab. On the hub:

```
grep -c '/bin/merge-sweep.sh' /var/spool/cron/crontabs/root      # 0
grep -c '/bin/merge-conductor.sh' /var/spool/cron/crontabs/root  # 1
```

In a checkout, the same two lines against the render (the crontabs are
generated and git-ignored since BH-1247):

```
bin/render-cron.sh --root . hub | grep -c '/bin/merge-sweep.sh'      # 0
bin/render-cron.sh --root . hub | grep -c '/bin/merge-conductor.sh'  # 1
bin/lanes-build.sh --root . --write && jq -r '.lanes[].id' catalog/lanes.json | grep -cx merge-sweep  # 0
```

The detector half is reached the way every `bin/pipeline-health.sh` check is:
the lane runs from `cron/lanes/330-pipeline-health.cron` every ten minutes and
writes to `logs/ALERTS.log` and `logs/pipeline-health.log`.

## How you drive it

```
HARNESS_TEST_SANDBOX=1 bash tests/merge-sweep-line-retired.bh-1388-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/hub-cron-gated-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/pipeline-health-detectors-test.sh
```

The first renders this repo's real `cron/hub.cron` and `catalog/lanes.json`
through `tests/lib/rendered.sh` and asserts on the rendered text, then extracts
the `# >>> sweep should have landed` block VERBATIM and drives it with a
recording `alert()`, a `gh` shim and the REAL `bin/jobs-client.sh` behind a curl
shim — so `merge_ledger_has` is the shipped verb reading the shipped route
shape. Every pipeline-health case seeds a STALE first-seen-CLEAN stamp, i.e. the
state in which the detector pages today; case 4 proves it still pages on that
fixture, which is what makes the "no alert" cases mean something.

`tests/hub-cron-gated-test.sh` is the neighbour: it asserts that every fleet-wide
hub lane is lease-gated exactly once, and its `GATED` list no longer names the
sweep.

## Preconditions

The conductor has to actually be merging before the sweep line may go. The
evidence is two reads, from any box that can reach the worker:

```
. "$HARNESS/bin/jobs-client.sh"
_jobs_req GET /api/flags/merge-conductor-merge      # .flag.active must be 1
_jobs_req GET '/api/ledger?kind=merge&limit=500'    # rows with detail "merge-conductor" in the last 24h
```

`detail="merge-conductor"` is written only by `mc_settle_merged`
(`bin/lib/mc/settle.sh`); a row with no detail is the sweep's own
(`sweep_record` in `bin/merge-sweep.sh`). At 2026-09-22 13:16Z the flag was
`active:1` (set 2026-09-12) and the last 24h held 36 conductor rows against 123
sweep rows.

`conductor-owns-merges` has NO DB row: it is a hub-local `touch`, invisible from
a pool box. It gates the box-side mergers (`bin/merge-queue.sh`,
`bin/tier2-merge-sweep.sh`, `bin/review-prs.sh`, `run-build`'s tier-1 step), none
of which this entry is about, so its state does not change whether the HUB sweep
line is redundant.

## What LIVE looks like, and the rollback

After the merge, `bin/fleet-propagate.sh` re-renders and installs the hub
crontab within 5 minutes (`bin/update-runners.sh` at 05:17Z is the backstop).
Live is then:

- `grep -c '/bin/merge-sweep.sh' /var/spool/cron/crontabs/root` is `0`;
- `logs/merge-sweep-cron.log` stops advancing its mtime;
- `logs/merge-conductor.log` keeps logging `-> MERGED` lines;
- `logs/ALERTS.log` gains no `sweepstall:` line for a PR the conductor landed.

The first 24 hours after the merge are the real exit test: the sweep was still
writing the majority of merged ledger rows (123 vs 36), and after this lands the
conductor is the only hub merger. **Rollback restores the two deleted files from
the main this merged into** (`git checkout <merge-sha>^1 -- cron/lanes/400-merge-sweep.cron
catalog/lanes.d/merge-sweep.json`, commit, PR), not from this branch's old copy,
because that registry entry carries BH-1575's required `SWEEP_PRS_FRESH_S` knob.
The next propagate puts the line back. Do not land #1389 (conductor `*/5` →
`*/30`) in the same window. The `lane-off-merge-sweep` flag row is left in place rather than
deleted: a flag with no lane harms nothing, and a rollback re-reads it.

## What it does NOT change

- `bin/merge-sweep.sh` itself, and its six suites.
- The writers of `state/merge-sweep-done.txt` (`bin/batch-resolve.sh`,
  `mc_settle_merged`): the file is still the free first answer in the detector,
  asked before the ledger because the block loops over every `PR_CREATED` record
  every ten minutes and a ledger-first order would cost hundreds of GETs a tick.
- `bin/outcome-metrics.sh`, which reads the same ledger kinds read-only.
- The box-side `tier2-merge-sweep` lane (already retired on main by BH-1366).
