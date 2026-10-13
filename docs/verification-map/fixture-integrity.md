# Fixture integrity — a broken setup is named, never blamed on the code

**What it is:** the rc checks, the kept stderr and the postconditions that
`tests/stacked-unstack-test.sh` now runs over its own git fixture, so a setup
step that did not happen is reported as `FIXTURE BROKEN: <name> — <step>` and
counted as a failure of its own — instead of surfacing as a **behaviour**
finding about `bin/run-build.sh` on a tree where `bin/run-build.sh` is innocent.

**Why it exists.** The fixture used to build a seed repo, a bare origin and a
child checkout inside `( cd … && git init -q . && … ) >/dev/null 2>&1`: twenty-odd
git steps, no rc read anywhere, no byte of stderr kept. PR #1014 at head
`e999973` went red on exactly one assertion out of 113 —

```
FAIL: nothing may rewrite the branch when the parent is not provably merged
stacked-unstack: 112 passed, 1 failed
```

— at a head that touches neither `bin/run-build.sh`, its `RB_MODULES`, the suite,
`tests/lib/rb-all.sh` nor `tests/lib/scratch.sh`, and whose flattened pipeline
text is byte-identical to `origin/main`. The same export ran 113/0 on the same
runner image minutes earlier and later, on main and on three other PR branches.
The red was the fixture; the report named the driver, and a resolver round was
spent reading the wrong file.

That single assertion is the one that notices because it is the only one whose
answer depends on the fixture's *shape* rather than on the recheck block's
verdict. If the seed's `checkout -qb ticket/TK-611` or the child's
`checkout -b ticket/bh-574 origin/ticket/TK-611` silently failed, then either
`git rev-parse origin/ticket/TK-611` printed its own ARGUMENT and exited 128 (so
`$P_SHA` is the literal string `origin/ticket/TK-611`), or the child was cut from
`main` instead of the parent. Every other assertion in the case still passes,
because the recheck block escalates on a gone-and-unmerged parent whatever shape
the child has.

**How an operator reaches it:** there is no cron lane and no live box. It runs
wherever the suite runs — locally, in `bin/run-tests-in-docker.sh`, and in the
`tests` job of `.github/workflows/harness-ci.yml`, which loops every
`tests/*.sh`.

**The three mechanisms, in order of what they catch:**

| mechanism | catches |
|---|---|
| `fx <name> <step> <cmd…>` — one step, rc checked, stdout+stderr appended to `$T/fixture-logs/<name>.setup.log` | a step that errored: the report names the step, its rc, and prints the tail of the log with git's own words in it |
| `fixture_assert` — `origin.git` has `refs/heads/ticket/TK-611` and `refs/heads/main`, the child's `HEAD` is `ticket/bh-574`, `origin/ticket/TK-611` resolves to a sha, and that sha is an ancestor of the child's `HEAD` | a step that exited 0 and produced the wrong tree, and the `rev-parse` that prints its argument instead of a sha |
| the `kill_parent` postcondition — `refs/heads/ticket/TK-611` is really gone after `branch -D` | a step that **lies**: exits 0 and deletes nothing. rc alone can never see this one |

Everything recorded is drained into the PASS/FAIL count in one loop just before
the summary line, because `C=$(fixture alive)` runs in a command substitution
whose `FAIL=$((FAIL+1))` cannot reach the parent shell. The diagnostic itself
goes to **stderr as it happens**, so the cause reads next to the symptom.

**How to drive it:**

| what | how |
|---|---|
| all three mechanisms, against a real suite run with one real git step sabotaged | `bash tests/stacked-unstack-fixture-guard-test.sh` |
| the suite it guards, unchanged | `bash tests/stacked-unstack-test.sh` (113 passed, 0 failed) |
| by hand: the #1014 shape | put a `git` shim on `PATH` that exits nonzero on `checkout -q -b ticket/bh-574` and run the suite — it must print `FIXTURE BROKEN: alive — git checkout -b ticket/bh-574 origin/ticket/TK-611 (rc 43)` |
| the guard reads no clock and no network | `bin/test-determinism-lint.sh tests/stacked-unstack-fixture-guard-test.sh` |

**Files it owns on a live box:** none. `$T/fixture-logs/<name>.setup.log` and
`$T/fixture-broken.log` live inside the suite's own `tests/lib/scratch.sh` tree
and die with it.

**Knobs:** none. Nothing here is a new env var, a flag file or a DB row.

**What must never regress:**

- **A healthy fixture must never print `FIXTURE BROKEN`.** A guard that cries
  wolf on a good tree re-teaches the fleet to ignore the word, which is worse
  than no guard. Section 4 of the guard suite runs the whole unsabotaged suite
  and fails on any occurrence of the phrase, on a nonzero rc, or on a summary
  that shows fewer than 100 passing assertions (a truncated suite is not a pass).
- **A broken fixture must be COUNTED, not only printed.** The guard asserts
  `FAIL: FIXTURE BROKEN` and a nonzero failed count in the summary, because a
  diagnostic nobody counts is the same silence in a louder font.
- **git's own stderr must survive.** The guard asserts the sabotage shim's own
  message appears in the suite's output. Re-adding a blanket `>/dev/null 2>&1`
  to any setup step turns it red.
- **Postconditions, not just rc.** The `kill-parent` case sabotages with a step
  that *reports success*, so any refactor that drops `fixture_assert` or the
  `branch -D` recheck in favour of rc alone fails immediately.
- **No assertion in the guarded suite was weakened.** The 113 existing
  assertions are unchanged; the `closed` and `typedred` messages gained the
  parent sha and the `git log --oneline HEAD` they actually saw, and nothing
  else in the file moved.
