# Suite runner and sourcing lint (a suite that dies says so once)

> **Since the CI cost cut (2026-09-24)** CI no longer runs this as its own matrix: one traced run per shard (`tests-shard`, `bin/test-trace-safety.sh --gate`) feeds both required checks, sized by `bin/ci-plan.sh`. See [ci-cost-lanes.md](ci-cost-lanes.md). What follows is the history and the runner contract, which still holds.

**What it is:** two CI-side scripts, `bin/test-suite-run.sh` and
`bin/test-sources-lint.sh`, wired into the `decisions` job of
`.github/workflows/harness-ci.yml` (BH-629.3).

`bin/test-suite-run.sh` replaces the job's inline
`for t in tests/*.sh tests/mc/*.sh` loop. It takes the suite dirs as arguments
(CI passes `tests tests/mc`, the explicit two-glob form of #929 — CI's bash has
no globstar) and sweeps them in order as ONE run. It runs each suite, echoes its
output unchanged, and classifies the result. A suite
is a **SUITE ERROR** rather than an ordinary FAIL when it exited nonzero AND
printed no `<name>: N passed, M failed` summary line — the shape of a suite that
died before it could count anything. At the end, one block names every such
suite with its first error line and the run exits 1. An ordinary FAIL keeps
today's behaviour exactly.

`bin/test-sources-lint.sh` is the prevention. For every `tests/*.sh` and
`tests/mc/*.sh` — the same two suite dirs CI runs — it refuses
a `.`/`source` of a path under `tests/lib/` when the path is CWD-relative (a bare
`tests/lib/x.sh` only resolves when the suite runs from the repo root) or when
the source line carries no same-line failure handler at all. Any `||` handler
counts — about 28 suites deliberately fall back rather than exit, and that is a
handled failure, not the incident's shape.

Heredoc bodies are data (several suites WRITE a broken source line into a
fixture on purpose), so the scan skips them — but only for a `<<` that is
really an operator. A `<<` quoted inside a string or shown as an example in a
comment does not open one, and a heredoc that never closes is rc 2 with the
file, line and tag named on stderr: a file whose tail was never read is not a
clean file.

Why both: on 2026-09-17 `tests/checks-suite-test.sh` died sourcing a
`tests/lib/` file main did not have. It printed no summary line, the CI log read
as an ordinary failure, and the real cause was buried in a run that also carried
genuine FAILs from the same missing file. See [pr-dep-gate.md](pr-dep-gate.md)
for the merge-side half of that incident.

**Status:** both scripts ship with BH-629.3, and the `decisions` lane runs them.
Since BH-1192 the sweep is four parallel shards — `decisions-shard`, running
`bash bin/test-suite-run.sh --shard i/4 tests tests/mc` — and
`tests/ sourcing lint` (`bash bin/test-sources-lint.sh`) runs once in the
fan-in job that keeps the name `Pure-logic gate fixtures`. The inline loop is
gone, and so is the serial sweep; see [ci-shard-split.md](ci-shard-split.md)
for the split itself.

The summary line the runner looks for is either shape this repo uses:
`N pass(ed), M fail(ed)` (about 170 suites) or `pass=N fail=M` (about 20),
either at the start of a line or after a `<name>: ` prefix. The NAME is
deliberately not matched: an earlier anchored name class rejected four real
suites — a parenthesised ticket key (`heartbeat-reaper (BH-638): 7 passed, 1
failed`, `review-prs-state (BH-977)`), a prefixed alt shape
(`tg-outbound-topic: pass=7 fail=1`) and a bare count with no name at all
(`cache-hit-report`) — so an honest failure in any of them printed under
"these suites did not run". About twenty suites print no summary at all; an
honest failure in one of those is reported as a SUITE ERROR with its first
error line quoted, which overstates the cause but hides nothing. Runner exit
codes: `0` every suite exited 0, `1` any FAIL or
SUITE ERROR, `2` no suites matched in ANY directory given — a sweep over
nothing is not green, while one empty dir beside a swept one is not a failure
(`tests/mc/` carries no suite until BH-477's slices land). Lint exit codes: `0` clean and silent, `1` offenders printed as
`<file>:<line>: <reason>`, `2` could not scan — no `tests/` dir, no suite in
it, the awk pass died, or a heredoc opened and never closed so the tail of a
file was never read.

**How an operator reaches it:** every PR's CI run, in the `decisions` job. There
is no cron lane and nothing to turn on. Locally both run from the repo root with
no arguments: `bash bin/test-suite-run.sh` (defaults to `tests`),
`bash bin/test-sources-lint.sh`.

**How to drive it:**

| what | how |
|---|---|
| a suite that dies is one SUITE ERROR block at the end, an honest FAIL is not, and several suite dirs sweep as one run (BH-629.3) | `bash tests/test-suite-run-test.sh` |
| the lint refuses a CWD-relative source and an unhandled one, accepts an anchored source with any `\|\|` handler, does not open a heredoc on a `<<` in a comment or a string, and is rc 2 on an unterminated one (BH-629.3) | `bash tests/test-sources-lint-test.sh` |
| this repo as the PR leaves it | `bash bin/test-sources-lint.sh` exits 0; `bash bin/test-suite-run.sh` is the full sweep |

**Files it writes on a live box:** none. Both scripts write to stdout and answer
with an exit code; nothing under `state/`, `logs/` or `flags/` changes.

**What must never regress:**

- **An ordinary FAIL stays an ordinary FAIL.** A suite that ran, counted and
  reported failures is not a SUITE ERROR, and classifying it as one would hide
  real test failures behind an infrastructure story.
- **One broken suite never ends the run.** No errexit in the runner: the
  remaining suites still run, and the block is printed once at the end where a
  reader will see it.
- **Every suite's own output is still echoed.** Anything that reads today's CI
  logs must keep working.
- **The lint stays narrow.** It flags the missing handler and the CWD-relative
  path, nothing else. A rule that drags two dozen unrelated suites into a diff is
  the wrong rule, not a bigger ticket.
- **A sweep that did not happen never reads as clean.** A missing `tests/` dir,
  an empty one, a dead awk pass and a heredoc that never closes are all rc 2 in
  the lint and all name what was not scanned. Silence plus rc 0 must only ever
  mean "every line of every suite was read and none offended".
- **The runner never files an honest failure as infrastructure noise.** The
  summary reader matches the counts, not the suite's name; a new suite that
  counts in a name shape nobody anticipated must still read as an ordinary FAIL.
