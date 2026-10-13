## 6. State

`state/pr-owners/<owner>_<repo>.json`, rewritten every run:

```json
{
  "repo": "example-org/project-5",
  "project": "project-5",
  "generated_at": "2026-09-15T16:20:03Z",
  "prs": {
    "907": {
      "number": 907, "state": "ORPHAN",
      "since": "2026-09-15T16:20:03Z",
      "reason": "head has been CONFLICTING for 40d (limit 14d)",
      "key": "TK-907", "author": "operator",
      "url": "https://github.com/example-org/project-5/pull/907",
      "dirty_since": 1754000000
    }
  }
}
```

- `since` means **the first tick this PR read this way**, not "now". It carries
  over while the state is unchanged, so "this has been ORPHAN for eleven days"
  is answerable from the file.
- `dirty_since` is remembered rather than recomputed. The first tick that sees a
  conflicting head with no record of one falls back to `updatedAt`, which is
  what makes `project-1` #630 (dirty since 2026-08-30) actionable on the
  first run instead of `PR_OWNER_STALE_DAYS` after it.
- The file is written even on a run that takes no action: it is the only durable
  record that these PRs were looked at at all.

### The D1 mirror, and which copy wins

The file is the ledger of record; `pr_owners` in the coordination DB is the warm
read-side that survives this box (`docs/DB-COORDINATION-SPEC.md`). Both halves
are in the per-repo loop, and both fail open:

- **After** the file is written (`mv -f` of the new state), `pr_owners_put
  <repo> <project> <state-file>` PUTs it — the body IS the file, with
  `complete:true` so D1 learns the full set this box owns. File first, row
  second, same as `bin/merge-sweep.sh`'s `sweep_record`. A dry run mirrors too:
  what `PR_OWNER_DRY_RUN=1` withholds is the GitHub writes, not the record.
- **Before** classification, `pr_owners_list <repo>` reads the rows back and
  overlays them onto the file — but a row only wins when
  `row.updated_at >= file.generated_at`. Those are two clocks in the normal
  case: `updated_at` is the worker's (`nowIso()`), `generated_at` is this box's,
  written when the sweep built the file. Same second-precision ISO format, so
  the string compare is a time compare, and the `>=` is biased toward the file —
  a box running ahead of the worker just makes the overlay a no-op, and the file
  is the record anyway. A file written after a PUT that failed therefore
  survives the stale row that PUT did not replace.
  An absent file is `{}`, its `generated_at` is `""`, and every row is `>= ""` —
  which is the back-fill a rebuilt box wants: `since` and `dirty_since` come
  home instead of restarting at now.
- The sweep never writes `updated_at`. The worker stamps it.
- Worker unreachable: one `pr-owners ledger unreachable … (degraded)` line in
  `logs/pr-owner-sweep.log` per run, the file is used alone, and the page is
  `bin/jobs-client.sh`'s existing once-a-day `harness-jobs unreachable` ALERTS
  line. There is no second alert. D1 with no rows for the repo is silent and
  normal.
- A `PR_OWNER_EXTRA_REPOS` repo has project `-` and reads and writes rows like
  any other.

Driven end to end in `tests/ledger-writethrough-test.sh`.

