# Merge-sweep throughput (walk order + terminal-skip cache)

**What it is:** how the hub's tier-2 merge sweep decides WHICH build records it
looks at and WHICH refusals it re-derives. Three things live here: the walk
order (round-robin across projects, newest record first within a project, each
record visited once), the terminal-skip cache (a refusal whose cause is a static
property of the build record is decided once and read back until the record
changes), and the tick deadline. None of it touches a merge gate — the gates
between the review verdict and `gh pr merge` are unchanged.

**How an operator reaches it:** `bin/merge-sweep.sh`, run by `cron/hub.cron`
`6,16,26,36,46,56 * * * *` (`*/10`) on the hub, under `locks/merge-sweep.lock`
(`flock -n`, dedupe — a tick that finds the lock held exits). Output lands in
`logs/merge-sweep.log`; `logs/merge-sweep-cron.log` holds the cron's own stderr.

**How to drive it:**

| what | how |
|---|---|
| walk order, the cache, the summary, the deadline | `bash tests/merge-sweep-order-cache-test.sh` |
| a merge that really lands, and the enqueue-is-not-a-merge rule | `bash tests/merge-sweep-async-test.sh` |
| the record-only refusals never reach gh (E2E FAIL / absent / SKIP) | `bash tests/e2e-smoke-test.sh` |
| a repo no token can see is alerted, not silently skipped | `bash tests/merge-sweep-invisible-repo-test.sh` |
| the head-bound park (not cached, re-evaluated every tick) | `bash tests/head-bound-approval-test.sh`, `bash tests/headbound-outcome-test.sh` |
| the starved-PR explanation this log owes pipeline-health | `bash tests/pipeline-health-detectors-test.sh` |

A one-tick look at a scratch tree, no repo state touched:

```
T=$(mktemp -d); mkdir -p "$T"/{bin,logs,state,locks,flags} "$T/builds/pool-demo-K-1"
cp bin/merge-sweep.sh "$T/bin/sweep.sh"
echo "PR_CREATED https://github.com/o/r/pull/1" > "$T/builds/pool-demo-K-1/RESULT"
echo "VERDICT: APPROVE" > "$T/builds/pool-demo-K-1/review.md"
printf 'E2E: FAIL\n' > "$T/builds/pool-demo-K-1/e2e.md"
HARNESS="$T" bash "$T/bin/sweep.sh"; HARNESS="$T" bash "$T/bin/sweep.sh"
cat "$T/logs/merge-sweep.log" "$T/state/merge-sweep-terminal.txt"
```

Two ticks, ONE reason line (the second tick reads the cache), one cache entry,
and per tick a `tick -:` project line plus a `tick TOTAL:` line — the bucket is
`-` because a scratch tree has no `bin/fleet-conf.sh`.

**Files it owns on a live box:**

- `state/merge-sweep-terminal.txt` — the cache. One line per refusal,
  `<last-logged-epoch> <cause> <pr-url> <fingerprint>`. Causes:
  `no-approve-record`, `ledger-verdict-<V>`, `ledger-provenance-<p>`,
  `judge-provenance-record`, `e2e-fail`. The fingerprint is `stat` name+mtime+size
  over `RESULT`, `review.md`, `pipeline.log`, `e2e.md`, `reviewed-sha`. Pure
  cache: delete it and the sweep does one expensive tick and converges. Not in
  `bin/harden-state.sh`'s `LEDGERS[]` — it is rewritten in place on prune, and
  append-only (`+a`) would break that.
- `state/merge-sweep-done.txt` — unchanged: the ledger's write-through fallback,
  which means *handled forever*. The cache is deliberately not this file.
- `logs/merge-sweep.log` — per-PR reason lines (first occurrence, then once a
  day) plus, per tick, one `[merge-sweep] tick <project>: seen= merged=
  retryable= terminal-new= terminal-cached=` line per project that had a record
  and one `tick TOTAL:` line. Summary lines carry NO PR URL.

**Knobs:** `SWEEP_DEADLINE_SECS` (540; 0 expires immediately, which is the test
hook), `SWEEP_TERMINAL_RELOG_SECS` (86400), `SWEEP_TERMINAL_TTL_SECS` (604800),
and `SWEEP_MERGE_BUDGET` (5) merges per tick — that one has its own entry,
[merge-sweep-budget.md](merge-sweep-budget.md). All env, defaults in the script.

**What must never regress:**

- A **retryable** skip is never cached: `mergeState != CLEAN`, a head-bound park,
  a TIGHTENED review gate, a `REBASE_*` park, a CLOSED-not-settled PR, pre-arm
  rc 3, an invisible repo, a queue hand-off, a merge that failed despite CLEAN.
  Each flips with no change to the build record, so caching one strands a PR.
- A record whose `review.md` gains `VERDICT: APPROVE` after a BLOCK is
  re-evaluated on the next tick (fingerprint change).
- An absent or corrupt cache file, an absent `bin/fleet-conf.sh`, a `find` that
  cannot run — all fail OPEN to walking and re-deciding. The cache may never
  invent a reason to hold a mergeable PR.
- A starved PR still has an explanation in `logs/merge-sweep.log` at least once a
  day, because `bin/pipeline-health.sh:344` greps this log per PR and pages
  "sweep never logged this PR — the silent-skip shape" when it finds nothing.
- E2E asymmetry: only `E2E: FAIL` is terminal. Absent and `E2E: SKIP` are not
  failures and must reach the gh path.
- The project buckets come from `bin/fleet-conf.sh --projects`. A literal fleet
  list in this script is a hard fail (`tests/fleet-projects-not-hardcoded-test.sh`).
