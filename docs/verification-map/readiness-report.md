# Repo readiness report + the enrolment gate

**What it is:** `bin/readiness-report.sh`, a deterministic grade (level 0–5) of
whether this harness can build, test, review, QA and ship a repo unattended, and
`bin/load-project.sh --require-readiness <n> --repo-dir <checkout>`, which
refuses to enrol a repo below that level. No model is called. The level
definitions are config — `catalog/readiness-levels.json`, with a builtin copy in
the script as the documented fallback. Full reference: [docs/READINESS.md](../READINESS.md).

**How an operator reaches it:** no cron lane, no lock, no registry row — it is
invoked by hand, from a checkout or from `/root/harness`.

```sh
bin/readiness-report.sh /root/repos/<project>                 the table
bin/readiness-report.sh /root/repos/<project> --json          the object load-project reads
bin/readiness-report.sh --print-levels                        the resolved level table
bin/load-project.sh <owner/repo> --require-readiness 4 --repo-dir <checkout>
```

**Reading the output:** one row per check (`pass` / `fail` / `unknown` /
`skipped` / `na`), then the gaps ascending by level, then — always as the LAST
line of stdout — `READINESS LEVEL: n/5`. rc is **0 whenever a report was
produced**: the level is data, not an exit code. rc 2 is usage (no repo dir, an
unreadable one, an unknown flag, an unreadable `$READINESS_LEVELS`, a level table
naming a check that does not exist). The gate's rc 3 is a refusal.

**How to drive it:**

| what | how |
|---|---|
| every check, every status, the level math, `--json`, `--no-run`, the gh probes | `bash tests/readiness-report-test.sh` |
| the gate refuses before the first write, and is inert at its default | `bash tests/load-project-readiness-gate-test.sh` |
| the builtin level table still equals the catalog copy | section A1 of `tests/readiness-report-test.sh` |
| the suites read no clock and no dice | `bin/test-determinism-lint.sh tests/readiness-report-test.sh tests/load-project-readiness-gate-test.sh` |
| it on a real checkout | `bin/readiness-report.sh /root/repos/<project>` |

**Files it names on a live box:** none. The report writes stdout and a `mktemp -d`
it removes on exit. No state file, no ledger, no lock, no watermark. The gate
persists nothing either — a refusal leaves `fleet.conf`, the prompt, the crontab
and the box untouched, which is the property `F1` asserts.

**Knobs:** `READINESS_TEST_TIMEOUT` (seconds, default 600), `READINESS_GH`
(`0` = ask GitHub nothing), `READINESS_LEVELS` (a level table, used as given).
No new required env var anywhere.

**What must never regress:**

- **`unknown` is a third status.** A probe that could not run — `gh` unauthed,
  `npm` absent, `node_modules` missing — must never read as `pass` and never as
  `fail`. Sections D1–D3 and C1–C3 exist for exactly this, and a report whose
  failure mode is a quiet yes would hand the fleet the repos it cannot build.
- **The builtin level table equals `catalog/readiness-levels.json`.** A1 diffs
  them. A drifted fallback means a repo's level depends on which box read it.
- **The gate runs before the first `gh` call.** Below it the command writes a
  `fleet.conf` row, a prompt, a commit, a push and a box bootstrap; a repo
  refused halfway through is worse off than one nobody touched. F1 drives the
  real script with a `gh` stub and fails if the stub is ever reached.
- **The default is inert.** Without `--require-readiness`, the gate block does
  not run and does not invoke the report (F3), so nothing changes for a project
  loaded before this existed.
- **A test-run timeout is a `fail`.** "We never found out" would let a suite that
  never finishes reach the level that talks about unattended merge (C3).
- **The level is never an exit code.** rc 0 with `READINESS LEVEL: 0/5` is a
  successful report about an unready repo; B1 pins it.
- **No level requires an info-only check.** `context.codegraph` and
  `context.conventions` are reported and can never appear in `gaps` (B11).
