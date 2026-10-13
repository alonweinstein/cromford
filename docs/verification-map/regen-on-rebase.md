# Regenerate on rebase (a rebased head never carries a stale generated file)

**What it is:** after `origin/main` is merged into a PR branch — on the hub
conductor, on a pool machine, or in a batch train — the repo's own
`## Generated files` commands run over the merged tree and the declared paths
are committed as ONE extra commit before the gates and the push. Before BH-969
only the batch train did this, and only for files a conflict had recorded, so an
ordinary rebase pushed a head whose generated file was stale and CI's drift step
failed the PR for a file no ticket was about.

**How an operator reaches it:** there is no UI. Three production entry points
call it, and each leaves its own trace:

| where | who calls it | what you see |
|---|---|---|
| `mc_rebase` (`bin/lib/mc/rebase.sh`) | the tick's inline NEEDS_REBASE arm in `bin/merge-conductor.sh`, `mc_rebase_run`, `br_mechanical` in `bin/blocked-resolver.sh`, `bin/rebase-train-ahead.sh` | one `regenerate <paths> after rebase onto origin/main` commit on the PR branch; on a failing generator, one `… rebase regenerate FAILED: <cmd> — <tail>` line in `logs/merge-conductor.log` |
| step 6b of `_rebase_job_body` (`bin/lib/rebase-job.sh`) | the pool machine runner, via the job `bin/fly-dispatch.sh` materialises | the same commit on the pushed head; the RESULT line is still `REBASED <sha>` |
| `build_union` (`bin/batch-resolve.sh`) | the train, spawned by `mc_batch_should_spawn` | `regenerated the union once with: <cmd>` in `logs/batch-resolve.log` on EVERY train now, not only conflicted ones, plus the `batch: regenerate the repo's generated files over the union` commit. A failure says which of the two arms it took — `… a member conflicted in its files …` (batch abandoned) or `… nothing conflicted in its files …` (batch keeps going) |

**Key routes/screens:** none. The observable surfaces are the two logs above
and the PR's commit list on GitHub.

**Preconditions:** the repo must declare a `## Generated files` table in
`AGENT_ARCHITECTURE.md`, `docs/verification-map/README.md` or
`docs/verification-map/index/tail.md` (BH-1175 added the third home, because this
repo's README left git and `git show <ref>:<path>` reads an absent path as an
empty table), and the command in
each row must be executable in a fresh checkout. A repo that declares no table
is untouched — same behaviour as before BH-950.

**Verify it works:**

| what | how |
|---|---|
| all three entry points, on real git fixtures | `HARNESS_TEST_SANDBOX=1 bash tests/generated-files-train.bh-969-test.sh` |
| the union obeys the same staging/deps/arm invariants as its twin | R9a/R9b/R9c in the same suite |
| the defect itself, on the merge base | `bash` the REPRO in the BH-969 build dir — red before, green after |
| the parser both halves share | `bash -c '. bin/lib/mc/rebase.sh; mc_regen_table . origin/main'` — one tab-separated row per declared path |
| the hub rebase contract is unchanged | `bash tests/mc-rebase-shallow-test.sh`, `bash tests/land-rebase.bh-870-test.sh` |
| the pool twin's RESULT shape is unchanged | `bash tests/rebase-job.bh-543-test.sh` |

**What must never regress:**

- **The regenerate never blocks a rebase.** `mc_regen_generated` always returns
  0. A generator that fails is logged, its partial writes are dropped with
  `git checkout -- .` so a half-regenerated tree cannot be committed, and the
  rebase proceeds to the gates. The local gates and CI's drift check stay the
  arbiters — a docs generator having a bad day is not a blocked PR.
- **On the union, a failing generator only abandons the batch when a member
  CONFLICTED in its files.** `build_union` keeps two sets: the commands a
  conflict recorded (resolved by taking THEIRS, so only the regenerate makes the
  resolution correct — a failure there abandons the batch and pushes nothing,
  exactly as it did before BH-969) and the commands that ran only because the
  table declares them (a freshness top-up — a failure is logged, that command's
  declared paths are restored, and the train keeps its members). Widening the
  set to the whole table must never widen the blast radius: before BH-969 the
  abandon arm needed a generated-file conflict to be reachable at all, and one
  bad generator run must not cost a project every train it has. The restore is
  per-command, not `git checkout -- .`, because an earlier command's good output
  is still uncommitted when a later one fails. Pinned by R8a/R8b in
  `tests/generated-files-train.bh-969-test.sh`.
- **Only the DECLARED paths are staged, on all three entry points.** Never
  `git add -A`: a generator that leaves stray output must not sweep it into a
  PR nobody reviewed for it. `mc_regen_generated` has always staged per
  declared path; `build_union` used `git add -A` until it was pinned by R9a,
  and BH-969 is what took that gap from unreachable to once per train per
  project. Stray output stays UNTRACKED in the worktree and dies with it.
- **The table is read from the BASE ref,** never the branch head, so the command
  STRING is the one main declares and a PR cannot introduce a new one in its own
  diff. The script that string names still runs from the MERGED tree, so this is
  the same trust level as the gates, not a sandbox. Same rule as
  `batch-resolve`'s `show_base`.
- **`node_modules` is linked BEFORE the regenerate,** not in the gate block
  after it — a generator is as likely to need the repo's deps as the typecheck.
  True on all three entry points; `build_union` linked it only in
  `verify_union`, after the regenerate had already run, until R9b pinned it.
- **Which failure arm a command takes is an EXACT question.** `build_union`
  decides fatal-vs-best-effort by testing the command against the set a conflict
  recorded; that test is anchored on both sides, so a command that merely shares
  a suffix with a conflict-recorded one (`bin/gen.sh` vs `E=1 bin/gen.sh`)
  cannot abandon a train it has no claim on. Pinned by R9c.
- **The pool call is `type`-guarded.** A pool machine whose harness copy of the
  conductor lib predates BH-969 skips step 6b silently instead of dying on a
  missing function.
- **`mc_restack` gets no regenerate.** It rebases commits rather than merging
  and is the documented "NO LOCAL GATE" path; BH-969 does not name it.

**Manual-only / not automatable:** nothing. Every case runs on local git
fixtures with no network.
