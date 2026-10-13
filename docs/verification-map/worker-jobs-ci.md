# The jobs worker's tests are a gate (`worker-jobs` CI job)

**What it is:** the `worker-jobs` job in `.github/workflows/harness-ci.yml`. It
runs `worker/jobs`'s own suite — `npm test`, i.e. `node --test test/*.test.js`,
302 cases as of BH-1137 — and then asserts the run skipped nothing.

**Why it exists.** `worker/jobs/src/index.js` is the coordination API every box
reads and writes: `/api/settings`, `/api/flags`, `/api/lanes/*`, the job rows,
the live-events stream, and `schema.sql` underneath all of it. Until BH-1137
this workflow had exactly one JS job, `console-ui`, so those 302 cases ran
nowhere. A PR could break a route or the schema's idempotence and every check on
it stayed green — the suite existed, and gated nothing.

**How an operator reaches it:** every PR's CI run, and every push to main. There
is no cron lane, no flag and nothing to turn on. Locally:

```sh
cd worker/jobs && npm test
```

**Two things about this job that are deliberate:**

- **No `npm ci`.** `worker/jobs` declares no dependencies on purpose (its
  `package.json` says so) and therefore carries no `package-lock.json` — and
  `npm ci` exits nonzero without a lockfile. An install step that cannot
  succeed would paint this gate red on every PR for a reason that has nothing
  to do with the diff. `tests/harness-ci-worker-jobs.bh-1137-test.sh` asserts
  the absence, conditioned on the lockfile still not existing, so the day the
  worker grows dependencies the rule steps aside instead of blocking them.
- **A SKIP is a failure.** `test/settings-schema.test.js` calls `t.skip()` when
  `node:sqlite` cannot be imported (it is unflagged from Node 22.13). That skip
  is honest in TAP and invisible in a green job, so the job reads the summary
  the runner printed and refuses a run that skipped anything — or that passed
  zero tests, or whose summary it could not parse at all. Measured on
  `node:22` (v22.23.2): 302 passed, 0 skipped, tap reporter.

**How to drive it:**

| what | how |
|---|---|
| the workflow really runs the worker/jobs suite, never `npm ci`, and every worker package with a test script is named by a job (BH-1137) | `bash tests/harness-ci-worker-jobs.bh-1137-test.sh` |
| the skip guard, extracted verbatim from the workflow, accepts a clean spec- **and** tap-reporter run and refuses a skip, a zero-pass run and an unreadable summary | same suite, section 3 |
| the suite itself | `cd worker/jobs && npm test` |

**Files it writes on a live box:** none. The job runs only on a GitHub runner
and writes `$RUNNER_TEMP/worker-jobs.log`, which the guard reads in the next
step. Nothing under `state/`, `logs/` or `flags/` changes anywhere.

**What must never regress:**

- **A skipped test never reads as a pass.** Downgrading the guard to a warning
  puts the lane back where BH-1137 found it, one layer down.
- **The job stays offline.** No miniflare, no network, no secrets: the suite
  drives the worker's own `fetch` handler against a D1 stub and applies
  `schema.sql` through `node:sqlite`. A test that needs a real D1 belongs in a
  different lane.
- **A new worker with tests is covered before it lands.** The suite walks
  `worker/*/package.json` and fails on any package that declares a `test`
  script no job runs.
