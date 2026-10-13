# Flaky tests — detect from run history, quarantine, one rerun

**Asked for by the operator, 2026-09-12:** *"nothing today separates red because broken
from red because flaky; each flake costs a fix round, a re-review, or (soon,
under Mergify batches) a queue ejection. Build flaky detection + quarantine that
is DATA-driven."*

Before this, every red was the same red. `mc_ci_state` sees a failed run on a
head, the merge conductor records a strike, two strikes on two heads park the PR
for a human — and none of it knows whether the test that failed has failed
randomly nine times this fortnight. The fleet has been paying that bill blind:
no count, no name, no rate, so "CI is flaky lately" has never been something
anyone could point at.

---

## The signal: the head sha

A head sha **is** a tree. Two runs of the **same workflow** on the **same head**
are the same code, the same lockfile, the same workflow file, run twice. If one
concluded `failure` and one concluded `success`, the code did not change between
them, so the difference is the test, the runner, or the network.

That is the whole definition, and the sha is what makes *"with no push in
between"* a fact rather than a guess: a push produces a different sha and
therefore a different group. (Mergify's CI Insights draws the same line — same
commit, differing results — which is confirmation this is the right primitive,
not a shortcut.)

Three outcomes, not two:

| kind | what it means | where it counts |
|---|---|---|
| `flake` | same workflow went **both** red and green on this head | numerator of the rate; evidence for quarantine |
| `red` | red on this head, never green on it | denominator of the rate |
| *(neither)* | `cancelled` / `skipped` / `neutral` | ignored — an operator pressing stop is not evidence |

**Both kinds go in the same table.** A flakes-only table can tell you a number
went up and nothing else; *flaky reds over all reds* is the measure anyone would
act on, and a denominator kept somewhere else is a denominator that stops
matching its numerator the first time one of the two writers changes.

**The unit of evidence is the HEAD**, never the run and never the row. A head
that was re-run nine times is one piece of evidence about one test. Every count
downstream — the known-flake set, the quarantine threshold, the 7-day rate — is
over DISTINCT heads, and the ledger's primary key `(repo, workflow, test, head)`
is what enforces it: re-scanning an overlapping window upserts the same keys and
changes no count.

---

## What we deliberately do NOT build, because Mergify already has it

| Mergify | Us |
|---|---|
| `queue_rules[].max_checks_retries` — retries a queue entry's CI on a fresh draft PR before ejecting it | nothing. The queue is Mergify's; the harness must not re-run inside it |
| `merge_queue.skip_intermediate_results` — ignores an intermediate batch failure when a later batch passes | nothing |
| CI Insights flaky detection + quarantine — needs a per-repo plugin (`pytest-mergify`, `@mergifyio/vitest`, …) and JUnit upload, and reruns tests on its own CI budget | nothing |
| — | **the PR's OWN checks, before it is ever enqueued** — which is where the harness counts its red strikes, and which no Mergify feature touches |

So the harness stops at the queue boundary. Everything below reads run history
GitHub already keeps, in every repo, for free.

---

## The pieces

### `bin/lib/flaky.sh`
The one definition of a flake, the failing-test-name parser, and the known-flake
set read from the ledger. Sourced by the detector, the quarantine proposer and
the merge conductor; a second copy of any of it is a bug.

The parser handles what the fleet's repos actually run — vitest `× name 42ms`
and ` FAIL src/x.test.ts > suite > name`, jest `● Suite › name` — and never
matches a PASSING marker (`✓`, `↓`). When a log carries no name we can read, the
row records `job:<failed job name>`; when even that is unavailable,
`workflow:<path>`. Those still count as reds (dropping them would quietly shrink
the denominator and make the fleet look less flaky than it is) but can never
become quarantine entries, because no test runner will match a name shaped like
that.

### `bin/flaky-detect.sh <project> [--dry-run] [--days N] [--min N]`
Pages the repo's workflow runs for the window, classifies every red head, names
what failed, writes the rows, prints the table. Read-only against GitHub; the
only writes are ledger rows, and `--dry-run` writes nothing at all.

```
flaky-detect example-org/project-3 — window 14d since 2026-08-29
  red heads: 23   flaky: 7   flake rate: 30%   this run: 3 flake / 6 red group(s), 14 row(s)

  heads  workflow                                test (>=3 heads = quarantine candidate)
* 4      .github/workflows/ci.yml                queue > drains under load
  2      .github/workflows/e2e.yml               nav > opens the client drawer
```

### `bin/flaky-quarantine.sh <project> [--apply]`
Proposes entries for the repo's `ci/flaky.txt` — every test at or above `--min`
(default 3) distinct flaky heads in the window that is not already listed.

**Dry-run by default, and that is the safety model.** Quarantining a test makes
it stop failing the build, so an automatic quarantine is a machine that can
silently switch off a repo's own alarms. Nothing is written until someone types
`--apply`, and even then it only opens a **pull request** on a new
`chore/quarantine-flaky-*` branch. A human merges it, sees the diff, and owns
the decision. It never pushes a default branch and never merges.

### The merge conductor
`mc_flake_rerun` (in `bin/lib/merge-conductor-lib.sh`, called from the REDS
lines of `bin/merge-conductor.sh`): a red whose failing tests are **all** known
flakes buys **one** `gh run rerun --failed` per `(PR, head)` **instead of** a
red strike. Guarded like the rebase and the re-review, on `MC_ATTEMPTS`.

Not counting reds is the cheapest possible way to stop flaky CI blocking
merges, and it is also how a genuinely broken build gets auto-merged. So all of
these must hold:

- every failing test on the head is already in the ledger as a flake on at
  least `FLAKY_MIN` **other** heads — one unknown failure alongside a known
  flake makes it an unknown red;
- we could **read** what failed — a red we cannot name fails closed, because
  "we could not tell what broke" must never read as "nothing real broke";
- one rerun per `(PR, head)`. The second red on that head is a real red and
  takes its strike, so the existing red-twice budget is untouched: this buys a
  retry, never forgiveness;
- actions mode only. `gh run rerun` is a write, so observe-only counts every
  red exactly as it does today.

`gh run rerun --failed` re-runs the failed jobs *inside the same run*, so the
run's own conclusion flips — which is why `mc_ci_state` needs no special case.

**The rerun is no longer flake-only (2026-09-15, project-5 #1045).** `WAIT_CI
checks red once` had no next transition, so a PR that went red and was never
pushed to again sat there for ever. `mc_red_rerun` applies exactly the
mechanics above to **any** red — one `gh run rerun --failed` per `(PR, head)`,
actions mode only, recorded in `MC_ATTEMPTS` as `cirerun <key> <head> <epoch>`
— and a head that is still red after it becomes `RED_TWICE`, which
`bin/blocked-resolver.sh` owns (docs/MERGE-CONDUCTOR.md section 3).

**What that does NOT change is the bookkeeping on this page.** The five bullets
above are about *forgiveness* — whether the red takes a strike — and every one
of them still holds: only an all-known-flake, readable red skips its strike.
`mc_red_rerun` buys a retry for a red that has **already** taken its strike, and
the two share one mark, so a head gets one rerun whichever path bought it.

**Batch-attributed rows (BH-3776).** When the BH-636 re-entry arm re-queues a
PR because its Mergify batch went red on something that is not its own
(`bin/lib/mc-foreign-red.sh`), each failing test name that is not a `job:` name
and is either already in `flaky_gate_set` or was passed by a later batch of the
same workflow on the same main is written with `metric_flake … flake`. A test
file in the PR's own diff (or tied to it by the test-impact map) is never
written: that verdict is `own`, and a later batch's pass does not change it. An
`always`/`full` suite from the map is never written either: it runs for every
diff, so a pass elsewhere says nothing about this one. The row
is keyed on the **batch draft's head sha**, which is the tree that went red, so
a repeat is the same upsert. A failed write is one conductor log line; it never
blocks the requeue. An attributed failure with neither kind of evidence writes
nothing.

### `bin/pipeline-health.sh` — the flake-rate line
Hourly, DB-only (no GitHub call — the detector already paid for that scan):

```
flake rate 7d (flaky reds / all reds, distinct workflow+head): example-org/project-3 7/23 (30%)  example-org/project-4 1/9 (11%)
```

One line in `logs/pipeline-health.log`, **never an ALERTS page**. Nobody has
decided yet what rate is too high, and a threshold invented here would train
people to skim the alert stream — which is the thing that lane exists to
protect. Measure first; page when there is a number worth paging on.

---

## The `ci/flaky.txt` convention (product repos)

A plain text file at the repo root, one test name per line as the runner reports
it, `#` for comments:

```
# Quarantined flaky tests — retried, not ignored. See docs/FLAKY-TESTS.md.
# DELETE a line once the test is fixed: this file is a debt list, not a config.
queue > drains under load
Auth › rejects an expired token
```

**Why a file in the product repo and not a row in our DB:** the list has to be
readable by the repo's own runner, on a laptop, with no harness and no network.
A committed file is reviewable in the PR that adds it, greppable, and shows up
in `git blame` when someone asks why a test stopped failing.

**Quarantine means RETRY, not skip.** A test that fails every attempt still
fails the build. A quarantine that skipped would be a way to delete coverage
without deleting a test, which is exactly the move a reviewer should block.

### The runner snippet (vitest)

*Not applied to any product repo by this change — this is the documented shape
for whoever opens that PR.* Add to the repo's setup file
(`test.setupFiles` in `vitest.config.ts`):

```ts
// vitest.quarantine.ts — retry tests listed in ci/flaky.txt, never skip them.
import { readFileSync } from 'node:fs';
import { beforeEach } from 'vitest';

const QUARANTINED = (() => {
  try {
    return new Set(
      readFileSync('ci/flaky.txt', 'utf8')
        .split('\n')
        .map((l) => l.trim())
        .filter((l) => l && !l.startsWith('#')),
    );
  } catch {
    return new Set<string>();   // no file, no quarantine — never fail the run over it
  }
})();

beforeEach((ctx) => {
  const name = ctx.task.name;
  const full = `${ctx.task.suite?.name ?? ''} > ${name}`.trim();
  if (QUARANTINED.has(name) || QUARANTINED.has(full)) {
    ctx.task.retry = 2;                       // retried, NOT skipped
    ctx.task.meta = { ...ctx.task.meta, quarantined: true };   // the reporter tag
  }
});
```

The `meta.quarantined` tag is the half that keeps this honest: a reporter reads
it so a quarantined test that passed **on a retry** is visible in the run
summary rather than silently green. Minimal reporter:

```ts
// vitest.quarantine-reporter.ts
import type { Reporter } from 'vitest/node';

export default class QuarantineReporter implements Reporter {
  onFinished(files = []) {
    const retried = files.flatMap((f) => f.tasks ?? [])
      .filter((t: any) => t.meta?.quarantined && (t.result?.retryCount ?? 0) > 0);
    if (retried.length) {
      console.log(`\n  ${retried.length} quarantined test(s) passed only on a retry:`);
      for (const t of retried as any[]) console.log(`    - ${t.name} (attempt ${t.result.retryCount + 1})`);
    }
  }
}
```

**Unverified against a real repo.** Both snippets are written from the vitest
API and have not been run in any of the fleet's repos by this change, because
this change does not touch product repos. Whoever opens the first `ci/flaky.txt`
PR should prove the retry actually fires — the honest way is to add a test that
fails on its first attempt and passes on its second, watch it go red without the
setup file and green with it, and put that output in the PR body. Jest's
equivalent is `jest.retryTimes(2)` in a setup file, gated on the same list.

---

## Auto-quarantine of this repo's own suites (BH-3686)

`bin/flaky-tier.sh` runs once a day on the hub (09:20Z, after `flaky-detect` has
written the ledger at 05:40Z). It only looks at this repo's own `tests/*.sh`
suites. One tick does this:

1. Reads every `flaky_quarantine` row for the repo. If the worker does not answer,
   it sends one warn alert (`flaky-tier-rows-unreadable`) and stops. Nothing is
   quarantined, released or projected on a tick that cannot see the rows.
2. Reads the flake ledger for the window and counts distinct flaky heads per
   suite. It keeps only `kind=flake` rows for suites that still exist. For a suite
   with an INACTIVE row, only heads from the day after that row's `updated_at`
   count, so a release or a `/ci` toggle starts the count over. A candidate has
   `FLAKY_TIER_MIN` heads or more and no active row.
3. More than `FLAKY_TIER_MAX_NEW` candidates in one tick looks like a runner or
   infra problem, so it quarantines none of them and sends one critical
   `flaky-tier-mass:<slug>` alert. A protected candidate gets a critical
   `flaky-protected:<suite>` alert and nothing else. That alert resolves once the
   suite's count drops below `FLAKY_TIER_MIN`.
4. For each remaining candidate it files the ticket FIRST: it searches every
   page of open issues for `<!-- harness-flaky-quarantine: <suite> -->`, reuses
   an open match, or files `Flaky suite quarantined: <suite>` with the `ai-build`
   label. It reads the label back and adds it once if needed. Only then does it
   write the active row (actor `flaky-tier`, reason `... fix #<n>`). If the
   search is not a clean read (rate limit, 5xx, the 1000-issue cap), it skips the
   suite. A failed create writes no row. There is no quarantine without its ticket.
5. Release is `ft_release` in `bin/lib/flaky-tier-release.sh` (the rules are in
   its header). When it releases nothing, its reason lines go into
   `logs/flaky-tier.log` before the tick line.
6. Projects the active rows, minus suites that no longer exist and minus
   protected ones, into the `CI_QUARANTINE` Actions variable, sorted and
   space-separated (`-` when empty, because a variable cannot be empty). It uses
   `GH_ADMIN_TOKEN` (the env or `github-admin.env`) on those calls only, and never
   logs it. It POSTs on 404, PATCHes on a different value, and does nothing when
   the value is equal. A failure sends a warn `flaky-tier-projection:<slug>` alert,
   and CI keeps the old value until the next tick.
7. Writes one line to `logs/flaky-tier.log`:
   `flaky-tier <slug>: candidates=… quarantined=… protected=… released=… projection=<same|updated|failed|skipped>`,
   with ` [dry-run]` appended on a dry run. `skipped` only appears on the step-1 stop.

**Overriding it.** The `/ci` screen toggles the same rows. Turning a row off
releases the suite, and because of the cutoff in step 2 the lane only
re-quarantines it on fresh flakes after that day. Turning one on by hand is
projected like any other active row.

**Protected suites** never get auto-quarantined. These come from
`catalog/test-quarantine-protected.txt` (exact paths and globs), plus the `guard`
rows in `catalog/test-tiers.tsv`, `catalog/test-impact-always.txt` and
`catalog/nightly-strict.txt` (`tp_protected` in `bin/lib/test-protected.sh`). If
the list cannot be read, every suite counts as protected.

**By hand:** `bin/flaky-tier.sh cromford --dry-run` prints every decision as
`would: …` and writes nothing. So does `FLAKY_TIER_ACT=0`. The switch is
`bin/harness-ctl.sh off flaky-tier` (flag `lane-off-flaky-tier`).

| env | default | read by | what it does |
|---|---|---|---|
| `FLAKY_TIER_MIN` | 3 | flaky-tier | distinct flaky heads before a suite is quarantined |
| `FLAKY_TIER_WINDOW_DAYS` | 7 | flaky-tier | days of ledger read per tick |
| `FLAKY_TIER_MAX_NEW` | 3 | flaky-tier | more candidates than this in one tick quarantines none |
| `FLAKY_TIER_ACT` | 1 | flaky-tier, ft_release | 0 = dry run |
| `FLAKY_TIER_REPO` | `example-org/cromford` | flaky-tier | the repo, unless the argument is a slug |
| `FLAKY_TIER_RELEASE_CLEAN` | 5 | ft_release | clean nightly runs in a row that lift a quarantine |
| `FLAKY_TIER_RELEASE_ACTORS` | `flaky-tier main-red-bisect` | ft_release | only these actors' rows are auto-released |
| `FLAKY_TIER_NIGHTLY_RUNS` | 10 | ft_release | recent nightly runs read |

A knob value that is not a positive integer falls back to its default, and the
tick says so. They are settings rows (`catalog/lanes.d/flaky-tier.json`), except
`FLAKY_TIER_REPO`: a repo is an identity, so it is registered with `settable: false`
and only the box's env moves it.
Tests: `tests/flaky-tier.bh-3686-test.sh`.

---

## Tuning

| env | default | what it does |
|---|---|---|
| `FLAKY_WINDOW_DAYS` | 14 | detection / known-set window |
| `FLAKY_MIN` | 3 | distinct flaky heads before a test is "known flaky" |
| `FLAKY_LOG_MAX` | 2000000 | bytes of `--log-failed` read per run; 0 disables log parsing (job names only) |
| `FLAKY_TESTS_MAX` | 20 | failing test names recorded per run |
| `FLAKY_PAGES` | 5 | run-listing pages per repo (100/page) |
| `FLAKERATE_EVERY` | 3600 | seconds between pipeline-health rate lines |

## Ledger

`ci_flakes` in harness-jobs D1 (`worker/jobs/schema.sql`), PK
`(repo, workflow, test, head)`, additive as everything in that file is.
`PUT /api/metrics/flakes` upserts, `GET /api/metrics/flakes?repo=&since=&limit=`
reads. Shell: `bin/jobs-client.sh metric-flake` / `metric-flakes`.

## Tests

`tests/flaky-detect-test.sh`, `tests/flaky-quarantine-test.sh`,
`tests/flaky-rerun-test.sh`, `tests/pipeline-health-flake-rate-test.sh`, and the
`ci_flakes` cases in `worker/jobs/test/index.test.js`. Run the shell ones under
`bin/run-tests-in-docker.sh` — several use GNU `date`.

## Harness suite names (BH-3686.2): known limits

`flaky_parse_tests` (`bin/lib/flaky.sh`) now also names cromford suites. It
reads the `--- tests/<x>.sh rc=<n> <secs>s` line that `bin/test-trace-safety.sh
--gate` prints for every suite, and only for a nonzero rc. So a cromford red
lands in `ci_flakes` as `tests/<x>.sh` instead of `job:<shard>`. Pinned by
`tests/flaky-parse-harness.bh-3686-test.sh`.

- **`FLAKY_LOG_MAX` can cut the line off.** `flaky_run_tests` reads at most
  `FLAKY_LOG_MAX` bytes (2 MB by default) of a run's `--log-failed`. If a shard's
  log runs past that before its `--- … rc=` line, that suite is not named. If no
  name survives, the row is `job:<shard>`, as before. The knob is settable.
- **`mc_flake_rerun` now covers cromford reds.** The BH-2632 known-flaky
  rerun applies to them for the first time: a red whose failing suites are all
  known-flaky or quarantined gets the one rerun instead of a strike. It is still
  one rerun per head.
- **`bin/flaky-quarantine.sh` may propose `tests/*.sh` names** when run by hand
  on cromford. It is dry-run by default, and `--apply` only opens a PR.
