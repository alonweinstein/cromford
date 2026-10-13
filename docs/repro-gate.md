# Pre-build repro gate (BH-2004)

This is the contract (BH-2039, order 1 of #2004): the runner, the record, the log line, the ledger key and the
run-build hook. Later children of #2004 fill the five stage functions. The thread fetch and the skip marker are
real (BH-2040, [repro-gate/skip.md](repro-gate/skip.md)), so a bug build on a wired board reads its thread,
honours a principal's `[no-repro]`, and otherwise reaches the drive. Only a project with no board row still
records cannot-drive fetch-not-wired.

## Where it runs

`bin/run-build.sh`, block `# >>> prebuild repro (BH-2004)`, between the rollout hook and the pre-plan adoption.
It runs `bin/prebuild-repro.sh <project> <ticket-id> <key> <build-dir>` only when `$BUILD/prebuild-repro.txt` is
absent, so a resumed build never runs it twice. A box without the runner or `bin/lib/prebuild-repro.sh` skips
the block and builds as before.

| runner exit | run-build does |
|---|---|
| 0 | proceeds, and sets `REPRO_BRIEF_LINE` from `pr_brief_line` |
| 10 | `RESULT "BUILD_DEFERRED repro NOT_REPRODUCED — commented on the ticket, waiting on the client"`, touches `COMMENTED`, exits 3 |
| 11 | deletes the record (so the next offer retries), `RESULT "BUILD_DEFERRED repro NOT_REPRODUCED but the board comment failed — retrying next offer"`, exits 3, no `COMMENTED` |

`$REPRO_BRIEF_LINE` goes into the plan prompt right after `$CARRIED_NOTE_LINE`. The `# >>> repro section` block
sets `REPRO_SECTION` from `pr_pr_section`, and `PR_BODY_FOR` appends it after `PREPR_SECTION`. Both render stubs
print nothing, so the plan prompt and the PR body are byte-identical to before.

## The runner's flow

The lane gate comes first: `lane-off-prebuild-repro[-<project>]` or `all-off` stops it with no record, and the
build proceeds. Then:

1. `lane_knob prebuild-repro REPRO_GATE <project>` is 0: record `skip knob-off`, exit 0.
   `REPRO_GATE_MAX_USD` is resolved the same way and exported for the drive stage.
2. `bin/kind-gate.sh <build>` gives the `KIND_HINT`. Not `bug`: record `skip not-bug`, exit 0. The thread is
   not fetched.
3. A stage function is not defined: record `cannot-drive stage-missing`, exit 0.
   `pr_fetch_thread`: rc 3 (the project has no board row) records `cannot-drive fetch-not-wired`, any other
   non-zero rc records `cannot-drive thread-unreadable`. Exit 0 either way.
4. `pr_skip_classify`: a first field of exactly `skip` records `skip <marker> <evidence>`, exit 0.
5. `pr_drive`: REPRODUCED, CANNOT_DRIVE, NOT_REPRODUCED and ALREADY_FIXED record `reproduced`, `cannot-drive`,
   `not-reproduced` and `already-fixed`, with field 2 as the reason. Anything else records
   `cannot-drive drive-bad-verdict`. It is never read as a stop.
6. Only on not-reproduced or already-fixed, `pr_stop`: rc 10 rewrites the record as
   `stop <not-reproduced|already-fixed> <drive reason>` and exits 10. rc 11 exits 11. Any other rc exits 0.

## The record

`$BUILD/prebuild-repro.txt`, written only by `pr_record` (tmp file then `mv`), exactly three lines:

```
REPRO_GATE: skip|cannot-drive|reproduced|not-reproduced|already-fixed|stop
REPRO_REASON: <reason>
REPRO_EVIDENCE: <evidence, or ->
```

Newlines and tabs in the reason and evidence become spaces, and evidence is capped at 500 characters. Any other
gate word is refused with rc 2 and nothing is written. Each record appends one line to both
`logs/<project>.log` and `$BUILD/pipeline.log`: `repro=<gate with - as _> reason=<reason> key=<KEY>`, for
example `repro=skip reason=not-bug key=BH-7`.

## The ledger key

`pr_ledger_key <project> <KEY> <thread-json>` prints `<project>/<KEY>/<thread_fp>`. `thread_fp` is the sha256 of
four lines: the comment count, the newest comment's id, its createdAt, and the sha256 of the body. The newest
comment is picked by createdAt and then id, never by array position. With no comments the id and createdAt are
`-`. Empty or unparseable JSON returns rc 1 and prints nothing.

The harness's own comments are left out before any of that is counted (BH-2133). That covers a comment flagged
`harness: true` by the fetcher, and one carrying the stop stage's `<!-- harness:repro-stop … -->` marker. Without
this, the stop comment moved the key it was keyed on, and each re-offer paid for another drive and posted
another comment. See [repro-gate/self-comment.md](repro-gate/self-comment.md).

The ledger itself (kind `repro_gate`, statuses `reproduced`, `cannot_drive`, `not_reproduced_uncommented`,
`already_fixed_uncommented`, `not_reproduced`, `already_fixed`) is not written by anything yet. The drive child
writes it.

## Stage functions (`bin/lib/prebuild-repro/*.sh`, function-only)

| file | function | today |
|---|---|---|
| thread.sh | `pr_fetch_thread <project> <ticket-id> <key>`: normalized thread JSON, rc 0 ok / 1 unreadable / 3 not wired | real (BH-2040, [skip.md](repro-gate/skip.md)); rc 3 only for a project with no board row |
| classify.sh | `pr_skip_classify <thread-json>`: `skip\t<marker>\t<evidence>` or `run\t<reason>\t-` | real (BH-2040, [skip.md](repro-gate/skip.md)) |
| drive.sh | `pr_drive <project> <key> <build> <thread-json>`: `<VERDICT>\t<reason>`, rc 0 | `CANNOT_DRIVE\tdrive-not-wired` |
| stop.sh | `pr_stop <project> <ticket-id> <key> <build> <thread-json> <verdict>`: rc 0 / 10 / 11 | rc 0 |
| render.sh | `pr_brief_line <build>`, `pr_pr_section <build>` | nothing |

## Knobs (`catalog/lanes.d/prebuild-repro.json`)

- `REPRO_GATE` (0..1, default 1). 0 turns the gate off, and every build records `skip knob-off`.
- `REPRO_GATE_MAX_USD` (0.5..10, default 3). The spend cap for one drive. Nothing spends yet.

Settings rows: `lane.prebuild-repro[.<project>].repro_gate`, `…repro_gate_max_usd`.

Tests: `tests/prebuild-repro-contract.bh-2039-test.sh`.
