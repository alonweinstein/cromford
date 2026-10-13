# The merge queue is fed at the verdict (BH-1026.2)

**What it is:** the moment an approved PR joins the merge queue. Until BH-1026.2
that moment was `bin/tier2-merge-sweep.sh`, a per-box lane that ran at
`3,13,23,33,43,53` on eight boxes, re-read every directory under `builds/` and
re-grepped each `review.md` for a `VERDICT: APPROVE` the build that wrote it had
already held in a variable. The enqueue now happens where the judgement is made
— the two marked verdict blocks of `bin/run-build.sh` and the two of
`bin/review-prs.sh` — and the sweep is retired.

The queue's CONSUMER, `bin/merge-queue.sh`, is unchanged in what it decides. It
gains a flag, `merge_queue_rows_only`: with it on the `merge_queue` ROWS are the
queue (union'd with whatever files are still on disk) and a blocking decision
writes `status='blocked'` with its reason sentence instead of renaming a file to
`<pr>.blocked`, which could never say why.

**How an operator reaches it:** no UI on the box. The observable surfaces are
the build's own `pipeline.log`, `logs/merge-queue.log`, `logs/pr-reviews.log`,
`logs/ALERTS.log`, and Mission Control's merge queue over
`GET /api/merge-queue`.

## Where the enqueue happens

| where | block | gate | what it writes |
|---|---|---|---|
| `bin/run-build.sh`, right after the provisional verdict row | `# >>> verdict at review` | `$VERDICT_WORD = APPROVE`, `TIER != 1`, no `flags/conductor-owns-merges`, a PR number in `$PR_URL` | `merge_queue_put <project> <pr> <repo> "tier-<n> APPROVE from <KEY>"` |
| `bin/run-build.sh`, phase 7 after the PR is open | `# >>> verdict artifact` | the same four | the same row; `MQ_ENQUEUED` makes the pair produce exactly ONE |
| `bin/review-prs.sh`, right after the D1 artifacts | `# >>> review-prs d1 artifacts` | `$VERDICT = APPROVE` **and `RP_MQ_WANT=1`** | `merge_queue_put <project> <pr> <slug> "APPROVE from review-prs @<sha>"` |
| `bin/review-prs.sh`, right after the ledger verdict | `# >>> review verdict ledger` | the same two | the same row; `RP_MQ_ENQUEUED` makes the pair produce exactly ONE |

**The gate is the VARIABLE, never a grep.** `bin/run-build.sh` carries prompt
strings containing the literal sentence `Last line exactly VERDICT: APPROVE or
VERDICT: BLOCK`; a text match over `review.md` enqueues blocked builds. The
comparison is `[ "$VERDICT_WORD" = APPROVE ]`, the same variable the verdict
artifact is written from.

**`RP_MQ_WANT` and why the reviewer lane does not gate on the bare verdict.**
`merge_step` runs before both verdict blocks and its final `else` arm is the ONE
place that has already decided this PR belongs on the box queue: every hold has
been asked (fallback-lane provenance, `conductor-owns-merges`, Mergify,
`automerge-disabled`, the block gate, main-red) and the two arms beside it are
"already merged" and "already in the repo's own provider queue". On the bare
verdict the lane would put a row on a PR it had just merged, which
`bin/merge-queue.sh` then records as `dropped` — a PR that landed, written into
the ledger as not landed.

**Tier 1 is excluded from `bin/run-build.sh`'s enqueue.** That process merges a
tier-1 PR itself 150 lines further down, and its failure arm already enqueues;
the pool's tier-1 APPROVE is enqueued by `bin/fly-results-ingest.sh` and by the
builder-direct block.

## Where the gates the sweep applied now live

A sweep decision was always "not this pass, re-offer in ten minutes". With the
sweep gone, a don't-enqueue is PERMANENT, so every one of its gates moved to the
consumer, which already had it:

| gate | now enforced by |
|---|---|
| batch hold | `bh_held` (`bin/merge-queue.sh`) |
| head-bound approval | `hb_blocked` |
| a human BLOCK on the thread | `bg_queue_hold` |
| PR dependencies | `dep_queue_hold` |
| main is red | `mr_queue_hold` |
| the repo's native merge queue | `mc_queue_enabled` |
| review-tighten | `review_tighten_active` |
| `flags/automerge-disabled` | the early exit in `bin/merge-queue.sh` |
| `flags/conductor-owns-merges` | the queue's stand-down **and** the enqueue itself |

The enqueue keeps two for itself: `conductor-owns-merges` (two owners for one PR
is the shape the conductor replaced) and "is there a PR number yet".

**The per-project switch.** `bin/harness-ctl.sh off tier2-merge-sweep <project>`
names a lane that no longer exists. The equivalent is
`bin/harness-ctl.sh off merge-queue <project>`, which `bin/merge-queue.sh`
already honours through `lane_gate_or_exit merge-queue "$PROJECT"`.

## The rows-only flag

`merge_queue_rows_only` (a `settings` row, resolved through the coordination
client's `merge_queue_rows_only_on`; **default off**, and off is today's
behaviour byte for byte). With it on, `bin/merge-queue.sh`:

- skips the row→file materialiser and `MQROW`'s 404 heal;
- reads the queue through `mq_queue_list` — the `queued` rows UNION the files
  still on disk, minus any PR whose row is `blocked` and minus any
  `<pr>.blocked` file. The union is not optional: two producers still write only
  a file (`bin/run-build.sh`'s tier-1 conflict arm, `merge_step`'s queue arm),
  and a bare row read would strand both;
- parks through `mq_park`, which sets `status='blocked'` with the same reason
  sentence the five call sites already passed `MQROW`, and removes the plain
  file only after the PATCH returned 0. A refused PATCH writes the `.blocked`
  file as the fallback.

An unreadable row list is not an empty queue: it writes
`merge-queue rows could not be read (rc <n>) — falling back to the files on disk
this tick` and reads the directory.

**Key files:**
- `bin/run-build.sh` — `# >>> verdict at review`, `# >>> verdict artifact`
- `bin/review-prs.sh` — `# >>> review-prs merge` (`RP_MQ_WANT`),
  `# >>> review-prs d1 artifacts`, `# >>> review verdict ledger`
- `bin/merge-queue.sh` — `MQROWS`, `mq_queue_list`, `mq_park`
- `bin/lib/jobs/queue.sh` — `merge_queue_put`, `merge_queue_list`,
  `merge_queue_set`
- `worker/jobs/src/routes/merge-queue.js`, `worker/jobs/schema.sql` — the table
  and its `(project, pr)` unique key, which is the fleet-wide dedupe

## Verify it works

Driven, not read. `bash tests/merge-queue-enqueue-on-verdict.bh-1366-test.sh`
extracts the four verdict blocks by their markers and executes them against the
real `bin/jobs-client.sh` talking to a file-backed fake worker, and runs
`bin/merge-queue.sh` whole against a scratch `$HARNESS`:

- §A the two `bin/run-build.sh` blocks: one POST for a tier-2 APPROVE with a PR;
  zero for `VERDICT: BLOCK`, for every real prompt line quoted as a review body
  with a `VERDICT: BLOCK` last line, for a security-only APPROVE, for `TIER=1`,
  for `flags/conductor-owns-merges`, and for an empty PR number (which logs the
  skip); one POST when both blocks run; a refused worker writes the file and one
  ALERTS line. §A7 is the mutation: point the gate at the text instead of
  `$VERDICT_WORD` and the fixture must POST.
- §B `bin/review-prs.sh`: one POST off `merge_step`'s queue arm, zero for
  `MERGED=yes`, `MERGED=queued`, a fallback-lane APPROVE and the conductor flag.
- §C `bin/merge-queue.sh`: a `queued` row with no file is reached; nothing is
  touched into `state/merge-queue/`; a `blocked` row and a `.blocked` file are
  not re-offered; a file with no row still is; with the flag OFF the log is
  identical to `main`'s script on the same fixture.
- §D `mq_park`: a head-bound mismatch PATCHes `status=blocked` carrying
  `head <h> is not the reviewed sha <s>` and creates no `.blocked` file; a 404
  on that PATCH writes the file and creates no phantom row.

On a live box, after an approved tier-2 build:

```
grep 'enqueued #' /root/harness/builds/<project>-<KEY>-*/pipeline.log
/root/harness/bin/jobs-client.sh mq-list <project> queued
```

and the rendered crontab carries no `tier2-merge-sweep` line:

```
/root/harness/bin/render-cron.sh project-6 | grep -c tier2-merge-sweep   # 0
```
