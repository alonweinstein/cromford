# Fleet branch guard (BH-1099)

**What it is:** the guard that keeps the hub's harness checkout on `main` so
`bin/fleet-propagate.sh` and `bin/harness-sync.sh` never run stale or
side-branch code against the fleet.

**Why it exists:** the hub checkout is shared infrastructure. A branch left
over from debugging or a manual `git checkout` made `git pull --ff-only origin
main` abort with a generic fail, which propagated as `hub=fail` with no branch
name and left the live `/root/harness` stale for hours.

**The guard (`bin/fleet-propagate.sh`, */5 cron):**

- Before the ff-only pull, read the current branch.
- If the tree is clean and no process has `cwd` under the checkout, force the
checkout back to `main` and log the branch name.
- If the tree is dirty or the checkout is in use, refuse, set `hub=fail`, and
record `hub_reason` with the branch name and cause.
- On any later ff-only pull failure, capture branch name, ahead/behind counts,
and the first git error line in `hub_reason`.

**The preflight (`bin/harness-sync.sh`, 05:17Z and pre-build gate):**

- Exit 30 with `branch=<name>` if the checkout is not on `main`, before any
fetch or rsync. `--check` prints that and nothing else; the deploy path (after
its lock) is the only one that stamps `state/harness-sync-last-refused` and
writes the ALERTS line.
- Install a `post-checkout` hook that appends one line to
`logs/checkout-moves.log` every time the checkout moves *off* `main`: branch,
short sha, the moving git process (`pid=`, `cmd=`) and `from=`/`to=` shas. The
hook always exits 0 — a failed log append must never change `git checkout`'s own
exit status — and it ignores file checkouts (git's third argument, `$3` = 0), so
`git checkout -- <file>` on a side branch logs nothing. Installed when missing,
re-installed when the file on disk is an older version OF OURS (the marker line
carries `(v2`); a hook without our marker is hand-written and is left alone.
- Limit: a lane-fenced agent session runs git with `core.hooksPath` pointed at
its own forwarder dir (`bin/lane-fence.sh hooks-env`), so a `git -C
/root/harness-checkout checkout -b ...` from such a session never reaches this
hook. The guard in `fleet-propagate.sh` and the preflight above still catch the
resulting branch; only the "who" line is missing for that actor.

**The state:**

| file | written when | contents |
|---|---|---|
| `state/fleet-propagate.json` | every propagation | `hub` (`ok`/`fail`/...) and `hub_reason` (empty on success, branch + cause on failure) |
| `state/harness-sync-last-refused` | rc 30 from `harness-sync.sh` | ISO-UTC line, then the reason including `branch=<name>` |
| `logs/checkout-moves.log` | post-checkout hook | one line per move off `main` |

**How an operator reaches it:**

- `cron/hub.cron` runs `bin/fleet-propagate.sh` every 5 minutes and
`bin/update-runners.sh` at 05:17Z.
- `bin/context-gate.sh` calls `harness-sync.sh --check` before every build.
- Output lands in `logs/fleet-propagate.log`, `logs/update-runners.log`,
`logs/ALERTS.log`, and `logs/checkout-moves.log`.

**How to drive it:**

| what | how |
|---|---|
| fleet-propagate side-branch cases | `bash tests/fleet-propagate-test.sh` |
| harness-sync branch guard + hook | `bash tests/harness-sync-branch-guard.bh-1099-test.sh` |
| hook rc, file checkouts, re-install rule | `bash tests/harness-sync-hook.bh-1128-test.sh` |
| the pull-failure enrichment in `hub_reason` | `bash tests/fleet-propagate.bh-1128-test.sh` |
| stale-hub detector still passes | `bash tests/harness-sync-stamps-test.sh`, `bash tests/pipeline-health-hub-sync-test.sh` |
| on a live hub | `cat /root/harness/logs/checkout-moves.log` after the next manual or automated branch move |

**What must never regress:**

- A dirty side branch must never be force-reset; the uncommitted files stay.
- The hook must never change `git checkout`'s exit status, whatever the log
append does — `bin/fleet-propagate.sh`'s forced-back-to-main step reads that rc
to decide `hub=ok` vs `hub=fail`.
- An in-use side branch must not be switched while something has `cwd` there.
- `hub=ok` on success stays exactly that string; downstream checks read it.
- `harness-sync.sh --check` must not write any stamp.
