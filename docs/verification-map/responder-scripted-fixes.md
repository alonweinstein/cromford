# Watchdog responder: scripted remedies for known conditions (BH-2548)

**What it is:** before the responder spends a model call, `bin/lib/responder-fix.sh`
classifies each prefetched item. `evidence_missing` is a line that starts
`EVIDENCE MISSING for <P>:<K> — `. `not_owed` is a fetched `waitingOn=client`
with `PRs: none open matching <K>`. A settings row maps each condition to
`model`, `none` or a script in `bin/responder-fix/`. Settled items never reach
the model. A pass with nothing unknown left makes no call.

**Where:** `bin/watchdog-responder.sh` (`cron/lanes/320-watchdog-responder.cron`,
hub, 3,23,43; on demand via `bin/watchdog-poll.sh` type `respond`), right after the
prefetch loop.

**Rows:** `lane.watchdog-responder.responder_fix_evidence_missing` (default
`escalate-missing`) and `lane.watchdog-responder.responder_fix_not_owed`
(default `none`). `model` restores the old path for that condition.

**Probe (hub):** `grep -E 'scripted:|no model call this pass|bad remedy row|routed to the model' /root/harness/logs/responder.log`

**Proven by:** `tests/responder-fix.bh-2548-test.sh`. It drives the shipped script
under `HARNESS=<scratch>` with stubbed board, gh, agent-call and beat.
