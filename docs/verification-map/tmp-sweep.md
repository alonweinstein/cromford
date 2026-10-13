# /tmp sweep (tmp-sweep lane)

**What it is:** `bin/tmp-sweep.sh`, a lane on every board box and the hub
(BH-5007). Cron runs it every 15 min, and `rpool_init` in
`bin/lib/review-pool.sh` runs it at the start of each review-prs and
lead-review tick, before the pool sizes itself from free /tmp (BH-5608). It
removes the suite and prototype leftovers and the builder and reviewer
checkouts at the top level of `/tmp` (`pb*-proto pb*-sg bh*-proto bh*-rp
scratch.* impact-gate.* rules-pack.* rv* wt* r[0-9]* bh[0-9]* pr[0-9]*
lr[0-9]* rules-pack-snap.* pb*-* lanes-build.* review-prs-*`) that nothing has written for `MIN_AGE_MIN` minutes
(180), no live process holds through its cwd, an open fd or an argv argument,
and no line of a live job claim (`state/claims/<project>/<KEY>`) names. When a
removed entry was a git worktree (its `.git` file points into
`<repo>/worktrees/`), the sweep runs `git worktree prune` once in that repo. When `rm -rf` cannot
finish an entry (a `chattr +a`/`+i` file inside), it clears those attributes
inside that entry and tries once more. After the sweep it reads `df -P /tmp` and
raises `tmp-high-<host>` (warn: the batched digest, not a page) through
`bin/lane-alert.sh` when /tmp is still over `TMP_ALERT_PCT` (85), and resolves
it when /tmp is back at or under that line. An unreadable df raises and resolves
nothing.

It also retires the hand-made stopgap: after a real sweep, `/etc/cron.d/tmp-sweep`
is removed when its only non-comment line is
`<min> * * * * root /root/bhfix-lane/tmp-sweep.sh [<n>] [...]`. Any other content
is left alone and logged once. `/root/bhfix-lane/` itself is never touched.

**Why it exists:** on 2026-10-06 box-small's 8 GB /tmp filled inside
hours and every lane failed with ENOSPC. On 2026-10-08 nine builder and
reviewer checkouts that no pattern matched held 1.5 GB of its 4 GB /tmp, and
review-prs ran at concurrency 1 from 18:37Z to 20:31Z (BH-5608). On 2026-10-11
a 2-day-old `/tmp/bh5775` (1.1 GB, no dash after the number) held lead-review at
concurrency 1 for hours (BH-6041). `bin/box-housekeeping.sh` sweeps /tmp
once a day at a 2-day age (see [disk-clean-hygiene.md](disk-clean-hygiene.md)),
which is too slow for that, and it cannot remove a tree holding a `+a` file.
That daily sweep is unchanged and still owns everything else stale in /tmp.

**How an operator reaches it:** `bin/render-cron.sh <box>` carries
`8,23,38,53 * * * * /root/harness/bin/tmp-sweep.sh >/dev/null 2>&1` for project-4, hub,
project-6, project-1, project-3, project-9, small, project-2 and project-5
(`cron/lanes/647-tmp-sweep.cron`). Output is `logs/tmp-sweep.log`: one
`removed <path> <kb> KB age_min=<n>` line per removed entry, `kept: <path> could
not be removed` for a stuck one, `pruned worktrees in <git dir>` (or `worktree
prune failed in <git dir> rc=<n>`), and one summary line per run:
`<iso> tmp-sweep removed=N freed_kb=N skipped_held=N skipped_fresh=N skipped_unreadable=N unlocked=N failed=N would_remove=N left=N min_age_min=N tmp_use=<pct>% tmp_avail_mb=<n>`.
A held entry and a claimed entry both count in `skipped_held`.

Every real sweep (not `--dry-run`) also writes one ledger row through
`job_ledger_put` (`bin/jobs-client.sh`): kind `box_health`, key
`tmp-sweep <host>`, status `ok`, detail
`{"freed_bytes":N,"removed":N,"failed":N,"tmp_use_pct":N|null,"tmp_avail_mb":N|null,"at":"<iso>"}`.
It is written with 0 removed too. A failed write logs `box-health row not
written (rc=<n>)` or `(no jobs client)`.

**How to drive it:**

| what | how |
|---|---|
| the lane suite (held by cwd/fd/argv, fresh inside, immutable file, patterns, symlink, knobs, alert, off switch, lock, dry run, stopgap) | `HARNESS_TEST_SANDBOX=1 bash tests/tmp-sweep.bh-5007-test.sh` |
| the BH-5608 suite (scratch checkout names, 180 min, claims, worktree prune, age in the log, box_health row, the `rpool_init` pre-tick run, the sandbox guard) | `HARNESS_TEST_SANDBOX=1 bash tests/tmp-sweep.bh-5608-test.sh` |
| the BH-6041 suite (`bh<N>`, `pr<N>`, `lr<N>-*`, `rules-pack-snap.*`, the negative names, the age knob) | `HARNESS_TEST_SANDBOX=1 bash tests/tmp-sweep.bh-6041-test.sh` |
| a lead-review worker's own `/tmp/lr<tickpid>-<id>` dir on every exit path | `HARNESS_TEST_SANDBOX=1 bash tests/review-pool-tmp-own.bh-6041-test.sh` |
| the capped-concurrency warn, and the worker dir through a real tick | `HARNESS_TEST_SANDBOX=1 bash tests/lead-review-capped-alert.bh-6041-test.sh` |
| the /tmp tmpfs size from RAM, persisted in fstab | `HARNESS_TEST_SANDBOX=1 bash tests/tmpfs-ensure.bh-6041-test.sh`; on a box `/root/harness/bin/tmpfs-ensure.sh --dry-run` |
| what a box would remove, deleting nothing | `/root/harness/bin/tmp-sweep.sh --dry-run` |
| on a live box, once | `/root/harness/bin/tmp-sweep.sh; tail -3 /root/harness/logs/tmp-sweep.log` |
| the knobs a box resolves | `bin/harness-ctl.sh show tmp-sweep` |

The suite drives the shipped script against a fixture /tmp under its scratch
tree, with real holder processes, a fake `df` first on `PATH` and a stubbed
`lane-alert.sh`. It never sweeps the real /tmp: under `HARNESS_TEST_SANDBOX=1`
with no `TMP_SWEEP_ROOT` the script logs `TMP_SWEEP_ROOT unset under
HARNESS_TEST_SANDBOX - sweep skipped` and reads nothing.

**Files on a box:** `logs/tmp-sweep.log`, `locks/tmp-sweep.lock` (dedupe: a
second run while one is going exits 0), `state/tmp-sweep/stopgap-mismatch-logged`,
and the alert state `state/alerts/tmp-high-<host>.json`.

**Knobs:** on the `tmp-sweep` lane (`catalog/lanes.d/tmp-sweep.json`), settings
row > env > registry default: `MIN_AGE_MIN` (180, min 30; settings key
`lane.tmp-sweep.min_age_min`), `TMP_ALERT_PCT` (85, 50..99),
`TMP_SWEEP_SCAN_TIMEOUT_S` (60), `TMP_SWEEP_RUN_DEADLINE_S` (900). A
`MIN_AGE_MIN` that is not a whole number at or over 30 skips the sweep with a
log line. `TMP_SWEEP_PATTERNS` (the deletion scope) and the seams
`TMP_SWEEP_ROOT`, `TMP_SWEEP_PROC`, `TMP_SWEEP_NOW`, `TMP_SWEEP_STOPGAP_FILE`,
`TMP_SWEEP_CLAIMS` are registered but not settable from a page. Off:
`flags/lane-off-tmp-sweep`; it stops the cron run and the pre-tick run, which
run the same script. `REVIEW_POOL_TMP_SWEEP=` (empty) turns off only the
pre-tick run.

**What must never regress:**

- **Only the top level, only the patterns.** Nothing outside a matching
  top-level entry of /tmp, never /tmp itself, never a symlink (or its target),
  socket or FIFO, never across a mount.
- **Held means kept.** A live cwd, open fd or argv argument under the entry, or
  a live job claim line naming a path under it, keeps it, at any age.
- **Newest write anywhere inside.** One fresh file deep in an old tree keeps the
  tree; an age that cannot be read in time keeps it too.
- **Counts are proved.** `removed` and `freed_kb` move only after `[ ! -e ]`
  proved the removal; the KB is measured before it.
- **A warn, not a page; unknown is not 0%.**
