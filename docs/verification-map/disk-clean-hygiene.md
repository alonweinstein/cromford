# Daily state hygiene (disk-clean stages 4-8)

**What it is:** the four bounds `bin/disk-clean.sh` puts on the state a box
accumulates and nothing else ever removes (BH-1044, from the 2026-09-19 audit of
the hub): `state/closeout-aged-out.tsv` pruned to the last
`CLOSEOUT_TSV_KEEP_DAYS` days of build dirs *that no longer exist*, with every
dropped row archived first, `locks/*` files older than `LOCK_STALE_H` with no holder deleted,
operator scratch (`state/*.sh`, `state/*.done`, `state/*.bak-*`) moved under
`state/scratch/`, and the dead `state/leases/` directory removed. Since BH-1363
stage 8 also sweeps the scratch under `tmp/` that no process holds: the
`tmp/brfix/*` fix-round worktrees `bin/blocked-resolver.sh` leaves behind when a
round is KILLED, and `tmp/state-backup.*` staging dirs, both older than
`TMP_SCRATCH_STALE_H` hours. Stages 1-3 of the same script (npm cache, bench
runs, stale worktrees) are untouched.

The hourly sweep of named suite and prototype leftovers at the top of `/tmp`
(BH-5007) is a separate lane, [tmp-sweep.md](tmp-sweep.md); `bin/box-housekeeping.sh`'s
daily 2-day /tmp sweep is unchanged by it.

**How an operator reaches it:** every `cron/*.cron` runs
`/root/harness/bin/disk-clean.sh` at 04:47Z. One summary line per run lands in
`logs/disk-clean.log`; every skip that could look like work (a held lock, a
crontab-named script, a leases dir with a recent entry) gets its own
`[disk-clean]` line in the same file.

**How to drive it:**

| what | how |
|---|---|
| all four state stages, against a scratch harness root | `HARNESS_TEST_SANDBOX=1 bash tests/disk-clean-hygiene-test.sh` |
| stage 8, against a real git repo with real registered brfix worktrees | `HARNESS_TEST_SANDBOX=1 bash tests/disk-clean-tmp-scratch.bh-1363-test.sh` |
| the resolver half of the same defect (the round cleans up after itself) | `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-wt-cleanup.bh-1363-test.sh` |
| the backup half (state/scratch/ stays off the box's tarball) | `HARNESS_TEST_SANDBOX=1 bash tests/state-backup-scratch-exclude.bh-1044-test.sh` |
| the writer half (one row per build dir, on a file past the 64 KB pipe buffer) | `HARNESS_TEST_SANDBOX=1 bash tests/closeout-record-aged-dedupe.bh-1044-test.sh` |
| one stage by hand | `HARNESS_ROOT=<scratch tree> DISK_CLEAN_REPOS=<empty dir> DISK_CLEAN_NPM_DIR=<empty dir> DISK_CLEAN_NOW=<epoch> bash bin/disk-clean.sh` |

**Files it owns on a live box:**

- `state/archive/closeout-aged-out.<YYYYMMDD>.tsv` — append-only, one file per
  calendar day on which something was pruned, same four columns as the tsv.
- `state/scratch/` — where operator one-offs land. `bin/state-backup.sh`
  excludes it from the off-box copy; nothing else reads it.
- `logs/disk-clean.log` — the summary line, ending
  `tsv_kept=N tsv_archived=N tsv_kept_live=N locks_removed=N locks_skipped_held=N scratch_moved=N scratch_skipped=N leases=removed|kept|none tmp_removed=N tmp_freed_kb=N tmp_skipped_held=N`.
  `tmp_freed_kb` is `du -sk` read BEFORE each removal and added only once the
  directory is really gone; `tmp_skipped_held` is the stale candidates a live
  `/proc/<pid>/cwd` or a `pgrep` cmdline saved.
  `tsv_kept_live` is the rows past the cutoff that were kept because their build
  dir is still on the box; a big number there means build dirs are piling up,
  not that the pruner is failing.

**Knobs** (all in `env/global.env`, all fall back to the documented default with
one log line when the value is not a number): `CLOSEOUT_TSV_KEEP_DAYS` (30),
`LOCK_STALE_H` (24), `LEASES_STALE_D` (7), `TMP_SCRATCH_STALE_H` (24). Test
seams, live paths by default:
`HARNESS_ROOT`, `DISK_CLEAN_REPOS`, `DISK_CLEAN_NPM_DIR`, `DISK_CLEAN_NOW`,
`DISK_CLEAN_PROC`.

**Verify it works on a box:** after 04:47Z, `tail -1 logs/disk-clean.log` carries
the counters; `ls -l state/closeout-aged-out.tsv state/archive/` shows the split;
`ls locks | wc -l` and `ls state/scratch` show the rest.

**What bounds the tsv is the writer, not this lane.** Pruning alone could not
bound it: `bin/pipeline-health.sh` re-records an aged build dir every 10 minutes
for as long as that dir exists, and nothing here deletes build dirs. So the
prune keeps any row whose dir is still present (at any age) and archives a row
only once its dir is gone, while the size itself is held down by
`closeout_record_aged`'s dedupe in `bin/lib/closeout-terminal.sh` — one read
process, no pipeline, because the old `cut | grep -q` died of SIGPIPE under the
caller's `set -o pipefail` on any file past 64 KB and re-appended the row it had
just found. That is the whole 45 MB. See
[closeout-health.md](closeout-health.md).

**What must never regress:** a lock with a live holder is never deleted — the
mtime gate, the `/proc` open-fd scan and `flock -n` must ALL agree first, and
the unlink happens inside the lock. The tsv's dropped rows are appended to the
archive BEFORE the file is swapped, so the worst failure duplicates rows instead
of losing them, and a counter is only incremented after the work really
happened. Stage 8 deletes only paths under `tmp/brfix/` or matching
`tmp/state-backup.*`, matched against the literal prefix — never the parent,
never a symlink, never `tmp/batch-resolve/<slug>` (a reused blob:none clone
cache, so sweeping it would buy a re-clone) and never `tmp/state-restore`. A
`brfix/<ck>` branch is never touched: it is the fix round's paid-for work, and
the resolver's reuse path starts from it. A `.git` file naming a repo outside
`$REPOS` gets no `git` command aimed at it at all.
