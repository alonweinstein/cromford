# Hub repo shallow ("/root/repos/<project> is a SHALLOW clone")

**What it is:** the pair of guards that keeps the hub's project checkouts
complete, plus the self-heal inside the merge conductor. Three pieces: a block
in `bin/pipeline-health.sh` that pages, a block in `bin/bootstrap-machine.sh`
that refuses, and `mc_unshallow_once` in `bin/lib/mc/rebase.sh` that
fixes the clone in the middle of the rebase that tripped over it.

**Why it exists (BH-517):** `/root/repos/<project>` is the checkout `mc_rebase`
merges `origin/main` into. Cloned with a `--depth` — which is how the
2026-09-15 hub wipe was recovered by hand — it has no merge base with
`origin/main` for any PR that forked before the boundary. `git merge` then
answers `fatal: refusing to merge unrelated histories` and leaves ZERO unmerged
paths, so `mc_resolve_conflicts` answered "everything resolved", the commit of a
merge that never happened returned rc 4, and NOTHING was logged. The conductor
said `rebase setup failed (rc 4)`, `blocked-resolver` parked it
`br_setup_blocked`, and seven PRs looped `NEEDS_REBASE` in a day with nothing
naming the git fatal. A `--filter=blob:none` partial clone is NOT shallow and is
unaffected.

**The three seams:**

| where | what it does |
|---|---|
| `bin/lib/mc/rebase.sh` `mc_rebase` / `mc_restack` | a failed merge/rebase is a CONFLICT (unmerged paths, rc 1 + the file list) or a FATAL (none — logged `rebase: merge failed — <stderr>` / `restack: rebase --onto failed — <stderr>`, rc 4, stdout empty). rc 4 never prints a conflict list of zero files |
| `bin/lib/mc/rebase.sh` `mc_unshallow_once` | on a fatal in the HUB clone only, `git fetch --unshallow origin` ONCE under the project git lock (fd 7), on `mc_git_auth`'s credentials, bounded by `MC_UNSHALLOW_SECS`; both the intent and the outcome are logged, then the merge is retried in the same call. The scratch clone is partial, never shallow, and is not eligible |
| `bin/pipeline-health.sh` marker block `# >>> hub repo shallow` | any `/root/repos/*/.git/shallow` = `alert 86400 hubreposhallow:<project>`, one line a day per repo, leading with `hub-repo-shallow-<project>` and carrying the fix command. In `RETRACT_NS`, so a healed repo earns one `RESOLVED hubreposhallow:<project>` |
| `bin/bootstrap-machine.sh` marker block `# >>> repo not shallow` | after the clone: unshallow a shallow checkout, and `exit 1` if it is still shallow afterwards rather than finishing a bootstrap on a repo the conductor cannot rebase in |

**How an operator reaches it:** `cron/hub.cron` runs `bin/pipeline-health.sh`
every 10 minutes on the hub (this check is hub-only — boxes clone with
`gh repo clone`, which is full, and do not run pipeline-health). The page lands
in `logs/ALERTS.log` and `logs/pipeline-health.log`; Mission Control's pipeline
pane reads the latter through `bin/fetch-log.sh which=pipeline`. The conductor's
own lines land in `logs/merge-conductor.log`.

**How to drive it:**

| what | how |
|---|---|
| the conductor arms, against REAL git (shallow heal, non-shallow fatal, real conflict, restack fatal, failed commit) and the bootstrap block extracted by its markers | `bash tests/mc-rebase-shallow-test.sh` |
| the health block, extracted verbatim with a pinned clock | `bash tests/pipeline-health-repo-shallow-test.sh` |
| the neighbouring blocks in the same file | `bash tests/pipeline-health-hub-sync-test.sh`, `tests/pipeline-health-detectors-test.sh` |
| the conflict classes the heal must not disturb | `bash tests/generated-path-conflicts-test.sh`, `tests/mc-stranded-child-test.sh` |
| on a live hub | `git -C /root/repos/<project> rev-parse --is-shallow-repository` → `false` for every project in `fleet.conf`; after a heal, `grep unshallowed /root/harness/logs/merge-conductor.log` |

**Knobs:** `MC_UNSHALLOW_SECS` (default 900) bounds the fetch; `MC_GIT_LOCK_WAIT`
(default 180) is the wait for the project git lock. `HUB_REPOS` overrides
`/root/repos` for the health block, for tests only.

**What must never regress:**

- **A zero-file conflict is not a conflict.** Returning rc 1 with an empty list
  tells the resolver "a conflict nobody can name", which is what sent these PRs
  round the ladder. Empty list = fatal = rc 4, logged.
- **Every rc 4 out of the merge/commit arms says why.** The silence was half the
  defect; the other half was the shallow clone.
- **At most one unshallow per call, and never on a complete clone.**
  `git fetch --unshallow` on a complete repo is itself a fatal, so the gate is
  `git rev-parse --is-shallow-repository`, never the stderr text. Two rebases of
  the same project in one tick: the second waits on the git lock (≤180s), finds
  the work already done, logs its rc-2 failure and takes rc 4 for that tick —
  healthy on the next one. It is a once-per-repo event.
- **Fail-open on the page.** A zero-byte `.git/shallow` is still a shallow clone
  and still pages; the boundary count degrades, the alert does not.
- **The negatives stay quiet:** complete clones, an empty or missing
  `/root/repos`, the `.preplan-*` copies (dot-prefixed, outside the glob by
  design) and stray files must page nothing.
