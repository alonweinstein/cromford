# Merge-conductor read memo + cadence knob

**What it is:** the merge conductor used to make the same GitHub read several
times inside one tick, and to make again every tick the reads whose answer could
not have changed. Three stores fix that — a per-tick memo for the stacked-parent
list, and two cross-tick memos (the check-run word and the iron-law diff scan)
keyed on the PR's head sha, its `updated_at` and a fingerprint of the
conductor's own CI writes for that head. A fourth knob, `MC_TICK_SECS`, lets one
project tick less often than the `*/5` cron fires.

**How a user reaches it:** this lane has no UI. It runs on the hub from
`cron/lanes/410-merge-conductor.cron` (`*/5 * * * *`), and everything below is
read on the hub box.

**Key routes/screens (the operator surfaces):**
- `logs/merge-conductor.log` — one `<owner/repo> READ-MEMO tick=<id>
  stack_hits=<n> ci_skipped=<n> scan_skipped=<n>` line per project per tick.
  `stack_hits` is the stacked-parent list read a second child did not make;
  `ci_skipped` is a `actions/runs?head_sha=` read not made; `scan_skipped` is a
  PR diff not fetched.
- `logs/merge-conductor.log` — `TICK <project> held: its last tick started <n>s
  ago and mc_tick_secs=<n> … (decision=held)`, written ONLY for a project with a
  non-zero `mc_tick_secs` whose last tick is younger than it. A held project
  makes no GitHub read and writes no tick metrics.
- `logs/gh-rate.log` — `gh-etag lane=merge-conductor:<project> fetched=<n>
  cached=<n>`, the other half of the ledger: `cached` is the reads GitHub
  answered 304 because the conductor sent `If-None-Match`, which do not count
  against the primary rate limit.
- `state/merge-conductor/read-memo/<owner_repo_N>.{ci,scan}` — one line,
  `<head> <updated_at> <fingerprint> <epoch> <answer>`. Pruned after 3 days by
  `read_memo_gc`.
- `state/merge-conductor/tick/<tick-id>.memo-stack-<owner_repo#branch>` — the
  per-tick stacked-parent answer. Pruned by the existing `mc_tick_gc` (24 h).

**The knobs** (settings rows through the lane registry,
`catalog/lanes.d/merge-conductor.json`; the code default is the documented
fallback):

| knob | key | default | what it does |
|---|---|---|---|
| `MC_TICK_SECS` | `lane.merge-conductor[.<project>].mc_tick_secs` | 0 | seconds between real ticks of one project. 0 = every cron fire (today). The cron is `*/5`, so this can only LENGTHEN a project's cadence. |
| `MC_READ_MEMO` | `lane.merge-conductor[.<project>].mc_read_memo` | 1 | 0 is the kill switch: every read is made exactly as it was before the memo existed. |
| `MC_READ_MEMO_TTL_SECS` | `lane.merge-conductor[.<project>].mc_read_memo_ttl_secs` | 900 | how long a memoised terminal answer may stand. 900 s = three cron fires. |

Set one with
`bin/jobs-client.sh setting-set lane.merge-conductor.<project>.mc_tick_secs 600 "BH-1486"`,
and clear it by setting `0`.

**Preconditions / seed needs:** none beyond a hub with open harness PRs. The
memo is OFF by construction for a PR whose `updated_at` is unknown — the open PR
list emits `-` for it — so a box whose list read is degraded behaves exactly as
it did before this shipped.

**Verify it works:**
- Drive it: `HARNESS_TEST_SANDBOX=1 bash tests/conductor-read-memo.bh-1486-test.sh`
  (exit 0 = pass). It runs the whole `bin/merge-conductor.sh` against a stub
  `gh` that records every argv and counts the reads; the claim under test is the
  COUNT, not the presence of any string in the source.
- On the hub, after a deploy:
  ```
  grep -h 'READ-MEMO tick=' /root/harness/logs/merge-conductor.log | tail -n 40
  grep -h 'gh-etag lane=merge-conductor:' /root/harness/logs/gh-rate.log | tail -n 300 \
    | awk -F'[= ]' '{f+=$5; c+=$7} END {print "fetched(counted)=" f, "cached(304)=" c}'
  grep -h ' api repos/' /root/harness/logs/gh-calls/*.log | grep merge-conductor \
    | sed -E 's#[0-9a-f]{40}#SHA#g; s#/[0-9]+#/N#g' | awk '{print $4}' | sort | uniq -c | sort -rn | head
  grep -c 'UNVERIFIABLE' /root/harness/logs/merge-conductor.log
  ls /root/harness/state/gh-etag | wc -l
  ```
  The first two are the before/after ledger. The last one is the ETag cache's
  entry count against `GH_ETAG_MAX` (20000): well under it means no hot key is
  being evicted, and the answer is a condition to read, never a number to
  assume.

**Manual-only / not automatable:** the production before/after numbers. They
come from hub logs and cannot be produced on a pool machine or in CI; the
commands above are what produces them, and they are owed after deploy, not
before merge. The `actions/runs` reads go out as a bare `gh api`, not through
`gh_rest`, so they can never answer 304 — the memo, not the ETag cache, is what
takes them off the budget.

## Follow-up: what the keys must cover, and what a tick spent

Three things the first build left open, each pinned by
`tests/conductor-read-memo-keys.bh-1486-test.sh`.

**1. A memo key that carries a BRANCH name carries a digest.** `mc_safe_name`
maps every character outside `[A-Za-z0-9._-]` to `_`, which is right for the
names it was written for — a project slug and a PR NUMBER — and wrong for
`tick_memo_file`, which is keyed on a branch. `ticket/x_y` and `ticket/x/y` can
both exist in one repo and both flattened to `ticket_x_y`, so one stacked child
was served the OTHER branch's parent state — and the stacked arm ACTS on that
answer by retargeting the PR onto it. That file name now carries
`_mc_key_digest` of the raw key beside the readable safe name. `read_memo_file`
is keyed on `<slug>#<PR number>` and needs none: a number cannot collide.
Entries written before the change are missed once, which costs one read.

**2. The `scan` memo's key covers the scanner and the base.**
`mc_iron_law_scan` is not a pure function of the diff bytes: it is its own grep
PLUS every `CHECK-HIT` `bin/checks-run.sh` finds, and checks-run reads
`checks/*/check.sh`. Deploy a check to the hub and nothing in
`(head, updated_at, attempts)` moved, so a PR parked in READY went on replaying
the count the OLD catalog produced and could merge carrying a violation of a
check that was live at merge time. And a PR's `.diff` is
`merge-base(base, head)..head`, so when the project base moves the patch can
change with all three of those standing still. `scanner_fp` digests
checks-run, the classifier that holds the inline patterns, and every check in
the catalog, file names included, once per project per tick; `scan_memo_fp`
joins it with the attempts count and the base tip.

The scanner is MANDATORY — an unidentifiable scanner might be a newer one, and
replaying past a check that is now live is the unsafe direction, so
`scan_memo_fp` returns rc 1 and the memo is off for that PR. The base is not: a
stale base can only make the count too HIGH, because moving the merge base
forward removes added lines from a patch and never introduces one, so it parks
a PR that would now pass. It is also triply covered — a base move sets
`LAND_FIRE` and offers every open PR a rebase, a restack moves the attempts
count, and the entry expires at `MC_READ_MEMO_TTL_SECS`. So an unreadable base
contributes the word `nobase` rather than killing the memo on every box with
`MC_LAND_REBASE=0`.

`read_memo_put`'s fingerprint charset widened from digits to `[0-9a-z.]` to
carry all of that. The widening matters twice over: as a bare-integer check it
would have dropped the richer token silently, and a first cut that allowed only
`[0-9a-f.]` dropped `nobase` the same way — stored never, hit never, and
indistinguishable in review from a memo that is simply cold. The existing
`tests/conductor-read-memo.bh-1486-test.sh` section C is what caught it.

**3. The TICK line says what the tick SPENT.** `READ-MEMO … stack_hits=` counts
memo HITS, which judges the memo and not the bill: a hit on a read GitHub would
have answered 304 saves a round trip and no quota at all. BH-1486's acceptance
is counted calls per tick, so `mc_tick_reads` reads the ETag counter file the
project subshell already arms and `mc_tick_metrics` appends
`reads=N counted=M cached=K` to its line and `reads`/`reads_counted`/
`reads_cached` to `state/merge-conductor/tick-<project>.json`. `counted` is a
FLOOR on what the tick spent, never a ceiling: a non-2xx GET writes no counter
line, and neither does a non-GET write nor a raw `gh api` read such as
`mc_ci_state`'s. The `READ-MEMO` line is untouched — this adds a counter, it
does not replace one.


## PR snapshot (BH-4656.1)

The conductor and batch-resolve read their open-PR list through the shared PR
snapshot in `state/pr-snapshot/<owner_repo>/` (`bin/lib/pr-snapshot.sh`,
BH-4658). Each lane sources the lib after `lane_env_apply` and exports
`HPL_SNAPSHOT=1`. `bin/lib/gh-pr-list.sh` then takes the open list from
`prs_open_list`, one read shared by every lane inside `PR_SNAPSHOT_TTL_S`, and
each row's merge-state read from `prs_pr_get`, keyed on the row's head,
`updated_at` and base tip. A PR that has not changed since its last read is
answered from disk, but only when its stored `mergeable_state` is one CI cannot
change (`clean`, `dirty`, `behind`, `draft`). GitHub does not bump `updated_at`
on check-run or status events (the BH-1486 trap above), so a stored `blocked`,
`unstable` or `has_hooks` body is never served: `_hpl_state_get` drops its key
and the read goes live, and a `WAIT_CI` row sees its CI go green on the next
tick. The contract (`prs_pr_get`) still stores those states; it should stop,
or the `pr` wakes sibling should invalidate on `check_suite`/`status`, before
any other caller reads it. Drafts are never read, and `files` reads stay live. Each
project tick writes one `<owner/repo> PR-SNAPSHOT hit=<n> miss=<n>` line to
`logs/merge-conductor.log`, and the conductor calls `prs_gc` next to
`read_memo_gc`.

Branch tips come from `bin/lib/pr-snapshot-refs.sh`. `prs_branch_tip` makes one
`GET git/matching-refs/heads/<prefix>/` per prefix that an open PR uses and
caches the answer as `refs-<prefix>.json` for `PR_SNAPSHOT_TTL_S`.
`head_lag_tip` asks it after its per-tick memo. A refs tip that disagrees with
the PR head is confirmed by the live `branches/<br>` read before it can start a
lag clock. `mc_branch_exists` answers 0 on a refs hit with no probe. A miss
probes, so "gone" (rc 1) is still only ever a live 404.

The decision and readback reads stay live: `mc_pr_view`, `mc_rest_pr_json`,
`mc_pr_live_head`, and batch-resolve's train re-reads. The snapshot is a
separate store from `read_memo`, and neither one reads the other's keys.
`PR_SNAPSHOT=0` (settings key `lib.pr-snapshot.pr_snapshot`) puts back today's
live requests, including today's `pulls?state=open` page shape. Suites:
`tests/pr-snapshot-lanes.bh-4656-test.sh`, `tests/mc-branch-refs.bh-4656-test.sh`.
