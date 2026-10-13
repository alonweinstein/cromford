# Audit tail (deletions under the harness roots)

**What it is:** `bin/audit-tail.sh`, the `*/5` cron lane on every live box that
reads the kernel audit trail (`ausearch -k harness`), collapses the records into
one burst per (pid, comm, class), writes each burst to `logs/audit-tail.log` and
alerts through `bin/lane-alert.sh`.

**Why it exists:** the hub's `/root/harness` was deleted on 2026-09-15 by one of
our own test runs (#388) and nothing recorded who did it, from where, or under
which build. The sibling installer (`bin/audit-install.sh`, landing in its own
slice) makes auditd write those records with key `harness`; this lane is the
reader, and it reports BLIND on a box the installer has not reached yet. Full
operator doc: `docs/AUDIT-TRAIL.md`.

**How an operator reaches it:** the operator line in every live `cron/*.cron`
file, between the clock-sync block and the harden-state block and OUTSIDE the
`# BEGIN fleet-managed` markers:

```
*/5 * * * * /root/harness/bin/audit-tail.sh >/dev/null 2>&1
```

`cron/project-10.cron` is a paused box and carries none. On a live box the
output is `logs/audit-tail.log`, `logs/ALERTS.log` and the `fleet_alert` beats
`lane-alert.sh` posts.

**How to drive it:**

| what | how |
|---|---|
| the whole suite (parser, live loop, cron lines, docs) | `bash tests/audit-tail-test.sh` |
| the parser alone, on a fixture | `bin/audit-tail.sh --parse < tests/fixtures/audit/single-unlink.txt` |
| the parser on a real capture, changing nothing | `ausearch -k harness -i -ts recent \| bin/audit-tail.sh --parse` |
| on a live box | `tail -n 50 /root/harness/logs/audit-tail.log` after the next `*/5` tick |
| on a live box, deliberately | `touch /root/harness/state/qa-probe && rm /root/harness/state/qa-probe`, then the same tail within 5 minutes — one `class=delete … sev=info` line |

The live loop is driven in the suite against a scratch `$HARNESS` with stubbed
`ausearch`, `pgrep`, `hostname` and `lane-alert.sh`; nothing in `tests/` installs
auditd or reads `/var/log/audit`.

**Knobs:** `AUDIT_ROOTS`, `AUDIT_MAX_BURSTS_PER_TICK` (5), `AUDIT_PAGE_MIN` (25),
`AUDIT_PAGE_ALL` in `env/global.env`. Kill: `AUDIT_TAIL=0` or
`flags/audit-off`. Lock: `locks/audit-tail.lock`, `flock -n`, shared with
nothing.

**What must never regress:**

- **Fail-open.** No `ausearch`, or auditd not running, is ONE `logs/ALERTS.log`
  line per box per UTC day naming what is needed and from whom. A box that
  cannot see must not be silent, and must not page every five minutes.
- **The negatives stay quiet.** Syscalls that are not deletes/renames/truncates,
  paths outside the watched roots (`/root/harnessfoo`, `/root/.sshd` included),
  a build releasing its own claim file and a truncated log file must never page.
  A noisy tailer is a tailer somebody switches off.
- **Log before alert.** The burst line is written to `logs/audit-tail.log`
  first; a burst may be logged and not paged (over the cap), never the reverse.
- **One page per burst, and a bounded tick.** The `--id audit:<box>:<pid>:<serial>`
  is what keeps a re-read after a failed tick from paging twice, and
  `AUDIT_MAX_BURSTS_PER_TICK` bounds the tick with an explicit "+N more bursts"
  line rather than a silent drop.
- **The cap is spent critical first, and the lane does not watch itself.**
  Events under `<root>/locks`, `<root>/state/alerts` and
  `<root>/state/audit-tail.checkpoint*` are this lane and `bin/lane-alert.sh`
  doing their own jobs and never become bursts; of what is left, critical
  bursts take the cap's slots before info ones. Both exist so the one tick that
  holds a real wipe cannot spend all five slots on harness churn.
- **Nothing out of the audit log breaks the line.** `path`, `comm`, `exe`,
  `cwd`, `lane`, `claim` and `session` are all `%20`-encoded, and the live
  reader takes the FIRST ` key=` on the line, so a process name or a worktree
  directory carrying whitespace cannot put a second `pid=` in front of the
  reader and mis-address the alert.
- **The lane is never guessed.** An unrecognised worktree stays
  `lane=unresolved`.
- **The cron line stays outside the managed markers**, or the next
  `bin/render-crontab.sh` run drops it (`tests/cron-fleet-parity-test.sh`).
