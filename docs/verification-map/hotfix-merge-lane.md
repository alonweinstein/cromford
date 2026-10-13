# Hotfix merge lane (a `hotfix` PR merges first)

**What it is:** the merge half of the hotfix lane (#367, BH-369). In Mergify, the
`fix-main-red` label on the pull request puts that PR at the head of the merge
queue, in a batch of one, without loosening a single gate it would otherwise
pass (BH-2121; a `hotfix`-only PR queues in `default`). The conductor's own
ordering still reads `hotfix`. It has two halves, and only one of them is code
in this repo:

| half | where it lives | when it acts |
|---|---|---|
| Mergify's own `hotfix` queue (first in `queue_rules`, `batch_size: 1`, keyed on `label=fix-main-red`) plus the `priority_rules` entry on the same label that preempts a running batch | `.mergify.yml` on the queued repo's DEFAULT branch — the template is `docs/MERGIFY.md` §2, the copy project-5 carries is mirrored at `tests/fixtures/mergify/project-5.mergify.yml` | whenever the queue is answering |
| the conductor's own ordering: hotfix PRs launched first, registered in a per-tick marker, and a plain PR's direct merge deferred one tick while one is in flight | `bin/merge-conductor.sh` (the `READY` arm's rc-3 branch and the open-pass ordering), `bin/lib/hotfix-lib.sh` (`hotfix_pr_is`, `hotfix_labels_csv_has`, `hotfix_announce`) | the LAUNCH ORDER on every repo with open PRs (BH-645); the marker and the one-tick deferral only in DEGRADED mode — the queue asked and answering nothing |

**How an operator reaches it:** `cron/hub.cron` runs `bin/merge-conductor.sh`
every 5 minutes; there is no UI and no command to run by hand. Section 2.1 of
`docs/MERGIFY.md` is the ops page.

**How to drive it:**

| what | how |
|---|---|
| the whole degraded lane against the real script (three READY PRs, one labelled `hotfix`, a queue that answers nothing) | `bash tests/hotfix-conductor-degraded-test.sh` |
| the label vocabulary on its own, including `hotfix-candidate` / `not-hotfix` / `hotfixes` | section 0 of that suite, and `bash tests/hotfix-lib-test.sh` |
| the `.mergify.yml` template, parsed rather than grepped | `bash tests/hotfix-mergify-template-test.sh` |
| the exact file a repo carries | `MERGIFY_FIXTURE=tests/fixtures/mergify/project-5.mergify.yml bash tests/hotfix-mergify-template-test.sh` |
| routing by label set: `fix-main-red` goes to `hotfix` and preempts, a `hotfix`-only PR goes to `default` and preempts nothing (BH-2121) | `bash tests/mergify-hotfix-key.bh-2121-test.sh` |
| the rest of the Mergify provider contract (unchanged by this lane) | `bash tests/merge-queue-mergify-test.sh` |
| the migration-proof gate on a hotfix PR (no proof / stale proof / held proof / accepted proof, on both the enqueue and the degraded direct-merge path) | `bash tests/hotfix-merge-requires-proof-test.sh` |
| the same gate on the THIRD exit — a merge-time batch train must not carry an unproven hotfix into main | `bash tests/batch-resolve-test.sh` (section F0) |
| the merge family under a limited GitHub read (403/429/404): no dequeue, no relabel, no close, close-out retried next pass | `bash tests/conductor-limited-read.bh-784-test.sh` (sections 5-8), reproduction `bash tests/merge-family-limited-read-repro.bh-784-test.sh` |
| the ordering on a repo with NO queue at all (`PROVIDER=none`), and that no tick marker is written there (BH-645) | `bash tests/hotfix-rereview-order-test.sh` |

**Files it writes on a live box:**

- `logs/merge-conductor.log` — `<slug>#<n> heads this tick's order …` when the
  tick reorders, `… degraded direct merge DEFERRED this tick: hotfix PR(s) #N
  merge first …` for each plain PR that stood aside, and `… HOTFIX merged first
  this tick …` when it lands.
- `logs/ALERTS.log` — `[<project>/<KEY>] HOTFIX merged: <slug>#<n> merged
  DIRECTLY (degraded: mergify queue not answering) at <sha> — <url>`, beside
  the unchanged once-a-day `mergify queue not answering for <slug> …` line.
- `state/hotfix-announced/<project>/<KEY>.merged` — the announce dedupe marker
  (written LAST, so a crash costs a duplicate line and never a missing one).
- `state/merge-conductor/tick/<tick-id>.hotfix-<project>` — this tick's hotfix PR
  numbers, one a line. Written before the first worker starts, a line dropped
  when that worker exits by any path, collected by the existing `mc_tick_gc`.
  **Queue repos only** (BH-645): on a `PROVIDER=none` repo the ordering still
  runs and this file is never written, because with no queue there is no
  degraded merge to hold back. The `heads this tick's order` line is logged on
  both paths; only there does it end "and a plain degraded merge waits a tick
  for it".

**Knobs:** `HOTFIX_LABEL` (the label name, `env/global.env`), `HOTFIX_LANE=0` or
`flags/hotfix-lane-off` (the kill switch: no reorder, no deferral, no announce).

**What must never regress:**

- **Entry is unchanged.** A hotfix PR is approved, green-gated and enqueued
  exactly like any other — the label changes the ORDER, never the bar. If the
  queue is answering, this lane does nothing at all.
- **Nothing ever waits for a hotfix.** The marker is READ, never waited on: a
  deferred PR writes nothing, hands its merge budget unit back and retries next
  tick (≤ 5 min). A hotfix that is not READY, or whose merge fails, costs the
  repo's other PRs one tick at most, because its worker drops its own marker
  line on every exit path.
- **The label match is exact.** `hotfix-candidate`, `not-hotfix`, `hotfixes` and
  the word "hotfix" in a title are NOT the label. A false positive here holds
  every other PR of that repo back.
- **"Announced" implies "merged".** The `HOTFIX merged` line is written after
  the merge returned rc 0, never before.
- **A hotfix PR with added migration SQL never enters the queue, never merges
  directly and never joins a batch train without an accepted proof on its
  CURRENT SQL** (BH-370.2, `mc_hotfix_proof`, `docs/MERGE-CONDUCTOR.md` section
  6). No proof or a proof for other SQL holds it in `WAIT_CI`;
  `decision=hold|flagged|no-path` parks it on
  `BLOCKED_HUMAN reason=hotfix-migration-hold`, which pages at once and which
  `bin/blocked-resolver.sh` deliberately does not own. Both GitHub reads fail
  CLOSED: a read that errors reads as "no proof", never as "no migrations".
  **All THREE exits have to keep asking.** Two of them are the conductor's own
  (`pr_worker`); the third is `bin/batch-resolve.sh`, which opens a PR of its
  own with no `hotfix` label and never runs `pr_worker` at all, so a guard put
  only in the conductor leaves the train open. A new lander is a new place this
  question has to be asked.
- **No `.mergify.yml` here is authoritative.** The fixture is evidence of what a
  repo carries; the file Mergify reads is on that repo's default branch.
