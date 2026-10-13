# In-app board lane of the child filer (`bin/lib/fc-board.sh`)

**What it is:** the lane module `file_children` (`bin/lib/file-children.sh`)
sources for a project whose fleet.conf column 4 is a board prefix rather than
`-`. It defines `fc_file_board`, which files each child of a split as a ticket
on the client's own board, in order, with the parent and dependency ids, and
then parks the master. It is sourced, never run on its own.

**How an operator reaches it:** it has no cron line of its own. It has two
live callers. The rollout lane: `bin/run-build.sh` hands a ticket with a
`## Rollout` section to `bin/run-rollout.sh`, which parses the waves into
`$BUILD/children.json` and calls `file_children … --kind rollout`. And the
in-app decompose lane (BH-3965): the size gate hands an oversized ticket to
`bin/run-decompose.sh`, the model writes `$BUILD/children.json`, and the script
calls `file_children` with the default `--kind decompose`. On a board that
advertises `dependencies` each decompose sibling gets `dependsOn` = [contract
id, then its `after` siblings] and no `Blocked-by:` text; on one that does not
it gets `Blocked-by: <contract key> (hard)[, …]` text from the create answers.
With `decompose-board-filer-off` on, the decompose lane goes back to letting
the model file the children, and this module is not called.

```bash
HARNESS_TEST_SANDBOX=1 bash tests/run-decompose-inapp-deps-test.sh
```

Every board call goes through the board adapter of the tracker contract,
`bin/lib/tracker/board.sh` (BH-4075, [tracker-adapter.md](tracker-adapter.md)):
`_fcb_curl` is its `_trk_board_curl`, and the parent read, the master's comment
and its move are `trk_board_ticket_raw`, `trk_board_comment` and
`trk_board_transition`. Without that file the lane files nothing.

**How to drive it:** the suite runs the real dispatch and the real
`bin/run-rollout.sh` against a `curl` stub on PATH, with no network:

```bash
HARNESS_TEST_SANDBOX=1 bash tests/fc-board.bh-983-test.sh
```

A dry run of a real project prints every call without sending any
(`FILE_CHILDREN_DRY_RUN=1` or `DECOMPOSE_DRY_RUN=1`):

```bash
FILE_CHILDREN_DRY_RUN=1 bin/run-rollout.sh <project> <ticket-id> <KEY> /tmp/rollout-dry
```

The dry run still makes `bin/run-rollout.sh`'s own read of the parent ticket,
which is a GET. It files nothing and writes no `children.txt`. The printed calls
land in `decompose-board.log` and on stdout. Because `bin/run-rollout.sh`
counts its RESULT from the record, a dry run ends in
`RESULT "ROLLOUT_FAILED filed 0 of N waves"`. That is expected.

**What a live box shows**, in the build directory of the rollout:

| File | What it holds |
|---|---|
| `children.txt` | one board key per filed wave, written right after its create answered. `bin/run-rollout.sh` counts it for its RESULT line |
| `children-board.tsv` | `<n>\t<key>\t<id>` for each filed wave; a rerun reads the ids of already-filed waves from here |
| `decompose-board.log` | every curl the run made or would make, the token shown as its variable name |
| `children/child-<n>.html`, `children/create-<n>.json` | the body and the request of each create |
| `pipeline.log` | `child n of N filed as KEY`, WARN lines, or `ROLLOUT_FAILED board lacks dependencies` |

On the client's board, each wave carries `parentId` and `dependsOn`, the board
derives `blocked` from them, and the master sits in `in_progress` with one
comment listing the waves.

**Failure states you can see:**

- `ROLLOUT_FAILED board lacks dependencies` in `pipeline.log`, and
  `ROLLOUT_FAILED filed 0 of N waves` in `rollout-run.txt`: board `[0]` does
  not advertise `dependencies`, or the probe failed. Nothing was written.
- `create failed on child n of N`: waves before `n` exist and are on the record.
  The master was not commented on or moved. The next run files only the rest.
- `cannot resolve the board id of recorded child KEY`: `children.txt` has a key
  that `children-board.tsv` has no id for. Nothing is re-created. A human has to
  resolve it.
- `WARN: … comment did not post` / `WARN: … move … did not take`: every wave
  is filed. Only the parking step failed.

**Not covered:** no UI. The board side (that `blocked` and `children[]` come
out of the fields sent) is the client app's behaviour and is not driven here.
