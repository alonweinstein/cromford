# PR terminal state: `pr_closed` is not `pr_merged`

**What it is:** `bin/reconcile-prs.sh` asks GitHub what really happened to every
PR the console still lists as unmerged, and classifies on the MERGE FACT —
`mergedAt`, or gh's `MERGED` state — never on `state == CLOSED`. `CLOSED` is true
of every merged PR and of every abandoned one, so a lane that reads it reports
work that never shipped as shipped: project-4 #1579 (auto-closed when its base branch
was deleted) and #1541 (closed by a human as superseded) both reached the console
as merged/deployed rows.

A closed-unmerged PR has its own terminal, `pr_closed`:

| | merged | closed unmerged |
|---|---|---|
| console POST | `{"merged":[bkey]}` | `{"closed":[bkey]}` |
| jobs ledger | untouched by this lane | `kind=merge`, `key=<pr url>`, `status=closed` |
| ship beat (`bin/beat.sh`) | `ticket_shipped` | none — nothing shipped |
| deploy gate (`bin/deploy-request.sh`) | yes | none |
| the ticket | done | launchable again ([ticket-identity.md](ticket-identity.md) reads that ledger row) |

**How an operator reaches it:** `bin/reconcile-prs.sh` on the hub, every 10
minutes (`bin/lib/cron-lines.sh:103`). A PR closed inside `MC_CLOSED_SETTLE` is
skipped and re-read next pass — the merge conductor's CI kick closes and reopens
a PR, and this lane's answer is permanent
(`tests/closed-settle-guard-test.sh`).

**Write-vs-send order** is deliberate: the ledger row (an idempotent upsert on
the PR url) is written FIRST, then the console POST, then the log line. A failed
POST leaves the row in place and the next \*/10 pass re-sends, because the console
still lists the build as unmerged. The console repo is not in this one; until it
learns the `closed` key, a non-2xx answer is retried once with `merged` only and
the refusal is logged as `console refused closed list` rather than swallowed.

**How to drive it:**

| what | how |
|---|---|
| the classifier and both terminals, end to end | `HARNESS_TEST_SANDBOX=1 bash tests/reconcile-prs-closed-unmerged-test.sh` |
| the settle window that sits in front of it | `HARNESS_TEST_SANDBOX=1 bash tests/closed-settle-guard-test.sh` |
| project/slug resolution on the merged arm | `HARNESS_TEST_SANDBOX=1 bash tests/reconcile-prs-project-test.sh` |

**Files it owns on the hub:**

- `logs/reconcile.log` — `cleared CLOSED (unmerged) PR row <bkey> (<url>) as
  pr_closed — nothing shipped, the ticket is launchable again`, ONCE per row,
  and the per-pass summary `reconciled N externally-merged PR(s), M closed
  unmerged (pr_closed)`.
- `state/reconcile-closed/<bkey>` — the marker that makes that line once-per-row.
  Until the console learns the `closed` key the row keeps coming back on every
  `*/10` pass, and the ledger PUT and the console list are re-sent each time (a
  PUT that failed once self-heals); only the log line is news exactly once.
- the jobs ledger, kind `merge` — status `closed` rows, which
  `closeout_terminal` (`bin/lib/closeout-terminal.sh`) already reads as
  superseded and `bin/pr-owner-sweep.sh` already excludes from `live_keys`.

**The other writers of a PR terminal, all of which already read the merge fact
and are deliberately untouched:** `bin/merge-sweep.sh:655` (`closed` for CLOSED,
`merged` only for MERGED), `mc_settle_merged` in
`bin/lib/merge-conductor-lib.sh` (off a `state == MERGED` read),
`pr_state_rest` in `bin/fly-pool.sh` (reads `.merged` first),
`bin/batch-resolve.sh:465` (train members, after the merge sha exists),
`bin/pr-owner-sweep.sh:260` (`gh pr list --state merged`).

**What must never regress:** a PR with no `mergedAt` must never enter the merged
list; an OPEN PR and a PR gh could not answer for reach NEITHER list (absent is
not closed); the merged arm keeps its ship beat and its deploy gate; a box with
no `bin/jobs-client.sh` still reconciles, it just writes no ledger row.
