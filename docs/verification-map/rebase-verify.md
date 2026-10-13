# Post-rebase verify typecheck

**What it is:** the rebase stage of `bin/run-build.sh`, marked
`# >>> rebase verify` / `# <<< rebase verify`. Before the PR is opened it
fetches `origin/$BASE`, and if main (or, for a stacked build, the parent branch)
has moved it rebases the branch and re-typechecks it. The verdict rides the
RESULT line as a note, which the board close-out comment and `evidence.md`
quote, and which `bin/merge-sweep.sh` reads before it merges anything.

**The four answers it can give** (exactly one, by construction):

| RESULT note | when |
|---|---|
| *(none)* | main did not move, or the rebase typechecked green, or `origin/$BASE` did not resolve at all (failed fetch, no ref) |
| `REBASE_VERIFY_FAILED: main moved (base=… main=…) and the rebase typechecks red` | `tsc` exited nonzero **with** `error TS…` diagnostics — a real red |
| `REBASE_VERIFY_INCONCLUSIVE: main moved (base=… main=…) but the rebase typecheck did not finish — tsc exit N …` | `tsc` crashed (exit ≥ 128 — V8 heap abort 134, SIGKILL 137), timed out (124), or exited nonzero with no diagnostics (npx could not run it). BH-575: this used to be reported as FAILED |
| `REBASE_VERIFY_INCONCLUSIVE: merge-base of origin/$BASE and HEAD is unresolvable (base=unresolved main=…)` | `origin/$BASE` resolves but shares no history with HEAD (shallow pool clone, unrelated histories). No rebase is attempted; "main moved" is never claimed without merge-base proof |
| `REBASE_CONFLICT vs origin/$BASE @sha (base=… main=…)` | the rebase itself conflicted — aborted, PR ships DIRTY |

On FAILED, INCONCLUSIVE and CONFLICT the worktree is `git reset --hard` back to
the pre-rebase head **before** the note is written, so a note never describes a
tree that was not reset.

**How an operator reaches it:** it is not its own cron lane — it runs inside
every build, after the review lenses and before the tier classification. On a
box, per build directory `builds/<project>-<KEY>-<stamp>/`:

- `pipeline.log` — `rebase typecheck at heap <N>MB (source: env|workflow|ram)`,
  then one of `rebased onto origin/main (base=… main=…) + typecheck green`,
  `… typechecked RED — reset to pre-rebase head`,
  `… typecheck INCONCLUSIVE (tsc exit 134 …) — reset to pre-rebase head, not claiming red`,
  `merge-base of origin/main and HEAD is unresolvable … — rebase skipped`, or
  `… CONFLICTED — aborted, PR ships on older base`.
- `rebase-tsc.txt` — the verify typecheck's own output, whatever it was. On a
  crash this is the FATAL line and nothing else, which is the tell.
- `RESULT` — `PR_CREATED <url>` plus the note above.
- reads `state/tsc-baseline-<project>.txt` (written by `bin/rebase-train.sh`,
  4h freshness) — a red whose every error line already exists on `origin/$BASE`
  is main's own baseline and is accepted. An INCONCLUSIVE run skips this branch:
  there are no error lines to diff.

**The heap** the verify typecheck runs at, in order: `TSC_HEAP_MB` from
`env/<project>.env` (see `env-templates/project.env.example`), else the largest
`--max-old-space-size=N` the repo's own `.github/workflows/*.yml` declare, else
70% of RAM capped at 12288. It is appended to any existing `NODE_OPTIONS`; a
later `--max-old-space-size` wins in V8.

**How to drive it:**

| what | how |
|---|---|
| the whole stage, extracted verbatim by its markers, against real `git` in a scratch repo with a fake `npx` | `bash tests/rebase-verify-test.sh` section 1 |
| the crash/red classifier (134, 137, 124, exit 1 with no diagnostics, exit 1 and exit 2 with `error TS2322`) | cases 1a-\* and 1b-\* |
| "main moved" only with merge-base proof, and the two shas in every note | cases 1s-\* |
| the heap resolver (env knob, CI-workflow declaration, RAM fallback, non-numeric knob ignored) | cases 1h-\* |
| `bin/merge-sweep.sh` parking an INCONCLUSIVE note and releasing it on a green CI Typecheck | `bash tests/rebase-verify-test.sh` section 2 |
| the approval-carry blocks nested inside this stage | `bash tests/head-bound-approval-test.sh` section 1j |

**What must never regress:**

- **An INCONCLUSIVE note never contains the substring `REBASE_VERIFY_FAILED`.**
  `bin/merge-sweep.sh` greps tokens, and the whole point is that a reader (human
  or grep) can tell a crash from a red.
- **INCONCLUSIVE parks the PR exactly as FAILED does** in `bin/merge-sweep.sh`
  (`:254`, `:264`), released by the same two paths: a head newer than the RESULT
  file, or a green CI `Typecheck` run on the head. An unverified rebase is not a
  verified one.
- **The green path is untouched.** A clean rebase that typechecks green still
  carries `review-head` across by distance (the head-bound carry block) and
  writes no note.
- **`origin/$BASE` that does not resolve changes nothing** — no rebase, no
  typecheck, no note. That was the behavior before BH-575 and it stays.
