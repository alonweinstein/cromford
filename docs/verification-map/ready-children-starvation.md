# A ready ticket nobody owns (decompose children, the board's triage note, the alarm)

**What it is:** three guards against one failure. On project-8
(2026-10-03) seven decomposed parents filed 32 children. Every child answered
`triage-gate.sh --buildable` OK, and none was ever enqueued. The board OS's own
`[AI Triage] … ready` note is written by the same system actor the harness
writes with, so the shards client-court guard read it as our write and skipped
every child (`client-court skipped … (BLOCKED newest-comment-system)`). The
fingerprint was consumed, and nothing re-offered them until a human ran
`jobs-client.sh ready-put` at 17:15Z.

1. **The decompose enqueues its own children.** The board lane of
   `bin/run-decompose.sh` (`dcp_enqueue_children`, `# >>> enqueue children
   (BH-3970)`) writes one ready row per child in `children.txt` order. Both
   board paths call it: the harness-filed default right after `file_children`
   (ids from `children-board.tsv`), and the model-filed path behind
   `decompose-board-filer-off` after the BH-866 re-map. Child 1 is the contract, so it goes
   first. On the box that owns the project it also writes a `logs/READY-QUEUE.log`
   line and touches `flags/force-triage-<project>`. The issues lane is unchanged:
   its children are open `ai-build` issues, and `bin/orphan-reconcile.sh`
   enqueues those.
2. **The board's own verdict is not our write.** `buildable_gate` in
   `bin/triage-gate.sh` stands down on `newest-comment-system` when the newest
   comment's first non-blank line starts with `[AI Triage]` AND the ticket is
   `triageVerdict=ready` AND `waitingOn=team`. A close-out or note by the same
   actor still blocks.
3. **The alarm.** `bin/lib/starved-ready.sh`, called from `rt_gate` on every
   triage tick (a `SKIP no-change` tick included), pages once per project when a
   `todo` + `ready` + `team` ticket that answers `--buildable-strict` OK has no
   ready line or row, no queue row in queued/claimed/ready/held and no build dir
   for `STARVED_READY_MIN` minutes.

**How an operator reaches it:** not a screen. The decompose runs inside a build
(`bin/run-build.sh` → `bin/run-decompose.sh`). The gate and the alarm run on the
cron line `run-triage.sh <project>` (`cron/<box>.cron`).

| thing | where |
|---|---|
| the enqueue | `dcp_enqueue_children` in `bin/run-decompose.sh` (`# >>> enqueue children (BH-3970)`), called after `file_children` on the default path and after `# <<< board child keys` on the model-filed path |
| its record | the build's `pipeline.log`: `enqueued <n> children ready: K1,K2,…`, or a `WARN:` line naming what did not land |
| the gate exemption | `buildable_gate` in `bin/triage-gate.sh` (`board_verdict`) |
| the alarm | `starved_ready_check` in `bin/lib/starved-ready.sh`, called from `rt_gate` in `bin/lib/rt/gate.sh` right after `GATE_DECISION=` |
| the knobs | `catalog/lanes.d/_lib.starved-ready.json`: `STARVED_READY` (1), `STARVED_READY_MIN` (60), `STARVED_READY_PROBE_MAX` (20), `STARVED_READY_STATUSES` (`todo`) |
| the ledger | `state/starved-ready/<project>.tsv` (`id<TAB>first_seen_epoch`, current candidates only) and `state/starved-ready/<project>.alerted` |
| the alert | `bin/lane-alert.sh --id starved-ready-<project> --severity warn triage`, resolved by `--resolve --id starved-ready-<project>` |
| an outage | `logs/<project>.log`: `starved-ready: the queue read failed …` or `… gate state … is unreadable`: no page, no resolve |

**How to drive it:**

| what | how |
|---|---|
| the enqueue (E1-E11) | `HARNESS_TEST_SANDBOX=1 bash tests/decompose-children-enqueued.bh-3970-test.sh`. It drives the real `bin/run-decompose.sh` and the real `bin/jobs-client.sh` against a fake curl that plays the board and `/api/queue` |
| the gate (B1-B12) | `HARNESS_TEST_SANDBOX=1 bash tests/triage-gate-board-triage-comment.bh-3970-test.sh`. It drives the real `triage-gate.sh --buildable` and the real shards client-court guard block |
| the alarm (S1-S12) | `HARNESS_TEST_SANDBOX=1 bash tests/starved-ready-ticket-alarm.bh-3970-test.sh`. S12 drives the real `rt_gate` on a `SKIP no-change` tick |

**On a live box:**

- `bin/jobs-client.sh ready-list <project>` right after an in-app decompose: the
  children are listed, contract first.
- `grep 'client-court skipped' logs/<project>.log`: a child whose newest note is
  `[AI Triage]` on a ready/team ticket is no longer listed.
- `cat state/starved-ready/<project>.tsv`: what the alarm is timing.
  `logs/alerts-state.log`: `starved-ready-<project>` opens only for a genuinely
  unowned ready ticket and resolves once it is owned.

**What it does not cover:** a ticket parked `in_progress` with no build (TK-7 and
TK-8 on project-8) is not a candidate under the default status set.
Widen `STARVED_READY_STATUSES` with a settings row to catch it. Sibling
dependency gating is #3946.

**What must never regress:**

- A harness close-out or note by the system actor still answers
  `BLOCKED newest-comment-system` (`tests/client-court-gate-test.sh` TK-220/TK-222).
- A failed label re-map (`DECOMPOSE_FAILED`) enqueues nothing.
- A queue outage never pages and never resolves.
