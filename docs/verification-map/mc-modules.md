# Conductor modules (the lib is a shim over `bin/lib/mc/`)

**What it is:** `bin/lib/merge-conductor-lib.sh` was a 5,446-line monolith that
14 production scripts source on every tick. BH-477 split it into six modules
under `bin/lib/mc/` and left the old path in place as a SHIM: the
one guarded source line per sibling lib, one guarded source of `mc/load.sh`, nothing else (held to a line grammar, not a
line count, since BH-5228). BH-684 is the cutover
— the body was deleted and the modules became live in the same commit.

**How a user reaches it:** there is no screen and no cron line of its own. Every
lane that sources the lib reaches it, on every tick: `bin/merge-conductor.sh`
(`cron/hub.cron`, `*/5`), `bin/merge-queue.sh`, `bin/merge-sweep.sh`,
`bin/blocked-resolver.sh`, `bin/batch-resolve.sh`,
`bin/review-prs.sh`, `bin/review-rescue.sh`, `bin/reconcile-prs.sh`,
`bin/rebase-train-ahead.sh`, `bin/restore-merge.sh`, `bin/run-build.sh`,
`bin/poll-commands.sh` and `bin/lib/gh-app-auth.sh`.

**Key routes/screens:**
- `bin/lib/merge-conductor-lib.sh` — the shim: `MC_H`, `MC_LIB_DIR`, then 6
  guarded source lines for the `bin/lib/` siblings (issue-state-lib, block-gate,
  pr-dep-gate, main-red-gate, verdict-parse, queue-batch-only; loaded BEFORE the
  modules), the one line `. "$MC_LIB_DIR/load.sh"` (BH-5240: `mc/load.sh` calls
  `mm_load`, which loads the names `bin/lib/mc/MODULES` lists), then
  7 source lines off `$MC_H/bin/lib/` (gh-app-auth, gh-pr-merge, review-model,
  gh-rest, verdict-status, flaky, review-provenance). The harness siblings come
  AFTER the modules on purpose, so a real helper replaces `mc/log.sh`'s fail-open
  stub. To verify: `bash -c '. tests/lib/scratch.sh; scratch_closure_list
  bin/lib/merge-conductor-lib.sh'` lists all 13 (`tests/mc/lib-complete-test.sh`
  check 5).
- `bin/lib/mc/{log,locks,classify,queue,rebase,settle}.sh` — the six modules;
  the table in `docs/MERGE-CONDUCTOR.md` § 1b says what each holds
- `tests/mc/expected-map.d/*.tsv` — the binding `module<TAB>function<TAB>origin`
  ownership map, as fragments (Lane E, 2026-09-24): the base rows in
  `00-lib.tsv` / `00-driver.tsv`, and one `<TICKET-KEY>.tsv` per later change.
  A PR that adds a conductor function writes its OWN fragment and never edits
  another's, so two such PRs cannot conflict on the map. `tests/lib/mc-expected-map.sh`
  assembles the union for the three suites and refuses a malformed row, a
  module or origin outside the set, and a function claimed twice
  (`tests/mc/expected-map-fragments-test.sh`). Count the rows rather than trust
  an integer: `awk -F'\t' '$3=="lib"' tests/mc/expected-map.d/*.tsv | wc -l`.

**Selectors:** none (no UI). The seam is addressed by the bootstrap line:
`grep -n 'MC_LIB_DIR/load.sh' bin/lib/merge-conductor-lib.sh`.

**Preconditions / seed needs:** a `$HARNESS` tree that carries `bin/lib/mc/`
NEXT TO the shim. `bin/harness-sync.sh` rsyncs `bin/` as a whole tree
(`rsync -a "$CHECKOUT/bin/" "$HARNESS/bin/"`) and enumerates no file list, so
the shim and its modules always travel together. The bootstrap line exits on
failure: a box that somehow has the shim without the modules prints the
`mm_load` reason (for example `module-map: …: module queue has no readable
file …`), then `merge-conductor-lib: the mc modules did not load from …`, and
exits the caller, rather than classifying PRs with half a classifier.
`mm_load` checks every listed file before it sources one, so a missing file
sources nothing. `HARNESS_TEST_SANDBOX=1 bash
tests/module-map-mc-cutover.bh-5240-test.sh` drives these paths.

**Verify it works:**
- `HARNESS_TEST_SANDBOX=1 bash tests/mc-split-layout-test.sh` — the six modules
  exist and parse, no function is defined twice, nothing is misplaced against
  the map, all 15 `MC_*` path globals resolve to their pre-split values, a
  missing module is a LOUD failure, and the sources happen in the fixed order
  with `log` first. 45 cases.
- `HARNESS_TEST_SANDBOX=1 bash tests/mc/lib-complete-test.sh` — the other
  direction: every line of the shim is shim grammar (a source, guard,
  assignment or guarded source; no loop, no function, no logic), every `origin=lib` row of the map is
  defined AFTER sourcing the shim by the module the row names (read with
  `shopt -s extdebug` + `declare -F`, never a grep), and the shim itself defines
  nothing; the grammar and check 4 are driven over fixtures (40-line
  sourcing-only shim passes, an `if` block fails, a defined function fails).
- `HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-test.sh` and the four
  `tests/mc/{classify,rebase,queue,settle}-test.sh` — the behaviour, unchanged,
  in the files named for the modules they exercise. All five take their scratch
  harness from `tests/lib/fixture-harness.sh` since BH-1196
  (`fx_mc_harness "$DIR" "$T"`, plus `fx_conductor_tick "$DIR" "$T"` in the four
  that drive the whole tick): the eight-line `cp` block they each carried — and
  that `tests/mc/classify-test.sh` carried twice — is one function now, so a
  fixture change is one edit. Sourcing the lib under test stays in each suite
  (`. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init`), and so does one rooted
  `$DIR/bin/lib/mc` token, which is what `bin/test-impact.sh` selects them by.

  in the files named for the modules they exercise.
- `HARNESS_TEST_SANDBOX=1 bash tests/conductor-detached-lanes-test.sh` § 1, "NO
  LANE JOB INHERITS THE TICK'S LOCK" (line 177) — **this is where the fd case
  lives.** Issue #684 item 4 asked for an fd-discipline case in
  `tests/mc/rebase-test.sh`; it was never carried there
  (`grep -c 'holds_fd\|/proc/' tests/mc/rebase-test.sh` → 0, audit finding I3),
  and nothing in #1191 said where it had actually landed. § 1's `probe_lane`
  holds a real flock on fd 9 the way `tick_project` does, spawns the rebase,
  deploy-verify and re-review lanes under it, and then asserts: a running job
  file was written, the lock is free the moment the holder releases it,
  `/proc/<pid>/fd` does not point at the lock file (`holds_fd`, line 165 — rc 2
  where `/proc` is unreadable, and there the flock probe carries the claim), and
  the job is STILL RUNNING. Without that last assertion the fd probe proves
  nothing, since an exited lane holds no fds either.
- On a live box: `bash -c '. /root/harness/bin/lib/merge-conductor-lib.sh;
  declare -F mc_classify'` prints
  `mc_classify <line> /root/harness/bin/lib/mc/classify.sh` under
  `shopt -s extdebug`, and `HARNESS=/root/harness bash
  /root/harness/bin/merge-conductor.sh --help` exits without one
  `command not found` — which is exactly what an incomplete extraction produces.

**What it does NOT do:** nothing here changes behaviour. No new cross-run state,
no renamed state path, no new env var, no metered API call, no DB, no migration,
no UI. A tick before and after the cutover classifies the same PRs the same way.
