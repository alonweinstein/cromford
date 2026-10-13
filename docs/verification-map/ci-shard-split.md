# CI shard split (eight shards, one check name)

> **Since the CI cost cut (2026-09-24)** CI no longer runs this as its own matrix: one traced run per shard (`tests-shard`, `bin/test-trace-safety.sh --gate`) feeds both required checks, sized by `bin/ci-plan.sh`. See [ci-cost-lanes.md](ci-cost-lanes.md). What follows is the history and the runner contract, which still holds.

**What it is:** `suite_shard_parse` and `suite_shard_filter` in
`bin/lib/suite-runner.sh`, the `--shard i/n` flag on `bin/test-suite-run.sh`,
`bin/test-trace-safety.sh` and `bin/run-tests-in-docker.sh`, and the four
matrix jobs plus two fan-in jobs in `.github/workflows/harness-ci.yml`
(BH-1192).

**Why.** The two long CI jobs each ran the whole `tests/` corpus serially:
`Pure-logic gate fixtures` measured 35–45 minutes on main and
`Tests cannot touch a real harness` 40–45. Every PR in the drain waited for
both before it could merge, so throughput was CI-bound rather than build-bound
— the runner pool is shared across the repo, and the gate, not the build, was
the queue.

**The split.** One function decides it, `suite_shard_filter <i> <n> <suite…>`:
the suite list is C-sorted and every n-th entry from index `i` is taken. Sorted
first, so the answer is a property of the NAMES and not of the order a caller's
glob or locale produced — two callers with the same corpus compute the same four
shards. `suite_shard_parse` validates the `i/n` spec and refuses everything else
(`4/4`, `-1/4`, `1/0`, `1`, `1/2/3`, empty): there is no safe fallback, because
a spec that degraded to "everything" would quadruple CI and one that degraded to
shard 0 would leave three quarters of the corpus unrun behind four green checks.

**The check names do not change.** `decisions-shard` and
`harness-safety-shard` run as `… (shard 0/8)` … `… (shard 7/8)`, and the jobs
`decisions` and `harness-safety` fan them in under the old names
`Pure-logic gate fixtures` and `Tests cannot touch a real harness` — the names
the branch's checks, `bin/merge-conductor.sh` and the main-red detector's
fixtures (`tests/main-red-*-test.sh`) already read. Each fan-in runs
`if: always()` and fails unless `needs.<shard job>.result` is `success`: a bare
`needs:` would SKIP the fan-in on a red shard, and a skipped check is not a
passing one but reads like nothing happened. `fail-fast: false` on both
matrices keeps a red shard from cancelling its siblings, which is how a reader
finds out whether one suite broke or fifty did.

**What stays single.** The determinism lint, the README/rendered-file checks,
the `tests/ sourcing lint`, the two gate-fixture steps (triage-gate,
merge-sweep) and the STATIC scratch-only check (`bin/checks-run.sh --tree .`)
all run exactly once, in the fan-in jobs. The static check reads the text of
every test in seconds; sharding it would only let a rule that matches nothing
hide in three green jobs.

**Status:** shipped with BH-1192. `HARNESS_TEST_SANDBOX=1` stays exported on
every `decisions` shard (#463) and stays unset on the safety lane, whose header
says why. The safety shards carry `timeout-minutes: 35` against a measured
quarter of 10–12 minutes.

**How an operator reaches it:** every PR's CI run — four shard checks and one
fan-in check per lane. Locally, one shard at a time:
`bin/run-tests-in-docker.sh --shard 0/4` reproduces exactly what CI's shard 0
ran, and `bash bin/test-suite-run.sh --shard 0/4 tests tests/mc` does the same
without the container. Both print how many of how many suites the shard took,
so a reader of one shard's log can see how much of the corpus that green covers.

**How to drive it:**

| what | how |
|---|---|
| the eight shards are the whole corpus, no suite in two, a new suite lands in exactly one, a malformed spec is refused, and the workflow's matrix matches the `/N` the runners are given (BH-1192) | `bash tests/ci-shard-split-test.sh` |
| the runner still sweeps, classifies and refuses an empty sweep exactly as before | `bash tests/test-suite-run-test.sh` |
| the trace runner still scans a lone copy of itself with no `lib/` beside it | `bash tests/tests-trace-safety-test.sh` |
| this repo as the PR leaves it | `for i in 0 1 2 3; do bin/run-tests-in-docker.sh --shard $i/4; done` — the union of the four `--- <suite>` lists is `ls tests/*.sh tests/mc/*.sh` |

**Files it writes on a live box:** none. Every script here writes to stdout and
answers with an exit code.

**What must never regress:**

- **The eight shards are the whole corpus.** A split that drops suites looks
  exactly like a fast green, which is why `tests/ci-shard-split-test.sh`
  asserts the partition rather than any single shard's contents.
- **One implementation of the split.** Both runners and the docker wrapper call
  `suite_shard_filter`. A second copy of the modulo is how the union quietly
  stops being the corpus.
- **The fan-in names stay.** `Pure-logic gate fixtures` and
  `Tests cannot touch a real harness` are pinned by the merge gate and by the
  main-red detector's fixtures; renaming either is a branch-rule change, not a
  workflow edit.
- **A red or skipped shard is a red fan-in.** Never `needs:` alone.
- **A bad `--shard` refuses.** It never falls back to shard 0 and never falls
  back to running everything.
- **A lone copy of `bin/test-trace-safety.sh` still scans.** The library is
  optional for the scan and required only for `--shard`, which the script says
  by name rather than by silently tracing everything.
