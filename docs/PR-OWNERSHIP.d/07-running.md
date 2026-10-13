## 7. Running it

```bash
bin/pr-owner-sweep.sh                      # every repo in fleet.conf + PR_OWNER_EXTRA_REPOS
bin/pr-owner-sweep.sh --explain            # …and print the per-PR verdict table
bin/pr-owner-sweep.sh --repo example-org/project-7
bin/pr-owner-sweep.sh project-5 project-1
PR_OWNER_DRY_RUN=1 bin/pr-owner-sweep.sh --explain    # decide everything, write nothing
```

The repo list comes from `bin/fleet-conf.sh --projects`, never from a copy of
the fleet's project list (`tests/fleet-projects-not-hardcoded-test.sh`, and the
2026-09-10 incident behind it). `example-org/project-7` is in the sweep because it
is enrolled in `fleet.conf` as the `project-7` project.

**Callers.** The hub cron (`cron/lanes/412-pr-owner-sweep.cron`) runs it every
30 minutes over every `fleet.conf` repo, behind `bin/hub-lease.sh check`, so a
box that does not hold the hub lease runs nothing. `bin/orphan-reconcile.sh`
also rings it with `--repo` for its own repo at the end of each triage tick,
and an operator can run it by hand. A `--repo` run records only: it never
enrolls, never spawns the conductor and never moves the ownerless clock,
because the conductor and its rows live on the hub.

**The gate.** The sweep is a registered lane (`catalog/lanes.d/pr-owner-sweep.json`,
BH-3932). `flags/all-off`, `flags/lane-off-pr-owner-sweep`, the D1 pause row of
that name, and the older `pr-owner-sweep-off` switch all stop it, whichever
caller rang it.

The lock is **dedupe, never a queue** (CLAUDE.md): two callers reaching one repo
in the same minute means the second one does not run, not that it waits.

