# Blocked-resolver decisions over REST (`bin/blocked-resolver.sh`)

**What it is:** every GitHub read, search, comment and close this lane DECIDES
from goes through `bin/lib/gh-rest.sh` (the rc 0/44/75 contract — see
[gh-rest.md](gh-rest.md)), and the file carries the `# gh-rest: no-graphql`
marker that forbids a `gh pr` / `gh issue` / `gh run` call from ever coming back.

It exists because of #768 (2026-09-18 02:49-03:05Z). `gh pr view` speaks
GraphQL; the shared bucket ran out; the read answered an EMPTY STRING and every
decision here read that silence as a fact:

* `"$(gh pr view --json state)" = OPEN` was false, so `br_close_pr` said "nothing
  to close" and returned SUCCESS — and its callers then enqueued a duplicate
  build and stamped `ABANDONED` over PRs that were open the whole time;
* an empty merged-PR search read as "this ticket never merged", so the ladder
  rebuilt work that had already landed (seven tickets, 2026-09-14);
* an empty comments list read as "no findings", and a fix round with no
  findings, no conflict and no job log drops straight to REBUILD FRESH — which
  closes the PR. A PR was closed for being unreadable.

**The rule now:** rc 75 is UNKNOWN. The enclosing decision takes its "unknown"
path, says `UNVERIFIABLE (HTTP <status>)` in `logs/blocked-resolver.log`, spends
no counter, closes nothing, enqueues nothing, relabels nothing — and the same
park is offered again on the next tick, ten minutes later. rc 44 is ABSENT and
is acted on: a PR GitHub says does not exist is not a PR to close.

**How an operator reaches it:** `cron/hub.cron`, the `4,14,24,34,44,54` line
that runs `bin/blocked-resolver.sh`. Nothing else changes: the lane's rungs,
caps and terminals are the ones it already had.

**Primary lanes / scripts:**
- `bin/blocked-resolver.sh` — the `>>> br-rest` block (`br_pr_field`,
  `br_pr_state`, `br_pr_comment`, `br_issue_comment`) and the converted call
  sites: ticket-key derivation, the conductor hand-off read, `br_close_pr`,
  `br_merged_prs_for` (REST `search/issues` + a per-hit PR read),
  `br_already_merged`, `br_rerun_ci`, `br_findings`, the iron-law diff read, the
  adjudication and re-review comments, and the ticket comment.
- `bin/lib/gh-rest.sh` — the contract. HARD-required: a resolver whose reads
  are undefined functions answers rc 127, which is neither 44 nor 75 and would
  be read as "not open, nothing to close".

**The one allow-listed exception:** `br_ci_log`'s
`gh run view <id> --log-failed`, tagged `# gh-guard-allow: non-decision read,
feeds the agent brief only — the REST equivalent is a zip download`. It decides
nothing; it is tail of a job log pasted into a fix round's prompt.

**How to drive it:**
- `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-rest.bh-783-test.sh` — 121
  assertions over the real script: the helper rc matrix (open/merged/closed,
  404 → 44, 403/429/5xx/401/000/empty-2xx → 75, a null `head.ref` as EMPTY at rc
  0), the comment body going by FILE and never on argv, comment-then-PATCH-then-
  verify ordering, a 2xx PATCH whose re-read still says open being 75, the
  merged guard and the merged search taking no rung on an unverifiable answer,
  the rebuild deferring on a close GitHub refused and landing on the next tick,
  ABANDONED never stamped over a PR that is still open, unreadable findings
  never becoming a rebuild, an unreadable diff never buying an adjudication, a
  refused CI re-run spending nothing, plus three mutants.
- `HARNESS_TEST_SANDBOX=1 bash tests/gh-no-graphql-decision-guard-test.sh` — the
  marker guard, which now scans this file too.
- `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-test.sh` and the
  per-ticket resolver suites (`blocked-resolver.bh-488/541/614/948/950/980/1122`,
  `resolver-hold`, `resolver-per-project-budget.bh-870`, `rebuild-ledger.bh-946`,
  `conductor-sticky-handoff`) — the lane's existing behaviour, unchanged, with
  their `gh` stubs answering the `gh api -i` envelope through
  `tests/lib/gh-rest-stub.sh`.

**Preconditions / seed needs:** `jq` on PATH. The suites need no token and no
network: `gh` is a stub that replays fixture responses.

**Verify it works on a live hub** (read-only):

```bash
# 1. the marker is on the file and the guard is green
grep -qx '# gh-rest: no-graphql' /root/harness/bin/blocked-resolver.sh && echo marked

# 2. the lane's decision reads are REST. After a tick, its gh calls are
#    `api -i -X …`; a `pr view` / `pr list` / `pr close` line is a regression.
grep -cE '(^|[^a-zA-Z_])gh (pr|issue) ' /root/harness/bin/blocked-resolver.sh   # 0

# 3. what an unverifiable read looks like when it happens
grep -n 'UNVERIFIABLE' /root/harness/logs/blocked-resolver.log | tail -5
```

A line in (3) is the lane saying it declined to decide. It must be followed, on
a later tick, by the same park being handled — never by a close, a rebuild or an
ABANDONED stamped in between.
