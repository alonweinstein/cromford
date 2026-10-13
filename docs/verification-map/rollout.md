# Rollout dispatch hook (`bin/run-build.sh` → `bin/run-rollout.sh`)

**What it is:** the point in a build where a ticket that carries a `## Rollout`
section stops being a ticket to plan and becomes a set of waves to file. The
`# >>> rollout hook` block of `bin/run-build.sh` reads the body out of
`$BUILD/ticket-meta.json`, asks `bin/run-rollout.sh --is-rollout` whether it is
one, and on a yes runs the lane and ends the build with its result line. Two
terminals: `ROLLOUT_FILED <n>` (the waves are on the board) and
`ROLLOUT_FAILED <reason>` (the body said rollout and nothing was filed).

**Preconditions.** `bin/run-rollout.sh` is slice `.3` of #816 and is not on any
box yet. Until it lands the hook is INERT BY DESIGN — the `[ -x ]` guard is
false, nothing runs, and every ticket takes the ordinary PLAN path. That is what
lets this slice merge on its own, and it is also the first thing to check if a
rollout body is not dispatching.

**How an operator reaches it** — no cron line and no separate lane. The block
runs inside every build, after the `# <<< ticket meta` marker and before
`# >>> preplan adopt`, so it is reached by whatever reached the build:
`bin/run-build.sh <project> <ticket-id> <KEY>` from the project's tick,
`bin/orphan-reconcile.sh`, or the resolver. The build's own DEDUPE lock
(`locks/build-key-<project>-<KEY>.lock`) and its claim are what stop two builds
of the same master; the hook adds no lock and holds none.

**How to drive it:**

| what | how |
|---|---|
| the hook, on a scratch tree | `HARNESS_TEST_SANDBOX=1 bash tests/run-build-rollout-hook.bh-985-test.sh` |
| the dispatch itself | the same suite, section B — the block is extracted by its markers and EXECUTED with a stub lane script whose `--is-rollout` runs the REAL `fc_has_rollout` from `bin/lib/file-children.sh` |
| the negatives (fences, child titles, #816's own body, every absence) | the same suite, section C |
| a lane run that failed, said nothing, or claimed FILED and exited non-zero | the same suite, section C' |
| where the block sits, and the child regex it shares with the size gate | the same suite, section D |
| the job row (`ROLLOUT_FILED` → `done`, `ROLLOUT_FAILED` → `failed`) | the same suite, section E |
| the watcher prompts carry the sweep rule | the same suite, section F |
| a parked master is not re-launched as a dropped ticket | `HARNESS_TEST_SANDBOX=1 bash tests/orphan-reconcile-rollout-master.bh-985-test.sh` |
| lint | `bash -n bin/run-build.sh`, `shellcheck -S error bin/run-build.sh` |

**What must never regress:**

- **Fail-open on every absence.** No `ticket-meta.json`, no `body` key, an empty
  body, no `bin/run-rollout.sh`, a non-executable one, or a detector that exited
  non-zero for any reason — each leaves the block a no-op and the ordinary plan
  path running. A build must never end because the rollout lane was missing.
- **A child title never dispatches.** `AB-7.2: …` is a wave, and a wave is
  planned like any other ticket. The regex is the size gate's own line, byte for
  byte; two spellings of "is this a split child" is how a wave gets dispatched
  as a master.
- **Fences never dispatch.** Issue #816's own body documents the convention
  inside a ``` fence. Detection stays delegated to `--is-rollout`; no fence
  logic is re-implemented in the hook.
- **`ROLLOUT_FILED` with a non-zero rc is `ROLLOUT_FAILED`.** `done` means the
  waves are on the board, never "the script ended". No result line at all is a
  failure too.
- **Order.** The block sits before the pre-plan adoption, the PLAN launch and
  the size gate, so a master never adopts a plan, never buys a model call and is
  never split.

**Preconditions / seed needs:** none for the suites — both build their own
scratch tree, their own `gh`/`curl` shims and their own fixtures. No network, no
token, no model call.

**Manual-only / not automatable:** the end-to-end proof. File one real rollout
on `example-org/cromford` (two small doc waves, wave 2 after wave 1) once
`bin/run-rollout.sh` is on the box, and watch the two children, the parked
master, and wave 2 releasing when wave 1 merges. Nothing in this repo can drive
that without filing real issues.
