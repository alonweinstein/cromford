# PR-list REST fallback

**What it is:** the shared `harness_pr_list` helper can page GitHub REST
(`repos/{owner}/{repo}/pulls`) once per page instead of running one GraphQL
`gh pr list` per author. When any requested `--json` field is not in the
mappable set, it falls back to the per-author loop unchanged.

**The REST page reads through `bin/lib/gh-rest.sh`, and a failure is FINAL
(BH-782).** A REST page that fails used to fall back to `gh pr list` — the very
call #768 caught exiting 0 and printing nothing under a GraphQL rate limit, so
an outage arrived at the caller as rc 0 with an empty list. It is now classified
and returned:

| rc | when |
|---|---|
| 0 | a 2xx array. `[]` is a REAL empty |
| 44 | HTTP 404 on the list — the token cannot see this repo |
| 75 | 403/429, any other non-2xx, a network failure, a 2xx with an empty or non-array body, or no `bin/lib/gh-rest.sh` on this box |
| 1 | the PER-AUTHOR path was used and every author failed **or answered empty** |

`harness_pr_list` returns that rc unchanged rather than flattening it to 1, so a
caller that wants to name the status (`bin/overlap-guard.sh` does) can.

**An empty per-author answer is a FAILED answer.** On the per-author path an
author must exit 0 **and** print something to count. `${out:-[]}` is gone: one
silent author used to be enough to answer the whole call rc 0 with a list, and
that is the shape that let `bin/overlap-guard.sh` launch on top of live work in
#768. All authors silent is rc 1.

**The per-author path itself stays**, for the fields REST list responses do not
carry (`files`, `mergeStateStatus`, `mergeable`, `isInMergeQueue`). Removing it
would answer 75 to four lanes that work today. That one surviving `gh pr list`
carries a `# gh-guard-allow:` line naming its callers; the file carries
`# gh-rest: no-graphql`.

**Rate-limit fall-through (BH-847):** a list that fails with a RATE-LIMIT shape
is retried ONCE on the next rung of the token ladder `bin/lib/gh-repo-token.sh`
owns (App installation token → default PAT → admin PAT), and one
`logs/gh-pr-list.log` line names the rung WORD that answered — never a token
value. From the `app` rung the next rung is `admin` when the default PAT cannot
see the repo, and `default` otherwise, so the one retry is never spent on a
credential that 404s. `GH_TOKEN` is restored to the caller's own on every exit
path. The classifier is narrow: `rate limit`, `ratelimit`, `HTTP 429` and
`too many requests` (in stderr or in a REST body `.message`) retry; a 404, a
permission refusal, bad credentials and a silent non-zero exit do not, and the
caller's single `gh_repo_list_failed` still fires once.

**How an operator reaches it:** the helper is sourced by cron lanes that list
harness-authored PRs. There is no UI.

**Primary lanes / scripts:**
- `bin/merge-conductor.sh` — open list at the classify step, closed list for
  close-out accounting.
- `bin/pipeline-health.sh` — open PR list for stale/close-out health.
- `bin/review-autopilot.sh` — open PR list for review targeting.

**The per-PR half is `mc_pr_view` (`bin/lib/mc/classify.sh`), not `mc_pr_read`.**
BH-597 originally added its own per-PR reader, `mc_pr_read`, to
`bin/lib/merge-conductor-lib.sh`. By the time that ticket rebased onto current
main, main had independently converted the same lanes' per-PR reads onto
`mc_pr_view <pr-url> <jq-expr>` (BH-783/BH-784, #966/#1157) — built on
`gh_rest`/`gh_rest_pr_state`/`gh_rest_pr_list`/`gh_rest_comment`/`gh_rest_close`
in `bin/lib/gh-rest.sh`, with a three-way `0`/`44`/`75` ok/absent/unverifiable
contract. Landing `mc_pr_read` on top would have put two live per-PR REST
readers with different failure contracts in the same lanes, so the rebase kept
`mc_pr_view` and dropped `mc_pr_read` and every call site BH-597 moved onto it.
`mc_pr_view` is the single per-PR reader for `bin/merge-conductor.sh`,
`bin/merge-sweep.sh` and `bin/blocked-resolver.sh` (the last through its own
`br_pr_field`/`br_pr_state` wrappers). See `docs/MERGE-CONDUCTOR.md` §7.3.

**Kept on GraphQL on purpose:** `isInMergeQueue` (`mc_inqueue`, `mc_queue_state`'s
`github|none` branch, `mc_enqueue_github`), `statusCheckRollup`
(`mc_mergify_check`'s fallback for a 403 checks API). `br_merged_prs_for`'s two
`gh pr list --search` reads have since moved to REST too (BH-783,
`gh_rest GET search/issues` — GitHub search has no `pulls` list form, so this is
a third budget, not the per-PR one above).

**What BH-597 did add, and what survived the rebase: every lane names its
credential.** `bin/merge-conductor.sh`, `bin/merge-sweep.sh` and
`bin/blocked-resolver.sh` each log, once per tick per repo (the resolver: once
per RUN), which credential a tick's `gh` calls ran on — the words
`App installation token` / `default PAT` / `admin PAT`, never a token value.
See `docs/MERGE-CONDUCTOR.md` §7.3.

**Knobs:**
- `HARNESS_PR_AUTHORS` — space-separated author set, default `operator app/cromford`.
- `GH_PR_LIST_REST_PAGES` — max REST pages to walk, default 3 (100 PRs/page).

**Mappable field set:** `number`, `url`, `title`, `body`, `headRefOid`,
`headRefName`, `baseRefName`, `isDraft`, `state`, `labels`, `author`,
`createdAt`, `updatedAt`, `mergedAt`, `closedAt`. Any other field keeps the
per-author GraphQL path.

**How to drive it:**
- `bash tests/gh-pr-list-test.sh` — covers REST happy path, the per-author path
  for unmappable fields, the 44/75 classification of a 404 / an empty 2xx body /
  a non-array 2xx body with NO GraphQL retry on any of them, page cap,
  `state=merged` mapping, and a mutation check on the array guard.
- `HARNESS_TEST_SANDBOX=1 bash tests/launch-gate-unknown.bh-782-test.sh` — §F
  drives the full rc table through the real library and asserts the stub never
  sees a `pr list` line after a REST failure; §E1/§E2/§E4 are the mutation
  checks that restore the GraphQL retry, restore `${out:-[]}`, and delete the
  rate-limit arm BH-847's rung retry fires from.
- `bash tests/harness-pr-authors-test.sh` — covers the per-author fallback and
  author-spelling matching that the REST path reuses.
- `bash tests/gh-budget-rest-test.sh` — the BH-597 credential-logging survivor:
  drives the real `bin/merge-sweep.sh` over main's `mc_pr_view` reads and its
  own credential ladder (block B), the conductor's and resolver's own token
  blocks by name (blocks C and D), plus the lock-hygiene regression over the
  real `run-triage.sh` / `triage-shard.sh` (block E — it asserts
  `lock_run_unheld`'s effect, it does not ship it; the mechanism is BH-651's
  `bin/lib/lock-hygiene.sh`). The resolver's and conductor's and sweep's own
  PR-state REST reads are covered where they are exercised in production —
  `tests/blocked-resolver-test.sh` and friends, `tests/merge-conductor-test.sh`,
  `tests/merge-rest-test.sh` — not here.
- `HARNESS_TEST_SANDBOX=1 bash tests/list-fallthrough.bh-847-test.sh` — covers the
  rate-limit fall-through: a limited App rung answered by the default PAT and by
  admin when the default PAT is blind, every rung limited (rc non-zero, one
  `gh_repo_list_failed`), a limit message in the REST body, the negative list
  (404 / permission / bad credentials / silent), `GH_TOKEN` restored on every
  path including unset, no token value in any log, and a mutation check that
  deletes the limit classifier.

**Preconditions / seed needs:** a GitHub repo with harness-authored PRs, or the
fixture `gh` shim in `tests/gh-pr-list-test.sh`.

**Verify it works:** `tests/gh-pr-list-test.sh` reports `41 passed, 0 failed` and
`gh-calls.txt` shows one `api repos/.../pulls` call per page for mappable fields.

**Manual-only / not automatable:** a live GitHub token with repo read access is
required outside the fixture suite.
